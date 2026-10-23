import Foundation
import ParloCore
import WhisperKit

/// OpenAI Whisper CoreML models via WhisperKit, stored under Parlo's own Application Support folder.
enum WhisperKitBackend {
    static let repo = "argmaxinc/whisperkit-coreml"

    static var downloadBase: URL {
        SettingsStore.appSupportDirectory.appendingPathComponent("Models/whisperkit", isDirectory: true)
    }

    static func variant(_ id: ModelID) -> String {
        switch id {
        case .whisperTiny: "openai_whisper-tiny"
        case .whisperBase: "openai_whisper-base"
        case .whisperSmall: "openai_whisper-small"
        case .whisperLargeV3: "openai_whisper-large-v3_947MB"
        case .whisperLargeV3TurboCompact: "openai_whisper-large-v3-v20240930_turbo_632MB"
        default: "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    static func directory(_ id: ModelID) -> URL {
        downloadBase.appendingPathComponent("models/\(repo)/\(variant(id))", isDirectory: true)
    }

    static func isInstalled(_ id: ModelID) -> Bool {
        ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: directory(id).appendingPathComponent($0).path)
        }
    }

    static func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: variant(id), downloadBase: downloadBase, from: repo) {
            progress($0.fractionCompleted)
        }
    }

    static func makeTranscriber(_ id: ModelID) async throws -> any Transcriber {
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: directory(id).path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        ))
        return WhisperKitTranscriber(kit: kit)
    }
}

actor WhisperKitTranscriber: Transcriber {
    let kit: WhisperKit

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        var options = DecodingOptions()
        options.language = languageCode
        options.detectLanguage = languageCode == nil
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        let terms = dictionary.terms
        if !terms.isEmpty, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + terms.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
