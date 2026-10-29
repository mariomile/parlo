import Testing
@testable import ParloCore

@Suite struct DictionaryLearnerTests {
    @Test func addsNewTerm() {
        var dictionary: [DictionaryEntry] = []
        let outcome = DictionaryLearner.learn(DictionaryEntry(term: "CLAUDE.md", heardAs: ["Cloud MD"]), into: &dictionary)
        #expect(outcome == .added(term: "CLAUDE.md"))
        #expect(dictionary.map(\.term) == ["CLAUDE.md"])
        #expect(dictionary.first?.heardAs == ["Cloud MD"])
    }

    @Test func addsMisheardSpellingToKnownTermIgnoringCase() {
        var dictionary = [DictionaryEntry(term: "Parlo", heardAs: ["Parla"])]
        let outcome = DictionaryLearner.learn(DictionaryEntry(term: "parlo", heardAs: ["Pablo"]), into: &dictionary)
        #expect(outcome == .extended(term: "Parlo"))
        #expect(dictionary.count == 1)
        #expect(dictionary[0].heardAs == ["Parla", "Pablo"])
    }

    @Test func sameFixTwiceSavesOnce() {
        var dictionary: [DictionaryEntry] = []
        let entry = DictionaryEntry(term: "Qwen", heardAs: ["Quen"])
        _ = DictionaryLearner.learn(entry, into: &dictionary)
        let again = DictionaryLearner.learn(DictionaryEntry(term: "QWEN", heardAs: ["quen"]), into: &dictionary)
        #expect(again == .known)
        #expect(dictionary.count == 1)
        #expect(dictionary[0].heardAs == ["Quen"])
    }

    @Test func caseOnlyFixOfKnownTermIsKnown() {
        var dictionary = [DictionaryEntry(term: "DeepAgent")]
        let outcome = DictionaryLearner.learn(DictionaryEntry(term: "deepagent"), into: &dictionary)
        #expect(outcome == .known)
        #expect(dictionary == [DictionaryEntry(id: dictionary[0].id, term: "DeepAgent")])
    }
}
