import Foundation
import Testing
@testable import ParloCore

@Suite struct SettingsStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func missingFileGivesDefaults() throws {
        let store = SettingsStore(directory: dir)
        let s = store.load()
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
        s.llm = LLMSettings(enabled: true, baseURL: "http://localhost:11434/v1", model: "llama3")
        s.styleOverrides = ["com.foo": .technical]
        s.dictionary = [DictionaryEntry(term: "Claude Code", heardAs: ["cloud code"])]
        s.snippets = [Snippet(trigger: "my address", text: "Via Roma 1")]
        s.hasCompletedOnboarding = true
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func corruptFileIsQuarantined() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        try Data("{not json".utf8).write(to: file)
        let store = SettingsStore(directory: dir)
        #expect(store.load() == AppSettings.default)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains("settings.json"))
        #expect(names.contains { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func missingKeysUseDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"activeModelID":"parakeetV3"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load()
        #expect(s.activeModelID == .parakeetV3)
        #expect(s.llm == AppSettings.default.llm)
        #expect(s.snippets.isEmpty)
    }

    @Test func unknownModelIDFallsBackToDefault() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"activeModelID":"gone","languageCode":"it"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load()
        #expect(s.activeModelID == .appleSpeech)
        #expect(s.languageCode == "it")
    }
}
