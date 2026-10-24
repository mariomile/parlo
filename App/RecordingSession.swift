import Foundation
import ParloCore

/// The microphone side of a dictation: one recording at a time, its live preview, and the short tail
/// after fn is released.
final class RecordingSession {
    struct Recording {
        let command: Bool
        let bundleID: String?
        /// Read when a command starts, before the user's focus can move.
        let selection: Task<String?, Never>?
        let startedAt: Date
    }

    struct Finished {
        let recording: Recording
        let samples: [Float]
        /// Recorded with the system default because the chosen microphone wasn't available.
        let usedFallback: Bool
    }

    private(set) var current: Recording?
    /// Called about 30 times a second while recording, for the level meter and the hotkey's polls.
    var onTick: () -> Void = {}
    /// The microphone stopped and could not restart.
    var onFailure: (String) -> Void = { _ in }

    private let sink = SampleSink()
    private let recorder: AudioRecorder
    private let previewer: LivePreviewer
    private var timer: Timer?
    /// The tail after fn is released, before the microphone stops.
    private var stopping: Task<Void, Never>?

    init(gate: TranscriberGate) {
        recorder = AudioRecorder(sink: sink)
        previewer = LivePreviewer(gate: gate)
        recorder.onFailure = { [weak self] in self?.onFailure($0) }
    }

    /// RMS of the latest buffer, 0...~1.
    var level: Float { sink.level }
    var isStopping: Bool { stopping != nil }

    /// `preview`: the language to show live words in, or nil for no preview. `show` gets each one.
    func start(
        command: Bool, deviceUID: String?, preview: (languageCode: String?, show: (String) -> Void)?
    ) throws {
        recorder.stop()
        sink.reset()
        try recorder.start(deviceUID: deviceUID)
        current = Recording(
            command: command, bundleID: FrontmostApp.bundleID,
            selection: command ? Task { await SelectionReader.read() } : nil, startedAt: .now
        )
        if let preview {
            previewer.start(languageCode: preview.languageCode, samples: { [weak self] in self?.sink.tail($0) ?? [] }) {
                [weak self] text in if self?.current != nil { preview.show(text) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    /// Keeps listening a moment, since people let go of fn while still saying the last word, then stops.
    func stopAfterTail(_ finished: @escaping (Finished) -> Void) {
        guard current != nil, stopping == nil else { return }
        stopping = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(HotkeyStateMachine.doubleTapWindow)) } catch { return }
            // Cancelled after the sleep ended but before this resumed: a new recording may be running.
            guard !Task.isCancelled, let done = self?.stop() else { return }
            finished(done)
        }
    }

    /// Keeps a recording in its tail going (the second tap of a double tap). False when there was none to keep.
    func continueRecording(command: Bool) -> Bool {
        guard stopping != nil, current?.command == command else { return false }
        stopping?.cancel()
        stopping = nil
        return true
    }

    /// Stops the microphone now. Nil when nothing was recording.
    func stop() -> Finished? {
        stopping?.cancel()
        stopping = nil
        guard let rec = current else { return nil }
        previewer.stop()
        timer?.invalidate()
        timer = nil
        // Everything since `start`, even if the microphone already died.
        recorder.stop()
        let samples = sink.drain()
        current = nil
        return Finished(recording: rec, samples: samples, usedFallback: recorder.usedFallback)
    }
}
