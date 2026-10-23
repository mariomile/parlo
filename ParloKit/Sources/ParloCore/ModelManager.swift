import Foundation
import Observation

public enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
}

/// Install state of every catalog model, the active model, and a warm transcriber for it.
@MainActor @Observable
public final class ModelManager {
    public private(set) var states: [ModelID: ModelState]
    public private(set) var activeModelID: ModelID

    private let installer: any ModelInstaller
    private let onActiveChange: (ModelID) -> Void
    private var downloads: [ModelID: Task<Void, Never>] = [:]
    /// The active model's transcriber, loaded once; concurrent callers share the same load.
    private var cached: (id: ModelID, load: Task<any Transcriber, any Error>)?

    public init(installer: any ModelInstaller, activeModelID: ModelID, onActiveChange: @escaping (ModelID) -> Void) {
        self.installer = installer
        self.activeModelID = activeModelID
        self.onActiveChange = onActiveChange
        states = Dictionary(uniqueKeysWithValues: ModelID.allCases.map { ($0, ModelState.notInstalled) })
        states[.appleSpeech] = .installed
    }

    public var activeInfo: ModelInfo { ModelCatalog.info(activeModelID) }

    public func refresh() async {
        for id in ModelID.allCases where downloads[id] == nil {
            let installed = await installer.isInstalled(id)
            // A download may have started while we were checking.
            if downloads[id] == nil { states[id] = installed ? .installed : .notInstalled }
        }
        if states[activeModelID] != .installed { setActive(.appleSpeech) }
    }

    /// Returns when the download finishes, fails or is cancelled.
    public func download(_ id: ModelID) async {
        if let existing = downloads[id] { return await existing.value }
        states[id] = .downloading(0)
        let installer = installer
        let task = Task { [weak self] in
            do {
                try await installer.install(id) { fraction in
                    Task { @MainActor in self?.updateProgress(id, fraction) }
                }
                try Task.checkCancellation()
                self?.states[id] = .installed
            } catch {
                try? await installer.uninstall(id)
                self?.states[id] = Task.isCancelled || error is CancellationError
                    ? .notInstalled
                    : .failed(error.localizedDescription)
            }
            self?.downloads[id] = nil
        }
        downloads[id] = task
        await task.value
    }

    public func cancel(_ id: ModelID) {
        downloads[id]?.cancel()
    }

    public func delete(_ id: ModelID) async {
        guard ModelCatalog.info(id).needsDownload else { return }
        cancel(id)
        try? await installer.uninstall(id)
        states[id] = .notInstalled
        if cached?.id == id { cached = nil }
        if activeModelID == id { setActive(.appleSpeech) }
    }

    public func select(_ id: ModelID) {
        guard states[id] == .installed, id != activeModelID else { return }
        setActive(id)
    }

    /// Loads (once) and returns the transcriber for the active model.
    public func transcriber() async throws -> any Transcriber {
        let id = activeModelID
        if let cached, cached.id == id { return try await cached.load.value }
        let installer = installer
        let load = Task { try await installer.makeTranscriber(id) }
        cached = (id, load)
        do {
            return try await load.value
        } catch {
            if cached?.id == id { cached = nil } // let the next dictation retry
            throw error
        }
    }

    /// Loads the active model in the background so the first dictation is fast.
    public func warmUp() {
        Task { _ = try? await transcriber() }
    }

    private func setActive(_ id: ModelID) {
        activeModelID = id
        cached = nil
        onActiveChange(id)
    }

    private func updateProgress(_ id: ModelID, _ fraction: Double) {
        guard case .downloading = states[id] else { return }
        states[id] = .downloading(min(max(fraction, 0), 1))
    }
}
