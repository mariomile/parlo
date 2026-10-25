import Foundation
import Testing
@testable import ParloCore

@Suite struct MeetingEchoReliabilityTests {
    @Test(arguments: [
        ("Non approvo il budget proposto", "Approvo il budget proposto"),
        ("Approvo il budget proposto", "Non approvo il budget proposto"),
        ("I do not approve this budget", "I do approve this budget"),
        ("We should ship next Friday", "We should not ship next Friday"),
        ("We should ship next Friday", "We should ship next Thursday"),
        ("We owe them 100 euros", "We owe them 1000 euros"),
        ("We owe them 10.50 euros", "We owe them 10,50 euros"),
        ("We owe them -100 euros", "We owe them 100 euros"),
        ("We owe them €100 today", "We owe them $100 today"),
        ("We accept >100 units today", "We accept <100 units today"),
        ("We approved the budget?", "We approved the budget."),
        ("Alice will pay Bob tomorrow", "Bob will pay Alice tomorrow"),
        ("We really really need this", "We really need this"),
        ("move the launch to next Thursday because the build", "We should move the launch to next Thursday because the build is late"),
    ]) func preservesUncertainOverlappingAssertions(_ mine: String, _ theirs: String) {
        let me = MeetingTurn(speaker: .me, start: 1, end: 5, text: mine)
        let them = MeetingTurn(speaker: .them, start: 0, end: 6, text: theirs)
        #expect(!MeetingTranscript.isEcho(me, of: [them]))
        #expect(MeetingTranscript.merge(me: [me], them: [them]).count == 2)
    }

    @Test func onlyOneMatchingOverlappingTurnCanEstablishAnEcho() {
        let me = MeetingTurn(speaker: .me, start: 0, end: 8, text: "We approve the proposed budget")
        let unrelated = MeetingTurn(speaker: .them, start: 0, end: 8, text: "Someone else is also speaking")
        let tooShort = MeetingTurn(speaker: .them, start: 6, end: 8, text: me.text)
        #expect(!MeetingTranscript.isEcho(me, of: [unrelated, tooShort, tooShort]))
        let actual = MeetingTurn(speaker: .them, start: 0, end: 8, text: "WE approve the proposed budget.")
        #expect(MeetingTranscript.isEcho(me, of: [actual]))
    }
}

