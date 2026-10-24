import Foundation

/// Hands the transcriber to one caller at a time (Nemotron and WhisperKit keep per-call state on a shared
/// instance): queued jobs in order, and live previews only while no job is waiting.
@MainActor
public final class TranscriberGate {
    /// Jobs queued or running.
    public private(set) var pendingJobs = 0 {
        didSet { onChange() }
    }
    public var onChange: () -> Void = {}

    private let transcriber: () async throws -> any Transcriber
    private let reload: () -> Void
    private let previewGrace: Double
    private var queue: Task<Void, Never>?
    /// May outlive its caller: a CoreML or MLX call can't be interrupted.
    private var preview: Task<String?, Never>?

    /// `reload` drops the loaded model for a fresh one, after it stopped answering.
    /// `previewGrace`: how long a job waits for a preview in flight before giving up on it.
    public init(
        transcriber: @escaping () async throws -> any Transcriber, reload: @escaping () -> Void, previewGrace: Double = 5
    ) {
        self.transcriber = transcriber
        self.reload = reload
        self.previewGrace = previewGrace
    }

    /// Runs `job` after every job queued before it. A preview stuck in the engine, or a job past its deadline,
    /// reloads the model so the jobs behind it get one that answers. Errors, loading the model included, go to `onError`.
    public func enqueue(
        _ job: @escaping (any Transcriber) async throws -> Void, onError: @escaping (any Error) -> Void
    ) {
        pendingJobs += 1
        let previous = queue
        queue = Task {
            await previous?.value
            if await !previewFinished() { reload() }
            do {
                try await job(try await transcriber())
            } catch {
                if error is DeadlineExceeded { reload() }
                onError(error)
            }
            pendingJobs -= 1
        }
    }

    /// Runs `work` unless a job is waiting or another preview is running; nil when skipped.
    public func runIfIdle(_ work: @escaping @Sendable (any Transcriber) async -> String?) async -> String? {
        guard pendingJobs == 0, preview == nil, let transcriber = try? await transcriber(),
              pendingJobs == 0, preview == nil else { return nil }
        let task = Task { await work(transcriber) }
        preview = task
        let result = await task.value
        // A job may have given up on this preview, and a newer one may be running.
        if preview == task { preview = nil }
        return result
    }

    private func previewFinished() async -> Bool {
        guard let task = preview else { return true }
        do {
            _ = try await Deadline.run(seconds: previewGrace) { await task.value }
            return true
        } catch {
            if preview == task { preview = nil }
            return false
        }
    }
}
