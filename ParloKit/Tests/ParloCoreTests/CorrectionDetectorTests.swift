import Testing
@testable import ParloCore

@Suite struct CorrectionDetectorTests {
    func suggest(_ pasted: String, _ corrected: String, around: (String, String) = ("", "")) -> DictionaryEntry? {
        CorrectionDetector.suggestion(
            pasted: pasted, before: around.0 + pasted + around.1, after: around.0 + corrected + around.1
        )
    }

    @Test func misheardTermBecomesASuggestion() {
        let s = suggest("Ho aggiornato Cloud MD ieri.", "Ho aggiornato CLAUDE.md ieri.")
        #expect(s?.term == "CLAUDE.md")
        #expect(s?.heardAs == ["Cloud MD"])
    }

    @Test func worksInsideALongerField() {
        let s = suggest("Scrivi a Marko domani.", "Scrivi a Mirko domani.", around: ("Note:\n", "\nAltro testo"))
        #expect(s?.term == "Mirko")
        #expect(s?.heardAs == ["Marko"])
    }

    @Test func trailingPunctuationIsNotPartOfTheTerm() {
        #expect(suggest("Apri il file Clod.", "Apri il file Claude.")?.term == "Claude")
    }

    @Test func lettersAddedInsideAWord() {
        #expect(suggest("Apri Clade.", "Apri Claude.")?.term == "Claude")
    }

    @Test func caseOnlyFixKeepsTheSpelling() {
        let s = suggest("Il repo è su github.", "Il repo è su GitHub.")
        #expect(s?.term == "GitHub")
        #expect(s?.heardAs == [])
    }

    @Test func editsOutsideThePasteAreIgnored() {
        #expect(CorrectionDetector.suggestion(pasted: "ciao", before: "Salve ciao", after: "Buongiorno ciao") == nil)
    }

    @Test func typingOnAfterThePasteIsIgnored() {
        #expect(CorrectionDetector.suggestion(pasted: "Ci vediamo", before: "Ci vediamo", after: "Ci vediamo domani") == nil)
        #expect(suggest("Ci vediamo domani", "Ci vediamo") == nil)
    }

    @Test func rewritesAndStyleChangesAreIgnored() {
        #expect(suggest("Possiamo sentirci domani mattina?", "Ti chiamo io più tardi?") == nil)
        #expect(suggest("È molto bello.", "È stupendo.") == nil)
        #expect(suggest("Ciao", "Ciao!") == nil)
    }

    @Test func grammarNumbersAndWordingAreIgnored() {
        #expect(suggest("Sono andato a casa.", "Sono andata a casa.") == nil)
        #expect(suggest("Ho visto la ragazze.", "Ho visto le ragazze.") == nil)
        #expect(suggest("Ci vediamo alle 15.", "Ci vediamo alle 16.") == nil)
        #expect(suggest("Ciao Marco, tutto bene?", "Ciao Mario, tutto bene?") == nil)
        #expect(suggest("Ci vediamo martedì.", "Ci vediamo mercoledì.") == nil)
    }

    @Test func editingEndsWhenTheTextAroundThePasteChanges() {
        let before = "Note: Va bene. Fine"
        #expect(CorrectionDetector.isEditing(pasted: "Va bene.", before: before, now: "Note: Va benissimo. Fine"))
        #expect(!CorrectionDetector.isEditing(pasted: "Va bene.", before: before, now: "Note: Fine"))
        // A chat box: the message was sent and the field cleared.
        #expect(!CorrectionDetector.isEditing(pasted: "Va bene.", before: "Va bene.", now: ""))
    }
}