@MainActor @Suite struct MeetingPersistenceReliabilityTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-meeting-reliability-\(UUID().uuidString)")

    private func metadata(_ store: MeetingStore, _ id: String) -> URL {
        store.trackURL(id, .me).deletingLastPathComponent().appending(path: "meeting.json")
    }

    private func record(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try TrackWriter(url: url, elapsed: { 1 })
        writer.append(oneSecond)
        if let error = writer.close() { throw error }
    }

    @Test func anotherSuccessfulSaveCannotHideUnsavedMeetingAndRetryMakesItDurable() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let store = MeetingStore(directory: dir, files: faults.files)
        let a = try store.create(date: Date(timeIntervalSince1970: 1))
        let b = try store.create(date: Date(timeIntervalSince1970: 2))
        faults.unwritable.value = [metadata(store, a.id)]
        store.update(a.id) { $0.status = .done; $0.notes = "irreplaceable new notes" }
        store.update(b.id) { $0.status = .done; $0.notes = "other notes" }
        #expect(store.saveErrors[a.id] != nil)
        #expect(store.saveErrors[b.id] == nil)
        #expect(store.saveError?.contains(a.id) == true)
        #expect(store.meeting(a.id)?.notes == "irreplaceable new notes")
        #expect(MeetingStore(directory: dir).meeting(a.id)?.notes == nil)
        store.retryFailedSaves()
        #expect(store.saveErrors[a.id] != nil)
        faults.unwritable.value = []
        store.retryFailedSaves()
        #expect(store.saveError == nil)
        #expect(MeetingStore(directory: dir).meeting(a.id)?.notes == "irreplaceable new notes")
    }

    @Test func failedDeletionStaysVisibleAndRetryRemovesPrivateAudio() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let store = MeetingStore(directory: dir, files: faults.files)
        let meeting = try store.create()
        try record(store.trackURL(meeting.id, .me))
        let folder = store.trackURL(meeting.id, .me).deletingLastPathComponent()
        faults.undeletable.value = [folder]
        #expect(!store.delete(meeting.id))
        store.update(meeting.id) { $0.notes = "still here" }
        store.retryFailedSaves()
        #expect(store.saveErrors.isEmpty)
        #expect(store.deletionErrors[meeting.id] != nil)
        #expect(store.saveError != nil)
        #expect(store.meeting(meeting.id) != nil)
        #expect(MeetingStore(directory: dir).meeting(meeting.id) != nil)
        #expect(FileManager.default.fileExists(atPath: store.trackURL(meeting.id, .me).path))
        faults.undeletable.value = []
        #expect(store.delete(meeting.id))
        #expect(store.saveError == nil)
        #expect(store.meetings.isEmpty)
        #expect(MeetingStore(directory: dir).meetings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func deletingAnAlreadyMissingFolderSucceeds() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let meeting = try store.create()
        try FileManager.default.removeItem(at: store.trackURL(meeting.id, .me).deletingLastPathComponent())
        #expect(store.delete(meeting.id))
        #expect(store.meetings.isEmpty)
        #expect(store.saveError == nil)
    }

    @Test func initialMetadataFailureDoesNotStartAMeeting() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        faults.unwritable.value = [dir.appending(path: "1000/meeting.json")]
        let store = MeetingStore(directory: dir, files: faults.files)
        #expect(throws: (any Error).self) { try store.create(date: Date(timeIntervalSince1970: 1)) }
        #expect(store.meetings.isEmpty)
        #expect(store.saveError != nil)
        #expect(!FileManager.default.fileExists(atPath: store.trackURL("1000", .me).path))
        faults.unwritable.value = []
        let meeting = try store.create(date: Date(timeIntervalSince1970: 1))
        #expect(MeetingStore(directory: dir).meeting(meeting.id) == meeting)
        #expect(store.saveError == nil)
    }

    @Test(arguments: ["missing", "corrupt", "unreadable"])
    func recoversValidCAFWithoutReplacingOriginalBytes(_ condition: String) throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = MeetingStore(directory: dir)
        let meeting = try initial.create(date: Date(timeIntervalSince1970: 100))
        let track = initial.trackURL(meeting.id, .me)
        try record(track)
        let originalTrack = try Data(contentsOf: track)
        let json = metadata(initial, meeting.id)
        let originalJSON: Data?
        let faults = CorePersistenceFaults()
        switch condition {
        case "missing":
            try FileManager.default.removeItem(at: json)
            originalJSON = nil
        case "corrupt":
            originalJSON = Data("{incomplete metadata".utf8)
            try originalJSON!.write(to: json)
        default:
            originalJSON = try Data(contentsOf: json)
            faults.unreadable.value = [json]
        }
        let recovered = MeetingStore(directory: dir, files: faults.files)
        let found = try #require(recovered.meeting(meeting.id))
        guard case let .failed(reason) = found.status else { Issue.record("Recovery must be visibly interrupted"); return }
        #expect(reason.contains("Recovered recording"))
        #expect(found.duration == 1)
        #expect(found.hasAudio)
        #expect(found.date == meeting.date)
        #expect(found.captureWarnings?.first?.contains("Them: No recoverable audio") == true)
        #expect(recovered.saveError != nil)
        #expect(try Data(contentsOf: track) == originalTrack)
        if let originalJSON { #expect(try Data(contentsOf: json) == originalJSON) }
        recovered.update(meeting.id) { $0.notes = "Recovered notes" }
        if condition == "unreadable" {
            #expect(recovered.saveErrors[meeting.id] != nil)
            #expect(try Data(contentsOf: json) == originalJSON)
            faults.unreadable.value = []
            recovered.retryFailedSaves()
        }
        #expect(recovered.saveError == nil)
        #expect(MeetingStore(directory: dir).meeting(meeting.id)?.notes == "Recovered notes")
        #expect(try Data(contentsOf: track) == originalTrack)
        let backups = try FileManager.default.contentsOfDirectory(at: track.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("meeting.damaged-") }
        #expect(backups.count == (condition == "missing" ? 0 : 1))
        if let originalJSON { #expect(try Data(contentsOf: #require(backups.first)) == originalJSON) }
    }

    @Test func invalidCAFIsNotClaimedAsRecoverableAudio() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a CAF".utf8).write(to: folder.appending(path: "me.caf"))
        #expect(MeetingStore(directory: dir).meetings.isEmpty)
        #expect(try Data(contentsOf: folder.appending(path: "me.caf")) == Data("not a CAF".utf8))
    }

    @Test func unrecoverableMetadataReadErrorsAreNotPendingSavesThatBlockQuit() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("{broken metadata".utf8)
        try bytes.write(to: folder.appending(path: "meeting.json"))
        let store = MeetingStore(directory: dir)
        store.retryFailedSaves()
        #expect(store.meetings.isEmpty)
        #expect(store.saveErrors.isEmpty)
        #expect(store.loadErrors["1000"] != nil)
        #expect(store.saveError != nil)
        #expect(try Data(contentsOf: folder.appending(path: "meeting.json")) == bytes)
    }

    @Test func failedRetentionNeverMarksRemainingAudioMissing() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let store = MeetingStore(directory: dir, audioLimit: 0, files: faults.files)
        let meeting = try store.create()
        try record(store.trackURL(meeting.id, .me))
        try record(store.trackURL(meeting.id, .them))
        store.update(meeting.id) { $0.status = .done }
        faults.undeletable.value = [store.trackURL(meeting.id, .them)]
        store.retryRetention()
        #expect(store.meeting(meeting.id)?.hasAudio == true)
        #expect(store.retentionErrors[meeting.id] != nil)
        store.update(meeting.id) { $0.title = "An unrelated metadata write" }
        #expect(store.saveError != nil)
        #expect(store.saveErrors.isEmpty)
        #expect(MeetingStore(directory: dir).meeting(meeting.id)?.hasAudio == true)
        #expect(FileManager.default.fileExists(atPath: store.trackURL(meeting.id, .them).path))
        faults.undeletable.value = []
        store.retryRetention()
        #expect(store.meeting(meeting.id)?.hasAudio == false)
        #expect(store.saveError == nil)
        #expect(!FileManager.default.fileExists(atPath: store.trackURL(meeting.id, .them).path))
        #expect(MeetingStore(directory: dir).meeting(meeting.id)?.hasAudio == false)
    }

    @Test(arguments: ["capture", "transcription", "unsaved"])
    func retentionKeepsIncompleteAndUnsavedMeetings(_ condition: String) throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let store = MeetingStore(directory: dir, audioLimit: 0, files: faults.files)
        let meeting = try store.create()
        try record(store.trackURL(meeting.id, .me))
        if condition == "unsaved" { faults.unwritable.value = [metadata(store, meeting.id)] }
        store.update(meeting.id) {
            $0.status = .done
            if condition == "capture" { $0.captureWarnings = ["System audio stopped at 0:20"] }
            if condition == "transcription" { $0.transcriptionWarnings = ["Me [0:10–0:20]: Transcription missing"] }
        }
        store.retryRetention()
        #expect(store.meeting(meeting.id)?.hasAudio == true)
        #expect(FileManager.default.fileExists(atPath: store.trackURL(meeting.id, .me).path))
    }

    @Test func warningsPersistAfterDoneAndReachMarkdownAndNotesContext() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(directory: dir)
        let meeting = try store.create()
        store.update(meeting.id) {
            $0.status = .done
            $0.captureWarnings = ["System audio stopped at 0:30"]
            $0.transcriptionWarnings = ["Me [0:10–0:20]: Transcription missing (temporary failure)."]
            $0.turns = [MeetingTurn(speaker: .me, start: 0, end: 1, text: "Known text")]
        }
        let reloaded = try #require(MeetingStore(directory: dir).meeting(meeting.id))
        let llm = FakeLLM { _, _ in "Title: Partial meeting\n## Summary\n- Known text" }
        _ = try await MeetingNotes(llm: llm, maxCharacters: 2000).write(reloaded.notesLines, duration: 60)
        for warning in reloaded.warnings {
            #expect(reloaded.markdown.contains(warning))
            #expect(llm.calls.first?.user.contains(warning) == true)
        }
        #expect(reloaded.markdown.contains("Known text"))
        #expect(llm.calls.first?.user.contains("Do not infer") == true)
    }

    @Test func oldMeetingJSONDecodesWithoutWarningFields() throws {
        let old = Meeting(id: "1", date: .distantPast, status: .done)
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("captureWarnings"))
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded.captureWarnings == nil)
        #expect(decoded.transcriptionWarnings == nil)
        #expect(decoded.warnings.isEmpty)
    }
}

