import FluidAudio
import Foundation
import ParloCore

/// Cohere Transcribe (q8 CoreML) via FluidAudio. Needs an explicit language.
enum CohereBackend {
    static var directory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .cohereTranscribeCoreml)
    }

    static var isInstalled: Bool {
        ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ModelHub.download(
            .cohereTranscribeCoreml,
            to: MLModelConfigurationUtils.defaultModelsDirectory()
        ) { progress($0.fractionCompleted) }
    }

    static func makeTranscriber() async throws -> any Transcriber {
        let models = try await CoherePipeline.loadModels(
            encoderDir: directory, decoderDir: directory, vocabDir: directory
        )
        return CohereTranscriber(pipeline: CoherePipeline(), models: models)
    }
}

struct CohereTranscriber: Transcriber {
    let pipeline: CoherePipeline
    let models: CoherePipeline.LoadedModels

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        guard let languageCode else { throw TranscriptionError.languageRequired("Cohere Transcribe") }
        guard let language = CohereAsrConfig.Language(rawValue: languageCode) else {
            throw TranscriptionError.unsupportedLanguage(languageCode)
        }
        return try await pipeline.transcribeLong(audio: samples, models: models, language: language).text
    }
}
