import Foundation
import Testing
@testable import ParloCore
@testable import ParloEngines

/// Latency and output of the local cleanup model on dictation-like transcripts, with the real prompt and timeout.
/// Run with `PARLO_BENCHMARK=1 swift test --filter LocalLLMBenchmarkTests`. Downloads the model first when
/// `PARLO_DOWNLOAD` contains `localLLM`; `PARLO_LLM_DIRS` (comma-separated folders) adds other MLX models to compare.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_BENCHMARK"] == "1"))
struct LocalLLMBenchmarkTests {
    private final class TestBundleToken {}

    /// Registers the test bundle so MLX finds its Metal library (see EngineIntegrationTests).
    init() {
        _ = Bundle(for: TestBundleToken.self)
    }

    static let transcripts = [
        "ehm allora domani mattina ho una riunione con il cliente alle nove no anzi alle dieci per parlare del budget",
        "secondo me dovremmo ehm spostare la riunione a giovedi perche mercoledi non ci sono quasi tutti",
        "allora ho fatto il deploy in produzione ma la pull request non e ancora stata approvata quindi aspetta prima di fare il merge",
        "um so I was thinking we could uh move the meeting to thursday because like half the team is out on wednesday",
        "can you send me the report by friday no wait by thursday and also add the design team in copy",
        "what time does the store close on sunday do you know",
    ]

    static var directories: [URL] {
        let extra = (ProcessInfo.processInfo.environment["PARLO_LLM_DIRS"] ?? "").split(separator: ",")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        return [LocalLLM.directory] + extra
    }

    @Test(arguments: directories)
    func cleanup(directory: URL) async throws {
        let name = directory.lastPathComponent
        if directory == LocalLLM.directory, !LocalLLM.isInstalled(at: directory) {
            guard EngineIntegrationTests.toDownload.contains("localLLM") else { return }
            let start = ContinuousClock.now
            try await LocalLLMInstaller().install { _ in }
            print("[llm \(name)] download: \(ContinuousClock.now - start)")
        }
        guard LocalLLM.isInstalled(at: directory) else { return }
        let client = LocalLLMClient(directory: directory)
        let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)

        var start = ContinuousClock.now
        _ = try await LocalLLM.loaded.container(directory)
        print("[llm \(name)] load: \(ContinuousClock.now - start)")
        start = ContinuousClock.now
        _ = try await client.complete(system: system, user: PromptBuilder.cleanupUserMessage("Prova."), timeout: 60)
        print("[llm \(name)] first cleanup: \(ContinuousClock.now - start)")

        var total = 0.0, worst = 0.0, answered = 0, accepted = 0
        for transcript in Self.transcripts {
            start = ContinuousClock.now
            let output: String
            do {
                output = try await client.complete(
                    system: system, user: PromptBuilder.cleanupUserMessage(transcript),
                    timeout: DictationPipeline.cleanupTimeout(for: transcript)
                )
            } catch {
                print("[llm \(name)] \(transcript) -> \(error.localizedDescription)")
                continue
            }
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            total += seconds
            answered += 1
            worst = max(worst, seconds)
            let ok = CleanupOutput.accepted(output, input: transcript) != nil
            if ok { accepted += 1 }
            print(String(format: "[llm %@] %.2fs%@ %@", name, seconds, ok ? "" : " (rejected)", output))
        }

        for (instruction, selection) in [
            ("rendilo più formale", "ciao, domani non ci sono, ci sentiamo lunedì"),
            ("write a two line reminder to water the plants", nil),
        ] {
            start = ContinuousClock.now
            let command = try await client.complete(
                system: PromptBuilder.commandSystemPrompt(),
                user: PromptBuilder.commandUserMessage(instruction: instruction, selection: selection),
                timeout: CommandPipeline.timeout
            )
            print("[llm \(name)] command \(ContinuousClock.now - start): \(command)")
        }
        print(String(format: "[llm %@] cleanup: mean %.2fs, worst %.2fs, %d/%d in time, %d accepted",
                     name, total / Double(max(answered, 1)), worst, answered, Self.transcripts.count, accepted))
        await LocalLLM.loaded.unload()
    }
}
