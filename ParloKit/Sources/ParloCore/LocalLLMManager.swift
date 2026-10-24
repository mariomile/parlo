import Foundation
import Observation

/// Downloads and deletes the files of the on-device cleanup model.
public protocol LocalLLMInstalling: Sendable {
    func isInstalled() async -> Bool
    /// Must throw `CancellationError` (or any error) promptly when the task is cancelled.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    func uninstall() async throws
}

/// Install state of the on-device cleanup model, for the AI tab.
@MainActor @Observable
public final class LocalLLMManager {
    public private(set) var state: ModelState = .notInstalled

    private let installer: any LocalLLMInstalling
    private var downloading: Task<Void, Never>?

    public init(installer: any LocalLLMInstalling) {
        self.installer = installer
    }

    public func refresh() async {
        guard downloading == nil else { return }
        let installed = await installer.isInstalled()
        if downloading == nil { state = installed ? .installed : .notInstalled }
    }

    /// Returns when the download finishes, fails or is cancelled.
    public func download() async {
        if let downloading { return await downloading.value }
        state = .downloading(0)
        let installer = installer
        let task = Task { [weak self] in
            do {
                try await installer.install { fraction in
                    Task { @MainActor in self?.updateProgress(fraction) }
                }
                try Task.checkCancellation()
                self?.state = .installed
            } catch {
                try? await installer.uninstall()
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
        try? await installer.uninstall()
        state = .notInstalled
    }

    private func updateProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(min(max(fraction, 0), 1))
    }
}
