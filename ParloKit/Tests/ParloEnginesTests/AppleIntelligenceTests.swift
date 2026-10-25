import Foundation
import ParloCore
@testable import ParloEngines
import Testing

/// Opt-in only: this test runs real on-device inference.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PARLO_INTEGRATION"] == "1"))
func appleIntelligenceCleansUpItalian() async throws {
    if let reason = AppleIntelligenceClient.unavailableReason { try Test.cancel("\(reason)") }
    let system = PromptBuilder.cleanupSystemPrompt(style: .neutral, dictionary: [], hasPlaceholders: false)
    let out = try await AppleIntelligenceClient().complete(
        system: system,
        user: PromptBuilder.cleanupUserMessage("ehm allora domani andiamo al mercato no anzi dopodomani a comprare la frutta"),
        timeout: 20
    )
    print("[appleIntelligence] \(out)")
    #expect(out.localizedCaseInsensitiveContains("dopodomani"))
    #expect(!out.localizedCaseInsensitiveContains("ehm"))
}
