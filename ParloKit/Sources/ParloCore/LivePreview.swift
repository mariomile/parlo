/// Live text while recording: about once a second the tail of the audio captured so far is transcribed
/// with the active model and shown in the HUD. Display only: the pasted text comes from `TranscriptionJob`.
public enum LivePreview {
    public static let interval: Double = 1
    /// Only the last seconds are transcribed, so a preview costs the same at minute ten as at second ten.
    /// The HUD shows about one line, a few seconds of speech.
    public static let windowSeconds: Double = 10
    /// Less audio than this isn't worth a preview.
    static let minimumSeconds = 0.5

    /// Slower models would keep the GPU busy for the whole recording and hold up the final transcription.
    public static func supports(_ info: ModelInfo) -> Bool {
        info.speed >= 4
    }
}

/// Runs the live preview while recording, through the gate, so the final transcription only waits for the
/// preview in flight.
@MainActor
public final class LivePreviewer {
    private let gate: TranscriberGate
    private let interval: Duration
    private var loop: Task<Void, Never>?

    public init(gate: TranscriberGate, interval: Double = LivePreview.interval) {
        self.gate = gate
        self.interval = .seconds(interval)
    }

    /// `samples(n)`: the last `n` samples captured. `show` gets each non-empty preview.
    public func start(languageCode: String?, samples: @escaping (Int) -> [Float], show: @escaping (String) -> Void) {
        stop()
        let gate = gate, interval = interval
        loop = Task {
            var tick = ContinuousClock.now
            while true {
                // Ticks that passed while a preview ran are skipped, not caught up.
                let now = ContinuousClock.now
                repeat { tick += interval } while tick <= now
                do { try await Task.sleep(until: tick, clock: .continuous) } catch { return }
                let audio = samples(Audio.sampleCount(LivePreview.windowSeconds))
                guard audio.count >= Audio.sampleCount(LivePreview.minimumSeconds) else { continue }
                let text = await gate.runIfIdle { transcriber in
                    try? await transcriber.transcribe(audio, languageCode: languageCode, dictionary: [])
                }
                guard !Task.isCancelled else { return }
                if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { show(text) }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
