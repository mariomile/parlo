import Testing
@testable import ParloCore

@Suite struct RecordingGuardTests {
    @Test func threshold() {
        #expect(!RecordingGuard.isLongEnough(sampleCount: 4_799))
        #expect(RecordingGuard.isLongEnough(sampleCount: 4_800))
    }
}

@Suite struct DictationPipelineTests {
    var settings: AppSettings {
        var s = AppSettings.default
        s.dictionary = [DictionaryEntry(term: "Claude Code", heardAs: ["cloud code"])]
        s.snippets = [Snippet(trigger: "my address", text: "Via Roma 1")]
        return s
    }

    @Test func shortAudioDiscarded() async throws {
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "hi"), llm: nil, settings: settings)
        #expect(try await p.run(samples: [0, 0], bundleID: nil) == .discarded)
    }

    @Test func emptyTranscript() async throws {
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "  \n"), llm: nil, settings: settings)
        #expect(try await p.run(samples: oneSecond, bundleID: nil) == .empty)
    }

    @Test func silenceIsEmptyWithoutTranscribing() async throws {
        // Parakeet invents words ("Oh yeah.") on silence; the detector must stop them reaching the paste.
        let p = DictationPipeline(
            transcriber: FakeTranscriber(text: "Oh yeah."), llm: nil, settings: settings,
            speech: FakeSpeechDetector(speech: false)
        )
        #expect(try await p.run(samples: oneSecond, bundleID: nil) == .empty)
    }

    @Test func speechIsTranscribed() async throws {
        let p = DictationPipeline(
            transcriber: FakeTranscriber(text: "ciao"), llm: nil, settings: settings,
            speech: FakeSpeechDetector(speech: true)
        )
        #expect(try await p.run(samples: oneSecond, bundleID: nil) == .inserted(text: "ciao", cleanupError: nil))
    }

    @Test func noLLMAppliesDictionaryAndSnippets() async throws {
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "open cloud code at my address"), llm: nil, settings: settings)
        #expect(try await p.run(samples: oneSecond, bundleID: nil) == .inserted(text: "open Claude Code at Via Roma 1", cleanupError: nil))
    }

    @Test func spokenLayoutCommands() async throws {
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "Ciao, a capo, come stai?"), llm: nil, settings: settings)
        #expect(try await p.run(samples: oneSecond, bundleID: nil) == .inserted(text: "Ciao\nCome stai?", cleanupError: nil))
    }

    @Test func llmCleanupWithStyleAndPlaceholders() async throws {
        let llm = FakeLLM { _, user in
            user.replacingOccurrences(of: "<transcript>", with: "").replacingOccurrences(of: "</transcript>", with: "")
                .replacingOccurrences(of: "um ", with: "").capitalized(firstOnly: true) + "."
        }
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "um send it to my address"), llm: llm, settings: settings)
        let out = try await p.run(samples: oneSecond, bundleID: "com.apple.mail")
        #expect(out == .inserted(text: "Send it to Via Roma 1.", cleanupError: nil))
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].user == "<transcript>um send it to ⟦S1⟧</transcript>")
        #expect(llm.calls[0].system.contains(PromptBuilder.styleInstruction(.formal)))
        #expect(llm.calls[0].system.contains("Claude Code"))
        #expect(llm.calls[0].timeout == DictationPipeline.cleanupTimeout(for: "um send it to ⟦S1⟧"))
    }

    @Test func llmFailureKeepsText() async throws {
        let llm = FakeLLM { _, _ in throw FailingError() }
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "cloud code at my address"), llm: llm, settings: settings)
        let out = try await p.run(samples: oneSecond, bundleID: nil)
        guard case let .inserted(text, err) = out else { Issue.record("unexpected \(out)"); return }
        #expect(text == "Claude Code at Via Roma 1")
        #expect(err != nil)
    }

    @Test func dictionaryReachesTranscriber() async throws {
        let transcriber = RecordingTranscriber(text: "ciao")
        let s = settings
        let p = DictationPipeline(transcriber: transcriber, llm: nil, settings: s)
        _ = try await p.run(samples: oneSecond, bundleID: nil)
        #expect(transcriber.dictionaries.value == [s.dictionary])
    }

    @Test(arguments: [
        "Sono le quindici e trenta a Roma, dove adesso il cielo è sereno e la temperatura è di circa ventidue gradi.",
        "ok",
        "Ciao Marco, ti scrivo perché domani non posso venire alla call. Possiamo spostarla a giovedì? Fammi sapere quando puoi, grazie mille di tutto.",
    ])
    func implausibleLengthFallsBackToRaw(reply: String) async throws {
        let llm = FakeLLM { _, _ in reply }
        let p = DictationPipeline(
            transcriber: FakeTranscriber(text: "che ore sono adesso a roma per favore"), llm: llm, settings: .default
        )
        let out = try await p.run(samples: oneSecond, bundleID: nil)
        #expect(out == .inserted(text: "che ore sono adesso a roma per favore", cleanupError: "Cleanup output looked wrong"))
    }

    @Test func preambleAndTagsStrippedFromCleanup() async throws {
        let llm = FakeLLM { _, _ in "Ecco il testo pulito:\n\"<transcript>Ho fatto il commit, ma la pull request non è pronta.</transcript>\"" }
        let p = DictationPipeline(
            transcriber: FakeTranscriber(text: "ho fatto il commit ma la pull request non e pronta"), llm: llm,
            settings: .default
        )
        #expect(try await p.run(samples: oneSecond, bundleID: nil)
            == .inserted(text: "Ho fatto il commit, ma la pull request non è pronta.", cleanupError: nil))
    }

    @Test func llmDroppingTokenFallsBack() async throws {
        let llm = FakeLLM { _, _ in "Send it." }
        let p = DictationPipeline(transcriber: FakeTranscriber(text: "send it to my address"), llm: llm, settings: settings)
        let out = try await p.run(samples: oneSecond, bundleID: nil)
        guard case let .inserted(text, err) = out else { Issue.record("unexpected \(out)"); return }
        #expect(text == "send it to Via Roma 1")
        #expect(err != nil)
    }

    @Test func longDictationsGetMoreTimeForCleanup() {
        #expect(DictationPipeline.cleanupTimeout(for: "Ci vediamo domani.") < 6)
        // About two minutes of hands-free speech.
        #expect(DictationPipeline.cleanupTimeout(for: String(repeating: "parola ", count: 300)) > 20)
    }
}

