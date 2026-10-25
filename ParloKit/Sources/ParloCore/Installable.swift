import Foundation
import Observation

public enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
}

/// Download state of one set of model files.
@MainActor @Observable
public final class Installable {
    public private(set) var state: ModelState {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called after every state change, for owners that act on it.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    private let isInstalled: @Sendable () async -> Bool
    private let install: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let uninstall: @Sendable () async throws -> Void
    private var downloading: Task<Void, Never>?
    private var deleting: Task<Void, any Error>?
    private var cleanupFailed = false
    /// Bumped by every download and delete, so a check that started before one doesn't overwrite its state.
    private var generation = 0

    /// `install` must throw `CancellationError` (or any error) promptly when the task is cancelled.
    public init(
        state: ModelState = .notInstalled,
        isInstalled: @escaping @Sendable () async -> Bool,
        install: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void,
        uninstall: @escaping @Sendable () async throws -> Void
    ) {
        self.state = state
        self.isInstalled = isInstalled
        self.install = install
        self.uninstall = uninstall
    }

    public func refresh() async {
        guard downloading == nil, deleting == nil, !cleanupFailed else { return }
        let checked = generation
        let installed = await isInstalled()
        // A download or delete may have happened while we were checking.
        if downloading == nil, deleting == nil, !cleanupFailed, generation == checked {
            state = installed ? .installed : .notInstalled
        }
    }

    /// Returns when the download finishes, fails or is cancelled.
    public func download() async {
        // Another deletion may take ownership before this waiter resumes.
        while let deleting {
            do { try await deleting.value } catch { return }
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        if let downloading { return await downloading.value }
        generation += 1
        let started = generation
        state = .downloading(0)
        let install = install, uninstall = uninstall
        let task = Task { [weak self] in
            do {
                try await install { fraction in
                    Task { @MainActor in self?.updateProgress(fraction, generation: started) }
                }
                try Task.checkCancellation()
                self?.cleanupFailed = false
                self?.state = .installed
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                do {
                    // Cleanup must run even if the download's task is already cancelled.
                    try await Task { try await uninstall() }.value
                    self?.cleanupFailed = false
                    self?.state = cancelled ? .notInstalled : .failed(error.localizedDescription)
                } catch let cleanupError {
                    self?.cleanupFailed = true
                    let reason = cancelled ? "Download cancelled." : error.localizedDescription
                    self?.state = .failed("\(reason) Couldn't remove partial files: \(cleanupError.localizedDescription). Use Delete to retry.")
                }
            }
            self?.generation += 1
            self?.downloading = nil
        }
        downloading = task
        await task.value
    }

    public func cancel() {
        downloading?.cancel()
    }

    /// Files that can't be removed leave the state failed, so the user sees it and can download them again.
    public func delete() async throws {
        if let deleting { return try await deleting.value }
        generation += 1
        // The cancelled download cleans up after itself; removing the files while it still writes them can fail.
        let download = downloading
        cancel()
        let uninstall = uninstall
        let task = Task {
            // No refresh or new install can run during this mutation, including its cleanup wait.
            defer { generation += 1; deleting = nil }
            await download?.value
            do {
                try await uninstall()
                cleanupFailed = false
                state = .notInstalled
            } catch {
                cleanupFailed = true
                state = .failed("Couldn't delete the files: \(error.localizedDescription)")
                throw error
            }
        }
        deleting = task
        try await task.value
    }

    private func updateProgress(_ fraction: Double, generation: Int) {
        guard self.generation == generation, case .downloading = state else { return }
        state = .downloading(min(max(fraction, 0), 1))
    }
}
