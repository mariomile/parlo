import FluidAudio
import Foundation
import ParloCore

/// Silero VAD via FluidAudio. The model is a few MB, downloaded to FluidAudio's cache on first use.
public struct SileroSpeechDetector: SpeechDetector {
    let manager: VadManager

    public static func load() async throws -> SileroSpeechDetector {
        // FluidAudio defaults to 0.85, which misses quiet or distant speech. Room noise peaks near 0.4.
        SileroSpeechDetector(manager: try await VadManager(config: VadConfig(defaultThreshold: 0.6)))
    }

    public func containsSpeech(_ samples: [Float]) async throws -> Bool {
        try await !manager.segmentSpeech(samples).isEmpty
    }
}
