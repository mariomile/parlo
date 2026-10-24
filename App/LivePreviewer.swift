import Foundation
import ParloCore

/// Runs the live preview while recording (see `LivePreview`). One preview at a time, and none while a dictation
/// is queued or being transcribed, so the transcriber is never called concurrently (Nemotron and WhisperKit keep
/// per-call state on a shared instance) and the final transcription only waits for the preview in flight.
final class LivePreviewer {
    private var loop: Task<Void, Never>?
    /// May outlive `stop()`: a CoreML or MLX call can't be interrupted.
    private var running: Task<String?, Never>?

    /// `isBusy`: a dictation needs the transcriber, so this tick is skipped.
    func start(
        transcriber: @escaping () async -> (any Transcriber)?, languageCode: String?,
        samples: @escaping (Int) -> [Float], isBusy: @escaping () -> Bool, show: @escaping (String) -> Void
    ) {
        stop()
        let interval = Duration.seconds(LivePreview.interval)
        let window = Int(LivePreview.windowSeconds * 16_000)
        loop = Task { [weak self] in
            var tick = ContinuousClock.now
            while true {
                // Ticks that passed while a preview ran are skipped, not caught up.
                let now = ContinuousClock.now
                repeat { tick += interval } while tick <= now
                do { try await Task.sleep(until: tick, clock: .continuous) } catch { return }
                guard let self, let transcriber = await transcriber(), !Task.isCancelled else { return }
                guard running == nil, !isBusy() else { continue }
                let audio = samples(window)
                guard audio.count >= 8_000 else { continue }
                let job = Task { try? await transcriber.transcribe(audio, languageCode: languageCode, dictionary: []) }
                running = job
                let text = await job.value
                // `idle` may have given up on this preview, and a newer one may be running.
                if running == job { running = nil }
                guard !Task.isCancelled else { return }
                if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { show(text) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Returns once no preview is using the transcriber, or false after `seconds`: a preview stuck in the
    /// engine must not hold the dictations queued behind it.
    func idle(seconds: Double = 5) async -> Bool {
        guard let job = running else { return true }
        do {
            _ = try await Deadline.run(seconds: seconds) { await job.value }
            return true
        } catch {
            if running == job { running = nil }
            return false
        }
    }
}
