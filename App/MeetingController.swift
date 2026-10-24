import AppKit
import ParloCore
import ParloEngines

/// Meetings: records both sides of a call, then transcribes them and writes the notes in the background,
/// one meeting at a time and behind any dictation.
@MainActor @Observable
final class MeetingController {
    /// What processing a meeting needs from the rest of the app, read when it starts.
    struct Context {
        let languageCode: String?
        let dictionary: [DictionaryEntry]
        /// Writes the notes from the transcript lines and the meeting's length. Nil when no model can write
        /// them right now; `notesProblem` says why.
        let writeNotes: (([String], Double) async throws -> MeetingNotes.Result)?
        let notesProblem: String?
    }

    let store = MeetingStore(directory: MeetingStore.appSupportDirectory)
    private(set) var recordingID: String?
    private(set) var progress: [String: Double] = [:]
    /// The last thing that went wrong with a meeting, for the menu: the HUD line is lost while dictating.
    private(set) var problem: String?
    private var recorder: MeetingRecorder?
    /// One task per meeting being processed, each waiting for the one queued before it.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var last: Task<Void, Never>?
    /// Meetings find their own speech: sharing dictation's detector would make a dictation wait behind an hour of audio.
    private var segmenter: SileroSpeechDetector?
    private var sleepObserver: NSObjectProtocol?
    private let gate: TranscriberGate
    private let context: () -> Context
    /// A short line for the HUD.
    private let report: (String, _ isError: Bool) -> Void

    init(gate: TranscriberGate, context: @escaping () -> Context, report: @escaping (String, Bool) -> Void) {
        self.gate = gate
        self.context = context
        self.report = report
    }

    var meetings: [Meeting] { store.meetings }
    var isRecording: Bool { recordingID != nil }

    /// Meetings a quit or crash left recording or processing are kept as failures, to process again with ↻.
    func launch() {
        store.markInterrupted()
        // A meeting left recording through the night would otherwise come back as one long silence.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func start(deviceUID: String?) {
        guard recordingID == nil else { return }
        problem = nil
        let meeting: Meeting
        do { meeting = try store.create() } catch {
            return fail("Couldn't start the meeting: \(error.localizedDescription)")
        }
        do {
            let recorder = try MeetingRecorder(
                me: store.trackURL(meeting.id, .me), them: store.trackURL(meeting.id, .them), deviceUID: deviceUID
            )
            recorder.onFailure = { [weak self] reason in
                self?.fail("\(reason). The meeting so far is kept.")
                self?.stop()
            }
            recorder.onSystemAudioLost = { [weak self] reason in
                self?.fail("The call can't be heard anymore (\(reason)). Recording only your side.")
            }
            self.recorder = recorder
            recordingID = meeting.id
            if let reason = recorder.systemAudioProblem {
                fail("The call can't be heard (\(reason)). Recording only your side.")
            } else {
                report("Recording the meeting", false)
            }
        } catch {
            store.delete(meeting.id)
            fail("Couldn't start the meeting: \(error.localizedDescription)")
        }
    }

    /// Ends the recording and queues it for transcription and notes.
    func stop() {
        guard let id = recordingID, let recorder else { return }
        let writeError = recorder.stop()
        let duration = recorder.duration
        self.recorder = nil
        recordingID = nil
        store.update(id) {
            $0.duration = duration
            $0.status = .processing
        }
        if let writeError { fail("Part of the meeting couldn't be saved: \(writeError.localizedDescription)") }
        process(id)
    }

    /// Quit, logout or a system update: the files are finished and the meeting is kept to process again with ↻.
    func terminate() {
        guard let id = recordingID, let recorder else { return }
        _ = recorder.stop()
        let duration = recorder.duration
        store.update(id) {
            $0.duration = duration
            $0.status = .failed("Interrupted")
        }
    }

