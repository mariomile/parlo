import Foundation
import ParloCore
import Testing
@testable import ParloEngines

/// Speed and word error rate of every installed model on this Mac, on synthesized Italian and English speech.
/// Run with `PARLO_BENCHMARK=1 swift test --filter ModelBenchmarkTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_BENCHMARK"] == "1"))
struct ModelBenchmarkTests {
    private final class TestBundleToken {}

    /// Registers the test bundle so MLX finds its Metal library (see EngineIntegrationTests).
    init() {
        _ = Bundle(for: TestBundleToken.self)
    }

    static let italian = [
        "Domani mattina alle nove ho una riunione con il cliente per discutere il budget del prossimo trimestre.",
        "Perché non mi hai mandato il file? Pensavo fosse già pronto, ma forse c'è ancora qualcosa da sistemare.",
        "La città è più bella d'autunno, quando le giornate si accorciano e l'aria diventa fresca.",
    ]
    static let english = [
        "Can you push the latest changes to the main branch and open a pull request before the meeting?",
        "The quarterly report shows revenue growth of twelve percent, which is above our original forecast.",
    ]

    @Test(arguments: ModelID.allCases)
    func benchmark(id: ModelID) async throws {
        let installer = try await EngineIntegrationTests.installer(with: id)
        let transcriber = try await installer.makeTranscriber(id)
        let info = ModelCatalog.info(id)
        // The first run compiles and warms the model; it isn't what a dictation costs.
        _ = try? await transcriber.transcribe(
            try EngineIntegrationTests.speech("Prova.", voice: "Alice"), languageCode: "it", dictionary: []
        )

        var lines: [String] = []
        for (language, voice, phrases) in [("it", "Alice", Self.italian), ("en", "Samantha", Self.english)] {
            if id == .parakeetV2, language == "it" { continue }
            var errors = 0, words = 0
            var audio = 0.0, elapsed = 0.0
            for phrase in phrases {
                let samples = try EngineIntegrationTests.speech(phrase, voice: voice)
                let start = ContinuousClock.now
                let text: String
                do {
                    text = try await transcriber.transcribe(samples, languageCode: language, dictionary: [])
                } catch {
                    lines.append("\(language): \(error.localizedDescription)")
                    break
                }
                elapsed += (ContinuousClock.now - start) / .seconds(1)
                audio += Double(samples.count) / 16_000
                let reference = Self.words(phrase)
                errors += Self.editDistance(reference, Self.words(text))
                words += reference.count
                print("[bench \(id.rawValue)] \(language): \(text)")
            }
            guard words > 0 else { continue }
            let wer = Double(errors) / Double(words) * 100
            lines.append(String(format: "%@ WER %.1f%%, %.2fs for %.1fs of audio (%.0fx real time)",
                                language, wer, elapsed, audio, audio / elapsed))
        }
        print("[bench \(id.rawValue)] \(info.displayName): " + lines.joined(separator: " · "))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "'", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}
