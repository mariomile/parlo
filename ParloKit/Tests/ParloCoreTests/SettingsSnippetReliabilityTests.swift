import Foundation
import Testing
@testable import ParloCore

@Suite struct SettingsPersistenceReliabilityTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-settings-reliability-\(UUID().uuidString)")

    @Test func unreadableSettingsBlockEditsUntilSuccessfulReload() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let store = SettingsStore(directory: dir, files: faults.files)
        var original = AppSettings.default
        original.dictionary = [DictionaryEntry(term: "Private saved vocabulary")]
        original.snippets = [Snippet(trigger: "my address", text: "Saved address")]
        try store.save(original)
        let originalBytes = try Data(contentsOf: store.fileURL)
        faults.unreadable.value = [store.fileURL]
        var defaults = store.load().settings
        #expect(store.loadError != nil)
        defaults.languageCode = "it"
        #expect(throws: (any Error).self) { try store.save(defaults) }
        #expect(try Data(contentsOf: store.fileURL) == originalBytes)
        faults.unreadable.value = []
        // Fixing permissions alone cannot make stale defaults safe to write over the recovered settings.
        #expect(throws: (any Error).self) { try store.save(defaults) }
        var recovered = store.load().settings
        #expect(store.loadError == nil)
        #expect(recovered == original)
        recovered.languageCode = "it"
        try store.save(recovered)
        #expect(store.load().settings.dictionary == original.dictionary)
        #expect(store.load().settings.snippets == original.snippets)
    }

    @Test func realReadPermissionFailureDoesNotOverwriteTheExistingFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var original = AppSettings.default
        original.dictionary = [DictionaryEntry(term: "Kept on disk")]
        try store.save(original)
        let originalBytes = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path) }
        let loaded = store.load()
        #expect(loaded.quarantined == nil)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.save(loaded.settings) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(try Data(contentsOf: store.fileURL) == originalBytes)
        #expect(store.load().settings == original)
    }

    @Test func savingWithoutLoadingStillRefusesAnUnreadableOriginal() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = SettingsStore(directory: dir)
        try original.save(.default)
        let bytes = try Data(contentsOf: original.fileURL)
        let faults = CorePersistenceFaults()
        faults.unreadable.value = [original.fileURL]
        let replacement = SettingsStore(directory: dir, files: faults.files)
        #expect(throws: (any Error).self) { try replacement.save(.default) }
        #expect(replacement.loadError != nil)
        #expect(try Data(contentsOf: original.fileURL) == bytes)
    }

    @Test func failedCorruptFileBackupBlocksWritingUntilTheOriginalIsPreserved() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appending(path: "settings.json")
        let bytes = Data("{not recoverable JSON".utf8)
        try bytes.write(to: json)
        let denyBackups = LockedBox(true)
        var files = PersistenceIO()
        files.write = { data, url in
            if denyBackups.value, url.lastPathComponent.hasPrefix("settings.corrupt-") { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
        let store = SettingsStore(directory: dir, files: files)
        #expect(store.load().quarantined == nil)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) { try store.save(.default) }
        #expect(try Data(contentsOf: json) == bytes)
        denyBackups.value = false
        let backup = try #require(store.load().quarantined)
        #expect(try Data(contentsOf: backup) == bytes)
        #expect(store.loadError == nil)
        try store.save(.default)
        #expect(try Data(contentsOf: backup) == bytes)
    }
}

@Suite struct SnippetReliabilityTests {
    @Test func tokenLikeTriggerCannotRewriteAnotherSnippetsGeneratedToken() {
        let snippets = [Snippet(trigger: "my address", text: "Via Roma 1"), Snippet(trigger: "s1", text: "Section one")]
        let encoded = SnippetCodec.encode("Send it to my address then s1", snippets: snippets)
        #expect(encoded.text == "Send it to ⟦S1⟧ then ⟦S2⟧")
        #expect(encoded.used.count == 2)
        #expect(SnippetCodec.allTokensPresent(encoded.text, used: encoded.used))
        #expect(SnippetCodec.decode(encoded.text, used: encoded.used) == "Send it to Via Roma 1 then Section one")
    }

    @Test func longestOverlappingTriggerWinsWithoutMatchingExpansionText() {
        let snippets = [
            Snippet(trigger: "address", text: "short"),
            Snippet(trigger: "my address", text: "address plus firma"),
            Snippet(trigger: "firma", text: "signature"),
        ]
        let encoded = SnippetCodec.encode("my, address; address; firma", snippets: snippets)
        #expect(encoded.used.count == 3)
        #expect(SnippetCodec.decode(encoded.text, used: encoded.used) == "address plus firma; short; signature")
    }

