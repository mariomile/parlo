import Foundation
import Testing
import ParloCore
@testable import ParloEngines

/// Mirrors pinned Argmax HubApi.HubFileDownloader: matching commit or etag returns the existing
/// destination without validating its bytes. Only a cache miss writes the synthetic remote bytes.
private actor CachedWhisperDownloader {
    enum Shortcut: String, CaseIterable, Sendable { case commit, etag }
    static let weight = "AudioEncoder.mlmodelc/weights/weight.bin"
    static let assets = [
        "AudioEncoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/coremldata.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin", weight,
        "TextDecoder.mlmodelc/weights/weight.bin", "config.json"
    ]
    static let bytes = Data(repeating: 7, count: 8)
    private let commit = String(repeating: "a", count: 40)
    private let etag = String(repeating: "e", count: 40)
    private(set) var cacheHits = 0
    private(set) var replacements = 0

    private func metadata(_ path: String, in directory: URL) -> URL {
        WhisperModelFiles.cacheDirectory(for: directory).appendingPathComponent(path + ".metadata")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func seed(at directory: URL, shortcut: Shortcut = .commit) throws {
        for path in Self.assets {
            try write(Self.bytes, to: directory.appendingPathComponent(path))
        }
        try seedMetadata(at: directory, shortcut: shortcut)
    }

    func seedMetadata(at directory: URL, shortcut: Shortcut) throws {
        for path in Self.assets {
            let localCommit = shortcut == .commit ? commit : String(repeating: "b", count: 40)
            try write(Data("\(localCommit)\n\(etag)\n0\n".utf8), to: metadata(path, in: directory))
        }
    }

    func resetCounts() { cacheHits = 0; replacements = 0 }

    func download(to directory: URL) throws {
        for path in Self.assets {
            let destination = directory.appendingPathComponent(path)
            let sidecar = metadata(path, in: directory)
            let local = (try? String(contentsOf: sidecar, encoding: .utf8))?.components(separatedBy: "\n")
            if FileManager.default.fileExists(atPath: destination.path), let local, local.count >= 2 {
                if local[0] == commit { cacheHits += 1; continue }
                if local[1] == etag {
                    try write(Data("\(commit)\n\(etag)\n0\n".utf8), to: sidecar)
                    cacheHits += 1
                    continue
                }
            }
            try write(Self.bytes, to: destination)
            try write(Data("\(commit)\n\(etag)\n0\n".utf8), to: sidecar)
            replacements += 1
        }
    }
}

@Suite struct WhisperRepairTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parlo-whisper-repair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func inventory(_ directory: URL) throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(directory.path.count))] = try Data(contentsOf: file)
        }
        return result
    }

    @MainActor @Test(arguments: CachedWhisperDownloader.Shortcut.allCases)
    fileprivate func repairReplacesCorruptedCacheBeforePublishingInstalled(_ shortcut: CachedWhisperDownloader.Shortcut) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("openai_whisper-tiny")
        let retained = root.appendingPathComponent("openai_whisper-base")
        let downloader = CachedWhisperDownloader()
        try await downloader.seed(at: directory, shortcut: shortcut)
        try WhisperModelFiles.markComplete(at: directory)
        try await downloader.seed(at: retained)
        try WhisperModelFiles.markComplete(at: retained)
        let retainedFiles = try inventory(retained)
        let retainedCache = try inventory(WhisperModelFiles.cacheDirectory(for: retained))

        let weight = directory.appendingPathComponent(CachedWhisperDownloader.weight)
        try Data([7]).write(to: weight)
        #expect(!WhisperModelFiles.isInstalled(at: directory))
        // Demonstrate that the fake really preserves corrupt bytes for the SDK's shortcut.
        try await downloader.download(to: directory)
        #expect(try Data(contentsOf: weight).count == 1)
        #expect(await downloader.cacheHits == CachedWhisperDownloader.assets.count)
        // The etag shortcut updates the commit sidecar. Restore it so repair sees that case too.
        try await downloader.seedMetadata(at: directory, shortcut: shortcut)
        await downloader.resetCounts()
        let incomplete = WhisperModelFiles.cacheDirectory(for: directory).appendingPathComponent("stale.incomplete")
        try Data([9]).write(to: incomplete)

        let model = Installable(isInstalled: { WhisperModelFiles.isInstalled(at: directory) }, install: { _ in
            // This is the same complete production transaction called by WhisperKitBackend.install.
            try await WhisperModelFiles.install(at: directory) { try await downloader.download(to: directory) }
        }, uninstall: { try WhisperModelFiles.uninstall(at: directory) })
        await model.download()
        #expect(model.state == .installed)
        #expect(WhisperModelFiles.isInstalled(at: directory))
        #expect(try Data(contentsOf: weight) == CachedWhisperDownloader.bytes)
        #expect(await downloader.cacheHits == 0)
        #expect(await downloader.replacements == CachedWhisperDownloader.assets.count)
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
        #expect(try inventory(retained) == retainedFiles)
        #expect(try inventory(WhisperModelFiles.cacheDirectory(for: retained)) == retainedCache)
    }

    @Test func missingManifestCannotAdoptUnverifiedCacheHits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("openai_whisper-tiny")
        let downloader = CachedWhisperDownloader()
        try await downloader.seed(at: directory)
        try Data([7]).write(to: directory.appendingPathComponent(CachedWhisperDownloader.weight))
        try await WhisperModelFiles.install(at: directory) { try await downloader.download(to: directory) }
        #expect(WhisperModelFiles.isInstalled(at: directory))
        #expect(await downloader.cacheHits == 0)
        #expect(try Data(contentsOf: directory.appendingPathComponent(CachedWhisperDownloader.weight)) == CachedWhisperDownloader.bytes)
    }

    @Test func validManifestIsPreservedWithoutDownloadingOrRecertifying() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("openai_whisper-tiny")
        try await CachedWhisperDownloader().seed(at: directory)
        try WhisperModelFiles.markComplete(at: directory)
        let before = try inventory(root)
        try await WhisperModelFiles.install(at: directory) { Issue.record("Verified variant was downloaded again") }
        #expect(try inventory(root) == before)
    }

    @Test func failedCacheRemovalStopsRepairBeforeDownload() async throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("openai_whisper-tiny")
        let cacheParent = WhisperModelFiles.cacheDirectory(for: directory).deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheParent.path)
            try? FileManager.default.removeItem(at: root)
        }
        try await CachedWhisperDownloader().seed(at: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheParent.path)
        await #expect(throws: ModelFileCleanup.Failure.self) {
            try await WhisperModelFiles.install(at: directory) { Issue.record("Repair reused undeletable cache") }
        }
        #expect(!WhisperModelFiles.isInstalled(at: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheParent.path)
        let retry = CachedWhisperDownloader()
        try await WhisperModelFiles.install(at: directory) { try await retry.download(to: directory) }
        #expect(WhisperModelFiles.isInstalled(at: directory))
        #expect(await retry.cacheHits == 0)
    }

    @Test func cancelledRepairNeverPublishesACompletionManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("openai_whisper-tiny")
        let task = Task {
            try await WhisperModelFiles.install(at: directory) {
                try await CachedWhisperDownloader().download(to: directory)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(WhisperModelFiles.marker).path))
        #expect(!WhisperModelFiles.isInstalled(at: directory))
    }
}
