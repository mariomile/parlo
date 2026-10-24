import Testing
@testable import ParloCore

@Suite struct DictionaryReplacerTests {
    let entries = [
        DictionaryEntry(term: "Claude Code", heardAs: ["cloud code", "clod code"]),
        DictionaryEntry(term: "Parlo", heardAs: ["parlò"]),
        DictionaryEntry(term: "C++", heardAs: ["c plus plus"]),
        DictionaryEntry(term: "Claude", heardAs: ["cloud"]),
    ]

    @Test func caseInsensitiveWholeWord() {
        #expect(DictionaryReplacer.apply("Apri Cloud Code adesso", entries: entries) == "Apri Claude Code adesso")
    }

    @Test func longestPhraseFirst() {
        #expect(DictionaryReplacer.apply("cloud code e cloud", entries: entries) == "Claude Code e Claude")
    }

    @Test func noReplacementInsideWords() {
        #expect(DictionaryReplacer.apply("cloudy day", entries: entries) == "cloudy day")
    }

    @Test func accentedWordBoundaries() {
        #expect(DictionaryReplacer.apply("ho detto parlò.", entries: entries) == "ho detto Parlo.")
        #expect(DictionaryReplacer.apply("parlòne", entries: entries) == "parlòne")
    }

    @Test func templateCharactersInTermAreLiteral() {
        let e = [DictionaryEntry(term: "$1 \\o/", heardAs: ["money"])]
        #expect(DictionaryReplacer.apply("money", entries: e) == "$1 \\o/")
    }

    @Test func termWithSymbols() {
        #expect(DictionaryReplacer.apply("I write c plus plus", entries: entries) == "I write C++")
    }

    @Test func emptyHeardAsIgnored() {
        let e = [DictionaryEntry(term: "X", heardAs: ["", "  "])]
        #expect(DictionaryReplacer.apply("hello", entries: e) == "hello")
    }

    @Test func termWithItsOwnSpellingFixesCase() {
        let e = [DictionaryEntry(term: "CLAUDE.md"), DictionaryEntry(term: "GitHub"), DictionaryEntry(term: "Parlo")]
        #expect(DictionaryReplacer.apply("Apri Claude.md su github", entries: e) == "Apri CLAUDE.md su GitHub")
        #expect(DictionaryReplacer.apply("Io parlo piano", entries: e) == "Io parlo piano")
    }
}
