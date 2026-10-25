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
        try Task.checkCancellation()
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
        let budget = Self.tokenBudget(sampleCount: samples.count)
        // mlx-audio-swift 0.1.6 checks cancellation between streamed tokens/chunks and cancels its
        // producer on stream termination. The synchronous generate path has neither guarantee.
        return try await Self.result(from: model.generateStream(
            audio: MLXArray(samples), maxTokens: budget, context: context, language: language
        ), tokenBudget: budget)
    }

    static func tokenBudget(sampleCount: Int) -> Int {
        // Generous for multilingual speech, but short previews must not generate 8192 tokens.
        min(8192, max(256, Int(ceil(Audio.seconds(sampleCount) * 32)) + 128))
    }

    static func result(from stream: AsyncThrowingStream<STTGeneration, any Error>, tokenBudget: Int) async throws -> String {
        var result: STTOutput?
        for try await event in stream {
            try Task.checkCancellation()
            if case .result(let output) = event { result = output }
        }
        // Upstream ends the stream normally on cancellation. Never publish its partial tokens.
        try Task.checkCancellation()
        guard let result else { throw STTError.generationFailed("Transcription ended without a final result") }
        guard result.generationTokens < tokenBudget else {
            throw STTError.generationFailed("Transcription reached its token limit. Retry with a shorter recording")
        }
        return result.text
    }
}
