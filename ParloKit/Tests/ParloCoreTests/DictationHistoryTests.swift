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
        let history = DictationHistory(directory: dir, audioLimit: 2)
        let a = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        let b = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        let c = try history.add(samples: [0.3], command: true, date: Date(timeIntervalSince1970: 3))
        #expect(history.entries().map(\.id) == [c.id, b.id])
        #expect(history.samples(a.id) == nil)
        #expect(history.samples(b.id) == [0.2])
    }

    @Test func keepsFailedRecordingsOverDoneOnes() throws {
        let history = DictationHistory(directory: dir, audioLimit: 2)
        let failed = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        history.update(failed.id, status: .failed("x"), text: nil)
        let done = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        history.update(done.id, status: .done, text: "ok")
        let new = try history.add(samples: [0.3], command: false, date: Date(timeIntervalSince1970: 3))
        #expect(history.entries().map(\.id) == [new.id, done.id, failed.id])
        #expect(history.entries().map(\.hasAudio) == [true, false, true])
        #expect(history.samples(done.id) == nil)
        #expect(history.samples(failed.id) == [0.1])
    }

    @Test func pruningAudioKeepsTheText() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1)
        let a = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        history.update(a.id, status: .done, text: "first")
        let b = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        history.update(b.id, status: .done, text: "second")
        let c = try history.add(samples: [0.3], command: false, date: Date(timeIntervalSince1970: 3))
        #expect(history.entries().map(\.text) == [nil, "second", "first"])
        #expect(history.entries().map(\.hasAudio) == [true, false, false])
        #expect(history.samples(a.id) == nil)
        #expect(history.samples(c.id) == [0.3])
    }

    @Test func dropsOldestEntriesPastTextLimit() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1, textLimit: 2)
        var ids: [String] = []
        for i in 1...3 {
            let e = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: Double(i)))
            history.update(e.id, status: .done, text: "t\(i)")
            ids.append(e.id)
        }
        #expect(history.entries().map(\.text) == ["t3", "t2"])
    }

    @Test func fileEntriesHaveNoAudio() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1)
        let file = try history.addFile(name: "memo.m4a", duration: 90)
        history.update(file.id, status: .done, text: "hello")
        try history.add(samples: [0.1], command: false, date: file.date.addingTimeInterval(1))
        let entry = try #require(history.entries().last)
        #expect(entry.fileName == "memo.m4a")
        #expect(entry.hasAudio == false)
        #expect(entry.text == "hello")
        #expect(history.samples(file.id) == nil)
    }

    @Test func deleteRemovesEntryAndAudio() throws {
        let history = DictationHistory(directory: dir)
        let a = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        let b = try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        history.delete(a.id)
        #expect(history.entries().map(\.id) == [b.id])
        #expect(!FileManager.default.fileExists(atPath: history.audioURL(a.id).path))
    }

    @Test func indexWithoutNewFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = """
        [{"id":"5","date":1000,"duration":2,"command":false,"status":{"done":{}},"text":"vecchio"},
         {"id":"4","date":900,"duration":1,"command":true,"status":{"failed":{"_0":"boom"}}}]
        """
        try Data(old.utf8).write(to: dir.appending(path: "history.json"))
        let entries = DictationHistory(directory: dir).entries()
        #expect(entries.map(\.id) == ["5", "4"])
        #expect(entries.map(\.hasAudio) == [true, true])
        #expect(entries[0].text == "vecchio")
        #expect(entries[1].status == .failed("boom"))
    }

    @Test func corruptIndexIsBackedUpAndAudioRecovered() throws {
        let history = DictationHistory(directory: dir)
        let old = try history.add(samples: [0.1, 0.2], command: false, date: Date(timeIntervalSince1970: 1))
        let index = dir.appending(path: "history.json")
        try Data("not json {".utf8).write(to: index)

        // Reading never changes the file.
        #expect(history.entries().isEmpty)
        #expect(try Data(contentsOf: index) == Data("not json {".utf8))

        let new = try history.add(samples: [0.3], command: false, date: Date(timeIntervalSince1970: 2))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("history.damaged-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appending(path: backups[0])) == Data("not json {".utf8))
        #expect(history.entries().map(\.id) == [new.id, old.id])
        #expect(history.entries().last?.status == .failed("Recovered from a damaged history file"))
        #expect(history.samples(old.id) == [0.1, 0.2])
    }

    @Test func malformedEntryDoesNotDropTheOthers() throws {
        let history = DictationHistory(directory: dir)
        let a = try history.add(samples: [0.1], command: false, date: Date(timeIntervalSince1970: 1))
        history.update(a.id, status: .done, text: "kept")
        let index = dir.appending(path: "history.json")
        var json = String(decoding: try Data(contentsOf: index), as: UTF8.self)
        json.removeLast() // the closing bracket
        try Data((json + #",{"id":"9"}]"#).utf8).write(to: index)

        #expect(history.entries().map(\.id) == [a.id])
        try history.add(samples: [0.2], command: false, date: Date(timeIntervalSince1970: 2))
        #expect(history.entries().count == 2)
        #expect(history.entries().last?.text == "kept")
    }

    @Test func interruptedEntriesBecomeRetryable() throws {
        let history = DictationHistory(directory: dir)
        let entry = try history.add(samples: [0.1], command: false)
        history.markInterrupted()
        #expect(history.entries().first?.status == .failed("Interrupted"))
        #expect(history.samples(entry.id) == [0.1])
    }
}
