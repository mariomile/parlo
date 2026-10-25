import Testing
@testable import ParloCore

@Suite struct SnippetCodecTests {
    let snippets = [
        Snippet(trigger: "my address", text: "Via Roma 1, Milano"),
        Snippet(trigger: "firma", text: "Mario\nmario@example.com"),
    ]

    @Test func standalone() {
        let (encoded, used) = SnippetCodec.encode("My address.", snippets: snippets)
        #expect(encoded == "⟦S1⟧.")
        #expect(SnippetCodec.decode(encoded, used: used) == "Via Roma 1, Milano.")
    }

    @Test func inlineAndPunctuationBetweenWords() {
        let (encoded, used) = SnippetCodec.encode("Send it to my, address please and add firma", snippets: snippets)
        #expect(encoded == "Send it to ⟦S1⟧ please and add ⟦S2⟧")
        #expect(SnippetCodec.decode(encoded, used: used) == "Send it to Via Roma 1, Milano please and add Mario\nmario@example.com")
    }

    @Test func noMatchInsideWord() {
        let (encoded, used) = SnippetCodec.encode("firmament", snippets: snippets)
        #expect(encoded == "firmament")
        #expect(used.isEmpty)
    }

    @Test func missingTokenDetected() {
        let (_, used) = SnippetCodec.encode("my address", snippets: snippets)
        #expect(SnippetCodec.allTokensPresent("⟦S1⟧ ok", used: used))
        #expect(!SnippetCodec.allTokensPresent("nothing here", used: used))
    }

    @Test func eachOccurrenceGetsItsOwnToken() {
        let (encoded, used) = SnippetCodec.encode("firma e firma, my address", snippets: snippets)
        #expect(encoded == "⟦S1⟧ e ⟦S2⟧, ⟦S3⟧")
        #expect(SnippetCodec.decode(encoded, used: used) == "Mario\nmario@example.com e Mario\nmario@example.com, Via Roma 1, Milano")
        #expect(!SnippetCodec.allTokensPresent("⟦S2⟧ e ⟦S1⟧", used: used))
    }
}
