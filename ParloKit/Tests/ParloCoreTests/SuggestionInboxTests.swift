import Testing
@testable import ParloCore

@Suite struct SuggestionInboxTests {
    @Test func newestFirst() {
        var inbox = SuggestionInbox()
        let offered1 = inbox.offer(DictionaryEntry(term: "Parlo"), dictionary: [])
        #expect(offered1)
        let offered2 = inbox.offer(DictionaryEntry(term: "Qwen"), dictionary: [])
        #expect(offered2)
        #expect(inbox.pending.map(\.term) == ["Qwen", "Parlo"])
    }

    @Test func skipsKnownTermsIgnoringCase() {
        var inbox = SuggestionInbox()
        let offered3 = inbox.offer(DictionaryEntry(term: "parlo"), dictionary: [DictionaryEntry(term: "Parlo")])
        #expect(!offered3)
        let offered4 = inbox.offer(DictionaryEntry(term: "Qwen"), dictionary: [])
        #expect(offered4)
        let offered5 = inbox.offer(DictionaryEntry(term: "QWEN"), dictionary: [])
        #expect(!offered5)
        #expect(inbox.pending.map(\.term) == ["Qwen"])
    }

    @Test func dismissedTermsAreNotOfferedAgain() {
        var inbox = SuggestionInbox()
        let entry = DictionaryEntry(term: "Qwen")
        _ = inbox.offer(entry, dictionary: [])
        inbox.dismiss(entry)
        #expect(inbox.pending.isEmpty)
        let offered6 = inbox.offer(DictionaryEntry(term: "qwen"), dictionary: [])
        #expect(!offered6)
    }

    @Test func removedTermsCanComeBack() {
        var inbox = SuggestionInbox()
        let entry = DictionaryEntry(term: "Qwen")
        _ = inbox.offer(entry, dictionary: [])
        inbox.remove(entry)
        #expect(inbox.pending.isEmpty)
        let offered7 = inbox.offer(DictionaryEntry(term: "Qwen"), dictionary: [])
        #expect(offered7)
    }
}
