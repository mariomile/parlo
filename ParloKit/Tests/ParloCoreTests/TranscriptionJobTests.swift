import Foundation
import Testing
@testable import ParloCore

@Suite struct RecordingGuardTests {
    @Test func threshold() {
        #expect(!RecordingGuard.isLongEnough(sampleCount: 4_799))
        #expect(RecordingGuard.isLongEnough(sampleCount: 4_800))
    }

    @Test func digitalSilence() {
        #expect(RecordingGuard.isDigitalSilence([Float](repeating: 0, count: 16_000)))
        var quietRoom = [Float](repeating: 0, count: 16_000)
        quietRoom[8_000] = 0.0001
        #expect(!RecordingGuard.isDigitalSilence(quietRoom))
    }
}

@Suite struct DictationJobTests {
    var settings: AppSettings {
        var s = AppSettings.default
        s.dictionary = [DictionaryEntry(term: "Claude Code", heardAs: ["cloud code"])]
        s.snippets = [Snippet(trigger: "my address", text: "Via Roma 1")]
        return s
    }

    @Test func stuckEngineHitsTheDeadline() async throws {
        let stuck = SlowTranscriber()
        var job = TranscriptionJob(transcriber: stuck, llm: nil, settings: settings, speech: nil)
        job.transcriptionDeadline = { _ in 0.05 }
        await #expect(throws: DeadlineExceeded.self) {
            try await job.run(Array(repeating: 0.1, count: Audio.sampleRate), .dictation(bundleID: nil))
        }
        stuck.release.value = true
    }

    @Test func shortAudioDiscarded() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "hi"), llm: nil, settings: settings, speech: nil)
        #expect(try await p.run([0, 0], .dictation(bundleID: nil)) == .discarded)
    }

    @Test func emptyTranscript() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "  \n"), llm: nil, settings: settings, speech: nil)
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil)) == .empty)
    }

    @Test func silenceIsEmptyWithoutTranscribing() async throws {
        // Parakeet invents words ("Oh yeah.") on silence; the detector must stop them reaching the paste.
        let p = TranscriptionJob(
            transcriber: FakeTranscriber(text: "Oh yeah."), llm: nil, settings: settings,
            speech: FakeSpeechDetector(speech: false)
        )
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil)) == .empty)
    }

    @Test func speechIsTranscribed() async throws {
        let p = TranscriptionJob(
            transcriber: FakeTranscriber(text: "ciao"), llm: nil, settings: settings,
            speech: FakeSpeechDetector(speech: true)
        )
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil)) == .text("ciao", warning: nil))
    }

    @Test func noLLMAppliesDictionaryAndSnippets() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "open cloud code at my address"), llm: nil, settings: settings, speech: nil)
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil)) == .text("open Claude Code at Via Roma 1", warning: nil))
    }

    @Test func spokenLayoutCommands() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "Ciao, a capo, come stai?"), llm: nil, settings: settings, speech: nil)
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil)) == .text("Ciao\nCome stai?", warning: nil))
    }

    @Test func llmCleanupWithStyleAndPlaceholders() async throws {
        let llm = FakeLLM { _, user in
            user.replacingOccurrences(of: "<transcript>", with: "").replacingOccurrences(of: "</transcript>", with: "")
                .replacingOccurrences(of: "um ", with: "").capitalized(firstOnly: true) + "."
        }
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "um send it to my address"), llm: llm, settings: settings, speech: nil)
        let out = try await p.run(oneSecond, .dictation(bundleID: "com.apple.mail"))
        #expect(out == .text("Send it to Via Roma 1.", warning: nil))
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].user == "<transcript>um send it to ⟦S1⟧</transcript>")
        #expect(llm.calls[0].system.contains(PromptBuilder.styleInstruction(.formal)))
        #expect(llm.calls[0].system.contains("Claude Code"))
        #expect(llm.calls[0].timeout == TranscriptionJob.cleanupTimeout(for: "um send it to ⟦S1⟧"))
    }

    @Test func llmFailureKeepsText() async throws {
        let llm = FakeLLM { _, _ in throw FailingError() }
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "cloud code at my address"), llm: llm, settings: settings, speech: nil)
        let out = try await p.run(oneSecond, .dictation(bundleID: nil))
        guard case let .text(text, err) = out else { Issue.record("unexpected \(out)"); return }
        #expect(text == "Claude Code at Via Roma 1")
        #expect(err != nil)
    }

    @Test func dictionaryReachesTranscriber() async throws {
        let transcriber = RecordingTranscriber(text: "ciao")
        let s = settings
        let p = TranscriptionJob(transcriber: transcriber, llm: nil, settings: s, speech: nil)
        _ = try await p.run(oneSecond, .dictation(bundleID: nil))
        #expect(transcriber.dictionaries.value == [s.dictionary])
    }

    @Test(arguments: [
        "Sono le quindici e trenta a Roma, dove adesso il cielo è sereno e la temperatura è di circa ventidue gradi.",
        "ok",
        "Ciao Marco, ti scrivo perché domani non posso venire alla call. Possiamo spostarla a giovedì? Fammi sapere quando puoi, grazie mille di tutto.",
    ])
    func implausibleLengthFallsBackToRaw(reply: String) async throws {
        let llm = FakeLLM { _, _ in reply }
        let p = TranscriptionJob(
            transcriber: FakeTranscriber(text: "che ore sono adesso a roma per favore"), llm: llm, settings: .default, speech: nil
        )
        let out = try await p.run(oneSecond, .dictation(bundleID: nil))
        #expect(out == .text("che ore sono adesso a roma per favore", warning: "Cleanup output looked wrong"))
    }

    @Test func preambleAndTagsStrippedFromCleanup() async throws {
        let llm = FakeLLM { _, _ in "Ecco il testo pulito:\n\"<transcript>Ho fatto il commit, ma la pull request non è pronta.</transcript>\"" }
        let p = TranscriptionJob(
            transcriber: FakeTranscriber(text: "ho fatto il commit ma la pull request non e pronta"), llm: llm,
            settings: .default, speech: nil
        )
        #expect(try await p.run(oneSecond, .dictation(bundleID: nil))
            == .text("Ho fatto il commit, ma la pull request non è pronta.", warning: nil))
    }

    @Test func llmDroppingTokenFallsBack() async throws {
        let llm = FakeLLM { _, _ in "Send it." }
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "send it to my address"), llm: llm, settings: settings, speech: nil)
        let out = try await p.run(oneSecond, .dictation(bundleID: nil))
        guard case let .text(text, err) = out else { Issue.record("unexpected \(out)"); return }
        #expect(text == "send it to Via Roma 1")
        #expect(err != nil)
    }

    @Test func longDictationsGetMoreTimeForCleanup() {
        #expect(TranscriptionJob.cleanupTimeout(for: "Ci vediamo domani.") < 6)
        // About two minutes of hands-free speech.
        #expect(TranscriptionJob.cleanupTimeout(for: String(repeating: "parola ", count: 300)) > 20)
    }

    @Test func textTooLongSkipsCleanup() async throws {
        let llm = FakeLLM { _, _ in "x" }
        let long = String(repeating: "parola ", count: TranscriptionJob.cleanupMaxCharacters / 7 + 1)
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: long), llm: llm, settings: .default, speech: nil)
        let out = try await p.run(oneSecond, .dictation(bundleID: nil))
        #expect(out == .text(long.trimmingCharacters(in: .whitespaces), warning: "Too long for AI cleanup"))
        #expect(llm.calls.isEmpty)
    }
}

