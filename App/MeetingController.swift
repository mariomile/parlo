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

    let store: MeetingStore
    private(set) var recordingID: String?
    private(set) var progress: [String: Double] = [:]
    /// The last thing that went wrong with a meeting, for the menu: the HUD line is lost while dictating.
    private(set) var problem: String?
    private var recorder: MeetingRecorder?
    /// One task per meeting being processed, each waiting for the one queued before it.
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var last: Task<Void, Never>?
    /// Meetings find their own speech: sharing dictation's detector would make a dictation wait behind an hour of audio.
    private var segmenter: SileroSpeechDetector?
    private var sleepObserver: NSObjectProtocol?
    private let gate: TranscriberGate
    private let context: () -> Context
    /// A short line for the HUD.
    private let report: (String, _ isError: Bool) -> Void

    init(
        gate: TranscriberGate, store: MeetingStore = MeetingStore(directory: MeetingStore.appSupportDirectory),
        context: @escaping () -> Context, report: @escaping (String, Bool) -> Void
    ) {
        self.gate = gate
        self.store = store
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
            recorder.onFailure = { [weak self, weak recorder] reason in
                self?.captureWarning(meeting.id, "\(reason). The meeting so far is kept.", at: recorder?.duration)
                if self?.recordingID == meeting.id { self?.stop() }
            }
            recorder.onSystemAudioLost = { [weak self, weak recorder] reason in
                self?.captureWarning(
                    meeting.id, "The call can't be heard anymore (\(reason)). Only your side was recorded after this point.",
                    at: recorder?.duration
                )
            }
            self.recorder = recorder
            recordingID = meeting.id
            if let reason = recorder.systemAudioProblem {
                captureWarning(meeting.id, "The call can't be heard (\(reason)). Recording only your side.", at: 0)
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
        if let writeError {
            captureWarning(id, "Part of the meeting couldn't be saved: \(writeError.localizedDescription)", at: duration)
        }
        self.recorder = nil
        recordingID = nil
        store.update(id) {
            $0.duration = duration
            $0.status = .processing
        }
        process(id)
    }

    /// Quit, logout or a system update: the files are finished and the meeting is kept to process again with ↻.
    func terminate() {
        guard let id = recordingID, let recorder else { return }
        let writeError = recorder.stop()
        let duration = recorder.duration
        if let writeError {
            captureWarning(id, "Part of the meeting couldn't be saved: \(writeError.localizedDescription)", at: duration)
        }
        self.recorder = nil
        recordingID = nil
        store.update(id) {
            $0.duration = duration
            $0.status = .failed("Interrupted")
        }
    }

    /// Transcribes the meeting again and writes new notes.
    func process(_ id: String) {
        guard tasks[id] == nil, let meeting = store.meeting(id), meeting.hasAudio else { return }
        store.update(id) { $0.status = .processing }
        let generation = UUID()
        generations[id] = generation
        let previous = last
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.run(id, generation: generation)
        }
        tasks[id] = task
        last = task
    }

    /// Deleting a meeting also stops its processing.
    func delete(_ id: String) {
        guard id != recordingID else { return }
        tasks.removeValue(forKey: id)?.cancel()
        generations[id] = nil
        progress[id] = nil
        guard !store.delete(id) else { return }
        let reason = store.error(for: id) ?? "The recording files couldn't be removed"
        if store.meeting(id)?.status == .processing {
            store.update(id) { $0.status = .failed("Processing cancelled because deletion was requested") }
        }
        fail("Couldn't delete the meeting: \(reason). Use Delete to retry.")
    }

    func copy(_ meeting: Meeting) {
        Task { [weak self] in
            await ClipboardTurn.copy(meeting.markdown) { [weak self] in self?.store.meeting(meeting.id) != nil }
        }
    }

    private func run(_ id: String, generation: UUID) async {
        guard generations[id] == generation else { return }
        progress[id] = 0
        defer {
            if generations[id] == generation {
                progress[id] = nil
                tasks[id] = nil
                generations[id] = nil
            }
        }
        let context = context()
        do {
            let myTrack = try await samples(id, .me)
            let theirTrack = try await samples(id, .them)
            let me = myTrack.samples, them = theirTrack.samples
            let readWarnings = [myTrack.warning, theirTrack.warning].compactMap { $0 }
            // Until replacement turns exist, the old transcript still needs its coverage warnings.
            // Keep any newly discovered track failures too, even if this attempt stops before ASR.
            if !readWarnings.isEmpty {
                store.update(id) {
                    var warnings = $0.transcriptionWarnings ?? []
                    for warning in readWarnings where !warnings.contains(warning) { warnings.append(warning) }
                    $0.transcriptionWarnings = warnings
                }
            }
            guard !(me.isEmpty && them.isEmpty),
                  readWarnings.isEmpty || !RecordingGuard.isDigitalSilence(me) || !RecordingGuard.isDigitalSilence(them)
            else { throw MeetingError.noUsableAudio }
            let tracks = try await MeetingTrackTranscriber(
                transcriber: BackgroundTranscriber(gate: gate), segmenter: speechSegmenter(),
                languageCode: context.languageCode, dictionary: context.dictionary
            )
            // Transcription is most of the work; the notes are the last tenth.
            // Theirs first: my track is cut where they speak, so what the microphone heard from the speakers drops out.
            let share = Double(them.count) / Double(max(me.count + them.count, 1))
            let theirs = try await tracks.transcribe(them, speaker: .them) { [weak self] p in
                self?.advance(id, generation: generation, to: p * share * 0.9)
            }
            let mine = try await tracks.transcribe(me, speaker: .me, cutAt: theirs.turns.flatMap { [$0.start, $0.end] }) { [weak self] p in
                self?.advance(id, generation: generation, to: (share + p * (1 - share)) * 0.9)
            }
            try Task.checkCancellation()
            let turns = MeetingTranscript.merge(me: mine.turns, them: theirs.turns)
            let transcriptionWarnings = readWarnings + theirs.warnings + mine.warnings
            // Empty speech is a valid result only when no attempted span failed. A wholly failed
            // retry must keep the prior transcript, notes and coverage until a replacement succeeds.
            if turns.isEmpty && (!theirs.failures.isEmpty || !mine.failures.isEmpty) {
                store.update(id) {
                    var warnings = $0.transcriptionWarnings ?? []
                    for warning in transcriptionWarnings where !warnings.contains(warning) { warnings.append(warning) }
                    $0.transcriptionWarnings = warnings
                }
                throw MeetingError.transcriptionFailed
            }
            let duration = Audio.seconds(max(me.count, them.count))
            store.update(id) {
                $0.turns = turns
                $0.transcriptionWarnings = transcriptionWarnings.isEmpty ? nil : transcriptionWarnings
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
                    let lines = store.meeting(id)?.notesLines ?? MeetingTranscript.lines(turns)
                    let result = try await writeNotes(lines, duration)
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
            let warnings = store.meeting(id).map { ($0.captureWarnings ?? []) + ($0.transcriptionWarnings ?? []) } ?? []
            if recordingID == nil { problem = warnings.first }
            report(
                warnings.isEmpty ? (turns.isEmpty ? "Nothing heard in the meeting" : "Meeting notes are ready")
                    : "Meeting processed with missing audio or speech. Review its warnings.",
                !warnings.isEmpty
            )
        } catch {
            // Deleted while it was being processed: nothing is left to tell about.
            guard !Task.isCancelled, store.meeting(id) != nil else { return }
            store.update(id) { $0.status = .failed(error.localizedDescription) }
            fail("Couldn't process the meeting: \(error.localizedDescription)")
        }
    }

    /// A surviving track remains usable when its peer is missing/corrupt. Never silently treat a read
    /// failure as a fully captured silent side; persist the missing side alongside ASR coverage warnings.
    private func samples(_ id: String, _ speaker: MeetingTurn.Speaker) async throws -> (samples: [Float], warning: String?) {
        do {
            let samples = try await AudioFileDecoder.decode(store.trackURL(id, speaker))
            try Task.checkCancellation()
            return (samples, nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return ([], "\(speaker.label): The recording track couldn't be read (\(error.localizedDescription)). This side is missing from the transcript.")
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

    /// Capture failures describe the recording, not the success of later ASR/notes. Keep them after done,
    /// through retries, and on the originating meeting even if another recording has already started.
    private func captureWarning(_ id: String, _ reason: String, at seconds: Double?) {
        guard let meeting = store.meeting(id) else { return }
        let warning = "[\(MeetingTranscript.timestamp(seconds ?? meeting.duration))] \(reason)"
        store.update(id) {
            var warnings = $0.captureWarnings ?? []
            if !warnings.contains(warning) { warnings.append(warning) }
            $0.captureWarnings = warnings
        }
        if recordingID == nil || recordingID == id { fail(warning) }
    }

    /// Progress reported from the transcriber's task.
    private nonisolated func advance(_ id: String, generation: UUID, to fraction: Double) {
        Task { @MainActor in
            if self.generations[id] == generation && self.progress[id] != nil { self.progress[id] = fraction }
        }
    }
}

private enum MeetingError: LocalizedError {
    case speechDetection(String)
    case noUsableAudio
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case let .speechDetection(reason): "Speech detection couldn't load (\(reason))"
        case .noUsableAudio: "No usable meeting audio could be read. The original files were kept; restore the tracks and use ↻ to retry."
        case .transcriptionFailed: "No speech could be transcribed. The recording and any previous transcript and notes were kept; use ↻ to retry."
        }
    }
}
