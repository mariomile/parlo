import Foundation
import Testing
@testable import ParloCore

@Suite struct MeetingTranscriptTests {
    func turn(_ speaker: MeetingTurn.Speaker, _ start: Double, _ end: Double, _ text: String) -> MeetingTurn {
        MeetingTurn(speaker: speaker, start: start, end: end, text: text)
    }

    @Test func mergesBothTracksInTimeOrder() {
        let me = [turn(.me, 5, 8, "Sounds good to me"), turn(.me, 20, 22, "Yes")]
        let them = [turn(.them, 0, 4, "Shall we ship on Friday?"), turn(.them, 10, 15, "Then I'll tell marketing")]
        #expect(MeetingTranscript.merge(me: me, them: them).map(\.start) == [0, 5, 10, 20])
    }

    @Test func dropsMyTurnWhenItRepeatsWhatTheySaid() {
        let them = [turn(.them, 10, 16, "We should move the launch to next Thursday because the build is late")]
        let echo = turn(.me, 10.4, 16.2, "move the launch to next Thursday because the build")
        let reply = turn(.me, 17, 20, "Thursday works, I will update the launch plan")
        let merged = MeetingTranscript.merge(me: [echo, reply], them: them)
        #expect(merged.map(\.speaker) == [.them, .me])
        #expect(merged.last?.text == reply.text)
    }

    @Test func keepsMyQuestionWhenTheirAnswerRepeatsItsWords() {
        let question = turn(.me, 0, 2.9, "Can you send me the budget for the launch by Friday?")
        let them = [turn(.them, 3.9, 6.8, "Sure, I will send the budget on Thursday morning.")]
        #expect(!MeetingTranscript.isEcho(question, of: them))
    }

    @Test func keepsMyTurnThatOnlySharesAWord() {
        let them = [turn(.them, 0, 5, "The budget review is on Monday morning")]
        let mine = turn(.me, 1, 5, "Monday is impossible for me, I'm travelling")
        #expect(!MeetingTranscript.isEcho(mine, of: them))
    }

    @Test func keepsShortTurnsAndTurnsAtOtherTimes() {
        let them = [turn(.them, 0, 5, "Please send the quarterly report today")]
        #expect(!MeetingTranscript.isEcho(turn(.me, 1, 2, "report today"), of: them))
        #expect(!MeetingTranscript.isEcho(turn(.me, 60, 65, "please send the quarterly report today"), of: them))
    }

    @Test func timestamps() {
        #expect(MeetingTranscript.timestamp(0) == "0:00")
        #expect(MeetingTranscript.timestamp(245.9) == "4:05")
        #expect(MeetingTranscript.timestamp(3729) == "1:02:09")
    }

    @Test func markdownHasNotesThenTranscript() {
        let meeting = Meeting(
            id: "1", date: Date(timeIntervalSince1970: 0), duration: 90, title: "Launch", status: .done,
            turns: [turn(.them, 3, 5, "Ready?"), turn(.me, 6, 7, "Yes")], notes: "## Summary\n- Ship it"
        )
        let md = meeting.markdown
        #expect(md.hasPrefix("# Launch\n"))
        #expect(md.contains("## Summary\n- Ship it\n\n## Transcript"))
        #expect(md.contains("**[0:03] Them:** Ready?\n\n**[0:06] Me:** Yes"))
    }
}

@Suite struct MeetingNotesTests {
    @Test func chunksNeverSplitATurn() {
        let lines = ["aaaa", "bbbb", "cccc"]
        #expect(MeetingNotes.chunks(lines, maxCharacters: 9) == ["aaaa\nbbbb", "cccc"])
        #expect(MeetingNotes.chunks(lines, maxCharacters: 100) == ["aaaa\nbbbb\ncccc"])
    }

    @Test func cutsATurnLongerThanAChunkAtWords() {
        let chunks = MeetingNotes.chunks(["one two three four"], maxCharacters: 9)
        #expect(chunks == ["one two", "three", "four"])
        #expect(chunks.allSatisfy { $0.count <= 9 })
    }

    @Test func parsesTitleAndDropsFence() {
        let result = MeetingNotes.parse("```markdown\nTitle: **Launch plan**\n## Summary\n- Ship\n```")
        #expect(result.title == "Launch plan")
        #expect(result.notes == "## Summary\n- Ship")
        #expect(MeetingNotes.parse("## Summary\n- Ship").title == nil)
        #expect(MeetingNotes.parse("**Title:** Launch plan\n## Summary").title == "Launch plan")
        #expect(MeetingNotes.parse("# Title: Launch plan\n## Summary") == .init(title: "Launch plan", notes: "## Summary"))
    }

    @Test func wideScriptsCountForMore() {
        // A CJK character is about a token, a Latin one about a quarter of one.
        #expect(MeetingNotes.size("会议") == 6)
        #expect(MeetingNotes.size("ok") == 2)
        let chunks = MeetingNotes.chunks(["会议会议", "会议"], maxCharacters: 12)
        #expect(chunks == ["会议会议", "会议"])
        #expect(MeetingNotes.chunks(["会议会议会议"], maxCharacters: 6) == ["会议", "会议", "会议"])
    }

