import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ParloCore
import Tokenizers

/// AI cleanup on Qwen3 4B Instruct 2507 (4-bit MLX), run inside Parlo: nothing leaves the Mac, no server needed.
/// Owns the model's files and, while cleanup uses it, the model loaded in memory.
@MainActor
public final class LocalLLM {
    public let files: Installable
    /// Whether AI cleanup is set to this model: it stays loaded only while it is.
    public var inUse = false {
        didSet { if inUse != oldValue { sync() } }
    }

    /// Work running with the model held in memory even when cleanup doesn't use it, such as meeting notes.
    private var holds = 0
    private var keepsLoaded: Bool { inUse || holds > 0 }

    let directory: URL
    private let loaded = SharedLoad<URL, ModelContainer>()

    public convenience init() {
        self.init(directory: HubSnapshot.directory(CleanupModel.folder))
    }

    init(directory: URL) {
        self.directory = directory
        files = Installable(
            isInstalled: { HubSnapshot.isInstalled(directory) },
            install: { try await HubSnapshot.install(
                CleanupModel.repo, to: directory, matching: ["*.safetensors", "*.json", "*.jinja", "*.txt"], progress: $0
            ) },
            uninstall: { try HubSnapshot.uninstall(directory) }
        )
        files.onChange = { [weak self] in self?.sync() }
    }

    public var client: LocalLLMClient { LocalLLMClient(llm: self) }

    func container() async throws -> ModelContainer {
        guard HubSnapshot.isInstalled(directory) else { throw LocalLLMError.notInstalled }
        let directory = directory
        // A one-off call (the connection test) doesn't keep the model in memory.
        guard keepsLoaded else { return try await Self.load(directory) }
        return try await loaded.value(directory) { try await Self.load(directory) }
    }

    /// Runs `work` with the model loaded once for all its requests, then frees it unless cleanup uses it.
    public func keepLoaded<T: Sendable>(during work: () async throws -> T) async throws -> T {
        holds += 1
        sync()
        defer {
            holds -= 1
            sync()
        }
        return try await work()
    }

    /// Frees the memory the model holds, about its size on disk.
    private func unload() {
        loaded.clear()
        Memory.clearCache()
    }

    /// Loads the model in the background so the first cleanup is fast, or frees it when cleanup stops using it.
    private func sync() {
        guard keepsLoaded, files.state == .installed else {
            if !loaded.isEmpty { unload() }
            return
        }
        let directory = directory
        loaded.start(directory) { try await Self.load(directory) }
    }

    private nonisolated static func load(_ directory: URL) async throws -> ModelContainer {
        try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
    }
}

/// Cleanup and command mode on the local model.
public struct LocalLLMClient: ChatCompleting {
    let llm: LocalLLM

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        let llm = llm
        let reply: String
        do {
            // A load cut short by the timeout keeps going, so the next cleanup finds the model ready.
            reply = try await Deadline.run(seconds: timeout) {
                let container = try await llm.container()
                let session = ChatSession(container, instructions: system, generateParameters: GenerateParameters(temperature: 0))
                return try await session.respond(to: user)
            }
        } catch is DeadlineExceeded {
            throw LocalLLMError.timedOut
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}

public enum LocalLLMError: Error, LocalizedError {
    case notInstalled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Download \(CleanupModel.displayName) in Settings → AI"
        case .timedOut: "\(CleanupModel.displayName) took too long"
        }
    }
}

/// mlx-swift-lm takes any tokenizer; this adapts swift-transformers', which reads the model folder's chat template.
struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
