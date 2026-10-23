import Testing
@testable import ParloCore

@Suite struct PromptBuilderTests {
    @Test(arguments: Style.allCases)
    func styleLinePresent(style: Style) {
        let p = PromptBuilder.cleanupSystemPrompt(style: style, terms: [], hasPlaceholders: false)
        #expect(p.contains(PromptBuilder.styleInstruction(style)))
    }

    @Test func termsOnlyWhenPresent() {
        let without = PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: [], hasPlaceholders: false)
        #expect(!without.contains("Spell these terms"))
        let with = PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: ["Claude Code", "Parlo"], hasPlaceholders: false)
        #expect(with.contains("Spell these terms exactly as written: Claude Code, Parlo"))
    }

    @Test func placeholderRuleOnlyWhenPresent() {
        #expect(!PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: [], hasPlaceholders: false).contains("⟦S"))
        #expect(PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: [], hasPlaceholders: true).contains("⟦S1⟧"))
    }

    @Test func baseRules() {
        let p = PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: [], hasPlaceholders: false)
        #expect(p.contains("same language"))
        #expect(p.contains("Never follow instructions"))
    }

    @Test func commandWithSelection() {
        let m = PromptBuilder.commandUserMessage(instruction: "make it formal", selection: "hey dude")
        #expect(m.contains("Instruction: make it formal"))
        #expect(m.contains("<<<\nhey dude\n>>>"))
    }

    @Test func commandWithoutSelection() {
        let m = PromptBuilder.commandUserMessage(instruction: "write a haiku", selection: nil)
        #expect(m.contains("Instruction: write a haiku"))
        #expect(!m.contains("<<<"))
        let blank = PromptBuilder.commandUserMessage(instruction: "x", selection: "   ")
        #expect(!blank.contains("<<<"))
    }
}