    @Test func literalPlaceholderTextIsProtectedAndDoesNotCollideWithAssignedTokens() {
        let snippets = [Snippet(trigger: "s1", text: "section one"), Snippet(trigger: "my address", text: "Via Roma")]
        let encoded = SnippetCodec.encode("Keep ⟦S1⟧ and ⟦S2⟧ literal, my address, s1", snippets: snippets)
        #expect(encoded.used["⟦S1⟧"] == nil)
        #expect(encoded.used["⟦S2⟧"] == nil)
        #expect(encoded.used.count == 2)
        #expect(SnippetCodec.allTokensPresent(encoded.text, used: encoded.used))
        #expect(SnippetCodec.decode(encoded.text, used: encoded.used) == "Keep ⟦S1⟧ and ⟦S2⟧ literal, Via Roma, section one")
    }

    @Test func longestMatchedSpanWinsEvenWhenShorterTriggerHasMorePunctuation() {
        let snippets = [Snippet(trigger: "my.....address", text: "short"), Snippet(trigger: "my address today", text: "long")]
        let encoded = SnippetCodec.encode("my address today", snippets: snippets)
        #expect(encoded.used.count == 1)
        #expect(SnippetCodec.decode(encoded.text, used: encoded.used) == "long")
    }

    @Test func decodingDoesNotRematchTokensInsideSavedExpansion() {
        let used = ["⟦S1⟧": Snippet(trigger: "first", text: "literal ⟦S2⟧"), "⟦S2⟧": Snippet(trigger: "second", text: "expanded")]
        #expect(SnippetCodec.decode("⟦S1⟧ then ⟦S2⟧", used: used) == "literal ⟦S2⟧ then expanded")
    }

    @Test func exactMultiplicityRejectsMissingDuplicatedAndAlteredTokens() {
        let snippets = [Snippet(trigger: "firma", text: "Mario")]
        let encoded = SnippetCodec.encode("firma then firma", snippets: snippets)
        #expect(encoded.used.count == 2)
        #expect(SnippetCodec.allTokensPresent(encoded.text, used: encoded.used))
        #expect(!SnippetCodec.allTokensPresent("⟦S1⟧", used: encoded.used))
        #expect(!SnippetCodec.allTokensPresent("⟦S1⟧ ⟦S2⟧ ⟦S2⟧", used: encoded.used))
        #expect(!SnippetCodec.allTokensPresent("⟦S1⟧ ⟦s2⟧", used: encoded.used))
        #expect(!SnippetCodec.allTokensPresent("⟦S1⟧ [S2]", used: encoded.used))
        #expect(SnippetCodec.decode(encoded.text, used: encoded.used) == "Mario then Mario")
    }

    @Test func duplicatedTokenIsRejectedEvenWhenCleanupLengthGuardAcceptsIt() {
        let encoded = SnippetCodec.encode("Please send it to my address today", snippets: [Snippet(trigger: "my address", text: "Saved address")])
        let duplicated = encoded.text.replacingOccurrences(of: "⟦S1⟧", with: "⟦S1⟧ ⟦S1⟧")
        #expect(CleanupOutput.accepted(duplicated, input: encoded.text) != nil)
        #expect(!SnippetCodec.allTokensPresent(duplicated, used: encoded.used))
    }

    @Test func cleanupDuplicationFallsBackToExactlyOneSavedExpansion() async throws {
        var settings = AppSettings.default
        settings.snippets = [Snippet(trigger: "my address", text: "Saved address")]
        let llm = FakeLLM { _, _ in "Please send it to ⟦S1⟧ ⟦S1⟧ today" }
        let job = TranscriptionJob(
            transcriber: FakeTranscriber(text: "Please send it to my address today"), llm: llm, settings: settings, speech: nil
        )
        let result = try await job.run(oneSecond, .dictation(bundleID: nil))
        guard case let .text(text, warning) = result else { Issue.record("Expected the preserved transcription"); return }
        #expect(text == "Please send it to Saved address today")
        #expect(warning != nil)
        #expect(llm.calls.count == 1)
    }

    @Test func tokenLikeTriggersWorkWithCleanupDisabled() async throws {
        var settings = AppSettings.default
        settings.snippets = [Snippet(trigger: "my address", text: "Via Roma 1"), Snippet(trigger: "s1", text: "Section one")]
        let job = TranscriptionJob(
            transcriber: FakeTranscriber(text: "Send it to my address"), llm: nil, settings: settings, speech: nil
        )
        #expect(try await job.run(oneSecond, .dictation(bundleID: nil)) == .text("Send it to Via Roma 1", warning: nil))
    }
}
