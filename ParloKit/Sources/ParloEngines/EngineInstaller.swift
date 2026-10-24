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
        case .qwen3ASR: Qwen3ASRBackend.isInstalled
        case .whisperKit: WhisperKitBackend.isInstalled(id)
        }
    }

    public func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch ModelCatalog.info(id).engine {
        case .apple: progress(1)
        case .parakeet: try await ParakeetBackend.install(id, progress: progress)
        case .cohere: try await CohereBackend.install(progress: progress)
        case .nemotron: try await NemotronBackend.install(progress: progress)
        case .qwen3ASR: try await Qwen3ASRBackend.install(progress: progress)
        case .whisperKit: try await WhisperKitBackend.install(id, progress: progress)
        }
    }

    public func uninstall(_ id: ModelID) async throws {
        guard let dir = Self.directory(id) else { return }
        try HubSnapshot.uninstall(dir)
    }

    /// Run once at launch, before any model loads or downloads.
    public static func prepare() {
        // Files left by a download Parlo quit in the middle of.
        HubSnapshot.removeLeftovers()
        MLXCache.limit()
    }

    /// Where a model's files live; nil for models macOS manages.
    static func directory(_ id: ModelID) -> URL? {
        switch ModelCatalog.info(id).engine {
        case .apple: nil
        case .parakeet: ParakeetBackend.directory(id)
        case .cohere: CohereBackend.directory
        case .nemotron: NemotronBackend.directory
        case .qwen3ASR: Qwen3ASRBackend.directory
        case .whisperKit: WhisperKitBackend.directory(id)
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
        case .qwen3ASR: try await Qwen3ASRBackend.makeTranscriber()
        case .whisperKit: try await WhisperKitBackend.makeTranscriber(id)
        }
    }
}
