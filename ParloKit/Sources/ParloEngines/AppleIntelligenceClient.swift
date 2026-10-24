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
        guard try await Self.fits(system: system, user: user) else { throw AppleIntelligenceError.tooLong }
        let reply: String
        do {
            reply = try await Deadline.run(seconds: timeout) {
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: user, options: GenerationOptions(temperature: 0)).content
            }
        } catch is DeadlineExceeded {
            throw AppleIntelligenceError.timedOut
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw AppleIntelligenceError.tooLong
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}

extension AppleIntelligenceClient {
    /// The context window holds the instructions, the prompt and the reply, and a cleanup's reply is about
    /// as long as its prompt. Checked up front: the model fails late, after the user waited.
    static func fits(system: String, user: String) async throws -> Bool {
        let model = SystemLanguageModel.default
        let needed: Int
        if #available(macOS 26.4, *) {
            needed = try await model.tokenCount(for: Instructions(system)) + 2 * model.tokenCount(for: user)
        } else {
            needed = (system.count + 2 * user.count) / estimatedCharactersPerToken
        }
        return needed <= model.contextSize
    }

    /// Conservative for Italian and English, so the estimate errs towards "too long".
    static let estimatedCharactersPerToken = 3
}

public enum AppleIntelligenceError: Error, LocalizedError {
    case unavailable(String)
    case timedOut
    case tooLong

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .timedOut: "Apple Intelligence took too long"
        case .tooLong: "Too long for Apple Intelligence"
        }
    }
}
