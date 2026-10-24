import Foundation

public enum Style: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual, technical, neutral

    public var displayName: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .technical: "Technical"
        case .neutral: "Neutral"
        }
    }
}

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var term: String
    public var heardAs: [String]

    public init(id: UUID = UUID(), term: String, heardAs: [String] = []) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
    }
}

public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var text: String

    public init(id: UUID = UUID(), trigger: String, text: String) {
        self.id = id
        self.trigger = trigger
        self.text = text
    }
}

public enum LLMProvider: String, Codable, Sendable {
    /// Apple Intelligence's on-device model: no key, nothing leaves the Mac.
    case apple
    /// An open model downloaded by Parlo and run in-process with MLX: no key, no server, nothing leaves the Mac.
    case local
    /// Any `/chat/completions` endpoint: Groq, OpenAI, OpenRouter, Ollama.
    case openAICompatible
}

public struct LLMSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: LLMProvider
    /// `baseURL` and `model` apply to `.openAICompatible` only.
    public var baseURL: String
    public var model: String

    public init(enabled: Bool, provider: LLMProvider, baseURL: String, model: String) {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
    }

    public static let `default` = LLMSettings(
        enabled: false,
        provider: .apple,
        baseURL: "https://api.groq.com/openai/v1",
        model: "llama-3.3-70b-versatile"
    )
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeModelID: ModelID
    /// BCP-47 language code ("it", "en"); nil means auto-detect where the model supports it.
    public var languageCode: String?
    public var llm: LLMSettings
    /// Bundle ID -> style, overriding the built-in defaults.
    public var styleOverrides: [String: Style]
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var hasCompletedOnboarding: Bool
    /// Core Audio UID of the chosen input device; nil follows the system default.
    public var microphoneUID: String?

    public static let `default` = AppSettings(
        activeModelID: .appleSpeech,
        languageCode: nil,
        llm: .default,
        styleOverrides: [:],
        dictionary: [],
        snippets: [],
        hasCompletedOnboarding: false,
        microphoneUID: nil
    )

    public init(
        activeModelID: ModelID, languageCode: String?, llm: LLMSettings, styleOverrides: [String: Style],
        dictionary: [DictionaryEntry], snippets: [Snippet], hasCompletedOnboarding: Bool, microphoneUID: String? = nil
    ) {
        self.activeModelID = activeModelID
        self.languageCode = languageCode
        self.llm = llm
        self.styleOverrides = styleOverrides
        self.dictionary = dictionary
        self.snippets = snippets
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.microphoneUID = microphoneUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        let rawModel = try c.decodeIfPresent(String.self, forKey: .activeModelID)
        activeModelID = rawModel.flatMap(ModelID.init(rawValue:)) ?? d.activeModelID
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
        llm = try c.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? d.llm
        styleOverrides = try c.decodeIfPresent([String: Style].self, forKey: .styleOverrides) ?? d.styleOverrides
        dictionary = try c.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? d.dictionary
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
    }
}
