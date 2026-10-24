import Foundation
import MLX
import MLXAudioSTT
import ParloCore

/// Qwen3-ASR 1.7B (4-bit MLX) via mlx-audio-swift, stored under Parlo's own Application Support folder.
enum Qwen3ASRBackend {
    static let repo = "mlx-community/Qwen3-ASR-1.7B-4bit"

    static var directory: URL { HubSnapshot.directory("qwen3-asr-1.7b-4bit") }
    static var isInstalled: Bool { HubSnapshot.isInstalled(directory) }

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

    /// Switching model or reloading drops this transcriber: return the buffers MLX kept for it.
    deinit {
        Memory.clearCache()
    }

    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        var language: String?
        if let languageCode {
            language = Locale(identifier: "en").localizedString(forLanguageCode: languageCode)
            guard let name = language, model.config.supportLanguages.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { throw TranscriptionError.unsupportedLanguage(languageCode) }
        }
        // Qwen3-ASR reads the system turn as context. Labelled terms there make it write most of them, though not
        // always with the same capitals ("Claude.md" for "CLAUDE.md"); a bare list worked less often.
        let terms = dictionary.terms
        let context = terms.isEmpty ? "" : "Vocabulary: " + terms.joined(separator: ", ")
        let output = model.generate(audio: MLXArray(samples), context: context, language: language)
        return output.text
    }
}
