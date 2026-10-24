import Foundation

public protocol Transcriber: Sendable {
    /// `samples`: 16 kHz mono Float32. `languageCode`: BCP-47 ("it"), nil = auto-detect.
    /// `dictionary`: the user's terms (and what they sound like), which engines that support it use to bias recognition.
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String
}

/// Tells real speech apart from silence and room noise, which ASR models turn into invented words.
public protocol SpeechDetector: Sendable {
    func containsSpeech(_ samples: [Float]) async throws -> Bool
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

    public static func isLongEnough(sampleCount: Int) -> Bool {
        Audio.seconds(sampleCount) >= minimumDuration - 1e-9
    }

    /// Every sample exactly zero: the microphone delivered no signal at all (a MacBook with its lid closed,
    /// an input muted in hardware). A real microphone in a quiet room still has noise.
    public static func isDigitalSilence(_ samples: [Float]) -> Bool {
        !samples.contains { $0 != 0 }
    }
}
