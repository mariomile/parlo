@preconcurrency import AVFoundation
import Foundation
import ParloCore
import Testing
@testable import ParloEngines

/// Real-model tests. Run with `PARLO_INTEGRATION=1 swift test --filter EngineIntegrationTests`.
/// Models not installed are skipped, unless listed in `PARLO_DOWNLOAD` (comma-separated ModelID raw values).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    private final class TestBundleToken {}

    /// MLX finds its Metal library by scanning the registered bundles for `mlx-swift_Cmlx.bundle`. `swift test` loads
    /// the test bundle without registering it, so register it here before any MLX model is loaded.
    init() {
        _ = Bundle(for: TestBundleToken.self)
    }

    static let toDownload = Set(
        (ProcessInfo.processInfo.environment["PARLO_DOWNLOAD"] ?? "").split(separator: ",").map(String.init)
    )

    static func speech(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parlo-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@16000", text]
        try p.run()
        p.waitUntilExit()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        try? FileManager.default.removeItem(at: url)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test(arguments: ModelID.allCases)
    func transcribesItalianAndEnglish(id: ModelID) async throws {
        let installer = EngineInstaller()
        if !(await installer.isInstalled(id)) {
            guard Self.toDownload.contains(id.rawValue) else { return }
            try await installer.install(id) { _ in }
            #expect(await installer.isInstalled(id))
        }
        let loadStart = ContinuousClock.now
        let transcriber = try await installer.makeTranscriber(id)
        print("[\(id.rawValue)] load: \(ContinuousClock.now - loadStart)")
        let info = ModelCatalog.info(id)

        if id != .parakeetV2 {
            try await check(transcriber, info, "it", "Domani andiamo al mercato a comprare la frutta fresca.",
                            voice: "Alice", expecting: "mercato")
        }
        try await check(transcriber, info, "en", "The quick brown fox jumps over the lazy dog.",
                        voice: "Samantha", expecting: "fox")
    }

    @Test func speechDetectorIgnoresRoomNoise() async throws {
        let detector = try await SileroSpeechDetector.load()
        // Room noise at the level measured on a MacBook mic (RMS about 0.01): models hallucinate words on it.
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<32_000).map { _ in Float.random(in: -0.018...0.018, using: &rng) }
        #expect(try await !detector.containsSpeech(noise))
        #expect(try await !detector.containsSpeech([Float](repeating: 0, count: 16_000)))
        let speech = try Self.speech("Allora, mandami il file entro stasera.", voice: "Alice")
        #expect(try await detector.containsSpeech(speech))
        // Quiet or distant speech, peaking around 0.05 like a soft voice on a MacBook mic.
        let peak = speech.map(abs).max() ?? 1
        #expect(try await detector.containsSpeech(speech.map { $0 / peak * 0.05 }))
        // A single short word.
        #expect(try await detector.containsSpeech(try Self.speech("Sì.", voice: "Alice")))
    }

    @Test func parakeetVocabularyBiasing() async throws {
        let installer = EngineInstaller()
        guard await installer.isInstalled(.parakeetV3) else { return }
        let transcriber = try await installer.makeTranscriber(.parakeetV3)
        let dictionary = [
            DictionaryEntry(term: "CLAUDE.md"), DictionaryEntry(term: "AGENTS.md"), DictionaryEntry(term: "pull request"),
        ]
        // The CTC model loads in the background after the first dictation that has a dictionary.
        let warmup = try Self.speech("Aggiorna il file CLAUDE.md", voice: "Alice")
        for _ in 0..<60 where try await !transcriber.transcribe(warmup, languageCode: "it", dictionary: dictionary)
            .contains("CLAUDE.md") {
            try await Task.sleep(for: .seconds(1))
        }
        for (phrase, expected) in [
            ("Aggiorna il file CLAUDE.md e apri una pull request", ["CLAUDE.md", "pull request"]),
            ("Modifica CLAUDE.md o AGENTS.md prima del commit", ["CLAUDE.md", "AGENTS.md"]),
        ] {
            let audio = try Self.speech(phrase, voice: "Alice")
            let without = try await transcriber.transcribe(audio, languageCode: "it", dictionary: [])
            let with = try await transcriber.transcribe(audio, languageCode: "it", dictionary: dictionary)
            print("[parakeetV3] without vocabulary: \(without)")
            print("[parakeetV3] with vocabulary:    \(with)")
            for term in expected { #expect(with.contains(term), "\(with)") }
        }
    }

    func check(_ transcriber: any Transcriber, _ info: ModelInfo, _ language: String, _ text: String,
               voice: String, expecting word: String) async throws {
        let result: String
        let samples = try Self.speech(text, voice: voice)
        let start = ContinuousClock.now
        do {
            result = try await transcriber.transcribe(samples, languageCode: language, dictionary: [])
        } catch let TranscriptionError.assetsInstalling(locale) {
            print("[\(info.id.rawValue)] \(language): skipped, system assets for \(locale) not installed")
            return
        }
        let wall = ContinuousClock.now - start
        print("[\(info.id.rawValue)] \(language): \(result) (audio \(String(format: "%.2f", Double(samples.count) / 16_000)) s, wall \(wall))")
        #expect(result.lowercased().contains(word), "\(info.displayName): \(result)")
    }

    @Test func cohereWithoutLanguageThrows() async throws {
        let installer = EngineInstaller()
        guard await installer.isInstalled(.cohereTranscribe) else { return }
        let t = try await installer.makeTranscriber(.cohereTranscribe)
        await #expect(throws: TranscriptionError.languageRequired("Cohere Transcribe")) {
            try await t.transcribe([Float](repeating: 0, count: 16_000), languageCode: nil, dictionary: [])
        }
    }

    @Test func qwen3DetectsLanguageWhenNoneIsSet() async throws {
        let installer = EngineInstaller()
        guard await installer.isInstalled(.qwen3ASR) else { return }
        let t = try await installer.makeTranscriber(.qwen3ASR)
        let italian = try await t.transcribe(
            try Self.speech("Domani andiamo al mercato a comprare la frutta fresca.", voice: "Alice"),
            languageCode: nil, dictionary: []
        )
        print("[qwen3ASR] auto-detect: \(italian)")
        #expect(italian.lowercased().contains("mercato"), "\(italian)")
    }

    /// The dictionary goes to Qwen3-ASR as context. It may change the capitals, so the check ignores case.
    @Test func qwen3UsesDictionaryAsContext() async throws {
        let installer = EngineInstaller()
        guard await installer.isInstalled(.qwen3ASR) else { return }
        let t = try await installer.makeTranscriber(.qwen3ASR)
        let dictionary = [
            DictionaryEntry(term: "CLAUDE.md"), DictionaryEntry(term: "AGENTS.md"), DictionaryEntry(term: "README"),
        ]
        for (phrase, voice, expected) in [
            ("Aggiorna il file CLAUDE.md e apri una pull request", "Alice", ["claude.md"]),
            ("Ho chiesto a Claude Code di sistemare il README", "Alice", ["readme"]),
            ("Can you check the AGENTS.md file in the repo", "Samantha", ["agents.md"]),
            ("Domani andiamo al mercato a comprare la frutta fresca.", "Alice", []),
        ] {
            let audio = try Self.speech(phrase, voice: voice)
            let without = try await t.transcribe(audio, languageCode: nil, dictionary: [])
            let with = try await t.transcribe(audio, languageCode: nil, dictionary: dictionary)
            print("[qwen3ASR] without dictionary: \(without)")
            print("[qwen3ASR] with dictionary:    \(with)")
            for term in expected { #expect(with.lowercased().contains(term), "\(with)") }
            if expected.isEmpty {
                #expect(!dictionary.terms.contains { with.lowercased().contains($0.lowercased()) }, "\(with)")
            }
        }
    }
}
