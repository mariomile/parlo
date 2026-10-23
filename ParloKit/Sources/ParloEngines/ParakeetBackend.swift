import FluidAudio
import Foundation
import ParloCore

/// Parakeet TDT models via FluidAudio. Files live in FluidAudio's shared cache, so models
/// already downloaded by FluidVoice are picked up as installed.
enum ParakeetBackend {
    static func version(_ id: ModelID) -> AsrModelVersion {
        switch id {
        case .parakeetUltra: .ultra
        case .parakeetRedux: .redux
        case .parakeetV2: .v2
        default: .v3
        }
    }

    static func directory(_ id: ModelID) -> URL {
        AsrModels.defaultCacheDirectory(for: version(id))
    }

    static func isInstalled(_ id: ModelID) -> Bool {
        AsrModels.modelsExist(at: directory(id), version: version(id))
    }

    static func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: version(id)) { progress($0.fractionCompleted) }
    }

    static func makeTranscriber(_ id: ModelID) async throws -> any Transcriber {
        let v = version(id)
        let models = try await AsrModels.load(from: directory(id), version: v)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetTranscriber(manager: manager)
    }
}

struct ParakeetTranscriber: Transcriber {
    let manager: AsrManager

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = languageCode.flatMap { Language(rawValue: $0) }
        return try await manager.transcribe(samples, decoderState: &state, language: language).text
    }
}
