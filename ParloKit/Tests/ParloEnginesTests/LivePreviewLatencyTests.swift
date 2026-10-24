import Foundation
import ParloCore
import Testing
@testable import ParloEngines

/// What a live preview tick costs: speech grows by 1 s at a time and the preview window is transcribed each time,
/// as the HUD does while recording. Run with `PARLO_BENCHMARK=1 swift test --filter LivePreviewLatencyTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_BENCHMARK"] == "1"))
struct LivePreviewLatencyTests {
    private final class TestBundleToken {}

    /// Registers the test bundle so MLX finds its Metal library (see EngineIntegrationTests).
    init() {
        _ = Bundle(for: TestBundleToken.self)
    }

    static let text = ModelBenchmarkTests.italian.joined(separator: " ")
        + " Poi passiamo in ufficio, sistemiamo la presentazione e la mandiamo a tutti prima di sera."

    @Test(arguments: [ModelID.parakeetV3, .appleSpeech, .qwen3ASR])
    func previewTicks(id: ModelID) async throws {
        let installer = try await EngineIntegrationTests.installer(with: id)
        let transcriber = try await installer.makeTranscriber(id)
        let speech = try EngineIntegrationTests.speech(Self.text, voice: "Alice")
        _ = try? await transcriber.transcribe(Array(speech.prefix(16_000)), languageCode: "it", dictionary: [])

        let window = Int(LivePreview.windowSeconds * 16_000)
        var latencies: [Double] = []
        var last = ""
        for seconds in 1...(speech.count / 16_000) {
            let captured = speech.prefix(seconds * 16_000)
            let start = ContinuousClock.now
            do {
                last = try await transcriber.transcribe(Array(captured.suffix(window)), languageCode: "it", dictionary: [])
            } catch {
                print("[preview \(id.rawValue)] \(error.localizedDescription)")
                return
            }
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            latencies.append(ms)
            print(String(format: "[preview %@] %2d s captured: %4.0f ms  …%@", id.rawValue, seconds, ms, String(last.suffix(50))))
        }
        let sorted = latencies.sorted()
        print(String(format: "[preview %@] %d ticks: median %.0f ms, max %.0f ms (window %.0f s)", id.rawValue,
                     sorted.count, sorted[sorted.count / 2], sorted.last ?? 0, LivePreview.windowSeconds))
        // For comparison: transcribing everything captured, which is what an unwindowed preview would cost at the end.
        let start = ContinuousClock.now
        _ = try await transcriber.transcribe(speech, languageCode: "it", dictionary: [])
        print(String(format: "[preview %@] whole %.0f s: %.0f ms", id.rawValue, Double(speech.count) / 16_000,
                     (ContinuousClock.now - start) / .milliseconds(1)))
        #expect(!last.isEmpty)
    }
}
