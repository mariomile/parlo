import Testing
@testable import ParloCore

@Suite struct CleanupOutputTests {
    let input = "ho fatto il commit ma la pull request non e ancora pronta"

    @Test(arguments: [
        ("Ecco il testo: Ho fatto il commit.", "Ho fatto il commit."),
        ("Ecco il testo pulito:\nHo fatto il commit.", "Ho fatto il commit."),
        ("Here is the cleaned text: Ho fatto il commit.", "Ho fatto il commit."),
        ("Here's the cleaned transcript:\n\nHo fatto il commit.", "Ho fatto il commit."),
        ("\"Ho fatto il commit.\"", "Ho fatto il commit."),
        ("“Ho fatto il commit.”", "Ho fatto il commit."),
        ("«Ho fatto il commit.»", "Ho fatto il commit."),
        ("<transcript>Ho fatto il commit.</transcript>", "Ho fatto il commit."),
        ("Ecco il testo:\n<transcript>\"Ho fatto il commit.\"</transcript>\n", "Ho fatto il commit."),
    ])
    func stripsWrappers(raw: String, expected: String) {
        #expect(CleanupOutput.stripWrappers(raw, input: input) == expected)
    }

    @Test func keepsApostrophesAndInnerQuotes() {
        #expect(CleanupOutput.stripWrappers("L'ho fatto, \"ok\".", input: input) == "L'ho fatto, \"ok\".")
        #expect(CleanupOutput.stripWrappers("'Ciao'", input: input) == "'Ciao'")
    }

    @Test func keepsWhatTheSpeakerSaid() {
        let spoken = "ecco la situazione: il server e giu da stamattina"
        #expect(CleanupOutput.stripWrappers("Ecco la situazione: il server è giù da stamattina.", input: spoken)
            == "Ecco la situazione: il server è giù da stamattina.")
        #expect(CleanupOutput.stripWrappers("\"Ciao\", ha detto.", input: "ciao ha detto") == "\"Ciao\", ha detto.")
        #expect(CleanupOutput.stripWrappers("\"Ciao a tutti\"", input: "\"ciao a tutti\"") == "\"Ciao a tutti\"")
    }

    @Test func acceptsRatioWithinRange() {
        // 57 chars in; 0.5 and 1.8 are the bounds.
        #expect(CleanupOutput.accepted("Ho fatto il commit, ma la pull request non è ancora pronta.", input: input) != nil)
        #expect(CleanupOutput.accepted(String(repeating: "a", count: 29), input: input) != nil)
        #expect(CleanupOutput.accepted(String(repeating: "a", count: 28), input: input) == nil)
        #expect(CleanupOutput.accepted(String(repeating: "a", count: 102), input: input) != nil)
        #expect(CleanupOutput.accepted(String(repeating: "a", count: 103), input: input) == nil)
    }

    @Test func shortDictationMayShrink() {
        #expect(CleanupOutput.accepted("Sì.", input: "ehm ehm sì") == "Sì.")
        #expect(CleanupOutput.accepted("Sono le tre e un quarto di pomeriggio.", input: "che ore sono") == nil)
    }

    @Test func rejectsEmptyAfterStripping() {
        #expect(CleanupOutput.accepted("", input: input) == nil)
        #expect(CleanupOutput.accepted("<transcript></transcript>", input: input) == nil)
        #expect(CleanupOutput.accepted("Ecco il testo:", input: input) == nil)
    }

    @Test func preambleWithEmojiIsCutAtTheRightPlace() {
        // Emoji and flags are several UTF-16 units each: the cut must not land inside the text.
        #expect(CleanupOutput.stripWrappers("Ecco 🎉🇮🇹 il testo: Ho fatto il commit.", input: input) == "Ho fatto il commit.")
        #expect(CleanupOutput.stripWrappers("Sure 👍🏽:\nHo fatto il commit 🚀", input: input) == "Ho fatto il commit 🚀")
    }

    @Test func ratioIsMeasuredAfterStripping() {
        // A long preamble must not make a too-short answer look fine.
        let reply = "Ecco il testo pulito:\nOk."
        #expect(CleanupOutput.accepted(reply, input: input) == nil)
    }
}
