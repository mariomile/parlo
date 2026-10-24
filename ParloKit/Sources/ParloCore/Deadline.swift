import Foundation
import Synchronization

public struct DeadlineExceeded: Error, Equatable, LocalizedError {
    public let seconds: Double
    public var errorDescription: String? { "Transcription took longer than \(Int(seconds)) s and was stopped" }
}

public enum Deadline {
    /// Runs `operation`, giving up after `seconds` even if it never returns (a wedged model ignores
    /// cancellation), so one stuck job can't hold the queue. The operation is cancelled but may keep running.
    /// The clock stops while the Mac sleeps.
    public static func run<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, seconds: seconds, operation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

/// The work and the timer: the first to finish resumes the caller and cancels the other.
private final class Race<T: Sendable>: Sendable {
    private struct State: ~Copyable {
        var continuation: CheckedContinuation<T, any Error>?
        var tasks: [Task<Void, Never>] = []
        var outcome: Result<T, any Error>?
    }

    private let state = Mutex(State())

    func start(
        _ continuation: CheckedContinuation<T, any Error>, seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) {
        // Cancelled before it started: answer at once.
        if let outcome = state.withLock({ s in s.outcome }) { return continuation.resume(with: outcome) }
        let work = Task { [self] in
            do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
        }
        let timer = Task { [self] in
            do { try await Task.sleep(for: .seconds(seconds), clock: .suspending) } catch { return }
            finish(.failure(DeadlineExceeded(seconds: seconds)))
        }
        let late = state.withLock { s -> Result<T, any Error>? in
            if s.outcome == nil {
                s.continuation = continuation
                s.tasks = [work, timer]
            }
            return s.outcome
        }
        if let late {
            work.cancel()
            timer.cancel()
            continuation.resume(with: late)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { s -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard s.outcome == nil else { return (nil, []) }
            s.outcome = result
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}
