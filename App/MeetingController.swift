import AppKit
import ParloCore

/// Meetings: records both sides of a call, then transcribes them and writes the notes in the background,
/// one meeting at a time and behind any dictation.
@MainActor @Observable
final class MeetingController {
    /// What processing a meeting needs from the rest of the app, read when it starts.
    struct Context {
        let languageCode: String?
        let dictionary: [DictionaryEntry]
        let segmenter: (any SpeechSegmenting)?
        /// Nil when no model can write notes right now; `notesProblem` says why.
        let notes: MeetingNotes?
        let notesProblem: String?
    }

    let store = MeetingStore(directory: MeetingStore.appSupportDirectory)
    private(set) var recordingID: String?
    private(set) var progress: [String: Double] = [:]
    private var recorder: MeetingRecorder?
    private var queue: Task<Void, Never>?
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

    /// Meetings a quit or crash left recording or processing are kept as failures, to process again.
    func launch() {
        store.markInterrupted()
    }

    func start(deviceUID: String?) {
        guard recordingID == nil else { return }
        let meeting: Meeting
        do { meeting = try store.create() } catch {
            return report("Couldn't start the meeting: \(error.localizedDescription)", true)
        }
        do {
            let recorder = try MeetingRecorder(
                me: store.trackURL(meeting.id, .me), them: store.trackURL(meeting.id, .them), deviceUID: deviceUID
            )
            recorder.onFailure = { [weak self] reason in
                self?.report("\(reason). The meeting so far is kept.", true)
                self?.stop()
            }
            self.recorder = recorder
            recordingID = meeting.id
            report("Recording the meeting", false)
        } catch {
            store.delete(meeting.id)
            report("Couldn't start the meeting: \(error.localizedDescription)", true)
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
        if let writeError { report("Part of the meeting couldn't be saved: \(writeError.localizedDescription)", true) }
        process(id)
    }

    /// Quit, logout or a system update: the files are finished so the meeting can be processed on next launch.
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
        guard let meeting = store.meeting(id), meeting.hasAudio else { return }
        store.update(id) { $0.status = .processing }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.run(id)
        }
    }

    func delete(_ id: String) {
        guard id != recordingID else { return }
        store.delete(id)
    }

    func copy(_ meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdown, forType: .string)
    }

    private func run(_ id: String) async {
        progress[id] = 0
        defer { progress[id] = nil }
        let context = context()
        do {
            let me = try await AudioFileDecoder.decode(store.trackURL(id, .me))
            let them = try await AudioFileDecoder.decode(store.trackURL(id, .them))
            let tracks = MeetingTrackTranscriber(
                transcriber: BackgroundTranscriber(gate: gate), segmenter: context.segmenter,
                languageCode: context.languageCode, dictionary: context.dictionary
            )
            // Transcription is most of the work; the notes are the last tenth.
            // Theirs first: my track is cut where they speak, so what the microphone heard from the speakers drops out.
            let share = Double(them.count) / Double(max(me.count + them.count, 1))
            let theirs = try await tracks.turns(them, speaker: .them) { [weak self] p in self?.advance(id, to: p * share * 0.9) }
            let mine = try await tracks.turns(me, speaker: .me, cutAt: theirs.flatMap { [$0.start, $0.end] }) { [weak self] p in
                self?.advance(id, to: (share + p * (1 - share)) * 0.9)
            }
            let turns = MeetingTranscript.merge(me: mine, them: theirs)
            let othersSilent = RecordingGuard.isDigitalSilence(them)
            store.update(id) {
                $0.turns = turns
                $0.othersSilent = othersSilent
                $0.duration = max($0.duration, Audio.seconds(max(me.count, them.count)))
            }
            var notesError = context.notesProblem
            if let notes = context.notes, !turns.isEmpty {
                do {
                    let result = try await notes.write(MeetingTranscript.lines(turns), duration: Audio.seconds(max(me.count, them.count)))
                    store.update(id) {
                        $0.title = result.title
                        $0.notes = result.notes
                    }
                    notesError = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    notesError = error.localizedDescription
                }
            }
            store.update(id) {
                $0.notesError = turns.isEmpty ? nil : notesError
                $0.status = .done
            }
            report(turns.isEmpty ? "Nothing heard in the meeting" : "Meeting notes are ready", false)
        } catch {
            store.update(id) { $0.status = .failed(error.localizedDescription) }
            report("Couldn't process the meeting: \(error.localizedDescription)", true)
        }
    }

    /// Progress reported from the transcriber's task.
    private nonisolated func advance(_ id: String, to fraction: Double) {
        Task { @MainActor in if self.progress[id] != nil { self.progress[id] = fraction } }
    }
}