    @Test func shortMeetingIsOneRequest() async throws {
        let llm = FakeLLM { _, _ in "Title: Sync\n## Summary\n- ok" }
        let result = try await MeetingNotes(llm: llm, maxCharacters: 1000).write(["[0:00] Me: hi", "[0:02] Them: hello"], duration: 60)
        #expect(result == .init(title: "Sync", notes: "## Summary\n- ok"))
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].system == MeetingNotes.finalPrompt)
        #expect(llm.calls[0].user.contains("[0:02] Them: hello"))
    }

    @Test func longMeetingIsReadInPartsThenMerged() async throws {
        let llm = FakeLLM { system, user in
            if system == MeetingNotes.extractPrompt { return "- p" }
            if system == MeetingNotes.mergePrompt { return "- m" }
            return "Title: Long\n## Summary\n- done"
        }
        let lines = (0..<10).map { "[0:\(String(format: "%02d", $0))] Me: " + String(repeating: "x", count: 40) }
        // Room for two 51-character lines per request.
        let limit = MeetingNotes.overhead(600) + 110
        let result = try await MeetingNotes(llm: llm, maxCharacters: limit).write(lines, duration: 600)
        #expect(result.title == "Long")
        #expect(result.coversWholeMeeting)
        let systems = llm.calls.map(\.system)
        #expect(systems.filter { $0 == MeetingNotes.extractPrompt }.count == 5)
        #expect(systems.last == MeetingNotes.finalPrompt)
        #expect(llm.calls.allSatisfy { $0.user.count <= limit })
    }

    @Test func mergeRoundsStopWhenTheModelDoesNotShrinkThePoints() async throws {
        let llm = FakeLLM { system, user in
            system == MeetingNotes.finalPrompt ? "## Summary\n- x" : String(repeating: "y", count: 60)
        }
        let lines = (0..<4).map { _ in String(repeating: "z", count: 90) }
        let result = try await MeetingNotes(llm: llm, maxCharacters: MeetingNotes.overhead(60) + 100).write(lines, duration: 60)
        #expect(result.notes == "## Summary\n- x")
        #expect(!result.coversWholeMeeting)
        #expect(llm.calls.count < 20)
        #expect(llm.calls.allSatisfy { $0.user.count <= MeetingNotes.overhead(60) + 100 })
    }
}

@MainActor @Suite struct MeetingStoreTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-meetings-\(UUID().uuidString)")

    @Test func savesAndReloads() throws {
        let store = MeetingStore(directory: dir)
        let meeting = try store.create(date: Date(timeIntervalSince1970: 100))
        #expect(meeting.status == .recording)
        store.update(meeting.id) {
            $0.status = .done
            $0.turns = [MeetingTurn(speaker: .me, start: 0, end: 1, text: "hi")]
            $0.notes = "## Summary"
        }
        let reloaded = MeetingStore(directory: dir)
        #expect(reloaded.meetings == store.meetings)
        #expect(reloaded.meeting(meeting.id)?.notes == "## Summary")
    }

    @Test func meetingsInTheSameMillisecondGetTheirOwnFolder() throws {
        let store = MeetingStore(directory: dir)
        let date = Date(timeIntervalSince1970: 100)
        let a = try store.create(date: date)
        let b = try store.create(date: date)
        #expect(a.id != b.id)
        #expect(store.trackURL(a.id, .me) != store.trackURL(b.id, .me))
    }

    @Test func interruptedMeetingsFail() throws {
        let store = MeetingStore(directory: dir)
        let recording = try store.create(date: Date(timeIntervalSince1970: 1))
        let processing = try store.create(date: Date(timeIntervalSince1970: 2))
        store.update(processing.id) { $0.status = .processing }
        MeetingStore(directory: dir).markInterrupted()
        let reloaded = MeetingStore(directory: dir)
        #expect(reloaded.meeting(recording.id)?.status == .failed("Interrupted"))
        #expect(reloaded.meeting(processing.id)?.status == .failed("Interrupted"))
    }

    @Test func oldFinishedMeetingsLoseTheirRecordingsButNotFailedOnes() throws {
        let store = MeetingStore(directory: dir, audioLimit: 1)
        let failed = try store.create(date: Date(timeIntervalSince1970: 1))
        store.update(failed.id) { $0.status = .failed("x") }
        let old = try store.create(date: Date(timeIntervalSince1970: 2))
        store.update(old.id) { $0.status = .done }
        let recent = try store.create(date: Date(timeIntervalSince1970: 3))
        store.update(recent.id) { $0.status = .done }
        for id in [failed.id, old.id, recent.id] { try Data([1]).write(to: store.trackURL(id, .me)) }

        _ = try store.create(date: Date(timeIntervalSince1970: 4))
        #expect(store.meeting(old.id)?.hasAudio == false)
        #expect(!FileManager.default.fileExists(atPath: store.trackURL(old.id, .me).path))
        #expect(store.meeting(recent.id)?.hasAudio == true)
        #expect(FileManager.default.fileExists(atPath: store.trackURL(failed.id, .me).path))
    }

    @Test func deleteRemovesTheFolder() throws {
        let store = MeetingStore(directory: dir)
        let meeting = try store.create()
        try Data([1]).write(to: store.trackURL(meeting.id, .them))
        store.delete(meeting.id)
        #expect(store.meetings.isEmpty)
        #expect(MeetingStore(directory: dir).meetings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.trackURL(meeting.id, .them).path))
    }
}