@Suite struct CommandPipelineTests {
    @Test func requiresLLM() async throws {
        let p = CommandPipeline(transcriber: FakeTranscriber(text: "make formal"), llm: nil, languageCode: nil)
        await #expect(throws: CommandError.llmNotConfigured) { try await p.run(samples: oneSecond, selection: "x") }
    }

    @Test func silenceIsEmptyWithoutCallingLLM() async throws {
        let llm = FakeLLM { _, _ in "Dear Sir." }
        let p = CommandPipeline(
            transcriber: FakeTranscriber(text: "Hello."), llm: llm, languageCode: nil,
            speech: FakeSpeechDetector(speech: false)
        )
        #expect(try await p.run(samples: oneSecond, selection: "x") == .empty)
        #expect(llm.calls.isEmpty)
    }

    @Test func forwardsSelection() async throws {
        let llm = FakeLLM { _, _ in "  Dear Sir.  " }
        let p = CommandPipeline(transcriber: FakeTranscriber(text: "make formal"), llm: llm, languageCode: nil)
        #expect(try await p.run(samples: oneSecond, selection: "hey dude") == .result("Dear Sir."))
        #expect(llm.calls[0].user.contains("hey dude"))
        #expect(llm.calls[0].timeout == 15)
    }

    @Test func emptyInstruction() async throws {
        let llm = FakeLLM { _, _ in "x" }
        let p = CommandPipeline(transcriber: FakeTranscriber(text: " "), llm: llm, languageCode: nil)
        #expect(try await p.run(samples: oneSecond, selection: nil) == .empty)
        #expect(llm.calls.isEmpty)
    }

    @Test func shortDiscarded() async throws {
        let p = CommandPipeline(transcriber: FakeTranscriber(text: "x"), llm: FakeLLM { _, _ in "y" }, languageCode: nil)
        #expect(try await p.run(samples: [0], selection: nil) == .discarded)
    }
}

extension String {
    func capitalized(firstOnly: Bool) -> String { prefix(1).uppercased() + dropFirst() }
}
