import Foundation
import MLX
import MLXAudioSTT
import ParloCore

/// Qwen3-ASR 1.7B (4-bit MLX) via mlx-audio-swift, stored under Parlo's own Application Support folder.
enum Qwen3ASRBackend {
    static let repo = "mlx-community/Qwen3-ASR-1.7B-4bit"

    static var directory: URL {
        SettingsStore.appSupportDirectory.appendingPathComponent("Models/qwen3-asr-1.7b-4bit", isDirectory: true)
    }

    static var isInstalled: Bool {
        ["config.json", "model.safetensors", "vocab.json", "merges.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await HubSnapshot.install(repo, to: directory, matching: ["*.safetensors", "*.json", "*.txt"], progress: progress)
    }

    static func makeTranscriber() async throws -> any Transcriber {
        Qwen3ASRTranscriber(model: try await Qwen3ASRModel.fromModelDirectory(directory))
    }
}

actor Qwen3ASRTranscriber: Transcriber {
    let model: Qwen3ASRModel

    init(model: Qwen3ASRModel) {
        self.model = model
    }

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        var language: String?
        if let languageCode {
            language = Locale(identifier: "en").localizedString(forLanguageCode: languageCode)
            guard let name = language, model.config.supportLanguages.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { throw TranscriptionError.unsupportedLanguage(languageCode) }
        }
        // The dictionary is ignored: the model has no vocabulary API, and passing terms as prompt context did not make
        // it spell them (measured on "CLAUDE.md" / "AGENTS.md").
        let output = model.generate(audio: MLXArray(samples), language: language)
        return output.text
    }
}
