import Foundation
import ParloCore
import Synchronization
import Testing
@testable import ParloEngines

/// Decodes real audio files and transcribes them with real models, the way "Transcribe File…" does.
/// Run with `PARLO_INTEGRATION=1 swift test --filter FileTranscriptionIntegrationTests`. Models not installed are skipped
/// (see EngineIntegrationTests).
/// `PARLO_LONG_MINUTES` sets the length of the long file (default 10).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_INTEGRATION"] == "1"))
struct FileTranscriptionIntegrationTests {
    private final class TestBundleToken {}

    /// See EngineIntegrationTests: MLX needs the test bundle registered.
    init() {
        _ = Bundle(for: TestBundleToken.self)
    }

    static let sentences = [
        "Domani andiamo al mercato a comprare la frutta fresca e un po' di pane.",
        "La riunione di lunedì è stata spostata alle undici nella sala grande.",
        "Ho letto un libro bellissimo sulla storia delle città medievali italiane.",
        "Per favore, ricordati di spegnere le luci prima di uscire dall'ufficio.",
        "Il treno per Milano parte dal secondo binario alle otto e quaranta.",
        "Questa estate vorremmo viaggiare in macchina lungo la costa fino al mare.",
        "Il nuovo ristorante in centro prepara una pasta fresca davvero eccellente.",
        "Mi piacerebbe imparare a suonare la chitarra durante le sere d'inverno.",
        "Abbiamo bisogno di più tempo per finire il progetto con la massima cura.",
        "La biblioteca comunale resta aperta fino a tardi durante il periodo degli esami.",
    ]

    static func say(_ text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Alice", "-o", url.path, text]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Share of the reference words that appear in the transcript, counting repeats.
    static func recall(reference: String, transcript: String) -> Double {
        var available = Dictionary(grouping: words(transcript), by: { $0 }).mapValues(\.count)
        let ref = words(reference)
        var hit = 0
        for w in ref where available[w, default: 0] > 0 {
            available[w]! -= 1
            hit += 1
        }
        return Double(hit) / Double(max(ref.count, 1))
    }

    static func peakMemoryMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576 // bytes on macOS
    }

    func run(_ id: ModelID, file url: URL, reference: String) async throws {
        let installer = try await EngineIntegrationTests.installer(with: id)
        let transcriber = try await installer.makeTranscriber(id)

        let decodeStart = ContinuousClock.now
        let samples = try await AudioFileDecoder.decode(url)
        let decodeTime = ContinuousClock.now - decodeStart
        let seconds = Double(samples.count) / 16_000

        let lastProgress = LastProgress()
        let chunked = ChunkedTranscriber(base: transcriber) { fraction in lastProgress.value.withLock { $0 = fraction } }
        var settings = AppSettings.default
        settings.languageCode = "it"
        let start = ContinuousClock.now
        let outcome: DictationOutcome
        do {
            outcome = try await DictationPipeline(transcriber: chunked, llm: nil, settings: settings)
                .run(samples: samples, bundleID: nil)
        } catch let TranscriptionError.assetsInstalling(locale) {
            try Test.cancel("system assets for \(locale) not installed")
        }
        let wall = ContinuousClock.now - start
        guard case let .inserted(text, _) = outcome else {
            Issue.record("\(id.rawValue): \(outcome)")
            return
        }
        let recall = Self.recall(reference: reference, transcript: text)
        let rtf = (wall / .seconds(1)) / seconds
        print("""
        [\(id.rawValue)] \(url.lastPathComponent): \(String(format: "%.1f", seconds)) s audio, decode \(decodeTime), \
        transcribe \(wall) (\(String(format: "%.1f", 1 / rtf))x realtime), \(Self.words(text).count) words, \
        recall \(String(format: "%.2f", recall)), progress \(lastProgress.value.withLock { $0 }), peak RSS \(Self.peakMemoryMB()) MB
        [\(id.rawValue)]   start: \(text.prefix(110))
        [\(id.rawValue)]   end:   \(text.suffix(110))
        """)
        #expect(recall > 0.85, "\(id.rawValue) recall \(recall)")
        #expect(lastProgress.value.withLock { $0 } == 1)
    }

    @Test(arguments: ModelID.allCases)
    func shortFile(id: ModelID) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "parlo-short-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = Self.sentences[0] + " " + Self.sentences[1]
        try Self.say(text, to: url)
        try await run(id, file: url, reference: text)
    }

    @Test(arguments: ModelID.allCases)
    func longFile(id: ModelID) async throws {
        _ = try await EngineIntegrationTests.installer(with: id)
        let minutes = Double(ProcessInfo.processInfo.environment["PARLO_LONG_MINUTES"] ?? "") ?? 10
        // About 170 spoken words a minute; the sentences are numbered by repetition so the transcript can't skip a block unnoticed.
        let target = Int(minutes * 170)
        var text = ""
        var n = 0
        while Self.words(text).count < target {
            text += Self.sentences[n % Self.sentences.count] + " "
            n += 1
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "parlo-long-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.say(text, to: url)
        try await run(id, file: url, reference: text)
    }
}

private final class LastProgress: Sendable {
    let value = Mutex(0.0)
}
