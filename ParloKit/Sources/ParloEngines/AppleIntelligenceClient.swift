import Foundation
import FoundationModels
import ParloCore

/// Cleanup and command mode on Apple Intelligence's on-device model.
public struct AppleIntelligenceClient: ChatCompleting {
    public init() {}

    /// nil when the model is ready; otherwise a short reason to show the user.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off"
        case .unavailable(.deviceNotEligible): "Not supported on this Mac"
        case .unavailable(.modelNotReady): "Model still downloading"
        case .unavailable: "Unavailable"
        }
    }

    public func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        if let reason = Self.unavailableReason { throw AppleIntelligenceError.unavailable(reason) }
        let reply = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: user, options: GenerationOptions(temperature: 0)).content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AppleIntelligenceError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}

public enum AppleIntelligenceError: Error, LocalizedError {
    case unavailable(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .timedOut: "Apple Intelligence took too long"
        }
    }
}
