import Foundation
import Testing
@testable import ParloCore

actor FakeInstaller: ModelInstaller {
    var installed: Set<ModelID> = [.appleSpeech]
    var failInstall = false
    var hang = false
    var uninstalled: [ModelID] = []
    var made: [ModelID] = []

    func setFail(_ v: Bool) { failInstall = v }
    func setHang(_ v: Bool) { hang = v }

    func isInstalled(_ id: ModelID) async -> Bool { installed.contains(id) }

    func install(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        if failInstall { throw FailingError() }
        while hang { try await Task.sleep(for: .milliseconds(5)) }
        installed.insert(id)
        progress(1)
    }

    func uninstall(_ id: ModelID) async throws {
        installed.remove(id)
        uninstalled.append(id)
    }

    func makeTranscriber(_ id: ModelID) async throws -> any Transcriber {
        made.append(id)
        try await Task.sleep(for: .milliseconds(20))
        return FakeTranscriber(text: id.rawValue)
    }
}

@MainActor @Suite struct ModelManagerTests {
    @Test func catalogCoversEveryModel() {
        #expect(ModelCatalog.all.map(\.id) == ModelID.allCases)
        #expect(ModelCatalog.info(.cohereTranscribe).requiresExplicitLanguage)
        #expect(!ModelCatalog.info(.appleSpeech).needsDownload)
    }

    @Test func missingActiveModelFallsBackWithoutSaving() async {
        var saved: [ModelID] = []
        let m = ModelManager(installer: FakeInstaller(), activeModelID: .parakeetV3) { saved.append($0) }
        await m.refresh()
        #expect(m.activeModelID == .appleSpeech)
        #expect(saved.isEmpty)
    }

    @Test func refreshReadsInstaller() async {
        let inst = FakeInstaller()
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        await m.refresh()
        #expect(m.states[.appleSpeech] == .installed)
        #expect(m.states[.parakeetV3] == .notInstalled)
    }

    @Test func downloadSucceeds() async {
        let m = ModelManager(installer: FakeInstaller(), activeModelID: .appleSpeech) { _ in }
        await m.refresh()
        await m.download(.parakeetV3)
        #expect(m.states[.parakeetV3] == .installed)
    }

    @Test func downloadFails() async {
        let inst = FakeInstaller()
        await inst.setFail(true)
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        await m.download(.parakeetV3)
        guard case .failed = m.states[.parakeetV3] else { Issue.record("expected failed"); return }
        #expect(await inst.uninstalled == [.parakeetV3])
    }

    @Test func cancelReturnsToNotInstalled() async throws {
        let inst = FakeInstaller()
        await inst.setHang(true)
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        let t = Task { await m.download(.whisperTiny) }
        while m.states[.whisperTiny] != .downloading(0.5) { try await Task.sleep(for: .milliseconds(5)) }
        m.cancel(.whisperTiny)
        await t.value
        #expect(m.states[.whisperTiny] == .notInstalled)
        #expect(await inst.uninstalled == [.whisperTiny])
    }

    @Test func selectPersistsAndDeleteActiveFallsBack() async {
        var persisted: [ModelID] = []
        let m = ModelManager(installer: FakeInstaller(), activeModelID: .appleSpeech) { persisted.append($0) }
        await m.download(.parakeetV3)
        m.select(.parakeetV3)
        #expect(m.activeModelID == .parakeetV3)
        await m.delete(.parakeetV3)
        #expect(m.activeModelID == .appleSpeech)
        #expect(m.states[.parakeetV3] == .notInstalled)
        #expect(persisted == [.parakeetV3, .appleSpeech])
    }

    @Test func selectIgnoresUninstalled() async {
        let m = ModelManager(installer: FakeInstaller(), activeModelID: .appleSpeech) { _ in }
        await m.refresh()
        m.select(.whisperBase)
        #expect(m.activeModelID == .appleSpeech)
    }

    @Test func transcriberCachedPerActiveModel() async throws {
        let inst = FakeInstaller()
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        _ = try await m.transcriber()
        _ = try await m.transcriber()
        #expect(await inst.made == [.appleSpeech])
        await m.download(.parakeetV3)
        m.select(.parakeetV3)
        let t = try await m.transcriber()
        #expect(try await t.transcribe([], languageCode: nil, dictionary: []) == "parakeetV3")
        #expect(await inst.made == [.appleSpeech, .parakeetV3])
    }

    @Test func concurrentTranscriberCallsLoadOnce() async throws {
        let inst = FakeInstaller()
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        m.warmUp()
        async let a = m.transcriber()
        async let b = m.transcriber()
        _ = try await (a, b)
        #expect(await inst.made == [.appleSpeech])
    }

    @Test func refreshKeepsRunningDownload() async {
        let inst = FakeInstaller()
        await inst.setHang(true)
        let m = ModelManager(installer: inst, activeModelID: .appleSpeech) { _ in }
        async let refreshed: Void = m.refresh()
        let download = Task { await m.download(.parakeetV3) }
        await refreshed
        #expect(m.states[.parakeetV3] != .notInstalled)
        m.cancel(.parakeetV3)
        await download.value
    }
}
