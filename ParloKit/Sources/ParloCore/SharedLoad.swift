/// One load per key, kept once it succeeds: concurrent callers share it, and a failed load is dropped so the next
/// call retries.
@MainActor
public final class SharedLoad<Key: Equatable & Sendable, Value: Sendable> {
    private var current: (key: Key, task: Task<Value, any Error>)?

    public init() {}

    public var isEmpty: Bool { current == nil }

    /// Starts loading `key` unless it's already loading or loaded.
    @discardableResult
    public func start(_ key: Key, _ load: @escaping @Sendable () async throws -> Value) -> Task<Value, any Error> {
        if let current, current.key == key { return current.task }
        let task = Task { try await load() }
        current = (key, task)
        Task { [weak self] in
            if case .failure = await task.result { self?.drop(task) }
        }
        return task
    }

    public func value(_ key: Key, _ load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task = start(key, load)
        do {
            return try await task.value
        } catch {
            drop(task)
            throw error
        }
    }

    public func clear() {
        current = nil
    }

    private func drop(_ task: Task<Value, any Error>) {
        if current?.task == task { current = nil }
    }
}
