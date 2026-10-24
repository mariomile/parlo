import Testing
@testable import ParloCore

@Suite struct VoiceFormattingTests {
    @Test func newLineAfterAPause() {
        #expect(VoiceFormatting.apply("Ciao Marco, a capo, come stai?") == "Ciao Marco\nCome stai?")
        #expect(VoiceFormatting.apply("Thanks. New line. See you soon.") == "Thanks.\nSee you soon.")
    }

    @Test func paragraph() {
        #expect(VoiceFormatting.apply("Ho finito. Nuovo paragrafo. Domani riprendo.") == "Ho finito.\n\nDomani riprendo.")
    }

    @Test func bullets() {
        #expect(
            VoiceFormatting.apply("La spesa: punto elenco latte, punto elenco uova.")
                == "La spesa:\n- Latte\n- Uova."
        )
    }

    @Test func commandsBackToBack() {
        #expect(VoiceFormatting.apply("Ciao. Nuovo paragrafo. Punto elenco latte.") == "Ciao.\n\n- Latte.")
        #expect(VoiceFormatting.apply("Fatto. A capo. A capo. Poi") == "Fatto.\n\nPoi")
    }

    @Test func atTheStart() {
        #expect(VoiceFormatting.apply("A capo. Ecco il resto") == "\nEcco il resto")
    }

    @Test func ordinaryUseIsLeftAlone() {
        // The phrases also occur as normal words; only a phrase that starts a clause is a command.
        let sentences = [
            "È a capo del progetto da un anno.",
            "Aggiungi una nuova riga alla tabella.",
            "Add a new line of code here.",
            "Il punto elenco è troppo lungo",
            "A capo del progetto c'è Marco.",
            "Ho parlato con Luca, a capo dell'ufficio, ieri.",
            "Vediamo. New line of products is out.",
        ]
        for s in sentences { #expect(VoiceFormatting.apply(s) == s) }
    }

    @Test func caseInsensitive() {
        #expect(VoiceFormatting.apply("uno, A CAPO due") == "uno\nDue")
    }
}
