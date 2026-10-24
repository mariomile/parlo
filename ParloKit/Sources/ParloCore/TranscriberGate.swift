import Foundation

/// Hands the transcriber to one caller at a time (Nemotron and WhisperKit keep per-call state on a shared
/// instance): dictations in order, then background work such as the pieces of an audio file, and live
/// previews only while nothing else is running or waiting.
@MainActor
public final class TranscriberGate {
    /// Dictation jobs queued or running.
    public private(set) var pendingJobs = 0 {
        didSet { onChange() }
    }
    public var onChange: () -> Void = {}

    private let transcriber: () async throws -> any Transcriber
    private let reload: () -> Void
    private let previewGrace: Double
    /// Someone holds the transcriber; whoever is waiting starts when it is released.
    private var busy = false
    private var waiting: [Waiter] = []
    private var nextWaiter = 0
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
        schedule(Waiter(id: takeID(), background: false, cancel: {}) {
            Task {
                do {
                    try await self.job(job)
                } catch {
                    onError(error)
                }
                self.pendingJobs -= 1
                self.release()
            }
        })
    }

    /// Runs `work` once the transcriber is free and no dictation is waiting for it, so a long audio file
    /// sent piece by piece never holds up a dictation by more than one piece. Cancelling while it waits
    /// leaves the queue at once.
    public func runInBackground<T: Sendable>(_ work: @escaping (any Transcriber) async throws -> T) async throws -> T {
        try await turn(background: true)
        defer { release() }
        return try await job(work)
    }

    /// Waits until the caller holds the transcriber.
    private func turn(background: Bool) async throws {
        let id = takeID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { return c.resume(throwing: CancellationError()) }
                schedule(Waiter(id: id, background: background, cancel: { c.resume(throwing: CancellationError()) }) {
                    c.resume()
                })
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(id) }
        }
    }

    private func withdraw(_ id: Int) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).cancel()
    }

    private func takeID() -> Int {
        nextWaiter += 1
        return nextWaiter
    }

    private func job<T>(_ work: (any Transcriber) async throws -> T) async throws -> T {
        if await !previewFinished() { reload() }
        do {
            return try await work(try await transcriber())
        } catch {
            if error is DeadlineExceeded { reload() }
            throw error
        }
    }

    private struct Waiter {
        let id: Int
        let background: Bool
        let cancel: () -> Void
        let start: () -> Void
    }

    private func schedule(_ waiter: Waiter) {
        guard busy else {
            busy = true
            return waiter.start()
        }
        waiting.append(waiter)
    }

    /// Dictations first, each kind in the order it arrived.
    private func release() {
        guard let next = waiting.firstIndex(where: { !$0.background }) ?? waiting.indices.first else {
            busy = false
            return
        }
        waiting.remove(at: next).start()
    }

    /// Runs `work` unless anything holds or waits for the transcriber, or another preview is running; nil when skipped.
    public func runIfIdle(_ work: @escaping @Sendable (any Transcriber) async -> String?) async -> String? {
        guard !busy, preview == nil, let transcriber = try? await transcriber(),
              !busy, preview == nil else { return nil }
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
