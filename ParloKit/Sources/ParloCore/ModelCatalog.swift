public enum ModelID: String, Codable, CaseIterable, Sendable {
    case appleSpeech
    case parakeetV3, parakeetUltra, parakeetRedux, parakeetV2
    case cohereTranscribe
    case nemotronMultilingual
    case qwen3ASR
    case whisperTiny, whisperBase, whisperSmall, whisperLargeV3TurboCompact, whisperLargeV3, whisperLargeV3Turbo
}

public enum Engine: String, Sendable {
    case apple, parakeet, cohere, nemotron, qwen3ASR, whisperKit
}

public struct ModelInfo: Identifiable, Sendable {
    public let id: ModelID
    public let displayName: String
    public let engine: Engine
    public let approxSizeMB: Int
    public let languages: String
    /// 1 (poor) to 5 (best), from published benchmarks and measurements on Apple Silicon; 0 = not supported.
    public let italian: Int
    public let english: Int
    /// 1 (several seconds per sentence) to 5 (instant).
    public let speed: Int
    public let note: String
    /// Cohere can't auto-detect: dictation needs a language set in Settings.
    public let requiresExplicitLanguage: Bool

    public var needsDownload: Bool { engine != .apple }

    public var sizeLabel: String {
        if approxSizeMB == 0 { return "Built in" }
        if approxSizeMB >= 1000 { return String(format: "~%.1f GB", Double(approxSizeMB) / 1000) }
        return "~\(approxSizeMB) MB"
    }
}

public enum ModelCatalog {
    public static let all: [ModelInfo] = [
        ModelInfo(id: .appleSpeech, displayName: "Apple Speech", engine: .apple, approxSizeMB: 0,
                  languages: "Italian, English and many more", italian: 3, english: 3, speed: 4, note: "Built into macOS. Language assets install on first use.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetV3, displayName: "Parakeet TDT v3", engine: .parakeet, approxSizeMB: 461,
                  languages: "25 European languages incl. Italian, auto-detect", italian: 4, english: 4, speed: 5, note: "Recommended. Fast and accurate.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetUltra, displayName: "Parakeet Ultra", engine: .parakeet, approxSizeMB: 632,
                  languages: "25 European languages incl. Italian", italian: 5, english: 5, speed: 5, note: "Higher accuracy than v3.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetRedux, displayName: "Parakeet Redux", engine: .parakeet, approxSizeMB: 215,
                  languages: "25 European languages incl. Italian", italian: 3, english: 4, speed: 5, note: "Lightest Parakeet, slightly less accurate.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetV2, displayName: "Parakeet TDT v2", engine: .parakeet, approxSizeMB: 443,
                  languages: "English only", italian: 0, english: 4, speed: 5, note: "Best English accuracy.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .cohereTranscribe, displayName: "Cohere Transcribe", engine: .cohere, approxSizeMB: 2200,
                  languages: "14 languages incl. Italian", italian: 1, english: 4, speed: 1, note: "Slow, and garbled most Italian sentences in our tests. Set the language in General.",
                  requiresExplicitLanguage: true),
        ModelInfo(id: .nemotronMultilingual, displayName: "Nemotron Speech Multilingual", engine: .nemotron, approxSizeMB: 610,
                  languages: "en, es, fr, it, pt, de, zh, ja", italian: 2, english: 2, speed: 4, note: "NVIDIA multilingual model.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .qwen3ASR, displayName: "Qwen3-ASR 1.7B", engine: .qwen3ASR, approxSizeMB: 1540,
                  languages: "30 languages, auto-detect", italian: 5, english: 5, speed: 3,
                  note: "Most accurate in our tests. Uses your dictionary words as hints.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperTiny, displayName: "Whisper Tiny", engine: .whisperKit, approxSizeMB: 77,
                  languages: "99 languages", italian: 1, english: 2, speed: 5, note: "Fastest Whisper, lowest accuracy.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperBase, displayName: "Whisper Base", engine: .whisperKit, approxSizeMB: 147,
                  languages: "99 languages", italian: 1, english: 2, speed: 5, note: "",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperSmall, displayName: "Whisper Small", engine: .whisperKit, approxSizeMB: 486,
                  languages: "99 languages", italian: 2, english: 3, speed: 4, note: "",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperLargeV3TurboCompact, displayName: "Whisper Large v3 Turbo (compact)", engine: .whisperKit,
                  approxSizeMB: 646, languages: "99 languages", italian: 4, english: 4, speed: 3, note: "Turbo compressed to a third of the size, same accuracy in our tests.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperLargeV3, displayName: "Whisper Large v3", engine: .whisperKit, approxSizeMB: 948,
                  languages: "99 languages", italian: 4, english: 3, speed: 2, note: "Most accurate Whisper on Italian.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperLargeV3Turbo, displayName: "Whisper Large v3 Turbo", engine: .whisperKit, approxSizeMB: 1638,
                  languages: "99 languages", italian: 4, english: 4, speed: 3, note: "Widest language coverage.",
                  requiresExplicitLanguage: false),
    ]

    public static func info(_ id: ModelID) -> ModelInfo {
        all.first { $0.id == id }!
    }
}

public protocol ModelInstaller: Sendable {
    func isInstalled(_ id: ModelID) async -> Bool
    /// Must throw `CancellationError` (or any error) promptly when the task is cancelled.
    func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
    func uninstall(_ id: ModelID) async throws
    func makeTranscriber(_ id: ModelID) async throws -> any Transcriber
}
