import Foundation
import Testing
@testable import ParloCore

@Suite struct SettingsStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func missingFileGivesDefaults() throws {
        let store = SettingsStore(directory: dir)
        let s = store.load().settings
        #expect(s == AppSettings.default)
        #expect(s.activeModelID == .appleSpeech)
        #expect(s.llm.enabled == false)
        #expect(s.llm.baseURL == "https://api.groq.com/openai/v1")
    }

    @Test func roundTrip() throws {
        let store = SettingsStore(directory: dir)
        var s = AppSettings.default
        s.activeModelID = .parakeetV3
        s.languageCode = "it"
        s.llm = LLMSettings(enabled: true, provider: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama3")
        s.styleOverrides = ["com.foo": .technical]
        s.dictionary = [DictionaryEntry(term: "Claude Code", heardAs: ["cloud code"])]
        s.snippets = [Snippet(trigger: "my address", text: "Via Roma 1")]
        s.hasCompletedOnboarding = true
        s.microphoneUID = "BuiltInMicrophoneDevice"
        try store.save(s)
        #expect(store.load().settings == s)
    }

    @Test func localProviderRoundTrips() throws {
        let store = SettingsStore(directory: dir)
        var s = AppSettings.default
        s.llm.enabled = true
        s.llm.provider = .local
        try store.save(s)
        #expect(store.load().settings.llm.provider == .local)
    }

    @Test func corruptFileIsQuarantined() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try Data("{not json".utf8).write(to: file)
        let store = SettingsStore(directory: dir)
        let (settings, quarantined) = store.load()
        #expect(settings == AppSettings.default)
        #expect(quarantined?.lastPathComponent.hasPrefix("settings.corrupt-") == true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains("settings.json"))
        #expect(names.contains { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func missingKeysUseDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"activeModelID":"parakeetV3"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load().settings
        #expect(s.activeModelID == .parakeetV3)
        #expect(s.llm == AppSettings.default.llm)
        #expect(s.snippets.isEmpty)
    }

    @Test func unknownModelIDFallsBackToDefault() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"activeModelID":"gone","languageCode":"it"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load().settings
        #expect(s.activeModelID == .appleSpeech)
        #expect(s.languageCode == "it")
    }

    @Test func badValuesCostOnlyThemselves() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"""
        {"activeModelID":"parakeetV3","languageCode":"it",
         "llm":{"enabled":true,"provider":"removedProvider","baseURL":"http://x/v1","model":"m"},
         "styleOverrides":{"com.a":"technical","com.b":"futureStyle"},
         "dictionary":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","term":"Parlo","heardAs":["parlò"]},{"term":42}],
         "snippets":[{"trigger":"no id"},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"addr","text":"Via Roma 1"}],
         "hasCompletedOnboarding":"yes"}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let (s, quarantined) = SettingsStore(directory: dir).load()
        #expect(quarantined == nil)
        #expect(s.activeModelID == .parakeetV3)
        #expect(s.languageCode == "it")
        #expect(s.llm == LLMSettings(enabled: true, provider: .apple, baseURL: "http://x/v1", model: "m"))
        #expect(s.styleOverrides == ["com.a": .technical])
        #expect(s.dictionary.map(\.term) == ["Parlo"])
        #expect(s.snippets.map(\.trigger) == ["addr"])
        #expect(s.hasCompletedOnboarding == false)
    }

    @Test func apiKeyBelongsToTheServer() {
        func scope(_ url: String) -> String? {
            LLMSettings(enabled: true, provider: .openAICompatible, baseURL: url, model: "m").keyScope
        }
        #expect(scope("https://api.groq.com/openai/v1") == "api.groq.com")
        #expect(scope(" https://API.OpenAI.com/v1/ ") == "api.openai.com")
        #expect(scope("http://localhost:11434/v1") == "localhost:11434")
        #expect(scope("https://api.groq.com/openai/v1") != scope("https://api.groq.com.evil.example/v1"))
        #expect(scope("not a url") == nil)
        #expect(scope("") == nil)
    }
}
