import Foundation


public protocol Transcriber: Sendable {
    /// `samples`: 16 kHz mono Float32. `languageCode`: BCP-47 ("it"), nil = auto-detect.
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String
}

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case languageRequired(String)
    case unsupportedLanguage(String)
    case modelNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case let .languageRequired(model): "\(model) needs a language. Pick one in Settings → General."
        case let .unsupportedLanguage(code): "Language \"\(code)\" is not supported by this model"
        case let .modelNotInstalled(model): "\(model) is not downloaded"
        }
    }
}

public enum RecordingGuard {
    public static let minimumDuration = 0.3

    public static func isLongEnough(sampleCount: Int, sampleRate: Double = 16_000) -> Bool {
        Double(sampleCount) / sampleRate >= minimumDuration - 1e-9
    }
}
