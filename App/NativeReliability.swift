import Foundation
import ParloCore

/// One history job's permission to perform work and deliver a result. A new retry gets a new lifetime.
/// Detached deadlines and noncooperative engines may outlive cancellation, so they share this revocation.
nonisolated final class HistoryWorkLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isCurrent: Bool { lock.withLock { !revoked } }
    func revoke() { lock.withLock { revoked = true } }

    func check() throws {
        try Task.checkCancellation()
        guard isCurrent else { throw CancellationError() }
    }
}

nonisolated struct HistoryTranscriber: Transcriber {
    let base: any Transcriber
    let lifetime: HistoryWorkLifetime

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        try lifetime.check()
        let text = try await base.transcribe(samples, languageCode: languageCode, dictionary: dictionary)
        try lifetime.check()
        return text
    }
}

nonisolated struct HistoryChatClient: ChatCompleting {
    let base: any ChatCompleting
    let lifetime: HistoryWorkLifetime

    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        try lifetime.check()
        let reply = try await base.complete(system: system, user: user, timeout: timeout)
        try lifetime.check()
        return reply
    }
}

/// The editor owns its endpoint identity even when both endpoints have no saved key. Validating at the
/// action boundary also protects a click arriving before SwiftUI runs onChange for a provider change.
nonisolated struct EndpointKeyDraft: Equatable {
    struct Identity: Equatable, Sendable {
        let provider: LLMProvider
        let endpoint: String

        init(_ settings: LLMSettings) {
            provider = settings.provider
            endpoint = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private(set) var identity: Identity?
    var text = ""

    mutating func reset(for settings: LLMSettings, savedKey: String?) {
        identity = Identity(settings)
        text = savedKey ?? ""
    }

    func matches(_ settings: LLMSettings) -> Bool { identity == Identity(settings) }
}

enum CommandSelectionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Parlo couldn't verify the selected text. Place the cursor in an accessible text field, select the text if needed, and record the command again."
    }
}
