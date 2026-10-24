import FluidAudio
import Foundation
import ParloCore

/// NVIDIA Nemotron Speech Multilingual via FluidAudio (full-vocab variant, 2240 ms chunks).
enum NemotronBackend {
    static let chunkMs = 2240

    static var repoDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .nemotronMultilingual)
    }

    /// FluidAudio's folder for the auto-language variant, relative to `repoDirectory`.
    static let variant = "multilingual/\(chunkMs)ms"

    static var directory: URL { repoDirectory.appendingPathComponent(variant, isDirectory: true) }

    /// Written once every file is in place. FluidAudio's own check only looks for `metadata.json`,
    /// so it can't tell a finished download from one cut short.
    private static var completeMarker: URL { directory.appendingPathComponent(".parlo-complete") }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: completeMarker.path) }

    /// Fetches only the files that are missing: FluidAudio moves each file in place once it is complete, so the
    /// files already there (from a download cut short, or from FluidVoice, which shares the folder) are kept.
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ModelHub.download(
            .nemotronMultilingual, subdirectory: variant, to: repoDirectory,
            progressHandler: { progress($0.fractionCompleted) }, shouldSkip: { $0.contains(".mlpackage") }
        )
        // Now that `metadata.json` is there this downloads nothing: it only repairs a tokenizer cached before the fix.
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: "auto", chunkMs: chunkMs)
        try Data().write(to: completeMarker)
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
