import Foundation
import Observation

/// Install state of every catalog model, the active model, and a warm transcriber for it.
@MainActor @Observable
public final class ModelManager {
    public let files: [ModelID: Installable]
    public private(set) var activeModelID: ModelID

    private let installer: any ModelInstaller
    private let onActiveChange: (ModelID) -> Void
    /// The active model's transcriber, loaded once.
    private let loaded = SharedLoad<ModelID, any Transcriber>()

    public init(installer: any ModelInstaller, activeModelID: ModelID, onActiveChange: @escaping (ModelID) -> Void) {
        self.installer = installer
        self.activeModelID = activeModelID
        self.onActiveChange = onActiveChange
        files = Dictionary(uniqueKeysWithValues: ModelID.allCases.map { id in
            let builtIn = !ModelCatalog.info(id).needsDownload
            return (id, Installable(
                state: builtIn ? .installed : .notInstalled,
                isInstalled: { await installer.isInstalled(id) },
                install: { try await installer.install(id, progress: $0) },
                uninstall: { try await installer.uninstall(id) }
            ))
        })
    }

    public var states: [ModelID: ModelState] { files.mapValues(\.state) }
    public var activeInfo: ModelInfo { ModelCatalog.info(activeModelID) }

    public func refresh() async {
        for id in ModelID.allCases { await files[id]!.refresh() }
        // Fall back for this session only: a model that briefly looks missing must not replace the saved choice.
        if files[activeModelID]!.state != .installed {
            activeModelID = .appleSpeech
            loaded.clear()
        }
    }

    /// Returns when the download finishes, fails or is cancelled.
    public func download(_ id: ModelID) async {
        await files[id]!.download()
    }

    public func cancel(_ id: ModelID) {
        files[id]!.cancel()
    }

    /// The active model is switched away from only once its files are gone.
    public func delete(_ id: ModelID) async throws {
        guard ModelCatalog.info(id).needsDownload else { return }
        try await files[id]!.delete()
        if activeModelID == id { setActive(.appleSpeech) }
    }

    public func select(_ id: ModelID) {
        guard files[id]!.state == .installed, id != activeModelID else { return }
        setActive(id)
    }

    /// Loads (once) and returns the transcriber for the active model.
    public func transcriber() async throws -> any Transcriber {
        let id = activeModelID, installer = installer
        return try await loaded.value(id) { try await installer.makeTranscriber(id) }
    }

    /// Drops the loaded model and loads it again, after it stopped answering.
    public func reload() {
        loaded.clear()
        warmUp()
    }

    /// Loads the active model in the background so the first dictation is fast.
    public func warmUp() {
        let id = activeModelID, installer = installer
        loaded.start(id) { try await installer.makeTranscriber(id) }
    }

    private func setActive(_ id: ModelID) {
        activeModelID = id
        loaded.clear()
        onActiveChange(id)
    }
}
