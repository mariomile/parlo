import Foundation
import ParloCore

extension LLMSettings {
    /// Whether cleanup runs on the model Parlo downloads, which then stays loaded.
    public var usesLocalModel: Bool { enabled && provider == .local }

    /// What cleanup and command mode call, or nil with cleanup off.
    @MainActor public func client(apiKey: String?, local: LocalLLM) -> (any ChatCompleting)? {
        enabled ? providerClient(apiKey: apiKey, local: local) : nil
    }

    /// The chosen provider's client even with cleanup off, for the connection test.
    @MainActor public func providerClient(apiKey: String?, local: LocalLLM) -> any ChatCompleting {
        switch provider {
        case .apple: AppleIntelligenceClient()
        case .local: local.client
        case .openAICompatible: LLMClient(settings: self, apiKey: apiKey)
        }
    }

    /// Why cleanup would fail right now, as a short line; nil when it can run or is off.
    @MainActor public func problem(apiKey: String?, local: LocalLLM) -> String? {
        guard enabled else { return nil }
        switch provider {
        case .apple:
            return AppleIntelligenceClient.unavailableReason.map { "Apple Intelligence: \($0.lowercased())" }
        case .local:
            return local.files.state == .installed ? nil : "AI cleanup: download \(CleanupModel.displayName)"
        case .openAICompatible:
            return apiKey == nil && !isOnThisMac ? "AI cleanup needs an API key" : nil
        }
    }

    /// A server on this Mac (Ollama, LM Studio) needs no key.
    private var isOnThisMac: Bool {
        ["localhost", "127.0.0.1"].contains(URL(string: baseURL)?.host() ?? "")
    }
}