    /// Transcribes the meeting again and writes new notes.
    func process(_ id: String) {
        guard tasks[id] == nil, let meeting = store.meeting(id), meeting.hasAudio else { return }
        store.update(id) { $0.status = .processing }
        let previous = last
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.run(id)
        }
        tasks[id] = task
        last = task
    }

    /// Deleting a meeting also stops its processing.
    func delete(_ id: String) {
        guard id != recordingID else { return }
        tasks.removeValue(forKey: id)?.cancel()
        store.delete(id)
    }

    func copy(_ meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdown, forType: .string)
    }

    private func run(_ id: String) async {
        progress[id] = 0
        defer {
            progress[id] = nil
            tasks[id] = nil
        }
        let context = context()
        do {
            let me = try await samples(id, .me)
            let them = try await samples(id, .them)
            let tracks = try await MeetingTrackTranscriber(
                transcriber: BackgroundTranscriber(gate: gate), segmenter: speechSegmenter(),
                languageCode: context.languageCode, dictionary: context.dictionary
            )
            // Transcription is most of the work; the notes are the last tenth.
            // Theirs first: my track is cut where they speak, so what the microphone heard from the speakers drops out.
            let share = Double(them.count) / Double(max(me.count + them.count, 1))
            let theirs = try await tracks.turns(them, speaker: .them) { [weak self] p in self?.advance(id, to: p * share * 0.9) }
            let mine = try await tracks.turns(me, speaker: .me, cutAt: theirs.flatMap { [$0.start, $0.end] }) { [weak self] p in
                self?.advance(id, to: (share + p * (1 - share)) * 0.9)
            }
            try Task.checkCancellation()
            let turns = MeetingTranscript.merge(me: mine, them: theirs)
            let duration = Audio.seconds(max(me.count, them.count))
            store.update(id) {
                $0.turns = turns
                $0.othersSilent = RecordingGuard.isDigitalSilence(them)
                $0.duration = max($0.duration, duration)
                // Notes from an earlier pass describe a transcript that is gone.
                $0.title = nil
                $0.notes = nil
                $0.notesError = nil
            }
            var notesError = context.notesProblem
            if let writeNotes = context.writeNotes, !turns.isEmpty {
                do {
                    let result = try await writeNotes(MeetingTranscript.lines(turns), duration)
                    try Task.checkCancellation()
                    store.update(id) {
                        $0.title = result.title
                        $0.notes = result.notes
                    }
                    notesError = result.coversWholeMeeting
                        ? nil : "These notes cover only the start of the meeting: the model couldn't shorten the rest enough"

                } catch {
                    // Cancelled requests surface as their client's own error, such as URLError.cancelled.
                    if Task.isCancelled { throw CancellationError() }
                    notesError = error.localizedDescription
                }
            }
            store.update(id) {
                $0.notesError = turns.isEmpty ? nil : notesError
                $0.status = .done
            }
            if recordingID == nil { problem = nil }
            report(turns.isEmpty ? "Nothing heard in the meeting" : "Meeting notes are ready", false)
        } catch {
            // Deleted while it was being processed: nothing is left to tell about.
            guard !Task.isCancelled, store.meeting(id) != nil else { return }
            store.update(id) { $0.status = .failed(error.localizedDescription) }
            fail("Couldn't process the meeting: \(error.localizedDescription)")
        }
    }

    /// A side that captured nothing, such as the Mac's audio when its permission is off, is a silent side, not a failure.
    private func samples(_ id: String, _ speaker: MeetingTurn.Speaker) async throws -> [Float] {
        do {
            return try await AudioFileDecoder.decode(store.trackURL(id, speaker))
        } catch AudioFileError.empty {
            return []
        }
    }

    private func speechSegmenter() async throws -> SileroSpeechDetector {
        if let segmenter { return segmenter }
        do {
            let loaded = try await SileroSpeechDetector.load()
            segmenter = loaded
            return loaded
        } catch {
            throw MeetingError.speechDetection(error.localizedDescription)
        }
    }

    private func fail(_ text: String) {
        problem = text
        report(text, true)
    }

    /// Progress reported from the transcriber's task.
    private nonisolated func advance(_ id: String, to fraction: Double) {
        Task { @MainActor in if self.progress[id] != nil { self.progress[id] = fraction } }
    }
}

private enum MeetingError: LocalizedError {
    case speechDetection(String)

    var errorDescription: String? {
        switch self {
        case let .speechDetection(reason): "Speech detection couldn't load (\(reason))"
        }
    }
}
