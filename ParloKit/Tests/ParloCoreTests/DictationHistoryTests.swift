import Foundation
import Testing
@testable import ParloCore

@MainActor @Suite struct DictationHistoryTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-history-\(UUID().uuidString)")

    @Test func keepsAudioAndStatus() throws {
        let history = DictationHistory(directory: dir)
        let samples: [Float] = (0..<16_000).map { Float($0 % 100) / 100 }
        let entry = history.add(samples: samples, kind: .dictation).entry
        #expect(entry.status == .processing)
        #expect(entry.duration == 1)
        #expect(history.samples(entry.id) == samples)

        history.update(entry.id, status: .done, text: "ciao")
        #expect(history.entries.first?.status == .done)
        #expect(history.entries.first?.text == "ciao")
    }

    @Test func dropsOldestPastLimit() throws {
        let history = DictationHistory(directory: dir, audioLimit: 2)
        let a = history.add(samples: [0.1], kind: .dictation, status: .failed("x"), date: Date(timeIntervalSince1970: 1)).entry
        let b = history.add(samples: [0.2], kind: .dictation, status: .failed("x"), date: Date(timeIntervalSince1970: 2)).entry
        let c = history.add(samples: [0.3], kind: .command(selection: nil), date: Date(timeIntervalSince1970: 3)).entry
        #expect(history.entries.map(\.id) == [c.id, b.id])
        #expect(history.samples(a.id) == nil)
        #expect(history.samples(b.id) == [0.2])
    }

    @Test func keepsFailedRecordingsOverDoneOnes() throws {
        let history = DictationHistory(directory: dir, audioLimit: 2)
        let failed = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(failed.id, status: .failed("x"), text: nil)
        let done = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.update(done.id, status: .done, text: "ok")
        let new = history.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 3)).entry
        #expect(history.entries.map(\.id) == [new.id, done.id, failed.id])
        #expect(history.entries.map(\.hasAudio) == [true, false, true])
        #expect(history.samples(done.id) == nil)
        #expect(history.samples(failed.id) == [0.1])
    }

    @Test func recordingsBeingTranscribedAreNeverPruned() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1)
        let a = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        let b = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        #expect(history.entries.map(\.id) == [b.id, a.id])
        #expect(history.samples(a.id) == [0.1])
        history.update(a.id, status: .done, text: "first")
        let c = history.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 3)).entry
        #expect(history.entries.map(\.id) == [c.id, b.id, a.id])
        #expect(history.entries.map(\.hasAudio) == [true, true, false])
    }

    @Test func pruningAudioKeepsTheText() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1)
        let a = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(a.id, status: .done, text: "first")
        let b = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.update(b.id, status: .done, text: "second")
        let c = history.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 3)).entry
        #expect(history.entries.map(\.text) == [nil, "second", "first"])
        #expect(history.entries.map(\.hasAudio) == [true, false, false])
        #expect(history.samples(a.id) == nil)
        #expect(history.samples(c.id) == [0.3])
    }

    @Test func dropsOldestEntriesPastTextLimit() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1, textLimit: 2)
        var ids: [String] = []
        for i in 1...3 {
            let e = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: Double(i))).entry
            history.update(e.id, status: .done, text: "t\(i)")
            ids.append(e.id)
        }
        #expect(history.entries.map(\.text) == ["t3", "t2"])
    }

    @Test func fileEntriesHaveNoAudio() throws {
        let history = DictationHistory(directory: dir, audioLimit: 1)
        let file = history.addFile(URL(filePath: "/tmp/memo.m4a"), duration: 90)
        history.update(file.id, status: .done, text: "hello")
        history.add(samples: [0.1], kind: .dictation, date: file.date.addingTimeInterval(1))
        let entry = try #require(history.entries.last)
        #expect(entry.kind == .file(name: "memo.m4a", path: "/tmp/memo.m4a"))
        #expect(entry.hasAudio == false)
        #expect(entry.text == "hello")
        #expect(history.samples(file.id) == nil)
    }

    @Test func fileCanBeRetriedWhileItIsThere() throws {
        let history = DictationHistory(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "memo.m4a")
        try Data([1]).write(to: url)
        let entry = history.addFile(url, duration: 3)
        #expect(entry.canRetry)
        try FileManager.default.removeItem(at: url)
        #expect(!entry.canRetry)
        #expect(!HistoryEntry(id: "1", date: .now, duration: 1, kind: .file(name: "old.m4a", path: nil), status: .done).canRetry)
    }

    @Test func deleteRemovesEntryAndAudio() throws {
        let history = DictationHistory(directory: dir)
        let a = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        let b = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.delete(a.id)
        #expect(history.entries.map(\.id) == [b.id])
        #expect(!FileManager.default.fileExists(atPath: history.audioURL(a.id).path))
    }

    @Test func entryStaysWhenItsRecordingCannotBeRemoved() throws {
        let history = DictationHistory(directory: dir)
        let a = history.add(samples: [0.1], kind: .dictation).entry
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        history.delete(a.id)
        #expect(history.entries.map(\.id) == [a.id])
        #expect(history.saveError != nil)
    }

    @Test func recordingTheIndexNeverListedComesBack() throws {
        let history = DictationHistory(directory: dir)
        let listed = history.add(samples: [0.1], kind: .dictation, status: .done, date: Date(timeIntervalSince1970: 1)).entry
        try WAV.encode([0.2]).write(to: history.audioURL("2000"))
        let relaunched = DictationHistory(directory: dir)
        #expect(relaunched.entries.map(\.id) == ["2000", listed.id])
        #expect(relaunched.entries.first?.status == .failed("Recovered recording"))
        #expect(relaunched.samples("2000") == [0.2])
    }

    @Test func indexWithoutNewFieldsStillLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = """
        [{"id":"5","date":1000,"duration":2,"command":false,"status":{"done":{}},"text":"vecchio"},
         {"id":"4","date":900,"duration":1,"command":true,"status":{"failed":{"_0":"boom"}}},
         {"id":"3","date":800,"duration":4,"command":false,"status":{"done":{}},"text":"memo","hasAudio":false,"fileName":"memo.m4a"},
         {"id":"2","date":700,"duration":1,"command":true,"status":{"done":{}},"text":"ok","selection":"hey"}]
        """
        try Data(old.utf8).write(to: dir.appending(path: "history.json"))
        let entries = DictationHistory(directory: dir).entries
        #expect(entries.map(\.id) == ["5", "4", "3", "2"])
        #expect(entries.map(\.hasAudio) == [true, true, false, true])
        #expect(entries.map(\.kind) == [.dictation, .command(selection: nil), .file(name: "memo.m4a", path: nil), .command(selection: "hey")])
        #expect(entries[0].text == "vecchio")
        #expect(entries[1].status == .failed("boom"))
    }

    @Test func corruptIndexIsBackedUpAndAudioRecovered() throws {
        let history = DictationHistory(directory: dir)
        let old = history.add(samples: [0.1, 0.2], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        let index = dir.appending(path: "history.json")
        try Data("not json {".utf8).write(to: index)

        // Loading never changes the file; the recording it lost is listed straight away.
        let relaunched = DictationHistory(directory: dir)
        #expect(relaunched.entries.map(\.id) == [old.id])
        #expect(try Data(contentsOf: index) == Data("not json {".utf8))

        let new = relaunched.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("history.damaged-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appending(path: backups[0])) == Data("not json {".utf8))
        #expect(relaunched.entries.map(\.id) == [new.id, old.id])
        #expect(relaunched.entries.last?.status == .failed("Recovered recording"))
        #expect(relaunched.entries.last?.duration == Audio.seconds(2))
        #expect(relaunched.samples(old.id) == [0.1, 0.2])
        #expect(DictationHistory(directory: dir).entries.map(\.id) == [new.id, old.id])
    }

    @Test func malformedEntryDoesNotDropTheOthers() throws {
        let history = DictationHistory(directory: dir)
        let a = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(a.id, status: .done, text: "kept")
        let index = dir.appending(path: "history.json")
        var json = String(decoding: try Data(contentsOf: index), as: UTF8.self)
        json.removeLast() // the closing bracket
        try Data((json + #",{"id":"9"}]"#).utf8).write(to: index)

        let relaunched = DictationHistory(directory: dir)
        #expect(relaunched.entries.map(\.id) == [a.id])
        relaunched.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2))
        #expect(relaunched.entries.count == 2)
        #expect(relaunched.entries.last?.text == "kept")
    }

    @Test func interruptedEntriesBecomeRetryable() throws {
        let history = DictationHistory(directory: dir)
        let entry = history.add(samples: [0.1], kind: .dictation).entry
        history.markInterrupted()
        #expect(history.entries.first?.status == .failed("Interrupted"))
        #expect(history.samples(entry.id) == [0.1])
    }

    @Test func addTakesItsStatus() {
        let history = DictationHistory(directory: dir)
        history.add(samples: [0.1], kind: .dictation, status: .failed("Cancelled"))
        #expect(history.entries.first?.status == .failed("Cancelled"))
        #expect(DictationHistory(directory: dir).entries.first?.status == .failed("Cancelled"))
    }

    @Test func commandKeepsItsSelection() {
        let history = DictationHistory(directory: dir)
        let command = history.add(samples: [0.1], kind: .command(selection: nil)).entry
        let dictation = history.add(samples: [0.2], kind: .dictation, date: command.date.addingTimeInterval(1)).entry
        history.setSelection(command.id, "hey dude")
        history.setSelection(dictation.id, "ignored")
        let reloaded = DictationHistory(directory: dir).entries
        #expect(reloaded.map(\.kind) == [.dictation, .command(selection: "hey dude")])
    }

    @Test func diskFormatKeepsItsFlatKeys() throws {
        let history = DictationHistory(directory: dir)
        history.add(samples: [0.1], kind: .command(selection: "x"), date: Date(timeIntervalSince1970: 1))
        history.addFile(URL(filePath: "/tmp/memo.m4a"), duration: 3, date: Date(timeIntervalSince1970: 2))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "history.json"))) as? [[String: Any]]
        let file = try #require(json?.first)
        let command = try #require(json?.last)
        #expect(file["fileName"] as? String == "memo.m4a")
        #expect(file["filePath"] as? String == "/tmp/memo.m4a")
        #expect(file["command"] as? Bool == false)
        #expect(command["command"] as? Bool == true)
        #expect(command["selection"] as? String == "x")
        #expect(command["fileName"] == nil)
    }

    @Test func entryIsKeptWhenTheDiskRefusesWrites() throws {
        let history = DictationHistory(directory: dir)
        history.add(samples: [0.1], kind: .dictation)
        // A read-only folder makes both the WAV and the index write fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let (entry, audioError) = history.add(samples: [0.2], kind: .dictation)
        #expect(audioError != nil)
        #expect(!entry.hasAudio)
        #expect(history.entries.first?.id == entry.id)
        #expect(history.saveError != nil)
    }

    @Test func entriesInTheSameMillisecondKeepTheirOwnAudio() throws {
        let history = DictationHistory(directory: dir)
        let date = Date(timeIntervalSince1970: 1)
        let a = history.add(samples: [0.1], kind: .dictation, date: date).entry
        let b = history.add(samples: [0.2], kind: .dictation, date: date).entry
        let c = history.addFile(URL(filePath: "/tmp/a.m4a"), duration: 3, date: date)
        #expect(Set([a.id, b.id, c.id]).count == 3)
        #expect(history.samples(a.id) == [0.1])
        #expect(history.samples(b.id) == [0.2])
    }

    @Test func saveErrorIsReportedAndClears() throws {
        let history = DictationHistory(directory: dir)
        let entry = history.add(samples: [0.1], kind: .dictation).entry
        #expect(history.saveError == nil)
        let index = dir.appending(path: "history.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        history.update(entry.id, status: .done, text: "ciao")
        #expect(history.saveError != nil)
        try FileManager.default.removeItem(at: index)
        history.update(entry.id, status: .done, text: "ciao!")
        #expect(history.saveError == nil)
    }

    @Test func wavDurationMatchesWhatEncodeWrote() {
        #expect(WAV.duration(byteCount: WAV.encode(Array(repeating: 0, count: Audio.sampleRate * 2)).count) == 2)
        #expect(WAV.duration(byteCount: 10) == 0)
    }
}
