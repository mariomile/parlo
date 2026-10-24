import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ParloCore
import Tokenizers

/// AI cleanup on Qwen3 4B Instruct 2507 (4-bit MLX), run inside Parlo: nothing leaves the Mac, no server needed.
public enum LocalLLM {
    static let repo = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    public static let displayName = "Qwen3 4B"
    public static let sizeLabel = "~2.3 GB"

    static var directory: URL {
        SettingsStore.appSupportDirectory.appendingPathComponent("Models/qwen3-4b-instruct-2507-4bit", isDirectory: true)
    }

    static func isInstalled(at directory: URL) -> Bool {
        ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Loads the model in the background so the first cleanup is fast. Does nothing until it's downloaded.
    public static func warmUp() {
        guard isInstalled(at: directory) else { return }
        Task { _ = try? await loaded.container(directory) }
    }

    /// Frees the memory the model holds, about its size on disk.
    public static func unload() {
        Task { await loaded.unload() }
    }

    static let loaded = LoadedLLM()
}

/// The model kept in memory between cleanups; concurrent callers share one load.
actor LoadedLLM {
    private var current: (directory: URL, load: Task<ModelContainer, any Error>)?

    func container(_ directory: URL) async throws -> ModelContainer {
        if let current, current.directory == directory { return try await current.load.value }
        let load = Task {
            try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        current = (directory, load)
        do {
            return try await load.value
        } catch {
            if current?.directory == directory { current = nil } // let the next cleanup retry
            throw error
        }
    }

    func unload() {
        current = nil
        Memory.clearCache()
    }
}

/// Cleanup and command mode on the local model.
public struct LocalLLMClient: ChatCompleting {
    let directory: URL

    public init() {
        directory = LocalLLM.directory
    }

    init(directory: URL) {
        self.directory = directory
    }

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        guard LocalLLM.isInstalled(at: directory) else { throw LocalLLMError.notInstalled }
        let directory = directory
        let reply = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // A load cut short by the timeout keeps going, so the next cleanup finds the model ready.
                let container = try await LocalLLM.loaded.container(directory)
                let session = ChatSession(container, instructions: system, generateParameters: GenerateParameters(temperature: 0))
                return try await session.respond(to: user)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw LocalLLMError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
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
        case .notInstalled: "Download \(LocalLLM.displayName) in Settings → AI"
        case .timedOut: "\(LocalLLM.displayName) took too long"
        }
    }
}

public struct LocalLLMInstaller: LocalLLMInstalling {
    public init() {}

    public func isInstalled() async -> Bool {
        LocalLLM.isInstalled(at: LocalLLM.directory)
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await HubSnapshot.install(
            LocalLLM.repo, to: LocalLLM.directory, matching: ["*.safetensors", "*.json", "*.jinja", "*.txt"],
            progress: progress
        )
    }

    public func uninstall() async throws {
        await LocalLLM.loaded.unload()
        if FileManager.default.fileExists(atPath: LocalLLM.directory.path) {
            try FileManager.default.removeItem(at: LocalLLM.directory)
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
