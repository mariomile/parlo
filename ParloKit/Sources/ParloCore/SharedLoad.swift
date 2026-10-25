import Foundation

public enum SharedLoadError: Error, LocalizedError {
    case retiredLoadsStillRunning

    public var errorDescription: String? {
        "Previous model loads are still stopping. Try again once they finish."
    }
}

/// One bounded load per key. Retired native loads may finish later, but cannot publish a cached value.
@MainActor
public final class SharedLoad<Key: Equatable & Sendable, Value: Sendable> {
    private var current: (key: Key, task: Task<Value, any Error>, native: Task<Value, any Error>)?
    private var running: Set<UUID> = []
    private let timeout: Double
    private let maxConcurrentLoads: Int

    /// At most one replacement can load beside a stuck native load by default. Repeated timeouts must
    /// not create an unlimited number of model allocations that Swift cancellation cannot interrupt.
    public init(timeout: Double = 60, maxConcurrentLoads: Int = 2) {
        self.timeout = timeout
        self.maxConcurrentLoads = max(1, maxConcurrentLoads)
    }

    public var isEmpty: Bool { current == nil }

    @discardableResult
    public func start(_ key: Key, _ load: @escaping @Sendable () async throws -> Value) -> Task<Value, any Error> {
        if let current, current.key == key { return current.task }
        clear()
        guard running.count < maxConcurrentLoads else {
            return Task { throw SharedLoadError.retiredLoadsStillRunning }
        }
        let id = UUID(), timeout = timeout
        running.insert(id)
        let native = Task {
            try Task.checkCancellation()
            return try await load()
        }
        let task = Task {
            try await Deadline.run(seconds: timeout) { try await native.value }
        }
        current = (key, task, native)
        Task { [weak self] in
            _ = await native.result
            self?.running.remove(id)
        }
        Task { [weak self] in
            if case .failure = await task.result {
                native.cancel()
                self?.drop(task)
            }
        }
        return task
    }

    public func value(_ key: Key, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let task = start(key, load)
        do {
            // Awaiting Task.value alone does not wake when its caller is cancelled.
            let value = try await Deadline.run(seconds: timeout) { try await task.value }
            try Task.checkCancellation()
            guard current?.task == task else { throw CancellationError() }
            return value
        } catch {
            drop(task)
            throw error
        }
    }

    public func clear() {
        let previous = current
        current = nil
        previous?.task.cancel()
        previous?.native.cancel()
    }

    private func drop(_ task: Task<Value, any Error>) {
        if current?.task == task { clear() }
    }
}
