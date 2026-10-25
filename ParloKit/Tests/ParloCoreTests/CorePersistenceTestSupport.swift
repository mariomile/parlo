import Foundation
@testable import ParloCore

/// Faults affect only these tests' temporary paths; successful operations still use real files.
final class CorePersistenceFaults: Sendable {
    let unreadable = LockedBox<Set<URL>>([])
    let unwritable = LockedBox<Set<URL>>([])
    let undeletable = LockedBox<Set<URL>>([])
    let writes = LockedBox(0)

    var files: PersistenceIO {
        PersistenceIO(
            read: { [self] url in
                if unreadable.value.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try Data(contentsOf: url)
            },
            write: { [self] data, url in
                writes.value += 1
                if unwritable.value.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: url, options: .atomic)
            },
            remove: { [self] url in
                if undeletable.value.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
    }
}

actor HeldCoreResult<Value: Sendable> {
    private var response: CheckedContinuation<Value, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func wait() async -> Value {
        hasStarted = true
        started?.resume()
        started = nil
        return await withCheckedContinuation { response = $0 }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release(_ value: Value) {
        response?.resume(returning: value)
        response = nil
    }
}
