import Foundation
import Testing
@testable import ParloCore

actor FakeLLMInstaller: LocalLLMInstalling {
    var installed = false
    var failInstall = false
    var hang = false
    var uninstalls = 0

    func setInstalled(_ v: Bool) { installed = v }
    func setFail(_ v: Bool) { failInstall = v }
    func setHang(_ v: Bool) { hang = v }

    func isInstalled() async -> Bool { installed }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        if failInstall { throw FailingError() }
        while hang { try await Task.sleep(for: .milliseconds(5)) }
        installed = true
        progress(1)
    }

    func uninstall() async throws {
        installed = false
        uninstalls += 1
    }
}

@MainActor @Suite struct LocalLLMManagerTests {
    @Test func refreshReadsInstaller() async {
        let inst = FakeLLMInstaller()
        let m = LocalLLMManager(installer: inst)
        await m.refresh()
        #expect(m.state == .notInstalled)
        await inst.setInstalled(true)
        await m.refresh()
        #expect(m.state == .installed)
    }

    @Test func downloadSucceeds() async {
        let m = LocalLLMManager(installer: FakeLLMInstaller())
        await m.download()
        #expect(m.state == .installed)
    }

    @Test func failedDownloadCleansUp() async {
        let inst = FakeLLMInstaller()
        await inst.setFail(true)
        let m = LocalLLMManager(installer: inst)
        await m.download()
        guard case .failed = m.state else { Issue.record("expected failed"); return }
        #expect(await inst.uninstalls == 1)
    }

    @Test func cancelReturnsToNotInstalled() async throws {
        let inst = FakeLLMInstaller()
        await inst.setHang(true)
        let m = LocalLLMManager(installer: inst)
        let t = Task { await m.download() }
        while m.state != .downloading(0.5) { try await Task.sleep(for: .milliseconds(5)) }
        await m.refresh()
        #expect(m.state == .downloading(0.5))
        m.cancel()
        await t.value
        #expect(m.state == .notInstalled)
        #expect(await inst.uninstalls == 1)
    }

    @Test func concurrentDownloadsShareOneInstall() async {
        let inst = FakeLLMInstaller()
        await inst.setHang(true)
        let m = LocalLLMManager(installer: inst)
        let a = Task { await m.download() }
        let b = Task { await m.download() }
        try? await Task.sleep(for: .milliseconds(30))
        await inst.setHang(false)
        await a.value
        await b.value
        #expect(m.state == .installed)
        #expect(await inst.uninstalls == 0)
    }

    @Test func deleteUninstalls() async {
        let inst = FakeLLMInstaller()
        let m = LocalLLMManager(installer: inst)
        await m.download()
        await m.delete()
        #expect(m.state == .notInstalled)
        #expect(await inst.installed == false)
    }
}
