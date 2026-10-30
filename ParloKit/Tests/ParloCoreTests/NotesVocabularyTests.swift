import Foundation
import Testing
@testable import ParloCore

@Suite struct NotesVocabularyTests {
    private func terms(_ notes: [String], dictionary: [DictionaryEntry] = [], known: Set<String> = []) -> [String] {
        NotesVocabulary.candidates(in: notes, excluding: dictionary, limit: 50) { known.contains($0) }.map(\.term)
    }

    @Test func findsNamesUsedAcrossNotes() {
        let notes = Array(repeating: "Call with Alice Morrone about DeepAgent and Next.js.", count: 3)
        #expect(Set(terms(notes, known: ["Call"])) == ["Alice Morrone", "DeepAgent", "Next.js"])
    }

    @Test func needsSeveralNotes() {
        let notes = ["Met Morrone.", "Met Morrone again.", "Nothing here."]
        #expect(terms(notes).isEmpty)
    }

    @Test func capitalizedWordAlsoWrittenLowercaseIsOrdinary() {
        let notes = Array(repeating: "Product notes. The product is good, the product works, product product.", count: 3)
        #expect(!terms(notes).contains("Product"))
    }

    @Test func titleWrittenLowercaseElsewhereIsNotAName() {
        let notes = Array(repeating: "## Product Management\nI love product management and product management loves me.", count: 3)
        #expect(!terms(notes).contains("Product Management"))
    }

    @Test func knownWordsAreLeftOutUnlessSpelledTheirOwnWay() {
        let notes = Array(repeating: "In October I used Notion, PostHog and macOS.", count: 3)
        #expect(Set(terms(notes, known: ["October", "Notion", "PostHog", "macOS"])) == ["PostHog", "macOS"])
    }

    @Test func skipsAcronymsFilesVersionsLinksAndCode() {
        let note = """
        ---
        owner: Giuliano Messina
        ---
        PMF and KPI. See Image.png and Tier-1. Visit https://Example.com/DeepWork or mail Foo@Bar.com.
        `SecretToken` and
        ```
        HiddenClass
        ```
        """
        #expect(terms(Array(repeating: note, count: 3), known: ["See", "Visit", "Tier"]).isEmpty)
    }

    @Test func skipsElisionsPossessivesPluralAcronymsAndCompounds() {
        let notes = Array(repeating: "Dell'AI di Mario's team: KPIs, AI-native, Counter-arguments.", count: 3)
        #expect(terms(notes, known: ["Dell", "Mario", "Counter"]).isEmpty)
    }

    @Test func titleMadeOfOrdinaryWordsIsLeftOut() {
        let notes = Array(repeating: "See Reference Library and Carlotta Negri. We see the library has a reference.", count: 3)
        #expect(terms(notes, known: ["See", "Reference", "Library", "Carlotta", "Negri"]) == ["Carlotta Negri"])
    }

    @Test func ruleIsNotFrontMatterAndLongLinesAreSkipped() {
        let note = "---\nAlice Morrone wrote this.\n----\nBlob " + String(repeating: "A", count: 100_000) + "Zappyrent"
        #expect(terms(Array(repeating: note, count: 3)) == ["Alice Morrone"])
    }

    @Test func wikiLinksKeepTheirText() {
        let notes = Array(repeating: "Ask [[Carlotta Negri|Carlotta]] about it, then ask again.", count: 3)
        #expect(terms(notes, known: ["Ask"]) == ["Carlotta Negri"])
    }

    @Test func greetingBeforeANameIsLeftOut() {
        let notes = Array(repeating: "Ciao Mario, ciao a tutti. Mario Miletta.", count: 3)
        #expect(terms(notes, known: ["Ciao", "Mario"]) == ["Mario Miletta"])
    }

    @Test func wordCoveredByLongerNameIsDropped() {
        let notes = Array(repeating: "Alice Morrone said so.", count: 3)
        #expect(!terms(notes).contains("Morrone"))
    }

    @Test func punctuationEndsAName() {
        let notes = Array(repeating: "Ciao Mario. Zappyrent, Coverzen.", count: 3)
        #expect(!terms(notes).contains("Zappyrent Coverzen"))
        #expect(Set(terms(notes)).isSuperset(of: ["Zappyrent", "Coverzen"]))
    }

    @Test func leavesOutWordsAlreadyInTheDictionary() {
        let notes = Array(repeating: "DeepAgent and Captoo.", count: 3)
        #expect(terms(notes, dictionary: [DictionaryEntry(term: "deepagent")]) == ["Captoo"])
    }

    @Test func mostUsedFirstAndMostCommonSpelling() {
        let notes = ["Captoo Captoo", "Captoo", "Captoo DeepAgent", "DeepAgent", "DEEPagent DeepAgent"]
        #expect(terms(notes) == ["Captoo", "DeepAgent"])
    }

    @Test func readsMarkdownFilesSkippingHiddenFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["a", "b/c", ".obsidian"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for path in ["a/1.md", "b/2.md", "b/c/3.md", ".obsidian/4.md", ".obsidian/5.md", ".obsidian/6.md"] {
            try "Thymer is here.".write(to: root.appending(path: path), atomically: true, encoding: .utf8)
        }
        try "Hidden is here.".write(to: root.appending(path: "a/notes.txt"), atomically: true, encoding: .utf8)
        #expect(NotesVocabulary.candidates(in: root, excluding: []) { _ in false }.map(\.notes) == [3])
    }
}
