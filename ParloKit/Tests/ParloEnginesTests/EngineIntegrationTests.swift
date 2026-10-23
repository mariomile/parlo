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

    func check(_ transcriber: any Transcriber, _ info: ModelInfo, _ language: String, _ text: String,
               voice: String, expecting word: String) async throws {
        let result: String
        do {
            result = try await transcriber.transcribe(try Self.speech(text, voice: voice), languageCode: language)
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
            try await t.transcribe([Float](repeating: 0, count: 16_000), languageCode: nil)
        }
    }
}
