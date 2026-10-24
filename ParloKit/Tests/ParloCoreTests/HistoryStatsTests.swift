import Foundation
import Testing
@testable import ParloCore

@Suite struct HistoryStatsTests {
    func entry(
        _ text: String?, seconds: Double, status: HistoryEntry.Status = .done, kind: HistoryEntry.Kind = .dictation
    ) -> HistoryEntry {
        HistoryEntry(id: UUID().uuidString, date: .now, duration: seconds, kind: kind, status: status, text: text, hasAudio: false)
    }

    @Test func countsOnlyFinishedDictations() {
        let stats = HistoryStats([
            entry("one two three", seconds: 2),
            entry("four  five\nsix seven", seconds: 3),
            entry("rewritten text", seconds: 1, kind: .command(selection: nil)),
            entry("a whole transcript here", seconds: 600, kind: .file(name: "memo.m4a")),
            entry(nil, seconds: 5, status: .nothingHeard),
            entry(nil, seconds: 5, status: .failed("x")),
        ])
        #expect(stats.dictations == 2)
        #expect(stats.words == 7)
        #expect(stats.speakingSeconds == 5)
    }

    @Test func timeSavedAssumesFortyWordsPerMinute() {
        // 80 words take 2 minutes to type; speaking them took 30 s.
        let text = Array(repeating: "word", count: 80).joined(separator: " ")
        let stats = HistoryStats([entry(text, seconds: 30)])
        #expect(stats.timeSavedSeconds == 90)
    }

    @Test func timeSavedNeverNegative() {
        #expect(HistoryStats([entry("hi", seconds: 60)]).timeSavedSeconds == 0)
        #expect(HistoryStats([]).timeSavedSeconds == 0)
    }

    @Test func exportListsEveryEntry() {
        let md = HistoryExport.markdown([
            entry("ciao a tutti", seconds: 2),
            entry(nil, seconds: 1, status: .nothingHeard),
            entry(nil, seconds: 1, status: .failed("no model")),
            entry("from a file", seconds: 61, kind: .file(name: "memo.m4a")),
        ])
        #expect(md.hasPrefix("# Parlo history"))
        #expect(md.contains("ciao a tutti"))
        #expect(md.contains("_Nothing heard._"))
        #expect(md.contains("_Failed: no model_"))
        #expect(md.contains("61 s · File: memo.m4a"))
        #expect(md.components(separatedBy: "\n## ").count == 5)
    }
}
