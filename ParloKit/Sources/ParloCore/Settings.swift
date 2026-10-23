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

public struct LLMSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String

    public init(enabled: Bool, baseURL: String, model: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
    }

    public static let groqDefault = LLMSettings(
        enabled: false,
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

    public static let `default` = AppSettings(
        activeModelID: .appleSpeech,
        languageCode: nil,
        llm: .groqDefault,
        styleOverrides: [:],
        dictionary: [],
        snippets: [],
        hasCompletedOnboarding: false
    )

    public init(
        activeModelID: ModelID, languageCode: String?, llm: LLMSettings, styleOverrides: [String: Style],
        dictionary: [DictionaryEntry], snippets: [Snippet], hasCompletedOnboarding: Bool
    ) {
        self.activeModelID = activeModelID
        self.languageCode = languageCode
        self.llm = llm
        self.styleOverrides = styleOverrides
        self.dictionary = dictionary
        self.snippets = snippets
        self.hasCompletedOnboarding = hasCompletedOnboarding
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
    }
}
