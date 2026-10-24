import Foundation
import Testing
@testable import ParloCore

actor FakeFiles {
    var installed = false
    var failInstall = false
    var hang = false
    var installs = 0
    var uninstalls = 0

    func setInstalled(_ v: Bool) { installed = v }
    func setFail(_ v: Bool) { failInstall = v }
    func setHang(_ v: Bool) { hang = v }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        installs += 1
        progress(0.5)
        if failInstall { throw FailingError() }
        while hang { try await Task.sleep(for: .milliseconds(5)) }
        installed = true
        progress(1)
    }

    func uninstall() {
        installed = false
        uninstalls += 1
    }

    @MainActor func installable() -> Installable {
        Installable(
            isInstalled: { await self.installed },
            install: { try await self.install(progress: $0) },
            uninstall: { await self.uninstall() }
        )
    }
}

@MainActor @Suite struct InstallableTests {
    @Test func refreshReadsTheFiles() async {
        let files = FakeFiles()
        let m = files.installable()
        await m.refresh()
        #expect(m.state == .notInstalled)
        await files.setInstalled(true)
        await m.refresh()
        #expect(m.state == .installed)
    }

    @Test func downloadSucceeds() async {
        let m = FakeFiles().installable()
        await m.download()
        #expect(m.state == .installed)
    }

    @Test func failedDownloadCleansUp() async {
        let files = FakeFiles()
        await files.setFail(true)
        let m = files.installable()
        await m.download()
        guard case .failed = m.state else { Issue.record("expected failed"); return }
        #expect(await files.uninstalls == 1)
    }

    @Test func cancelReturnsToNotInstalledAndRefreshKeepsTheDownload() async throws {
        let files = FakeFiles()
        await files.setHang(true)
        let m = files.installable()
        let t = Task { await m.download() }
        while m.state != .downloading(0.5) { try await Task.sleep(for: .milliseconds(5)) }
        await m.refresh()
        #expect(m.state == .downloading(0.5))
        m.cancel()
        await t.value
        #expect(m.state == .notInstalled)
        #expect(await files.uninstalls == 1)
    }

    @Test func concurrentDownloadsShareOneInstall() async throws {
        let files = FakeFiles()
        await files.setHang(true)
        let m = files.installable()
        let a = Task { await m.download() }
        let b = Task { await m.download() }
        while m.state != .downloading(0.5) { try await Task.sleep(for: .milliseconds(5)) }
        await files.setHang(false)
        await a.value
        await b.value
        #expect(m.state == .installed)
        #expect(await files.installs == 1)
        #expect(await files.uninstalls == 0)
    }

    @Test func deleteUninstalls() async {
        let files = FakeFiles()
        let m = files.installable()
        await m.download()
        await m.delete()
        #expect(m.state == .notInstalled)
        #expect(await files.installed == false)
    }

    @Test func onChangeFiresOncePerChange() async {
        let m = FakeFiles().installable()
        var changes: [ModelState] = []
        m.onChange = { [unowned m] in changes.append(m.state) }
        await m.refresh()
        #expect(changes.isEmpty)
        await m.download()
        #expect(changes.first == .downloading(0))
        #expect(changes.last == .installed)
    }
}
