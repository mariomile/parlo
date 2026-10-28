struct AuditFailure: Error, CustomStringConvertible { let description: String }
func expect(_ value: Bool, _ message: String) throws { if !value { throw AuditFailure(description: message) } }
func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(await condition()) {
        if ContinuousClock.now > deadline { throw AuditFailure(description: "Timed out waiting for controlled work") }
        await Task.yield()
    }
}
func expectRetainedMeeting(_ meeting: Meeting?, from original: Meeting) throws {
    guard let meeting else { throw AuditFailure(description: "Retained meeting disappeared") }
    try expect(meeting.turns == original.turns && meeting.title == original.title && meeting.notes == original.notes
               && meeting.notesError == original.notesError, "Failed retry changed the retained transcript or notes")
    try expect(meeting.captureWarnings == original.captureWarnings, "Failed retry changed capture warnings")
    for warning in original.transcriptionWarnings ?? [] {
        try expect(meeting.transcriptionWarnings?.contains(warning) == true, "Retained transcript lost its coverage warning")
        try expect(meeting.markdown.contains(warning) && meeting.notesLines.contains { $0.contains(warning) },
                   "Retained coverage warning disappeared from Markdown or notes input")
    }
}
func expectInterruptedHistory(_ c: ControllerProbe, ids: Set<String>) throws {
    try expect(!c.history.entries.contains { $0.status == .processing }, "Refused quit left orphan processing rows after storage repair")
    for id in ids {
        guard let entry = c.history.entries.first(where: { $0.id == id }) else {
            throw AuditFailure(description: "Interrupted history entry disappeared")
        }
        try expect(entry.status == .failed("Interrupted"), "Revoked history work did not become interrupted")
        // The exact Retry visibility predicate in HistoryView, without running native UI.
        try expect(entry.canRetry && entry.status != .processing, "Retained audio has no visible Retry after storage repair")
    }
    let reloaded = DictationHistory(directory: c.history.directory)
    try expect(reloaded.entries == c.history.entries, "Interrupted history state was not durable after storage Retry")
    try expect(c.history.saveError == nil, "Repaired history still reports a storage failure")
}
func expectFailedMeetingRetry(_ meeting: Meeting?, from original: Meeting, newWarnings: Int) throws {
    try expectRetainedMeeting(meeting, from: original)
    guard let meeting, case .failed = meeting.status else {
        throw AuditFailure(description: "Wholly failed ASR retry was presented as completed")
    }
    // The exact MeetingsView Retry visibility predicate, without running native UI.
    try expect(meeting.hasAudio && meeting.status != .processing, "Failed meeting retry lost its Retry action")
    let warnings = meeting.transcriptionWarnings ?? []
    try expect(warnings.count == (original.transcriptionWarnings?.count ?? 0) + newWarnings,
               "Failed ASR retry lost or duplicated its new diagnostics")
    for text in original.turns.map(\.text) + [original.title, original.notes].compactMap({ $0 }) + meeting.warnings {
        try expect(meeting.markdown.contains(text), "Failed retry lost retained content or diagnostics in Markdown")
    }
}

@main struct NativeAuditRegressions {
    static func main() async throws {
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            Fixtures.resetDesktop()
            try await body()
            passed += 1
            print("PASS \(name)")
        }

