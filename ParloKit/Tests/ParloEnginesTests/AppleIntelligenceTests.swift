import ParloCore
@testable import ParloEngines
import Testing

/// Runs against the real on-device model; skipped while Apple Intelligence isn't ready.
@Test func appleIntelligenceCleansUpItalian() async throws {
    if let reason = AppleIntelligenceClient.unavailableReason {
        print("[appleIntelligence] skipped, \(reason)")
        return
    }
    let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, terms: [], hasPlaceholders: false)
    let out = try await AppleIntelligenceClient().complete(
        system: system,
        user: "ehm allora domani andiamo al mercato no anzi dopodomani a comprare la frutta",
        timeout: 20
    )
    print("[appleIntelligence] \(out)")
    #expect(out.localizedCaseInsensitiveContains("dopodomani"))
    #expect(!out.localizedCaseInsensitiveContains("ehm"))
}
