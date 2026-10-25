import Foundation
import MLXLMCommon
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
        MLXCache.limit() // Match the cache limit applied by EngineInstaller.prepare in the app.
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
        return [HubSnapshot.directory(CleanupModel.folder)] + extra
    }

    /// Same model and exact instructions, with independent requests in both paths. The reference
    /// deliberately starts a fresh session so a cache optimization cannot change the conversation.
    @MainActor @Test func cachedRequestsMatchFreshSessions() async throws {
        let llm = LocalLLM()
        guard HubSnapshot.isInstalled(llm.directory) else { try Test.cancel("Local cleanup model is not installed") }
        llm.inUse = true
        defer { llm.inUse = false }
        let container = try await llm.container()
        let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)
        // Exclude the first model forward and initial prefix construction from steady-state timings.
        _ = try await llm.client.complete(system: system, user: PromptBuilder.cleanupUserMessage("Prova."), timeout: 30)
        var freshSeconds = 0.0, cachedSeconds = 0.0
        let inputs = Self.transcripts + [
            "non fare il merge non approvare la pull request finche i test non sono verdi",
            "il codice del progetto e CANARY7429 ricordalo solo in questa frase",
            "ciao marco ci vediamo domani alle dieci",
            "prima riga\n- seconda riga\n- terza riga",
        ]
        for (index, input) in inputs.enumerated() {
            let user = PromptBuilder.cleanupUserMessage(input)
            let freshStart = ContinuousClock.now
            let fresh = try await Deadline.run(seconds: 20) {
                try await ChatSession(container, instructions: system, generateParameters: GenerateParameters(temperature: 0))
                    .respond(to: user)
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            let freshTime = (ContinuousClock.now - freshStart) / .seconds(1)
            let cachedStart = ContinuousClock.now
            let cached = try await llm.client.complete(system: system, user: user, timeout: 20)
            let cachedTime = (ContinuousClock.now - cachedStart) / .seconds(1)
            freshSeconds += freshTime
            cachedSeconds += cachedTime
            print(String(format: "[prefix] case=%d fresh=%.3fs cached=%.3fs", index, freshTime, cachedTime))
            #expect(cached == fresh, "Independent request \(index) changed its result")
            if index == 8 { #expect(!cached.contains("CANARY7429")) }
        }
        print(String(format: "[prefix] mean fresh=%.3fs cached=%.3fs speedup=%.2fx",
                     freshSeconds / Double(inputs.count), cachedSeconds / Double(inputs.count), freshSeconds / cachedSeconds))

        // A style/dictionary change must not reuse a different system's instructions.
        let changed = PromptBuilder.cleanupSystemPrompt(
            style: .technical, dictionary: [DictionaryEntry(term: "Parlo", heardAs: ["parlo app"])], hasPlaceholders: true
        )
        let user = PromptBuilder.cleanupUserMessage("apri ⟦S1⟧ nella parlo app")
        let reference = try await ChatSession(container, instructions: changed, generateParameters: GenerateParameters(temperature: 0))
            .respond(to: user).trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = try await llm.client.complete(system: changed, user: user, timeout: 20)
        #expect(actual == reference)
        #expect(actual.contains("⟦S1⟧"))
    }

    @MainActor @Test func concurrentRequestsStayIndependent() async throws {
        let llm = LocalLLM()
        guard HubSnapshot.isInstalled(llm.directory) else { try Test.cancel("Local cleanup model is not installed") }
        llm.inUse = true
        defer { llm.inUse = false }
        let container = try await llm.container()
        let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)
        let users = ["domani ci vediamo alle dieci", "the project code is CANARY7429", "non approvare il deploy"]
            .map(PromptBuilder.cleanupUserMessage)
        var expected: [String] = []
        for user in users {
            expected.append(try await ChatSession(container, instructions: system, generateParameters: GenerateParameters(temperature: 0))
                .respond(to: user).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let client = llm.client
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, user) in users.enumerated() {
                group.addTask { (index, try await client.complete(system: system, user: user, timeout: 20)) }
            }
            for try await (index, result) in group { #expect(result == expected[index]) }
        }
    }

    @MainActor @Test func timedOutRequestDoesNotPoisonNextCompletion() async throws {
        let llm = LocalLLM()
        guard HubSnapshot.isInstalled(llm.directory) else { try Test.cancel("Local cleanup model is not installed") }
        llm.inUse = true
        defer { llm.inUse = false }
        let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)
        let user = PromptBuilder.cleanupUserMessage("ci vediamo domani alle dieci")
        let expected = try await llm.client.complete(system: system, user: user, timeout: 20)
        do {
            _ = try await llm.client.complete(
                system: system,
                user: PromptBuilder.cleanupUserMessage(String(repeating: "CANARY7429 ", count: 200)), timeout: 0.001
            )
            Issue.record("The deliberately expired cleanup returned a successful result")
        } catch LocalLLMError.timedOut { }
        let actual = try await llm.client.complete(system: system, user: user, timeout: 20)
        #expect(actual == expected)
        #expect(!actual.contains("CANARY7429"))
        // Unloading must also drop the retained prefix before another model lifetime.
        llm.inUse = false
        llm.inUse = true
        #expect(try await llm.client.complete(system: system, user: user, timeout: 20) == expected)
    }

    @MainActor @Test(arguments: directories)
    func cleanup(directory: URL) async throws {
        let name = directory.lastPathComponent
        let llm = LocalLLM(directory: directory)
        if !HubSnapshot.isInstalled(directory) {
            guard directory == HubSnapshot.directory(CleanupModel.folder),
                  EngineIntegrationTests.toDownload.contains("localLLM")
            else { try Test.cancel("\(name) is not installed") }
            let start = ContinuousClock.now
            await llm.files.download()
            try #require(llm.files.state == .installed)
            print("[llm \(name)] download: \(ContinuousClock.now - start)")
        }
        llm.inUse = true
        let client = llm.client
        let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)

        var start = ContinuousClock.now
        _ = try await llm.container()
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
                    timeout: TranscriptionJob.cleanupTimeout(for: transcript, provider: .local)
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
                timeout: TranscriptionJob.commandTimeout
            )
            print("[llm \(name)] command \(ContinuousClock.now - start): \(command)")
        }
        print(String(format: "[llm %@] cleanup: mean %.2fs, worst %.2fs, %d/%d in time, %d accepted",
                     name, total / Double(max(answered, 1)), worst, answered, Self.transcripts.count, accepted))
        llm.inUse = false
        // What dictation needs from the model: every cleanup back in time, and each one usable.
        #expect(answered == Self.transcripts.count, "\(name): \(answered)/\(Self.transcripts.count) in time")
        #expect(accepted == answered, "\(name): \(answered - accepted) rejected")
    }
}
