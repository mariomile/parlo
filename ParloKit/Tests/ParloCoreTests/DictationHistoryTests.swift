import Foundation
import Testing
@testable import ParloCore

@Suite struct DictationHistoryTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-history-\(UUID().uuidString)")

    @Test func keepsAudioAndStatus() throws {
        let history = DictationHistory(directory: dir)
        let samples: [Float] = (0..<16_000).map { Float($0 % 100) / 100 }
        let entry = try history.add(samples: samples, command: false)
        #expect(entry.status == .processing)
        #expect(entry.duration == 1)
        #expect(history.samples(entry.id) == samples)

        history.update(entry.id, status: .done, text: "ciao")
        #expect(history.entries().first?.status == .done)
        #expect(history.entries().first?.text == "ciao")
    }

    @Test func dropsOldestPastLimit() throws {
        let history = DictationHistory(directory: dir, limit: 2)
        let a = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        let b = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        let c = try history.add(samples: [0.3], command: true, date: Date(timeIntervalSince1970: 3))
        #expect(history.entries().map(\.id) == [c.id, b.id])
        #expect(history.samples(a.id) == nil)
        #expect(history.samples(b.id) == [0.2])
    }

    @Test func keepsFailedRecordingsOverDoneOnes() throws {
        let history = DictationHistory(directory: dir, limit: 2)
        let failed = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        history.update(failed.id, status: .failed("x"), text: nil)
        let done = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        history.update(done.id, status: .done, text: "ok")
        let new = try history.add(samples: [0.3], command: false, date: Date(timeIntervalSince1970: 3))
        #expect(history.entries().map(\.id) == [new.id, failed.id])
        #expect(history.samples(done.id) == nil)
    }

    @Test func interruptedEntriesBecomeRetryable() throws {
        let history = DictationHistory(directory: dir)
        let entry = try history.add(samples: [0.1], command: false)
        history.markInterrupted()
        #expect(history.entries().first?.status == .failed("Interrupted"))
        #expect(history.samples(entry.id) == [0.1])
    }
}