@Suite struct CommandJobTests {
    @Test func requiresLLM() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "make formal"), llm: nil, settings: .default, speech: nil)
        await #expect(throws: CommandError.llmNotConfigured) { try await p.run(oneSecond, .command(selection: "x")) }
    }

    @Test func silenceIsEmptyWithoutCallingLLM() async throws {
        let llm = FakeLLM { _, _ in "Dear Sir." }
        let p = TranscriptionJob(
            transcriber: FakeTranscriber(text: "Hello."), llm: llm, settings: .default,
            speech: FakeSpeechDetector(speech: false)
        )
        #expect(try await p.run(oneSecond, .command(selection: "x")) == .empty)
        #expect(llm.calls.isEmpty)
    }

    @Test func forwardsSelection() async throws {
        let llm = FakeLLM { _, _ in "  Dear Sir.  " }
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "make formal"), llm: llm, settings: .default, speech: nil)
        #expect(try await p.run(oneSecond, .command(selection: "hey dude")) == .text("Dear Sir.", warning: nil))
        #expect(llm.calls[0].user.contains("hey dude"))
        #expect(llm.calls[0].timeout == 15)
    }

    @Test func emptyInstruction() async throws {
        let llm = FakeLLM { _, _ in "x" }
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: " "), llm: llm, settings: .default, speech: nil)
        #expect(try await p.run(oneSecond, .command(selection: nil)) == .empty)
        #expect(llm.calls.isEmpty)
    }

    @Test func shortDiscarded() async throws {
        let p = TranscriptionJob(transcriber: FakeTranscriber(text: "x"), llm: FakeLLM { _, _ in "y" }, settings: .default, speech: nil)
        #expect(try await p.run([0], .command(selection: nil)) == .discarded)
    }
}

extension String {
    func capitalized(firstOnly: Bool) -> String { prefix(1).uppercased() + dropFirst() }
}
