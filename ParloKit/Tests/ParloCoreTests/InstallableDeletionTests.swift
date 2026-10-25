import Foundation
import Testing
@testable import ParloCore

/// Two independently held deletions expose the interval between an old wait and new ownership.
private actor SuccessiveDeletions {
    private var holds: [Int: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    private(set) var starts = 0
    private(set) var overlaps = 0
    private(set) var installed = true

    func uninstall() async {
        starts += 1
        let deletion = starts
        active += 1
        if deletion <= 2 { await withCheckedContinuation { holds[deletion] = $0 } }
        installed = false
        active -= 1
    }

    func install() {
        if active > 0 { overlaps += 1 }
        installed = true
    }

    func release(_ deletion: Int) { holds.removeValue(forKey: deletion)?.resume() }
}

@MainActor @Suite struct InstallableDeletionTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw DeadlineExceeded(seconds: 2) }
            await Task.yield()
        }
    }

    @Test func waitingDownloadDoesNotOverlapSuccessiveDeletions() async throws {
        var waitedForBoth = 0
        // Exercise both scheduler orders. A download admitted before D2 may be cancelled by it;
        // one still waiting when D2 owns deletion must remain blocked until that deletion finishes.
        for _ in 0..<100 {
            let files = SuccessiveDeletions()
            let model = Installable(state: .installed, isInstalled: { await files.installed },
                                    install: { _ in await files.install() }, uninstall: { await files.uninstall() })
            var admissions = 0
            model.onChange = { if case .downloading = model.state { admissions += 1 } }
            let deleting = Task(priority: .userInitiated) {
                try await model.delete()
                try await model.delete()
            }
            try await waitUntil { await files.starts == 1 }
            let downloading = Task(priority: .background) { await model.download() }
            for _ in 0..<20 { await Task.yield() }
            await files.release(1)
            try await waitUntil { await files.starts >= 2 }
            for _ in 0..<50 { await Task.yield() }
            let waitingForSecond = admissions == 0
            #expect(await files.overlaps == 0)
            await files.release(2)
            try await deleting.value
            await downloading.value
            #expect(await files.overlaps == 0)
            if waitingForSecond {
                waitedForBoth += 1
                #expect(model.state == .installed)
                #expect(await files.installed)
            }
            model.onChange = nil
        }
        #expect(waitedForBoth > 0, "The test must exercise a download waiting through both deletions")
    }

    @Test func cancelledDeletionWaiterNeverStartsInstallation() async throws {
        let files = SuccessiveDeletions()
        let model = Installable(state: .installed, isInstalled: { await files.installed },
                                install: { _ in Issue.record("Cancelled waiter started installation") },
                                uninstall: { await files.uninstall() })
        let deleting = Task { try await model.delete() }
        try await waitUntil { await files.starts == 1 }
        let downloading = Task { await model.download() }
        for _ in 0..<20 { await Task.yield() }
        downloading.cancel()
        await files.release(1)
        try await deleting.value
        await downloading.value
        #expect(model.state == .notInstalled)
    }
}
