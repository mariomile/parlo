import FluidAudio
import Foundation
import ParloCore

/// Silero VAD via FluidAudio. The model is a few MB, downloaded to FluidAudio's cache on first use.
public struct SileroSpeechDetector: SpeechDetector {
    let manager: VadManager

    public static func load() async throws -> SileroSpeechDetector {
        SileroSpeechDetector(manager: try await VadManager())
    }

    public func containsSpeech(_ samples: [Float]) async throws -> Bool {
        try await !manager.segmentSpeech(samples).isEmpty
    }
}
