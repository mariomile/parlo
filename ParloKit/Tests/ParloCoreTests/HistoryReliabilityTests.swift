import Foundation
import Testing
@testable import ParloCore

@MainActor @Suite struct HistoryReliabilityTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "parlo-history-reliability-\(UUID().uuidString)")

    @Test func interruptedOldestRetrySurvivesDefaultQuotaSaveRepairSelectionAndReload() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seed = (0..<2000).map { i in
            HistoryEntry(id: "seed-\(i)", date: Date(timeIntervalSince1970: Double(i)), duration: 1,
                         kind: .dictation, status: .done, text: "Saved text \(i)", hasAudio: i == 0)
        }
        let index = dir.appending(path: "history.json")
        try JSONEncoder().encode(seed).write(to: index)
        try WAV.encode([0.1]).write(to: dir.appending(path: "seed-0.wav"))
        let faults = CorePersistenceFaults()
        let history = DictationHistory(directory: dir, files: faults.files)
        #expect(history.textLimit == 2000)
        history.update("seed-0", status: .processing, text: nil)
        let newer = history.addFile(dir.appending(path: "new.m4a"), duration: 1)
        history.update(newer.id, status: .done, text: "New completed result")
        let pending = history.add(samples: [0.2], kind: .command(selection: nil), commandSelectionUnavailable: true).entry
        #expect(history.entries.count == 2002)

        faults.unwritable.value = [index]
        history.markInterrupted()
        #expect(history.indexSaveError != nil)
        #expect(history.entries.first { $0.id == "seed-0" }?.status == .failed("Interrupted"))
        #expect(history.samples("seed-0") == [0.1])
        // A different pending command's flush must not prune the interrupted oldest retry.
        history.setSelection(pending.id, "Pending selection")
        faults.unwritable.value = []
        history.retrySave()
        history.retryRetention()
        let reopened = DictationHistory(directory: dir)
        reopened.retryRetention()
        let old = try #require(reopened.entries.first { $0.id == "seed-0" })
        #expect(old.text == "Saved text 0")
        #expect(old.recoveryPending == true && old.canRetry)
        #expect(reopened.samples(old.id) == [0.1])
        #expect(reopened.entries.count == 2002)
        #expect(reopened.entries.first { $0.id == pending.id }?.kind == .command(selection: "Pending selection"))
        #expect(reopened.entries.first { $0.id == pending.id }?.recoveryPending == true)
    }

    @Test func interruptedRecoverySurvivesZeroQuotasUntilSuccessOrExplicitDelete() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        let old = history.add(samples: [0.1], kind: .dictation).entry
        let other = history.add(samples: [0.2], kind: .command(selection: nil), commandSelectionUnavailable: true).entry
        history.markInterrupted()
        history.setSelection(other.id, "selection")
        history.retryRetention()
        let reopened = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        reopened.update(old.id, status: .processing, text: nil)
        reopened.update(old.id, status: .failed("ASR unavailable"), text: nil)
        reopened.retryRetention()
        #expect(reopened.samples(old.id) == [0.1])
        #expect(reopened.samples(other.id) == [0.2])
        #expect(reopened.entries.allSatisfy { $0.recoveryPending == true })

        reopened.update(old.id, status: .done, text: "Recovered result")
        #expect(reopened.entries.first { $0.id == old.id }?.recoveryPending == nil)
        #expect(reopened.entries.first { $0.id == old.id }?.text == "Recovered result")
        reopened.retryRetention()
        #expect(!reopened.entries.contains { $0.id == old.id })
        #expect(reopened.samples(old.id) == nil)
        #expect(reopened.entries.first?.id == other.id)
        #expect(reopened.delete(other.id))
        #expect(reopened.entries.isEmpty && reopened.samples(other.id) == nil)
    }

    @Test func recordingSavedDirectlyForQuitIsProtectedBeforeInsertionPrunes() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        let recording = history.add(samples: [0.1], kind: .dictation, status: .failed("Interrupted"), recoveryPending: true).entry
        history.retryRetention()
        let reopened = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        #expect(reopened.entries.first?.id == recording.id)
        #expect(reopened.entries.first?.recoveryPending == true)
        #expect(reopened.samples(recording.id) == [0.1])
    }

    @Test func oldHistoryWithoutRecoveryFlagKeepsNormalRetention() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        let old = HistoryEntry(id: "legacy", date: .now, duration: 1, kind: .dictation,
                               status: .failed("Previous failure"), text: "Previous result", hasAudio: false)
        let encoded = try JSONEncoder().encode([old])
        #expect(!String(decoding: encoded, as: UTF8.self).contains("recoveryPending"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoded.write(to: dir.appending(path: "history.json"))
        let reopened = DictationHistory(directory: dir, audioLimit: history.audioLimit, textLimit: history.textLimit)
        #expect(reopened.entries.first?.recoveryPending == nil)
        reopened.retryRetention()
        #expect(reopened.entries.isEmpty)
    }

    @Test func orphanRecoveredAfterFailedInitialIndexWriteKeepsAudioBeyondQuotas() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WAV.encode([0.1]).write(to: dir.appending(path: "1000.wav"))
        let history = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        #expect(history.entries.first?.status == .failed("Recovered recording"))
        history.retryRetention()
        let reopened = DictationHistory(directory: dir, audioLimit: 0, textLimit: 0)
        #expect(reopened.entries.first?.recoveryPending == true)
        #expect(reopened.entries.first?.canRetry == true)
        #expect(reopened.samples("1000") == [0.1])
    }

    @Test func oldestRetrySurvivesAppendAndCompletion() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir, audioLimit: 20, textLimit: 2)
        let oldest = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(oldest.id, status: .done, text: "old result")
        let recent = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.update(recent.id, status: .done, text: "recent result")
        history.update(oldest.id, status: .processing, text: nil)
        let newest = history.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 3)).entry
        #expect(history.entries.count == 3)
        #expect(history.samples(oldest.id) == [0.1])
        history.update(oldest.id, status: .done, text: "retried result")
        #expect(history.entries.first { $0.id == oldest.id }?.text == "retried result")
        #expect(DictationHistory(directory: dir).entries.first { $0.id == oldest.id }?.text == "retried result")
        history.update(newest.id, status: .done, text: "newest result")
        #expect(history.entries.count == 2)
    }

    @Test func oldestRetryStaysDuringHeldDeliveryAndItsCompletionWrite() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir, audioLimit: 20, textLimit: 2)
        let oldest = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(oldest.id, status: .done, text: "old result")
        let other = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.update(other.id, status: .done, text: "other result")
        history.update(oldest.id, status: .processing, text: nil)
        let newest = history.add(samples: [0.3], kind: .dictation, date: Date(timeIntervalSince1970: 3)).entry
        let delivery = HeldCoreResult<Bool>()
        let completing = Task { @MainActor in
            // The native controller persists text while delivery is pending, then completes it.
            history.update(oldest.id, status: .processing, text: "retried result")
            let delivered = await delivery.wait()
            guard delivered, history.entries.contains(where: { $0.id == oldest.id }) else { return false }
            history.update(oldest.id, status: .done, text: "retried result")
            return true
        }
        await delivery.waitUntilStarted()
        history.update(newest.id, status: .done, text: "newest result")
        #expect(history.entries.count == 3)
        #expect(history.samples(oldest.id) == [0.1])
        await delivery.release(true)
        #expect(await completing.value)
        #expect(history.entries.count == 2)
        #expect(history.entries.first { $0.id == oldest.id }?.text == "retried result")
        #expect(history.entries.first { $0.id == oldest.id }?.status == .done)
        #expect(history.entries.contains { $0.id == newest.id })
        #expect(!history.entries.contains { $0.id == other.id })
        #expect(DictationHistory(directory: dir).entries.first { $0.id == oldest.id }?.text == "retried result")
    }

    @Test func failedAudioPruningKeepsBytesMetadataAndErrorAcrossUnrelatedSaves() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let history = DictationHistory(directory: dir, audioLimit: 0, files: faults.files)
        let entry = history.add(samples: [0.1], kind: .dictation).entry
        history.update(entry.id, status: .done, text: "saved transcript")
        faults.undeletable.value = [history.audioURL(entry.id)]
        let other = history.addFile(dir.appending(path: "external.m4a"), duration: 1)
        history.update(other.id, status: .done, text: "unrelated")
        #expect(history.entries.first { $0.id == entry.id }?.hasAudio == true)
        #expect(history.samples(entry.id) == [0.1])
        #expect(history.audioErrors[entry.id] != nil)
        #expect(history.saveError != nil)
        #expect(history.indexSaveError == nil)
        #expect(!history.delete(entry.id))
        #expect(DictationHistory(directory: dir).entries.first { $0.id == entry.id }?.hasAudio == true)
        faults.undeletable.value = []
        history.retryRetention()
        #expect(history.entries.first { $0.id == entry.id }?.hasAudio == false)
        #expect(history.samples(entry.id) == nil)
        #expect(history.saveError == nil)
        #expect(history.delete(entry.id))
        #expect(!DictationHistory(directory: dir).entries.contains { $0.id == entry.id })
    }

    @Test func failedTextPruningKeepsRowUntilSuccessfulRetry() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let history = DictationHistory(directory: dir, audioLimit: 20, textLimit: 1, files: faults.files)
        let entry = history.add(samples: [0.1], kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
        history.update(entry.id, status: .done, text: "private result")
        faults.undeletable.value = [history.audioURL(entry.id)]
        let next = history.add(samples: [0.2], kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
        history.update(next.id, status: .done, text: "next result")
        #expect(history.entries.count == 2)
        #expect(history.samples(entry.id) == [0.1])
        #expect(history.saveError != nil)
        #expect(DictationHistory(directory: dir).entries.count == 2)
        faults.undeletable.value = []
        history.retryRetention()
        #expect(history.entries.map(\.id) == [next.id])
        #expect(history.samples(entry.id) == nil)
        #expect(history.saveError == nil)
    }

    @Test func oldIncorrectAudioFlagCannotHideFailedExplicitDeletion() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let history = DictationHistory(directory: dir, files: faults.files)
        let entry = history.addFile(dir.appending(path: "external.m4a"), duration: 1)
        try WAV.encode([0.1]).write(to: history.audioURL(entry.id))
        faults.undeletable.value = [history.audioURL(entry.id)]
        #expect(!history.delete(entry.id))
        #expect(history.entries.map(\.id) == [entry.id])
        #expect(history.saveError != nil)
        faults.undeletable.value = []
        #expect(history.delete(entry.id))
        #expect(history.entries.isEmpty)
        #expect(history.saveError == nil)
    }

    @Test func missingAudioCountsAsSuccessfulDeletion() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir)
        let entry = history.add(samples: [0.1], kind: .dictation).entry
        try FileManager.default.removeItem(at: history.audioURL(entry.id))
        #expect(history.delete(entry.id))
        #expect(history.entries.isEmpty)
        #expect(history.saveError == nil)
    }

    @Test func retrySaveOnlyRetriesPendingMetadataAndDoesNotHideDeletionError() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let faults = CorePersistenceFaults()
        let history = DictationHistory(directory: dir, files: faults.files)
        let entry = history.add(samples: [0.1], kind: .dictation).entry
        let writeCount = faults.writes.value
        history.retrySave()
        #expect(faults.writes.value == writeCount)
        faults.unwritable.value = [dir.appending(path: "history.json")]
        history.update(entry.id, status: .done, text: "unsaved result")
        faults.undeletable.value = [history.audioURL(entry.id)]
        #expect(!history.delete(entry.id))
        faults.unwritable.value = []
        history.retrySave()
        #expect(history.indexSaveError == nil)
        #expect(history.audioErrors[entry.id] != nil)
        #expect(history.saveError != nil)
        #expect(DictationHistory(directory: dir).entries.first?.text == "unsaved result")
    }

    @Test func pendingCommandSelectionSurvivesRestartAndDisablesRetry() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir)
        let pending = history.add(samples: [0.1], kind: .command(selection: nil), commandSelectionUnavailable: true).entry
        let reopened = DictationHistory(directory: dir)
        reopened.markInterrupted()
        #expect(reopened.entries.first?.commandSelectionUnavailable == true)
        #expect(reopened.entries.first?.canRetry == false)
        reopened.setSelection(pending.id, "verified selection")
        #expect(DictationHistory(directory: dir).entries.first?.commandSelectionUnavailable == false)
        #expect(reopened.entries.first?.kind == .command(selection: "verified selection"))
        #expect(reopened.entries.first?.canRetry == true)
    }

    @Test func verifiedEmptyAndLegacyCommandsRemainRetryable() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(directory: dir)
        let empty = history.add(samples: [0.1], kind: .command(selection: nil), commandSelectionUnavailable: true).entry
        history.setSelectionUnavailable(empty.id, false)
        let legacy = history.add(samples: [0.2], kind: .command(selection: nil)).entry
        let reloaded = DictationHistory(directory: dir)
        #expect(reloaded.entries.first { $0.id == empty.id }?.commandSelectionUnavailable == false)
        #expect(reloaded.entries.first { $0.id == legacy.id }?.commandSelectionUnavailable == nil)
        #expect(reloaded.entries.allSatisfy { $0.canRetry })
    }
}
