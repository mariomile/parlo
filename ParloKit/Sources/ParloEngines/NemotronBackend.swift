import FluidAudio
import Foundation
import ParloCore

/// NVIDIA Nemotron Speech Multilingual via FluidAudio (full-vocab variant, 2240 ms chunks).
enum NemotronBackend {
    static let chunkMs = 2240

    static var repoDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronMultilingual)
    }

    static var directory: URL {
        repoDirectory.appendingPathComponent("multilingual/\(chunkMs)ms", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata).path
        )
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: chunkMs
        ) { progress($0.fractionCompleted) }
    }

    static func makeTranscriber() async throws -> any Transcriber {
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: directory)
        return NemotronTranscriber(manager: manager)
    }
}

struct NemotronTranscriber: Transcriber {
    let manager: StreamingNemotronMultilingualAsrManager

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        await manager.reset()
        await manager.setLanguage(LanguageCodes.regional(languageCode))
        _ = try await manager.process(samples: samples)
        return try await manager.finish()
    }
}
