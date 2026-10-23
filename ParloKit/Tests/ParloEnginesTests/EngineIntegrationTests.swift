@preconcurrency import AVFoundation
import Foundation
import ParloCore
import Testing
@testable import ParloEngines

/// Real-model tests. Run with `PARLO_INTEGRATION=1 swift test --filter EngineIntegrationTests`.
/// Models not installed are skipped, unless listed in `PARLO_DOWNLOAD` (comma-separated ModelID raw values).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
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
        let transcriber = try await installer.makeTranscriber(id)
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
        do {
            result = try await transcriber.transcribe(try Self.speech(text, voice: voice), languageCode: language, dictionary: [])
        } catch let TranscriptionError.assetsInstalling(locale) {
            print("[\(info.id.rawValue)] \(language): skipped, system assets for \(locale) not installed")
            return
        }
        print("[\(info.id.rawValue)] \(language): \(result)")
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
}