        try await test("R01 unrelated meeting Copy never becomes command input or gets restored away") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            let meeting = try c.meetings.store.create()
            let latch = Latch()
            FocusedElement.holdSelection = { await latch.wait() }
            let read = Task { await SelectionReader.read(expectedPID: 10) }
            try await eventually { await latch.entered }
            c.meetings.copy(meeting)
            try await eventually { NSPasteboard.general.string(forType: .string) == meeting.markdown }
            await latch.release()
            try expect(await read.value.context == nil, "Unrelated Copy was accepted as selected text")
            try expect(NSPasteboard.general.string(forType: .string) == meeting.markdown, "Meeting Copy was overwritten")
        }
        try await test("R01 verified empty selection is distinct from unavailable; focus changes invalidate reads") {
            FocusedElement.selectionResult = Fixtures.selection("")
            let empty = await SelectionReader.read(expectedPID: 10)
            try expect(empty.context != nil && empty.text == nil, "Verified generation context was lost")
            let latch = Latch()
            FocusedElement.selectionResult = Fixtures.selection()
            FocusedElement.holdSelection = { await latch.wait() }
            let read = Task { await SelectionReader.read(expectedPID: 10) }
            try await eventually { await latch.entered }
            FrontmostApp.processID = 20
            await latch.release()
            try expect(await read.value.context == nil, "Selection from a changed app was trusted")
        }
        try await test("R10 expected app is checked after waiting for the clipboard turn") {
            let latch = Latch()
            let blocker = Task { await ClipboardTurn.take { await latch.wait() } }
            try await eventually { await latch.entered }
            let paste = Task { await TextInserter.insert("HISTORY_RESULT", expectedPID: 10) }
            FrontmostApp.processID = 20
            await latch.release(); await blocker.value
            guard case .targetChanged = await paste.value else { throw AuditFailure(description: "Expected safe copy fallback") }
            try expect(KeyPoster.posts.isEmpty, "Paste reached a different app")
            try expect(NSPasteboard.general.string(forType: .string) == "HISTORY_RESULT", "Fallback text missing")
        }
        try await test("R10 focus changes during AX reads and command selection changes prevent paste") {
            let latch = Latch()
            FocusedElement.holdFocus = { await latch.wait() }
            let paste = Task { await TextInserter.insert("RESULT", expectedPID: 10) }
            try await eventually { await latch.entered }
            FrontmostApp.processID = 20; FocusedElement.field = WatchedField(id: 2)
            await latch.release(); _ = await paste.value
            try expect(KeyPoster.posts.isEmpty, "Stale AX focus permitted a key event")
            Fixtures.resetDesktop()
            let selection = Fixtures.selection().context!
            FocusedElement.selected = "A DIFFERENT SELECTION"
            guard case .targetChanged = await TextInserter.insert("COMMAND_RESULT", selection: selection) else {
                throw AuditFailure(description: "Changed command selection should copy instead")
            }
            try expect(KeyPoster.posts.isEmpty, "Command replaced a new selection")
        }
        try await test("Runtime paste: bystander read cannot confirm insertion or restore old clipboard") {
            var lateRead: String?
            var late: Task<Void, Never>?
            KeyPoster.onPaste = {
                _ = NSPasteboard.general.string(forType: .string)
                late = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    lateRead = NSPasteboard.general.string(forType: .string)
                }
            }
            guard case .leftOnClipboard = await TextInserter.insert("DICTATED_TEXT") else {
                throw AuditFailure(description: "Unverified read was treated as inserted")
            }
            await late?.value
            try expect(lateRead == "DICTATED_TEXT", "Late target read the old clipboard")
        }
        try await test("Runtime paste: verified exact field insertion permits clipboard restoration") {
            FocusedElement.values[1] = "Hello "
            FocusedElement.ranges[1] = CFRange(location: 6, length: 0)
            KeyPoster.onPaste = { FocusedElement.values[1] = "Hello world" }
            guard case .pasted = await TextInserter.insert("world") else { throw AuditFailure(description: "Exact insertion not recognized") }
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Verified insertion failed to restore clipboard")
        }
        try await test("Paste feedback: unavailable field readback quietly dismisses the HUD and keeps recovery text") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            await c.deliver("DICTATED_TEXT", warning: nil, if: { true })
            try expect(KeyPoster.posts.count == 1, "Expected exactly one paste request")
            try expect(c.messages == [nil], "Unverified insertion showed a routine warning or claimed verified success")
            try expect(NSPasteboard.general.string(forType: .string) == "DICTATED_TEXT", "Unverified paste lost its recovery text")
        }
        try await test("Paste feedback: unavailable readback does not mask an AI cleanup warning") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            let warning = "AI cleanup wasn't used: Request timed out"
            await c.deliver("RAW_TRANSCRIPT", warning: warning, if: { true })
            try expect(c.messages == [.message(warning, isError: true)], "Unverified paste masked an actionable cleanup warning")
            try expect(NSPasteboard.general.string(forType: .string) == "RAW_TRANSCRIPT", "Raw transcript is unavailable for recovery")
        }
        try await test("Paste feedback: verified insertion still confirms completion") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            FocusedElement.values[1] = "Hello "
            FocusedElement.ranges[1] = CFRange(location: 6, length: 0)
            KeyPoster.onPaste = { FocusedElement.values[1] = "Hello world" }
            await c.deliver("world", warning: nil, if: { true })
            try expect(c.messages == [.done], "Verified insertion lost its completion feedback")
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Verified insertion failed to restore clipboard")
        }
        try await test("Recording start wakes the target app's accessibility so its text field is found at paste time") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            FrontmostApp.processID = 42
            try c.session.start(command: false, deviceUID: nil, preview: nil)
            try await eventually { FocusedElement.woken == [42] }
        }
        try await test("Paste feedback: missing target and changed target still explain manual recovery") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            FocusedElement.focus = .nothing
            await c.deliver("RESULT", warning: nil, if: { true })
            try expect(c.messages == [.message("No text field to paste into. \(ControllerProbe.copiedHint)", isError: false)], "Missing target was silenced")
            Fixtures.resetDesktop(); c.messages = []
            await c.deliver("RESULT", warning: nil, expectedPID: 20, if: { true })
            try expect(c.messages == [.message("The target changed. \(ControllerProbe.copiedHint)", isError: false)], "Changed target was silenced")
            try expect(KeyPoster.posts.isEmpty, "Changed target received a paste")
        }
        try await test("Paste feedback: overwritten clipboard still warns about recovery in Recent") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            KeyPoster.onPaste = {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("OTHER_COPY", forType: .string)
            }
            await c.deliver("RESULT", warning: nil, if: { true })
            try expect(c.messages == [.message("Insertion couldn't be verified. The text is in Recent, in the menu bar.", isError: true)], "Lost clipboard recovery was silenced")
            try expect(NSPasteboard.general.string(forType: .string) == "OTHER_COPY", "Concurrent clipboard content was overwritten")
        }
        try await test("R09 queued Retry deletion prevents ASR and obsolete recovery messages") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let engine = HeldTranscriber(), c = Fixtures.controller(in: dir, transcriber: engine)
            c.gate.enqueue({ t in _ = try await t.transcribe(Fixtures.audio, languageCode: nil, dictionary: []) }, onError: { _ in })
            try await eventually { await engine.calls == 1 }
            let entry = c.history.add(samples: Fixtures.audio, kind: .dictation).entry
            c.retry(entry); c.delete(entry)
            let messageCount = c.messages.count
            await engine.release("FIRST_JOB")
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(await engine.calls == 1, "Deleted queued job invoked ASR")
            try expect(c.history.entries.isEmpty && KeyPoster.posts.isEmpty && c.messages.count == messageCount, "Deleted job had visible effects")
        }
        try await test("R09 held noncooperative ASR deletion blocks cleanup and all delivery") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let engine = HeldTranscriber(), chat = ChatSpy(), c = Fixtures.controller(in: dir, transcriber: engine, llm: chat)
            let entry = c.history.add(samples: Fixtures.audio, kind: .dictation).entry
            c.retry(entry)
            try await eventually { await engine.calls == 1 }
            c.delete(entry); let messages = c.messages.count
            await engine.release("DELETED_JOB_RESULT")
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(await chat.calls == 0, "Deleted job sent new cleanup request")
            try expect(c.messages.count == messages && KeyPoster.posts.isEmpty, "Deleted job reported recovery or pasted")
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Deleted job copied")
        }
        try await test("R09 deleting during held cleanup discards late reply") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let chat = ChatSpy(); await chat.setHeld()
            let c = Fixtures.controller(in: dir, llm: chat)
            let entry = c.history.add(samples: Fixtures.audio, kind: .dictation).entry
            c.retry(entry); try await eventually { await chat.calls == 1 }
            c.delete(entry); let messages = c.messages.count
            await chat.release("DELETED_JOB_RESULT")
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(c.history.entries.isEmpty && c.messages.count == messages, "Late cleanup completion escaped revocation")
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Late cleanup copied deleted result")
        }
        try await test("R09 deletion revokes an already queued clipboard delivery") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir), latch = Latch()
            let blocker = Task { await ClipboardTurn.take { await latch.wait() } }
            try await eventually { await latch.entered }
            let entry = c.history.add(samples: Fixtures.audio, kind: .dictation).entry
            c.retry(entry)
            try await eventually { c.history.entries.first?.text == "NEW_RESULT" }
            c.delete(entry); let messages = c.messages.count
            await latch.release(); await blocker.value
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Queued copy outlived deletion")
            try expect(c.messages.count == messages, "Cancelled copy showed a success message")
        }
        try await test("R09 active and queued file import deletion prevents ASR and cleanup") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let engine = HeldTranscriber(), chat = ChatSpy(), c = Fixtures.controller(in: dir, transcriber: engine, llm: chat)
            let latch = Latch(); AudioFileDecoder.hold = { await latch.wait() }
            c.transcribeFile(dir.appending(path: "one.wav"))
            try await eventually { await latch.entered }
            c.transcribeFile(dir.appending(path: "two.wav"))
            for entry in c.history.entries { c.delete(entry) }
            let messages = c.messages.count
            await latch.release(); await c.fileQueue?.value
            let engineCalls = await engine.calls, chatCalls = await chat.calls
            try expect(engineCalls == 0 && chatCalls == 0, "Deleted file import invoked a model")
            try expect(AudioFileDecoder.reads == 1 && c.fileProgress.isEmpty && c.messages.count == messages, "Queued file import had side effects")
        }
        try await test("R09 failed audio deletion still revokes work and remains retryable") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(), engine = HeldTranscriber()
            let files = PersistenceIO(remove: { url in
                if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
            let c = Fixtures.controller(in: dir, transcriber: engine, files: files)
            let entry = c.history.add(samples: Fixtures.audio, kind: .dictation).entry
            c.retry(entry); try await eventually { await engine.calls == 1 }
            failure.set(true); c.delete(entry)
            try expect(c.history.entries.first?.status == .failed("Cancelled") && c.history.saveError != nil, "Failed removal hid state")
            await engine.release("DELETED_RESULT"); try await eventually { c.gate.pendingJobs == 0 }
            try expect(NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Failed removal left delivery alive")
            failure.set(false); c.delete(entry)
            try expect(c.history.entries.isEmpty, "Removal could not be retried")
        }
        try await test("R04/R09 oldest Retry survives newer completion while clipboard delivery waits") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir, textLimit: 1), latch = Latch()
            let old = c.history.add(samples: Fixtures.audio, kind: .dictation, date: Date(timeIntervalSince1970: 1)).entry
            let newer = c.history.add(samples: Fixtures.audio, kind: .dictation, date: Date(timeIntervalSince1970: 2)).entry
            let blocker = Task { await ClipboardTurn.take { await latch.wait() } }
            try await eventually { await latch.entered }
            c.retry(old)
            try await eventually { c.history.entries.first(where: { $0.id == old.id })?.text == "NEW_RESULT" }
            c.history.update(newer.id, status: .done, text: "NEWER_RESULT")
            try expect(c.history.entries.first(where: { $0.id == old.id })?.status == .processing, "Pending delivery lost retention protection")
            await latch.release(); await blocker.value
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(NSPasteboard.general.string(forType: .string) == "NEW_RESULT", "Oldest retry was not delivered")
            let completed = c.history.entries.first { $0.id == old.id }
            try expect(completed?.status == .done && completed?.text == "NEW_RESULT", "Fresh completion was immediately pruned")
        }
        try await test("R11 resolved command selection is on disk at synchronous save return") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir)
            let capture = CommandSelectionCapture { Fixtures.selection() }
            _ = await capture.value()
            let recording = RecordingSession.Recording(command: true, bundleID: nil, selection: capture, startedAt: .now)
            c.save(.init(recording: recording, samples: Fixtures.audio, usedFallback: false), transcribe: false)
            let persisted = DictationHistory(directory: c.history.directory).entries.first!
            try expect(persisted.kind == .command(selection: "ORIGINAL_SELECTION") && persisted.commandSelectionUnavailable == false,
                       "Synchronous termination lost resolved command context")
        }
        try await test("R11 pending selection defers termination and is never decoded as verified absence") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let c = Fixtures.controller(in: dir), latch = Latch()
            FocusedElement.selectionResult = Fixtures.selection()
            FocusedElement.holdSelection = { await latch.wait() }
            try c.session.start(command: true, deviceUID: nil, preview: nil)
            try await eventually { await latch.entered }
            let flush = c.prepareForTermination()
            try expect(flush != nil && c.isTerminating, "Pending selection did not defer termination")
            let pending = DictationHistory(directory: c.history.directory).entries.first!
            try expect(pending.commandSelectionUnavailable == true && !pending.canRetry, "Pending read was persisted as empty selection")
            await latch.release(); await flush?.value
            try expect(c.terminationSaveSucceeded(), "Resolved context did not flush")
            let reloaded = DictationHistory(directory: c.history.directory).entries.first!
            try expect(reloaded.kind == .command(selection: "ORIGINAL_SELECTION") && reloaded.commandSelectionUnavailable == false, "Flush lost selection")
        }
        try await test("R01/R11 unavailable command context never silently becomes generation") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let engine = HeldTranscriber(), chat = ChatSpy(), c = Fixtures.controller(in: dir, transcriber: engine, llm: chat)
            let capture = CommandSelectionCapture { .unavailable }; _ = await capture.value()
            let recording = RecordingSession.Recording(command: true, bundleID: nil, selection: capture, startedAt: .now)
            c.save(.init(recording: recording, samples: Fixtures.audio, usedFallback: false))
            try await eventually { c.gate.pendingJobs == 0 }
            let entry = c.history.entries.first!
            c.retry(entry)
            let engineCalls = await engine.calls, chatCalls = await chat.calls
            try expect(engineCalls == 0 && chatCalls == 0, "Unverified input invoked a model")
            try expect(entry.commandSelectionUnavailable == true && !entry.canRetry, "Unavailable input became retryable generation")
        }
        try await test("R11 audio write failure cancels quit, retains samples, and retries after repair") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(); failure.set(true)
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.pathExtension == "wav" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            let c = Fixtures.controller(in: dir, files: files)
            try c.session.start(command: false, deviceUID: nil, preview: nil)
            _ = c.prepareForTermination()
            try expect(!c.terminationSaveSucceeded() && c.unsavedTerminationRecordings.count == 1, "Failed WAV save allowed quit")
            failure.set(false); _ = c.prepareForTermination()
            try expect(c.terminationSaveSucceeded(), "Repaired WAV save could not retry")
            let reloaded = DictationHistory(directory: c.history.directory)
            try expect(reloaded.entries.count == 1 && reloaded.samples(reloaded.entries[0].id) == Fixtures.audio, "Retry lost or duplicated recording")
        }
        try await test("R11 metadata write failure blocks quit until selection is durable") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(); failure.set(true)
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let c = Fixtures.controller(in: dir, files: files)
            let capture = CommandSelectionCapture { Fixtures.selection() }; _ = await capture.value()
            c.save(.init(recording: .init(command: true, bundleID: nil, selection: capture, startedAt: .now),
                         samples: Fixtures.audio, usedFallback: false), transcribe: false)
            try expect(!c.terminationSaveSucceeded(), "Unsaved selection permitted quit")
            failure.set(false)
            try expect(c.terminationSaveSucceeded(), "Metadata retry failed after repair")
            try expect(DictationHistory(directory: c.history.directory).entries.first?.kind == .command(selection: "ORIGINAL_SELECTION"), "Retry failed to persist selection")
        }
        try await test("CN1 refused quit and storage Retry recover held ASR, queued command and active recording") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(), engine = HeldTranscriber(), selection = Latch()
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let c = Fixtures.controller(in: dir, transcriber: engine, files: files)
            let completed = c.history.add(samples: Fixtures.audio, kind: .dictation, status: .done).entry
            c.history.update(completed.id, status: .done, text: "KEEP_COMPLETED_TEXT")
            let active = c.history.add(samples: Fixtures.audio, kind: .dictation, status: .failed("Earlier failure")).entry
            c.retry(active); try await eventually { await engine.calls == 1 }
            let capture = CommandSelectionCapture { await selection.wait(); return Fixtures.selection() }
            c.save(.init(recording: .init(command: true, bundleID: nil, selection: capture, startedAt: .now),
                         samples: Fixtures.audio, usedFallback: false))
            try await eventually { await selection.entered }
            let queued = c.history.entries.first { $0.isCommand }!
            try expect(queued.commandSelectionUnavailable == true && !queued.canRetry, "Pending selection was treated as verified")
            let revoked = Array(c.historyWork.values)
            try expect(revoked.count == 2, "Fixture did not queue the command behind held ASR")
            try c.session.start(command: false, deviceUID: nil, preview: nil)
            failure.set(true)
            let flush = c.prepareForTermination()
            try expect(flush != nil && c.session.current == nil, "Quit did not stop recording and await pending command selection")
            try expect(c.historyWork.isEmpty && revoked.allSatisfy { !$0.lifetime.isCurrent }, "Quit left old work authorized")
            await selection.release(); await flush?.value
            try expect(!c.terminationSaveSucceeded() && !c.isTerminating, "Metadata failure did not refuse quit")
            let messages = c.messages.count
            await engine.release("OBSOLETE_ASR_RESULT")
            for work in revoked { await work.task?.value }
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(await engine.calls == 1, "Revoked queued command reached ASR")
            try expect(c.messages.count == messages && KeyPoster.posts.isEmpty
                       && NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Cancelled quit-time work delivered a late result")
            failure.set(false); c.retryHistoryStorage()
            let interruptedIDs = Set(c.history.entries.filter { $0.id != completed.id }.map(\.id))
            try expect(interruptedIDs.count == 3, "Quit failed to retain all three unfinished recordings")
            try expectInterruptedHistory(c, ids: interruptedIDs)
            let retainedCommand = c.history.entries.first { $0.id == queued.id }!
            try expect(retainedCommand.kind == .command(selection: "ORIGINAL_SELECTION")
                       && retainedCommand.commandSelectionUnavailable == false, "Revocation cancelled unfinished command context persistence")
            try expect(c.history.entries.first { $0.id == completed.id }?.text == "KEEP_COMPLETED_TEXT"
                       && c.history.entries.first { $0.id == completed.id }?.status == .done, "Quit changed an already completed entry")
            c.retry(active); try await eventually { await engine.calls == 2 }
            await engine.release("RECOVERED_RETRY_RESULT")
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(c.history.entries.first { $0.id == active.id }?.status == .done
                       && NSPasteboard.general.string(forType: .string) == "RECOVERED_RETRY_RESULT", "Retry could not complete without restarting the app")
        }
        try await test("CN1 refused quit and storage Retry recover active and queued file imports") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(), decoder = Latch()
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let c = Fixtures.controller(in: dir, files: files)
            let firstURL = dir.appending(path: "one.wav"), secondURL = dir.appending(path: "two.wav")
            for url in [firstURL, secondURL] { try Data("FAKE_SOURCE_AUDIO".utf8).write(to: url) }
            AudioFileDecoder.hold = { await decoder.wait() }
            c.transcribeFile(firstURL); try await eventually { await decoder.entered }
            let active = c.history.entries.first!
            c.transcribeFile(secondURL)
            let revoked = Array(c.historyWork.values)
            try c.session.start(command: false, deviceUID: nil, preview: nil)
            failure.set(true); await c.prepareForTermination()?.value
            try expect(!c.terminationSaveSucceeded(), "Quit ignored a failed history write")
            let messages = c.messages.count
            await decoder.release()
            for work in revoked { await work.task?.value }
            try expect(AudioFileDecoder.reads == 1 && c.fileProgress.isEmpty && c.historyWork.isEmpty,
                       "Revoked active/queued file work continued")
            try expect(c.messages.count == messages && KeyPoster.posts.isEmpty
                       && NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD", "Revoked file import delivered a result")
            failure.set(false); c.retryHistoryStorage()
            try expect(c.history.entries.count == 3, "Quit lost a file import or active recording")
            try expectInterruptedHistory(c, ids: Set(c.history.entries.map(\.id)))
            AudioFileDecoder.hold = nil
            c.retry(active); await c.fileQueue?.value
            try expect(c.history.entries.first { $0.id == active.id }?.status == .done, "File retry required an app restart")
        }
        try await test("R15 nil-key provider changes reject stale Save/Test before UI onChange") {
            let p = SettingsProbe()
            p.controller.settings.llm = .init(enabled: true, provider: .openAICompatible, baseURL: "https://a.invalid/v1", model: "fake")
            p.resetKeyDraft(); p.keyDraft.text = "FAKE_KEY_A"
            p.controller.settings.llm.baseURL = "https://b.invalid/v1"
            p.test()
            try expect(p.testTask == nil, "Stale Test was scheduled")
            p.controller.settings.llm.baseURL = "https://a.invalid/v1"
            p.resetKeyDraft(); p.keyDraft.text = "FAKE_KEY_A"
            p.controller.settings.llm.baseURL = "https://b.invalid/v1"
            p.saveKey()
            await p.testTask?.value
            try expect(p.controller.saved.isEmpty, "A's draft was saved for B")
            let sent = await EndpointSpy.shared.sent
            try expect(!sent.contains { $0.0.contains("b.invalid") && $0.1 == "FAKE_KEY_A" }, "A's draft was sent to B")
            try expect(p.keyDraft.text.isEmpty && p.keyDraft.matches(p.llm), "Draft was not rebound/reset")
            p.keyDraft.text = "FAKE_KEY_B"; p.saveKey()
            try expect(p.controller.saved.last?.0 == "FAKE_KEY_B", "Current endpoint could not save its own draft")
        }
        try await test("R15 queued connection test snapshots endpoint and ignores later provider change") {
            let p = SettingsProbe(), before = await EndpointSpy.shared.sent.count
            p.controller.settings.llm = .init(enabled: true, provider: .openAICompatible, baseURL: "https://a.invalid/v1", model: "fake")
            p.resetKeyDraft(); p.keyDraft.text = "FAKE_KEY_A"; p.test()
            p.controller.settings.llm.baseURL = "https://b.invalid/v1"
            await p.testTask?.value
            try expect(await EndpointSpy.shared.sent.count == before, "Stale test still made a request")
            try expect(p.testResult == nil, "Stale test changed the new provider result")
        }
        try await test("R20/R25 storage removal waits for owner and preserves failed cleanup without direct fallback") {
            ModelStorage.deleted = []
            let p = StorageDeleteProbe(), latch = Latch()
            p.models.latch = latch
            p.delete(.init(kind: .model(.parakeetV3)))
            try await eventually { await latch.entered }
            try expect(p.scans == 0 && ModelStorage.deleted.isEmpty, "Direct removal bypassed active model owner")
            await latch.release(); try await eventually { p.scans == 1 }
            try expect(p.models.deletions == 1 && ModelStorage.deleted.isEmpty, "Speech model owner wasn't used")
            p.cleanupModel.failure = true
            p.delete(.init(kind: .cleanupModel)); try await eventually { p.scans == 2 }
            try expect(p.cleanupModel.deletions == 1 && p.deleteError != nil && ModelStorage.deleted.isEmpty,
                       "Failed cleanup was hidden or bypassed by direct deletion")
            p.cleanupModel.failure = false
            p.delete(.init(kind: .cleanupModel)); try await eventually { p.scans == 3 }
            try expect(p.cleanupModel.deletions == 2 && p.deleteError == nil, "Cleanup was not retryable")
        }
        try await test("R12 capture/write warnings survive success, reload, export and notes input") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingStore(directory: dir), gate = TranscriberGate(transcriber: { FixedTranscriber(text: "Useful speech") }, reload: {})
            var notesInput: [String] = []
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { lines, _ in
                    notesInput = lines
                    return .init(title: "Notes", notes: "Useful notes")
                }, notesProblem: nil)
            }, report: { _, _ in })
            c.start(deviceUID: nil)
            let id = c.recordingID!, recorder = MeetingRecorder.latest!
            recorder.onSystemAudioLost("fixture lost device")
            recorder.writeError = CocoaError(.fileWriteOutOfSpace)
            c.stop()
            try await eventually { store.meeting(id)?.status == .done }
            let reloaded = MeetingStore(directory: dir).meeting(id)!
            try expect(reloaded.captureWarnings?.count == 2 && !reloaded.othersSilent, "Known partial loss was cleared")
            try expect(reloaded.markdown.contains("fixture lost device") && notesInput.contains(where: { $0.contains("fixture lost device") }), "Warning missing from export or model input")
            try expect(c.problem != nil, "Completed partial meeting was presented as complete")
        }
        try await test("R12 delayed capture callback stays on original meeting after a new recording starts") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingStore(directory: dir), gate = TranscriberGate(transcriber: { FixedTranscriber(text: "Speech") }, reload: {})
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
            }, report: { _, _ in })
            c.start(deviceUID: nil); let old = c.recordingID!, oldRecorder = MeetingRecorder.latest!; c.stop()
            try await eventually { store.meeting(old)?.status == .done }
            c.start(deviceUID: nil); let newer = c.recordingID!
            oldRecorder.onSystemAudioLost("late old-track failure")
            try expect(store.meeting(old)?.captureWarnings?.first?.contains("late old-track failure") == true, "Old warning was lost")
            try expect(store.meeting(newer)?.captureWarnings == nil && c.problem == nil, "Old callback contaminated new meeting")
            c.terminate()
        }
        try await test("R13 native processing persists partial ASR warnings and sends them to notes") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let engine = PartialTranscriber(), store = MeetingStore(directory: dir)
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesInput: [String] = []
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { lines, _ in
                    notesInput = lines
                    return .init(title: "Partial", notes: "Notes disclose missing speech")
                }, notesProblem: nil)
            }, report: { _, _ in })
            c.start(deviceUID: nil); let id = c.recordingID!; c.stop()
            try await eventually { store.meeting(id)?.status == .done }
            let reloaded = MeetingStore(directory: dir).meeting(id)!
            try expect(reloaded.turns.count == 1 && reloaded.transcriptionWarnings?.count == 1, "Partial ASR loss wasn't persisted")
            try expect(notesInput.contains { $0.contains("Transcription missing") }, "Notes missed the coverage warning")
            try expect(reloaded.markdown.contains("Transcription missing"), "Export dropped ASR warning")
        }
        try await test("CN2 failed segmenter load preserves reloaded partial transcript warnings and Markdown") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), engine = HeldTranscriber()
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesCalls = 0
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { _, _ in
                    notesCalls += 1
                    return .init(title: "Unexpected replacement", notes: "Unexpected notes")
                }, notesProblem: nil)
            }, report: { _, _ in })
            SileroSpeechDetector.loadFailure = true
            c.process(original.id)
            try await eventually { if case .failed = store.meeting(original.id)?.status { true } else { false } }
            try expect(AudioFileDecoder.reads == 2 && SileroSpeechDetector.loadCalls == 1, "Fixture did not fail after both successful track reads")
            try expect(await engine.calls == 0 && notesCalls == 0, "Early failed retry reached ASR or notes")
            try expectRetainedMeeting(store.meeting(original.id), from: original)
            try expectRetainedMeeting(MeetingStore(directory: dir).meeting(original.id), from: original)
        }
        try await test("CN2 early read warnings accumulate without erasing or duplicating retained coverage") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), gate = TranscriberGate(transcriber: { FixedTranscriber(text: "Unused") }, reload: {})
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
            }, report: { _, _ in })
            SileroSpeechDetector.loadFailure = true
            AudioFileDecoder.unreadableTracks = ["them.caf"]
            for _ in 0..<2 {
                c.process(original.id)
                try await eventually { if case .failed = store.meeting(original.id)?.status { true } else { false } }
                try expectRetainedMeeting(store.meeting(original.id), from: original)
                let reloaded = MeetingStore(directory: dir).meeting(original.id)!
                try expectRetainedMeeting(reloaded, from: original)
                try expect(reloaded.transcriptionWarnings?.count == 2, "Retry erased old coverage or duplicated the track-read warning")
                try expect(reloaded.markdown.contains("Them: The recording track couldn't be read"), "New read failure was not persisted/exported")
            }
        }
        try await test("CN2 cancelled retry with failed deletion preserves old warnings through late completion") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let failure = FailureSwitch(), loader = Latch(), engine = HeldTranscriber()
            let files = PersistenceIO(remove: { url in
                if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
            let store = MeetingStore(directory: dir, files: files), gate = TranscriberGate(transcriber: { engine }, reload: {})
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
            }, report: { _, _ in })
            SileroSpeechDetector.holdLoad = { await loader.wait() }
            c.process(original.id); try await eventually { await loader.entered }
            failure.set(true); c.delete(original.id)
            guard case .failed = store.meeting(original.id)?.status else { throw AuditFailure(description: "Failed deletion left no retryable meeting") }
            try expect(store.meeting(original.id)?.hasAudio == true && store.error(for: original.id) != nil, "Failed deletion lost recovery state")
            try expectRetainedMeeting(store.meeting(original.id), from: original)
            try expectRetainedMeeting(MeetingStore(directory: dir).meeting(original.id), from: original)
            // The next attempt waits for the cancelled one, proving that its late completion drained.
            SileroSpeechDetector.holdLoad = nil; SileroSpeechDetector.loadFailure = true
            c.process(original.id); await loader.release()
            try await eventually { if case .failed = store.meeting(original.id)?.status { true } else { false } }
            try expect(SileroSpeechDetector.loadCalls == 2 && c.progress[original.id] == nil, "Cancelled processing did not drain before retry")
            try expect(await engine.calls == 0, "Cancelled attempt reached ASR")
            try expectRetainedMeeting(store.meeting(original.id), from: original)
            try expectRetainedMeeting(MeetingStore(directory: dir).meeting(original.id), from: original)
        }
        try await test("CN2 replacement turns replace obsolete warnings together, including a later complete retry") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), engine = PartialTranscriber(), loader = Latch()
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesInput: [String] = []
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { lines, _ in
                    notesInput = lines
                    return .init(title: "Replacement meeting", notes: "Replacement notes")
                }, notesProblem: nil)
            }, report: { _, _ in })
            SileroSpeechDetector.holdLoad = { await loader.wait() }
            c.process(original.id); try await eventually { await loader.entered }
            try expectRetainedMeeting(store.meeting(original.id), from: original)
            try expectRetainedMeeting(MeetingStore(directory: dir).meeting(original.id), from: original)
            await loader.release()
            try await eventually { store.meeting(original.id)?.status == .done }
            let partial = MeetingStore(directory: dir).meeting(original.id)!
            let oldWarning = original.transcriptionWarnings!.first!
            try expect(partial.turns != original.turns && partial.turns.count == 1 && partial.transcriptionWarnings?.count == 1,
                       "Replacement partial transcript did not publish its own coverage")
            try expect(partial.notes == "Replacement notes" && partial.title == "Replacement meeting", "New turns retained obsolete notes")
            try expect(partial.captureWarnings == original.captureWarnings && !partial.markdown.contains(oldWarning), "Replacement retained obsolete ASR warning or erased capture warning")
            let newWarning = partial.transcriptionWarnings!.first!
            try expect(partial.markdown.contains(newWarning) && notesInput.contains { $0.contains(newWarning) }
                       && !notesInput.contains { $0.contains(oldWarning) }, "Replacement notes/export used obsolete coverage")
            c.process(original.id); try await eventually { store.meeting(original.id)?.status == .done }
            let complete = MeetingStore(directory: dir).meeting(original.id)!
            try expect(complete.transcriptionWarnings == nil && complete.turns.count == 2, "Complete retry retained obsolete partial warnings")
            try expect(!complete.markdown.contains(newWarning) && !notesInput.contains { $0.contains(newWarning) }
                       && complete.captureWarnings == original.captureWarnings, "Complete replacement did not update coverage consistently")
        }
        try await test("R07 integration preserves usable peer track and fails visibly when neither can be read") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingStore(directory: dir), gate = TranscriberGate(transcriber: { FixedTranscriber(text: "Surviving speech") }, reload: {})
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
            }, report: { _, _ in })
            AudioFileDecoder.unreadableTracks = ["them.caf"]
            c.start(deviceUID: nil); let id = c.recordingID!; c.stop()
            try await eventually { store.meeting(id)?.status == .done }
            try expect(store.meeting(id)?.turns.first?.text == "Surviving speech", "Peer failure discarded surviving audio")
            try expect(store.meeting(id)?.transcriptionWarnings?.first?.contains("Them") == true, "Missing side was hidden")
            AudioFileDecoder.unreadableTracks = ["me.caf", "them.caf"]
            c.start(deviceUID: nil); let empty = c.recordingID!; c.stop()
            try await eventually {
                if case .failed = store.meeting(empty)?.status { true } else { false }
            }
            try expect(store.meeting(empty)?.transcriptionWarnings?.count == 2 && c.problem?.contains("No usable") == true,
                       "No usable tracks was presented as ordinary completion")
        }
        try await test("R06 integration failed meeting delete exits processing and permits retry") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(), latch = Latch()
            let files = PersistenceIO(remove: { url in
                if failure.enabled { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
            let store = MeetingStore(directory: dir, files: files)
            let gate = TranscriberGate(transcriber: { FixedTranscriber(text: "Speech") }, reload: {})
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
            }, report: { _, _ in })
            AudioFileDecoder.hold = { await latch.wait() }
            c.start(deviceUID: nil); let id = c.recordingID!; c.stop()
            try await eventually { await latch.entered }
            failure.set(true); c.delete(id)
            guard case .failed = store.meeting(id)?.status else { throw AuditFailure(description: "Failed delete stranded processing row") }
            try expect(c.problem?.contains("Delete to retry") == true && c.progress[id] == nil, "Delete failure was not actionable")
            await latch.release()
            failure.set(false); c.delete(id)
            try expect(store.meeting(id) == nil, "Deletion retry failed")
        }
        try await test("CN4 all ASR failures preserve reloaded partial content and retryability in memory, JSON and Markdown") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), engine = FailingTranscriber()
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesCalls = 0, reports: [(String, Bool)] = []
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { _, _ in
                    notesCalls += 1
                    return .init(title: "Unexpected replacement", notes: "Unexpected notes")
                }, notesProblem: "New attempt has no available notes model")
            }, report: { reports.append(($0, $1)) })
            for attempt in 1...2 {
                c.process(original.id)
                try await eventually { store.meeting(original.id)?.status != .processing }
                try expect(await engine.calls == attempt * 2 && AudioFileDecoder.reads == attempt * 2,
                           "Fixture did not fail ASR on both successfully decoded nonempty tracks")
                try expect(notesCalls == 0 && reports.last?.1 == true && c.problem != nil,
                           "Failed transcription invoked notes or reported ordinary completion")
                let memory = store.meeting(original.id)!
                let metadata = dir.appending(path: original.id).appending(path: "meeting.json")
                let json = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: metadata))
                let reloaded = MeetingStore(directory: dir).meeting(original.id)
                for meeting in [memory, json, reloaded] {
                    try expectFailedMeetingRetry(meeting, from: original, newWarnings: 2)
                    let warnings = meeting?.transcriptionWarnings ?? []
                    try expect(warnings.contains { $0.hasPrefix("Me [0:00–0:01]: Transcription missing") }
                               && warnings.contains { $0.hasPrefix("Them [0:00–0:01]: Transcription missing") },
                               "Failed retry omitted a track's missing-interval diagnostic")
                }
                try expect(json == memory && reloaded == memory && store.saveErrors.isEmpty,
                           "Failed retry was not persisted consistently")
            }
        }
        try await test("CN4 one failed track and a silent peer preserve the prior meeting for either speaker") {
            for silentTrack in ["me.caf", "them.caf"] {
                let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
                let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
                let store = MeetingStore(directory: dir), engine = FailingTranscriber()
                let gate = TranscriberGate(transcriber: { engine }, reload: {})
                let c = MeetingController(gate: gate, store: store, context: {
                    .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
                }, report: { _, _ in })
                AudioFileDecoder.trackSamples = [silentTrack: [Float](repeating: 0, count: Audio.sampleRate)]
                c.process(original.id)
                try await eventually { store.meeting(original.id)?.status != .processing }
                try expect(await engine.calls == 1, "Silent peer incorrectly reached ASR")
                try expectFailedMeetingRetry(store.meeting(original.id), from: original, newWarnings: 1)
                try expectFailedMeetingRetry(MeetingStore(directory: dir).meeting(original.id), from: original, newWarnings: 1)
            }
        }
        try await test("CN4 successful peer replaces a stored partial meeting while retaining the failed track's diagnostics") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), engine = PartialTranscriber()
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesInput: [String] = []
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { lines, _ in
                    notesInput = lines
                    return .init(title: "Recovered partial meeting", notes: "Notes for the surviving speech")
                }, notesProblem: nil)
            }, report: { _, _ in })
            c.process(original.id)
            try await eventually { store.meeting(original.id)?.status != .processing }
            try expect(await engine.calls == 2, "Fixture did not attempt both tracks")
            for meeting in [store.meeting(original.id)!, MeetingStore(directory: dir).meeting(original.id)!] {
                try expect(meeting.status == .done && meeting.turns.count == 1
                           && meeting.turns.first?.text == "A surviving statement" && meeting.turns.first?.speaker == .me,
                           "One successful track did not publish a usable replacement")
                try expect(meeting.title == "Recovered partial meeting" && meeting.notes == "Notes for the surviving speech"
                           && meeting.notesError == nil && meeting.captureWarnings == original.captureWarnings,
                           "Partial replacement kept obsolete notes or lost capture warnings")
                let warnings = meeting.transcriptionWarnings ?? []
                try expect(warnings.count == 1 && warnings[0].hasPrefix("Them [0:00–0:01]: Transcription missing"),
                           "Partial replacement did not publish its own missing interval")
                try expect(meeting.markdown.contains(warnings[0]) && notesInput.contains { $0.contains(warnings[0]) },
                           "Current partial coverage was absent from notes or Markdown")
                for old in original.turns.map(\.text) + (original.transcriptionWarnings ?? []) {
                    try expect(!meeting.markdown.contains(old) && !notesInput.contains { $0.contains(old) },
                               "Partial replacement mixed old content with new coverage")
                }
            }
        }
        try await test("CN4 genuine no-speech input completes without ASR failures or obsolete content") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let original = try Fixtures.partialMeeting(in: MeetingStore(directory: dir))
            let store = MeetingStore(directory: dir), engine = FailingTranscriber()
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            var notesCalls = 0
            let c = MeetingController(gate: gate, store: store, context: {
                .init(languageCode: nil, dictionary: [], writeNotes: { _, _ in
                    notesCalls += 1
                    return .init(title: "Unexpected notes", notes: "Unexpected notes")
                }, notesProblem: nil)
            }, report: { _, _ in })
            let silence = [Float](repeating: 0, count: Audio.sampleRate)
            AudioFileDecoder.trackSamples = ["me.caf": silence, "them.caf": silence]
            c.process(original.id)
            try await eventually { store.meeting(original.id)?.status != .processing }
            try expect(AudioFileDecoder.reads == 2 && SileroSpeechDetector.loadCalls == 1
                       && notesCalls == 0, "No-speech fixture did not traverse both readable tracks or invoked notes")
            try expect(await engine.calls == 0, "Digital silence was sent to ASR")
            for meeting in [store.meeting(original.id)!, MeetingStore(directory: dir).meeting(original.id)!] {
                try expect(meeting.status == .done && meeting.turns.isEmpty && meeting.othersSilent,
                           "Genuine silence was misclassified as a failed retry")
                try expect(meeting.title == nil && meeting.notes == nil && meeting.notesError == nil
                           && meeting.transcriptionWarnings == nil && meeting.captureWarnings == original.captureWarnings,
                           "Valid no-speech result retained obsolete content or removed capture history")
                try expect(!meeting.markdown.contains(original.notes!)
                           && !meeting.markdown.contains(original.transcriptionWarnings!.first!),
                           "No-speech Markdown retained obsolete notes or ASR warnings")
            }
        }
        try await test("CN3 default 2000-row interrupted retry survives selection flush, refused quit, storage repair, retention and reload") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let historyDirectory = dir.appending(path: "History")
            let seed = try Fixtures.fullHistory(in: historyDirectory), oldest = seed[0]
            let failure = FailureSwitch(), engine = HeldTranscriber(), selection = Latch()
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let c = Fixtures.controller(in: dir, transcriber: engine, files: files)
            try expect(c.history.textLimit == 2_000 && c.history.audioLimit == 20 && c.history.entries.count == 2_000,
                       "Fixture does not use the production history limits")
            c.retry(oldest); try await eventually { await engine.calls == 1 }
            let newer = c.history.add(samples: Fixtures.audio, kind: .dictation, status: .done).entry
            c.history.update(newer.id, status: .done, text: "NEWER_COMPLETED")
            try expect(c.history.entries.count == 2_001 && c.history.entries.first { $0.id == oldest.id }?.status == .processing,
                       "Fixture did not reach the full-history retry overflow")
            let capture = CommandSelectionCapture { await selection.wait(); return Fixtures.selection() }
            c.save(.init(recording: .init(command: true, bundleID: nil, selection: capture, startedAt: .now),
                         samples: Fixtures.audio, usedFallback: false))
            try await eventually { await selection.entered }
            let command = c.history.entries.first { $0.isCommand }!
            let revoked = Array(c.historyWork.values)
            try expect(revoked.count == 2 && c.history.entries.count == 2_002, "Pending command did not join the full-history queue")
            failure.set(true)
            let flush = c.prepareForTermination()
            try expect(flush != nil && c.historyWork.isEmpty && revoked.allSatisfy { !$0.lifetime.isCurrent },
                       "Quit failed to revoke work or await pending selection")
            for id in [oldest.id, command.id] {
                let row = c.history.entries.first { $0.id == id }
                try expect(row?.status == .failed("Interrupted") && row?.recoveryPending == true,
                           "Interruption lost a recovery row at the default text limit")
            }
            try expect(c.history.entries.first { $0.id == command.id }?.canRetry == false,
                       "Unresolved command context became retryable")
            await selection.release(); await flush?.value
            try expect(!c.terminationSaveSucceeded() && !c.isTerminating, "Failed index write did not refuse quit")
            let messages = c.messages.count
            await engine.release("REVOKED_LATE_RESULT")
            for work in revoked { await work.task?.value }
            try await eventually { c.gate.pendingJobs == 0 }
            try expect(await engine.calls == 1, "Revoked queued command reached ASR")
            try expect(c.selectionSaves.isEmpty && c.historyWork.isEmpty && c.messages.count == messages
                       && KeyPoster.posts.isEmpty && NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD",
                       "Late revoked work delivered or disturbed the refused-quit state")
            failure.set(false); c.retryHistoryStorage(); c.history.retryRetention()
            try expectInterruptedHistory(c, ids: [oldest.id, command.id])
            let reloaded = DictationHistory(directory: historyDirectory)
            reloaded.retryRetention()
            for history in [c.history, reloaded, DictationHistory(directory: historyDirectory)] {
                let old = history.entries.first { $0.id == oldest.id }, savedCommand = history.entries.first { $0.id == command.id }
                try expect(history.entries.count == 2_002 && old?.text == oldest.text && old?.recoveryPending == true
                           && old?.status == .failed("Interrupted") && old?.canRetry == true,
                           "Storage/retention retry or reload pruned the oldest interrupted result")
                try expect(history.samples(oldest.id) == Fixtures.audio && history.samples(command.id) == Fixtures.audio,
                           "Recovery row survived but its WAV was removed")
                try expect(savedCommand?.kind == .command(selection: "ORIGINAL_SELECTION")
                           && savedCommand?.commandSelectionUnavailable == false && savedCommand?.recoveryPending == true
                           && savedCommand?.canRetry == true, "Pending selection flush lost context or recovery protection")
                try expect(history.entries.first { $0.id == newer.id }?.text == "NEWER_COMPLETED",
                           "Recovery changed the newer completed result")
            }
            c.retry(oldest); try await eventually { await engine.calls == 2 }
            try expect(c.history.entries.first { $0.id == oldest.id }?.recoveryPending == true,
                       "Starting another retry cleared durable recovery protection")
            await engine.release("RECOVERED_OLDEST_RESULT"); try await eventually { c.gate.pendingJobs == 0 }
            let recovered = DictationHistory(directory: historyDirectory).entries.first { $0.id == oldest.id }
            try expect(recovered?.status == .done && recovered?.text == "RECOVERED_OLDEST_RESULT"
                       && recovered?.recoveryPending != true && NSPasteboard.general.string(forType: .string) == "RECOVERED_OLDEST_RESULT",
                       "Successful retry did not deliver and release durable recovery protection")
        }
        try await test("CN3 zero-limit quit recording survives first prune, refused quit, repair and reload") {
            let dir = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let failure = FailureSwitch(), engine = HeldTranscriber()
            let files = PersistenceIO(write: { data, url in
                if failure.enabled && url.lastPathComponent == "history.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            let history = DictationHistory(directory: dir.appending(path: "History"), audioLimit: 0, textLimit: 0, files: files)
            let gate = TranscriberGate(transcriber: { engine }, reload: {})
            let c = ControllerProbe(history: history, gate: gate, meetingStore: MeetingStore(directory: dir.appending(path: "Meetings")))
            try c.session.start(command: false, deviceUID: nil, preview: nil)
            failure.set(true); await c.prepareForTermination()?.value
            try expect(!c.terminationSaveSucceeded() && c.session.current == nil, "Fixture did not refuse quit after stopping the recording")
            try expect(history.entries.count == 1 && history.entries[0].recoveryPending == true
                       && history.entries[0].hasAudio, "Initial zero-limit pruning deleted the quit recording")
            let id = history.entries[0].id
            failure.set(false); c.retryHistoryStorage(); history.retryRetention()
            let reloaded = DictationHistory(directory: history.directory, audioLimit: 0, textLimit: 0)
            reloaded.retryRetention()
            try expect(reloaded.entries.count == 1 && reloaded.entries[0].id == id
                       && reloaded.entries[0].status == .failed("Interrupted") && reloaded.entries[0].recoveryPending == true
                       && reloaded.entries[0].canRetry && reloaded.samples(id) == Fixtures.audio,
                       "Repaired or reloaded zero-limit history lost recoverable quit audio")
            try expect(await engine.calls == 0, "Quit unexpectedly transcribed the recording")
            try expect(KeyPoster.posts.isEmpty && NSPasteboard.general.string(forType: .string) == "USER_CLIPBOARD",
                       "Quit recording caused unexpected delivery")
        }
        print("\(passed) native audit regressions passed; all OS and engine effects were faked.")
    }
}