@Suite struct MeetingTrackTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "parlo-track-\(UUID().uuidString).caf")

    @Test func writerFillsGapsToKeepTheMeetingClock() async throws {
        let clock = LockedBox(0.0)
        let writer = try TrackWriter(url: url, elapsed: { clock.value })
        clock.value = 1
        writer.append(oneSecond)
        clock.value = 4 // two seconds missing, then one more second
        writer.append(oneSecond)
        clock.value = 5.1 // jitter, not a gap
        writer.append(oneSecond)
        #expect(writer.close() == nil)

        let samples = try await AudioFileDecoder.decode(url)
        #expect(samples.count == 5 * Audio.sampleRate)
        #expect(abs(samples[Audio.sampleCount(0.5)] - 0.1) < 0.001)
        #expect(samples[Audio.sampleCount(2)] == 0)
        #expect(abs(samples[Audio.sampleCount(3.5)] - 0.1) < 0.001)
    }

    struct Segmenter: SpeechSegmenting {
        let ranges: [Range<Int>]
        func speechRanges(_ samples: [Float]) async throws -> [Range<Int>] { ranges }
    }

    final class ScriptedTranscriber: Transcriber, @unchecked Sendable {
        var replies: [Result<String, FailingError>]
        init(_ replies: [Result<String, FailingError>]) { self.replies = replies }
        func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
            try replies.removeFirst().get()
        }
    }

    @Test func eachStretchOfSpeechBecomesATimedTurn() async throws {
        let samples = [Float](repeating: 0.1, count: 10 * Audio.sampleRate)
        let segmenter = Segmenter(ranges: [Audio.sampleCount(1)..<Audio.sampleCount(3), Audio.sampleCount(5)..<Audio.sampleCount(9)])
        let track = MeetingTrackTranscriber(
            transcriber: ScriptedTranscriber([.success(" Hello "), .success("")]), segmenter: segmenter, languageCode: nil, dictionary: []
        )
        let progress = LockedBox<[Double]>([])
        let turns = try await track.turns(samples, speaker: .them) { progress.value.append($0) }
        #expect(turns == [MeetingTurn(speaker: .them, start: 1, end: 3, text: "Hello")])
        #expect(progress.value == [0.5, 1])
    }

    @Test func stretchIsCutWhereTheOtherSideStartsAndStops() async throws {
        let samples = [Float](repeating: 0.1, count: 10 * Audio.sampleRate)
        let segmenter = Segmenter(ranges: [0..<Audio.sampleCount(9)])
        let track = MeetingTrackTranscriber(
            transcriber: ScriptedTranscriber([.success("Mine"), .success("Echo"), .success("Mine again")]), segmenter: segmenter,
            languageCode: nil, dictionary: []
        )
        let turns = try await track.turns(samples, speaker: .me, cutAt: [3, 6, 12]) { _ in }
        #expect(turns.map { [$0.start, $0.end] } == [[0, 3], [3, 6], [6, 9]])
        #expect(turns.map(\.text) == ["Mine", "Echo", "Mine again"])
    }

    @Test func oneFailedStretchCostsOnlyItself() async throws {
        let samples = [Float](repeating: 0.1, count: 4 * Audio.sampleRate)
        let segmenter = Segmenter(ranges: [0..<Audio.sampleCount(2), Audio.sampleCount(2)..<Audio.sampleCount(4)])
        let ok = MeetingTrackTranscriber(
            transcriber: ScriptedTranscriber([.failure(FailingError()), .success("Still here")]), segmenter: segmenter,
            languageCode: nil, dictionary: []
        )
        #expect(try await ok.turns(samples, speaker: .me) { _ in }.map(\.text) == ["Still here"])

        let broken = MeetingTrackTranscriber(
            transcriber: ScriptedTranscriber([.failure(FailingError()), .failure(FailingError())]), segmenter: segmenter,
            languageCode: nil, dictionary: []
        )
        await #expect(throws: FailingError.self) { try await broken.turns(samples, speaker: .me) { _ in } }
    }

    @Test func silentTrackHasNoTurns() async throws {
        let track = MeetingTrackTranscriber(
            transcriber: ScriptedTranscriber([]), segmenter: Segmenter(ranges: []), languageCode: nil, dictionary: []
        )
        #expect(try await track.turns([Float](repeating: 0, count: 32_000), speaker: .them) { _ in }.isEmpty)
    }
}
