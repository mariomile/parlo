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
    private var systemPrefix = LocalPromptCache<LocalSystemPrefix>()
    // A weak identity witness avoids retaining unloaded model weights or reusing a recycled identity.
    private weak var prefixContainer: ModelContainer?

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
        guard HubSnapshot.isInstalled(directory) else {
            clearSystemPrefix()
            throw LocalLLMError.notInstalled
        }
        let directory = directory
        // A one-off call (the connection test) doesn't keep the model in memory.
        guard keepsLoaded else { return try await Self.load(directory) }
        return try await loaded.value(directory) { try await Self.load(directory) }
    }

    /// Each completion owns its session and mutable KV copies; only system tokens are reusable.
    func complete(system: String, user: String) async throws -> String {
        let container = try await container()
        try Task.checkCancellation()
        var prefix: LocalSystemPrefix?
        if keepsLoaded {
            if prefixContainer !== container {
                clearSystemPrefix()
                prefixContainer = container
            }
            let ticket = systemPrefix.select(container: ObjectIdentifier(container), system: system)
            let existing = systemPrefix.value(for: ticket)
            prefix = try await container.perform { context in
                try Task.checkCancellation()
                guard context.model is Qwen3Model,
                      let tokenizer = context.tokenizer as? TokenizerBridge else { return nil as LocalSystemPrefix? }
                do {
                    let tokens = try tokenizer.upstream.applyChatTemplate(
                        messages: [["role": "system", "content": system]], chatTemplate: nil,
                        addGenerationPrompt: false, truncation: false, maxLength: nil, tools: nil)
                    // Use the actual processor used by ChatSession, including its message generator.
                    // Prove the split anew for every user input; template/BPE boundaries may differ.
                    let fragment = try await context.processor.prepare(input: UserInput(chat: [.user(user)]))
                    let full = try await context.processor.prepare(input: UserInput(chat: [.system(system), .user(user)]))
                    guard LocalPromptCache<LocalSystemPrefix>.allows(
                        prefix: tokens, fragment: fragment.text.tokens.asArray(Int.self),
                        full: full.text.tokens.asArray(Int.self)) else { return nil }
                    try Task.checkCancellation()
                    if let existing { return existing }
                    let cache = try context.model.newCache(parameters: GenerateParameters(temperature: 0))
                    // Restrict copying to the supported independent cache implementation.
                    guard cache.allSatisfy({ $0 is KVCacheSimple }) else { return nil }
                    let output = context.model(
                        LMInput.Text(tokens: MLXArray(tokens).expandedDimensions(axis: 0)),
                        cache: cache, state: nil)
                    guard output.state == nil else { return nil }
                    // Only KV is retained. Evaluating the discarded vocabulary projection for
                    // every system token adds cold latency and a large temporary allocation.
                    for layer in cache { eval(layer.state) }
                    try Task.checkCancellation()
                    return LocalSystemPrefix(cache: cache)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A template that cannot prove an exact split uses the ordinary fresh path.
                    return nil
                }
            }
            // Deadline cancellation and lifecycle changes must not publish stale native work.
            if let prefix { systemPrefix.publish(prefix, ticket: ticket, isCancelled: Task.isCancelled) }
        }
        try Task.checkCancellation()
        let reply = try await Self.respond(
            container: container, system: system, user: user,
            prefix: prefix)
        try Task.checkCancellation()
        return reply
    }

    // Construct and use the non-Sendable session on the same nonisolated execution path.
    // The frozen system prefix is Sendable; mutable copies and the session stay request-local.
    private nonisolated static func respond(
        container: ModelContainer, system: String, user: String,
        prefix: LocalSystemPrefix?
    ) async throws -> String {
        let session: ChatSession
        if let prefix {
            session = ChatSession(container, promptCache: prefix.requestSnapshot(),
                                  generateParameters: GenerateParameters(temperature: 0))
        } else {
            session = ChatSession(container, instructions: system,
                                  generateParameters: GenerateParameters(temperature: 0))
        }
        return try await session.respond(to: user)
    }

    private func clearSystemPrefix() {
        systemPrefix.clear()
        prefixContainer = nil
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
        clearSystemPrefix()
        loaded.clear()
        Memory.clearCache()
    }

    /// Loads the model in the background so the first cleanup is fast, or frees it when cleanup stops using it.
    private func sync() {
        guard keepsLoaded, files.state == .installed else {
            clearSystemPrefix()
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
                try await llm.complete(system: system, user: user)
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

/// Evaluated, system-only KV objects are frozen after construction. They are never given to a
/// session: requestSnapshot makes fresh mutable objects via the public copy contract. Array
/// materialization happens before crossing container isolation. Concurrent snapshot creation
/// only reads the frozen KVCacheSimple objects; copy() never mutates its source. Each caller
/// evaluates and exclusively owns its copies. This box never contains model weights, user
/// tokens, or generated conversation state.
private final class LocalSystemPrefix: @unchecked Sendable {
    private let cache: [any KVCache]

    init(cache: [any KVCache]) {
        self.cache = cache
    }

    func requestSnapshot() -> PromptCacheSnapshot {
        let copies = cache.map { $0.copy() }
        for layer in copies { eval(layer.state) }
        return PromptCacheSnapshot(cache: copies)
    }
}
