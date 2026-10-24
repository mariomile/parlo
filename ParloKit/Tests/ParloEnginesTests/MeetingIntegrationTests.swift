import Foundation
import ParloCore
import Testing
@testable import ParloEngines

/// A two-person call made with `say`: each side on its own track, cut by Silero, transcribed by Parakeet,
/// merged into turns and, when Apple Intelligence is ready, turned into notes.
/// Run with `PARLO_INTEGRATION=1 swift test --filter MeetingIntegrationTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARLO_INTEGRATION"] == "1"))
struct MeetingIntegrationTests {
    @Test func twoSidedCallBecomesOrderedTurns() async throws {
        let installer = try await EngineIntegrationTests.installer(with: .parakeetV3)
        let tracks = try await MeetingTrackTranscriber(
            transcriber: installer.makeTranscriber(.parakeetV3), segmenter: SileroSpeechDetector.load(),
            languageCode: "en", dictionary: []
        )

        let first = try EngineIntegrationTests.speech("Can you send me the budget for the launch by Friday?", voice: "Samantha")
        let reply = try EngineIntegrationTests.speech("Sure, I will send the budget on Thursday morning.", voice: "Daniel")
        let second = try EngineIntegrationTests.speech("Great, then we book the venue next week.", voice: "Samantha")
        let gap = [Float](repeating: 0, count: Audio.sampleRate)

        let them = [Float](repeating: 0, count: first.count) + gap + reply + gap + [Float](repeating: 0, count: second.count) + gap
        // No headphones: the microphone also hears their reply from the speakers, quieter and a little late.
        let bleed = [Float](repeating: 0, count: 480) + them.dropLast(480).map { $0 * 0.4 }
        let me = zip(first + gap + [Float](repeating: 0, count: reply.count) + gap + second + gap, bleed).map { $0 + $1 }

        let theirs = try await tracks.turns(them, speaker: .them) { _ in }
        let mine = try await tracks.turns(me, speaker: .me, cutAt: theirs.flatMap { [$0.start, $0.end] }) { _ in }
        let turns = MeetingTranscript.merge(me: mine, them: theirs)
        for line in MeetingTranscript.lines(turns) { print("[meeting] \(line)") }

        try #require(turns.count == 3)
        #expect(turns.map(\.speaker) == [.me, .them, .me])
        #expect(turns[0].text.localizedCaseInsensitiveContains("budget"))
        #expect(turns[1].text.localizedCaseInsensitiveContains("Thursday"))
        #expect(turns[2].text.localizedCaseInsensitiveContains("venue"))
        #expect(turns[0].end <= turns[1].start && turns[1].end <= turns[2].start)

        if let reason = AppleIntelligenceClient.unavailableReason {
            print("[meeting] notes skipped: \(reason)")
            return
        }
        let notes = try await MeetingNotes(llm: AppleIntelligenceClient(), maxCharacters: 4000)
            .write(MeetingTranscript.lines(turns), duration: Audio.seconds(me.count))
        print("[meeting] title: \(notes.title ?? "-")\n\(notes.notes)")
        #expect(notes.notes.localizedCaseInsensitiveContains("budget"))
    }
}
