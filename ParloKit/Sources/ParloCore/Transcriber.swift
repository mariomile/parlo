import Foundation

public protocol Transcriber: Sendable {
    /// `samples`: 16 kHz mono Float32. `languageCode`: BCP-47 ("it"), nil = auto-detect.
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String
}

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case languageRequired(String)
    case unsupportedLanguage(String)
    case modelNotInstalled(String)
    /// System speech assets for this language are still downloading.
    case assetsInstalling(String)

    public var errorDescription: String? {
        switch self {
        case let .languageRequired(model): "\(model) needs a language. Pick one in Settings → General."
        case let .unsupportedLanguage(code): "Language \"\(code)\" is not supported by this model"
        case let .modelNotInstalled(model): "\(model) is not downloaded"
        case let .assetsInstalling(language):
            "Apple Speech is still downloading \(language). Try again later, or use Parakeet in Settings → Models."
        }
    }
}

public enum RecordingGuard {
    public static let minimumDuration = 0.3

    public static func isLongEnough(sampleCount: Int, sampleRate: Double = 16_000) -> Bool {
        Double(sampleCount) / sampleRate >= minimumDuration - 1e-9
    }
}
