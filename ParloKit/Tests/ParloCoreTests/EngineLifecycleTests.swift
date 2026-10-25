import Foundation
import Testing
@testable import ParloCore

/// Deliberately ignores cancellation, without polling a cancelled sleep or allocating real models.
private actor HeldOperation {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0
    func wait() async {
        starts += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

private actor HeldEngine: Transcriber {
    let hold = HeldOperation()
    private(set) var active = 0
    private(set) var maximumActive = 0
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        active += 1
        maximumActive = max(maximumActive, active)
        await hold.wait()
        active -= 1
        return "retired"
    }
}

@MainActor @Suite struct EngineLifecycleTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < end else { throw DeadlineExceeded(seconds: 2) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func cancellationBeforeEnqueuedTaskStartsReleasesItsReservation() async throws {
        var acquisitions = 0, errors = 0
        let gate = TranscriberGate(transcriber: {
            acquisitions += 1
            return FakeTranscriber(text: "next")
        }, reload: { Issue.record("No engine was acquired, so none should be retired") })
        let job = gate.enqueue({ _ in Issue.record("Cancelled job ran") }, onError: { error in
            #expect(error is CancellationError)
            errors += 1
        })
        job.cancel()
        await job.value
        #expect(acquisitions == 0)
        #expect(errors == 1)
        #expect(gate.pendingJobs == 0)
        let next = try await Deadline.run(seconds: 1) {
            try await gate.runInBackground { try await $0.transcribe([], languageCode: nil, dictionary: []) }
        }
        #expect(next == "next")
    }

    @Test func cancelledInferenceRetiresTheInstanceBeforeTheNextCall() async throws {
        let old = HeldEngine()
        var reloads = 0
        let gate = TranscriberGate(transcriber: {
            reloads == 0 ? (old as any Transcriber) : FakeTranscriber(text: "replacement")
        }, reload: { reloads += 1 })
        let background = BackgroundTranscriber(gate: gate)
        let first = Task { try await background.transcribe([], languageCode: nil, dictionary: []) }
        try await waitUntil { await old.active == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await Deadline.run(seconds: 1) { try await first.value }
        }
        #expect(await old.active == 1)
        #expect(try await background.transcribe([], languageCode: nil, dictionary: []) == "replacement")
        #expect(reloads == 1)
        #expect(await old.maximumActive == 1)
        await old.hold.release()
        try await waitUntil { await old.active == 0 }
        #expect(try await background.transcribe([], languageCode: nil, dictionary: []) == "replacement")
    }

    @Test func cancelledEnqueueHandleWithdrawsBeforeAcquisition() async throws {
        let hold = HeldOperation()
        var acquisitions = 0, reloads = 0, errors = 0
        let gate = TranscriberGate(transcriber: {
            acquisitions += 1
            return FakeTranscriber(text: "")
        }, reload: { reloads += 1 })
        let first = gate.enqueue({ _ in await hold.wait() }, onError: { _ in Issue.record("first failed") })
        try await waitUntil { await hold.starts == 1 }
        let queued = gate.enqueue({ _ in Issue.record("cancelled job ran") }, onError: { error in
            #expect(error is CancellationError)
            errors += 1
        })
        await Task.yield()
        queued.cancel()
        try await Deadline.run(seconds: 1) { await queued.value }
        #expect(acquisitions == 1)
        #expect(reloads == 0)
        #expect(errors == 1)
        #expect(gate.pendingJobs == 1)
        await hold.release()
        await first.value
        #expect(gate.pendingJobs == 0)
    }

    @Test func runningEnqueueHandleRetiresCancelledInference() async throws {
        let old = HeldEngine()
        var reloads = 0, cancellations = 0
        let gate = TranscriberGate(transcriber: {
            reloads == 0 ? (old as any Transcriber) : FakeTranscriber(text: "replacement")
        }, reload: { reloads += 1 })
        let job = gate.enqueue({ engine in
            _ = try await Deadline.run(seconds: 10) {
                try await engine.transcribe([], languageCode: nil, dictionary: [])
            }
        }, onError: { error in
            #expect(error is CancellationError)
            cancellations += 1
        })
        try await waitUntil { await old.active == 1 }
        job.cancel()
        try await Deadline.run(seconds: 1) { await job.value }
        #expect(cancellations == 1)
        #expect(reloads == 1)
        #expect(try await gate.runInBackground { try await $0.transcribe([], languageCode: nil, dictionary: []) } == "replacement")
        #expect(await old.maximumActive == 1)
        await old.hold.release()
    }

    @Test func acquisitionCancellationReleasesGateAndRejectsLateLoad() async throws {
        let hold = HeldOperation()
        var generation = 0
        let gate = TranscriberGate(transcriber: {
            let captured = generation
            if captured == 0 { await hold.wait() }
            return FakeTranscriber(text: "generation \(captured)")
        }, reload: { generation += 1 })
        let first = Task { try await gate.runInBackground { try await $0.transcribe([], languageCode: nil, dictionary: []) } }
        try await waitUntil { await hold.starts == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await Deadline.run(seconds: 1) { try await first.value }
        }
        #expect(try await gate.runInBackground { try await $0.transcribe([], languageCode: nil, dictionary: []) } == "generation 1")
        await hold.release()
        #expect(try await gate.runInBackground { try await $0.transcribe([], languageCode: nil, dictionary: []) } == "generation 1")
    }

    @Test func acquisitionHasItsOwnDeadline() async throws {
        let hold = HeldOperation()
        var generation = 0
        let gate = TranscriberGate(transcriber: {
            if generation == 0 { await hold.wait() }
            return FakeTranscriber(text: "ready")
        }, reload: { generation += 1 }, acquisitionTimeout: 0.03)
        await #expect(throws: DeadlineExceeded.self) { try await gate.runInBackground { _ in "never" } }
        #expect(generation == 1)
        #expect(try await gate.runInBackground { _ in "next" } == "next")
        await hold.release()
    }

    @Test func previewAcquisitionCannotPublishAfterRetirement() async throws {
        let hold = HeldOperation()
        var generation = 0
        let gate = TranscriberGate(transcriber: {
            if generation == 0 { await hold.wait() }
            return FakeTranscriber(text: "ready")
        }, reload: { generation += 1 }, previewGrace: 0.03)
        let preview = Task { await gate.runIfIdle { _ in Issue.record("retired preview ran"); return "stale" } }
        try await waitUntil { await hold.starts == 1 }
        #expect(try await gate.runInBackground { _ in "next" } == "next")
        await hold.release()
        #expect(await preview.value == nil)
        #expect(generation == 1)
    }

    @Test func sharedLoadClearWakesWaiterAndRejectsLateValue() async throws {
        let hold = HeldOperation()
        let cache = SharedLoad<String, String>()
        let first = Task { try await cache.value("a") { await hold.wait(); return "retired" } }
        try await waitUntil { await hold.starts == 1 }
        cache.clear()
        await #expect(throws: CancellationError.self) {
            try await Deadline.run(seconds: 1) { try await first.value }
        }
        #expect(try await cache.value("a") { "replacement" } == "replacement")
        await hold.release()
        #expect(try await cache.value("a") { Issue.record("cache was lost"); return "unexpected" } == "replacement")
    }

    @Test func sharedLoadCancellationRetiresItsGeneration() async throws {
        let hold = HeldOperation()
        let cache = SharedLoad<String, String>()
        let first = Task { try await cache.value("a") { await hold.wait(); return "retired" } }
        try await waitUntil { await hold.starts == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) {
            try await Deadline.run(seconds: 1) { try await first.value }
        }
        #expect(cache.isEmpty)
        #expect(try await cache.value("a") { "replacement" } == "replacement")
        await hold.release()
    }

    @Test func repeatedStalledLoadsAreBoundedAndCanRecover() async throws {
        let hold = HeldOperation()
        let cache = SharedLoad<String, String>(timeout: 0.03)
        for _ in 0..<2 {
            await #expect(throws: DeadlineExceeded.self) {
                try await cache.value("a") { await hold.wait(); return "stale" }
            }
        }
        #expect(await hold.starts == 2)
        await #expect(throws: SharedLoadError.self) { try await cache.value("a") { "must not start" } }
        await hold.release()
        // Allow the two native completion observers to release their slots.
        for _ in 0..<10 { await Task.yield() }
        #expect(try await cache.value("a") { "recovered" } == "recovered")
    }

    @Test func refreshDuringDeletionCannotResurrectInstalledState() async throws {
        let deletion = HeldOperation()
        let installed = LockedBox(true)
        var checks = 0
        let files = Installable(state: .installed, isInstalled: { installed.value }, install: { _ in }, uninstall: {
            await deletion.wait()
            installed.value = false
        })
        files.onChange = { checks += 1 }
        let deleting = Task { try await files.delete() }
        try await waitUntil { await deletion.starts == 1 }
        await files.refresh()
        await deletion.release()
        try await deleting.value
        await files.refresh()
        #expect(files.state == .notInstalled)
        #expect(!installed.value)
        #expect(checks == 1)
    }

    @Test func cancellationCleanupFailureStaysVisibleUntilSuccessfulRetry() async throws {
        let files = FakeFiles()
        await files.setHang(true)
        await files.setFailUninstall(true)
        let model = files.installable()
        let download = Task { await model.download() }
        try await waitUntil { model.state == .downloading(0.5) }
        model.cancel()
        await download.value
        guard case .failed(let message) = model.state else { Issue.record("cleanup failure hidden"); return }
        #expect(message.contains("partial files"))
        await model.refresh()
        #expect(model.state == .failed(message))
        await files.setFailUninstall(false)
        try await model.delete()
        #expect(model.state == .notInstalled)
    }

    @Test func cleanupRunsOutsideCancelledDownloadTask() async throws {
        let started = HeldOperation()
        let cleanups = LockedBox(0)
        let model = Installable(isInstalled: { false }, install: { _ in
            await started.wait()
            try Task.checkCancellation()
        }, uninstall: {
            try Task.checkCancellation()
            cleanups.value += 1
        })
        let download = Task { await model.download() }
        try await waitUntil { await started.starts == 1 }
        model.cancel()
        await started.release()
        await download.value
        #expect(cleanups.value == 1)
        #expect(model.state == .notInstalled)
    }
}
