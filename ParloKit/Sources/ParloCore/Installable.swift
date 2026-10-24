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
        guard downloading == nil else { return }
        let installed = await isInstalled()
        // A download may have started while we were checking.
        if downloading == nil { state = installed ? .installed : .notInstalled }
    }

    /// Returns when the download finishes, fails or is cancelled.
    public func download() async {
        if let downloading { return await downloading.value }
        state = .downloading(0)
        let install = install, uninstall = uninstall
        let task = Task { [weak self] in
            do {
                try await install { fraction in
                    Task { @MainActor in self?.updateProgress(fraction) }
                }
                try Task.checkCancellation()
                self?.state = .installed
            } catch {
                try? await uninstall()
                self?.state = Task.isCancelled || error is CancellationError
                    ? .notInstalled
                    : .failed(error.localizedDescription)
            }
            self?.downloading = nil
        }
        downloading = task
        await task.value
    }

    public func cancel() {
        downloading?.cancel()
    }

    public func delete() async {
        cancel()
        try? await uninstall()
        state = .notInstalled
    }

    private func updateProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(min(max(fraction, 0), 1))
    }
}
