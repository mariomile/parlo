public enum ModelID: String, Codable, CaseIterable, Sendable {
    case appleSpeech
    case parakeetV3, parakeetUltra, parakeetRedux, parakeetV2
    case cohereTranscribe
    case nemotronMultilingual
    case whisperTiny, whisperBase, whisperSmall, whisperLargeV3Turbo
}

public enum Engine: String, Sendable {
    case apple, parakeet, cohere, nemotron, whisperKit
}

public struct ModelInfo: Identifiable, Sendable {
    public let id: ModelID
    public let displayName: String
    public let engine: Engine
    public let approxSizeMB: Int
    public let languages: String
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
                  languages: "Italian, English and many more", note: "Built into macOS. Language assets install on first use.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetV3, displayName: "Parakeet TDT v3", engine: .parakeet, approxSizeMB: 600,
                  languages: "25 European languages incl. Italian, auto-detect", note: "Recommended. Fast and accurate.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetUltra, displayName: "Parakeet Ultra", engine: .parakeet, approxSizeMB: 600,
                  languages: "25 European languages incl. Italian", note: "Higher accuracy than v3.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetRedux, displayName: "Parakeet Redux", engine: .parakeet, approxSizeMB: 220,
                  languages: "Multilingual", note: "Lightest Parakeet.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .parakeetV2, displayName: "Parakeet TDT v2", engine: .parakeet, approxSizeMB: 600,
                  languages: "English only", note: "Best English accuracy.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .cohereTranscribe, displayName: "Cohere Transcribe", engine: .cohere, approxSizeMB: 1800,
                  languages: "14 languages incl. Italian", note: "Top accuracy. Set the language in General.",
                  requiresExplicitLanguage: true),
        ModelInfo(id: .nemotronMultilingual, displayName: "Nemotron Speech Multilingual", engine: .nemotron, approxSizeMB: 600,
                  languages: "en, es, fr, it, pt, de, zh, ja", note: "NVIDIA multilingual model.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperTiny, displayName: "Whisper Tiny", engine: .whisperKit, approxSizeMB: 75,
                  languages: "99 languages", note: "Fastest Whisper, lowest accuracy.",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperBase, displayName: "Whisper Base", engine: .whisperKit, approxSizeMB: 145,
                  languages: "99 languages", note: "",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperSmall, displayName: "Whisper Small", engine: .whisperKit, approxSizeMB: 480,
                  languages: "99 languages", note: "",
                  requiresExplicitLanguage: false),
        ModelInfo(id: .whisperLargeV3Turbo, displayName: "Whisper Large v3 Turbo", engine: .whisperKit, approxSizeMB: 1600,
                  languages: "99 languages", note: "Widest language coverage, slower.",
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
