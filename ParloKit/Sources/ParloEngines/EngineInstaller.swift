import Foundation
import ParloCore

/// Routes each catalog model to the library that downloads and runs it.
public struct EngineInstaller: ModelInstaller {
    public init() {}

    public func isInstalled(_ id: ModelID) async -> Bool {
        switch ModelCatalog.info(id).engine {
        case .apple: true
        case .parakeet: ParakeetBackend.isInstalled(id)
        case .cohere: CohereBackend.isInstalled
        case .nemotron: NemotronBackend.isInstalled
        case .whisperKit: WhisperKitBackend.isInstalled(id)
        }
    }

    public func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch ModelCatalog.info(id).engine {
        case .apple: progress(1)
        case .parakeet: try await ParakeetBackend.install(id, progress: progress)
        case .cohere: try await CohereBackend.install(progress: progress)
        case .nemotron: try await NemotronBackend.install(progress: progress)
        case .whisperKit: try await WhisperKitBackend.install(id, progress: progress)
        }
    }

    public func uninstall(_ id: ModelID) async throws {
        let dir: URL? = switch ModelCatalog.info(id).engine {
        case .apple: nil
        case .parakeet: ParakeetBackend.directory(id)
        case .cohere: CohereBackend.directory
        case .nemotron: NemotronBackend.directory
        case .whisperKit: WhisperKitBackend.directory(id)
        }
        if let dir, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    public func makeTranscriber(_ id: ModelID) async throws -> any Transcriber {
        guard await isInstalled(id) else {
            throw TranscriptionError.modelNotInstalled(ModelCatalog.info(id).displayName)
        }
        return switch ModelCatalog.info(id).engine {
        case .apple: AppleSpeechTranscriber()
        case .parakeet: try await ParakeetBackend.makeTranscriber(id)
        case .cohere: try await CohereBackend.makeTranscriber()
        case .nemotron: try await NemotronBackend.makeTranscriber()
        case .whisperKit: try await WhisperKitBackend.makeTranscriber(id)
        }
    }
}