@Suite struct MeetingASRReliabilityTests {
    @Test(arguments: [0, 1, 2]) func exposesFirstMiddleAndLastFailedSpans(_ failed: Int) async throws {
        let replies: [Swift.Result<String, FailingError>] = (0..<3).map { $0 == failed ? .failure(FailingError()) : .success("Turn \($0)") }
        let track = MeetingTrackTranscriber(
            transcriber: MeetingTrackTests.ScriptedTranscriber(replies),
            segmenter: MeetingTrackTests.Segmenter(ranges: (0..<3).map { Audio.sampleCount(Double($0))..<Audio.sampleCount(Double($0 + 1)) }),
            languageCode: nil, dictionary: []
        )
        let result = try await track.transcribe(Array(repeating: 0.1, count: Audio.sampleRate * 3), speaker: .them) { _ in }
        #expect(result.turns.map(\.text) == (0..<3).filter { $0 != failed }.map { "Turn \($0)" })
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.speaker == .them)
        #expect(result.failures.first?.start == Double(failed))
        #expect(result.failures.first?.end == Double(failed + 1))
        #expect(result.warnings.first?.contains("Transcription missing") == true)
        #expect(result.warnings.first?.contains("Them [0:0\(failed)–0:0\(failed + 1)]") == true)
    }

    @Test func whollyFailedTrackReportsAllSpansSoTheOtherTrackCanStillBeUsed() async throws {
        let track = MeetingTrackTranscriber(
            transcriber: MeetingTrackTests.ScriptedTranscriber([.failure(FailingError()), .failure(FailingError())]),
            segmenter: MeetingTrackTests.Segmenter(ranges: [0..<Audio.sampleRate, Audio.sampleRate..<(Audio.sampleRate * 2)]),
            languageCode: nil, dictionary: []
        )
        let result = try await track.transcribe(Array(repeating: 0.1, count: Audio.sampleRate * 2), speaker: .me) { _ in }
        #expect(result.turns.isEmpty)
        #expect(result.failures.count == 2)
        #expect(result.warnings.count == 2)
    }

    struct HeldTranscriber: Transcriber {
        let result: HeldCoreResult<String>
        func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
            await result.wait()
        }
    }

    struct HeldSegmenter: SpeechSegmenting {
        let result: HeldCoreResult<[Range<Int>]>
        func speechRanges(_ samples: [Float]) async throws -> [Range<Int>] { await result.wait() }
    }

    @Test func heldNoncooperativeFinalASRDoesNotTurnCancellationIntoSuccess() async throws {
        let held = HeldCoreResult<String>()
        let track = MeetingTrackTranscriber(
            transcriber: HeldTranscriber(result: held), segmenter: MeetingTrackTests.Segmenter(ranges: [0..<Audio.sampleRate]),
            languageCode: nil, dictionary: []
        )
        let task = Task { try await track.transcribe(oneSecond, speaker: .me) { _ in } }
        await held.waitUntilStarted()
        task.cancel()
        await held.release("obsolete text")
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func heldSegmenterCannotHideCancellationAsAnEmptyTranscript() async throws {
        let held = HeldCoreResult<[Range<Int>]>()
        let track = MeetingTrackTranscriber(
            transcriber: FakeTranscriber(text: "unused"), segmenter: HeldSegmenter(result: held), languageCode: nil, dictionary: []
        )
        let task = Task { try await track.transcribe(oneSecond, speaker: .them) { _ in } }
        await held.waitUntilStarted()
        task.cancel()
        await held.release([])
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    struct FailedSegmenter: SpeechSegmenting {
        func speechRanges(_ samples: [Float]) async throws -> [Range<Int>] { throw FailingError() }
    }

    @Test func failedSegmentationReportsTheWholeTrackInterval() async throws {
        let track = MeetingTrackTranscriber(
            transcriber: FakeTranscriber(text: "unused"), segmenter: FailedSegmenter(), languageCode: nil, dictionary: []
        )
        let result = try await track.transcribe(oneSecond, speaker: .me) { _ in }
        #expect(result.turns.isEmpty)
        #expect(result.failures.first?.start == 0)
        #expect(result.failures.first?.end == 1)
    }
}
