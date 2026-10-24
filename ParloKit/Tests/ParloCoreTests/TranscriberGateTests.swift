import Foundation
import Testing
@testable import ParloCore

/// Answers when `release` is set, and records how many calls overlap.
final class SlowTranscriber: Transcriber, @unchecked Sendable {
    let release = LockedBox(false)
    let running = LockedBox(0)
    let maxRunning = LockedBox(0)
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        running.value += 1
        maxRunning.value = max(maxRunning.value, running.value)
        defer { running.value -= 1 }
        while !release.value { try? await Task.sleep(for: .milliseconds(2)) }
        return "preview"
    }
}

@MainActor @Suite struct TranscriberGateTests {
    func gate(_ t: any Transcriber, reloads: LockedBox<Int> = LockedBox(0), grace: Double = 5) -> TranscriberGate {
        TranscriberGate(transcriber: { t }, reload: { reloads.value += 1 }, previewGrace: grace)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func jobsRunInOrderOneAtATime() async throws {
        let g = gate(FakeTranscriber(text: ""))
        var order: [Int] = []
        var running = 0, maxRunning = 0
        for i in 1...3 {
            g.enqueue({ _ in
                running += 1
                maxRunning = max(maxRunning, running)
                order.append(i)
                try await Task.sleep(for: .milliseconds(5))
                running -= 1
            }, onError: { _ in })
        }
        #expect(g.pendingJobs == 3)
        try await waitUntil { g.pendingJobs == 0 }
        #expect(order == [1, 2, 3])
        #expect(maxRunning == 1)
    }

    @Test func previewIsSkippedWhileAJobIsWaiting() async throws {
        let g = gate(FakeTranscriber(text: "x"))
        let hold = LockedBox(true)
        g.enqueue({ _ in while hold.value { try await Task.sleep(for: .milliseconds(2)) } }, onError: { _ in })
        #expect(await g.runIfIdle { _ in "preview" } == nil)
        hold.value = false
        try await waitUntil { g.pendingJobs == 0 }
        #expect(await g.runIfIdle { _ in "preview" } == "preview")
    }

    @Test func jobWaitsForThePreviewInFlight() async throws {
        let slow = SlowTranscriber()
        let reloads = LockedBox(0)
        let g = gate(slow, reloads: reloads)
        let preview = Task { await g.runIfIdle { try? await $0.transcribe([], languageCode: nil, dictionary: []) } }
        try await waitUntil { slow.running.value == 1 }
        var ran = false
        g.enqueue({ t in
            ran = true
            _ = try await t.transcribe([], languageCode: nil, dictionary: [])
        }, onError: { _ in })
        try await Task.sleep(for: .milliseconds(20))
        #expect(!ran)
        slow.release.value = true
        #expect(await preview.value == "preview")
        try await waitUntil { g.pendingJobs == 0 }
        #expect(ran)
        #expect(slow.maxRunning.value == 1)
        #expect(reloads.value == 0)
    }

    @Test func stuckPreviewReloadsTheModel() async throws {
        let slow = SlowTranscriber()
        let reloads = LockedBox(0)
        let g = gate(slow, reloads: reloads, grace: 0.05)
        _ = Task { await g.runIfIdle { try? await $0.transcribe([], languageCode: nil, dictionary: []) } }
        try await waitUntil { slow.running.value == 1 }
        var ran = false
        g.enqueue({ _ in ran = true }, onError: { _ in })
        try await waitUntil { g.pendingJobs == 0 }
        #expect(ran)
        #expect(reloads.value == 1)
        slow.release.value = true
    }

    @Test func deadlineReloadsAndReportsTheError() async throws {
        let reloads = LockedBox(0)
        let g = gate(FakeTranscriber(text: ""), reloads: reloads)
        var errors: [any Error] = []
        g.enqueue({ _ in throw DeadlineExceeded(seconds: 1) }, onError: { errors.append($0) })
        g.enqueue({ _ in throw FailingError() }, onError: { errors.append($0) })
        try await waitUntil { g.pendingJobs == 0 }
        #expect(errors.count == 2)
        #expect(errors.first is DeadlineExceeded)
        #expect(reloads.value == 1)
    }

    @Test func previewerShowsTextWhileIdle() async throws {
        let g = gate(FakeTranscriber(text: " ciao "))
        let previewer = LivePreviewer(gate: g, interval: 0.01)
        var shown: [String] = []
        previewer.start(languageCode: nil, samples: { _ in oneSecond }, show: { shown.append($0) })
        try await waitUntil { !shown.isEmpty }
        previewer.stop()
        #expect(shown.first == "ciao")
    }

    @Test func previewerSkipsTooLittleAudio() async throws {
        let g = gate(FakeTranscriber(text: "ciao"))
        let previewer = LivePreviewer(gate: g, interval: 0.01)
        var shown: [String] = []
        previewer.start(languageCode: nil, samples: { _ in [0, 0] }, show: { shown.append($0) })
        try await Task.sleep(for: .milliseconds(60))
        previewer.stop()
        #expect(shown.isEmpty)
    }
}
