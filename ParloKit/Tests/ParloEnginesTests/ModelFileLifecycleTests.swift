import Foundation
import Testing
@testable import ParloEngines

@Suite struct ModelFileLifecycleTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parlo-model-files-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relative: String, in directory: URL, count: Int = 8) throws {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: file)
    }

    private func completeWhisper(in directory: URL) throws {
        for bundle in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            try write("\(bundle)/coremldata.bin", in: directory)
        }
        for bundle in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try write("\(bundle)/weights/weight.bin", in: directory)
        }
        try write("config.json", in: directory)
    }

    @Test func emptyOrInterruptedWhisperBundlesAreNotInstalled() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for bundle in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
        }
        #expect(!WhisperModelFiles.isInstalled(at: directory))
        #expect(throws: (any Error).self) { try WhisperModelFiles.markComplete(at: directory) }
        for bundle in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            try write("\(bundle)/coremldata.bin", in: directory)
        }
        #expect(throws: (any Error).self) { try WhisperModelFiles.markComplete(at: directory) }
        #expect(!WhisperModelFiles.isInstalled(at: directory))
    }

    @Test func whisperManifestRequiresEveryCompletedFileAndItsSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try completeWhisper(in: directory)
        // Legacy cache cannot be adopted just from whatever files happen to exist.
        #expect(!WhisperModelFiles.isInstalled(at: directory))
        try WhisperModelFiles.markComplete(at: directory)
        #expect(WhisperModelFiles.isInstalled(at: directory))
        try write("config.json", in: directory, count: 1)
        #expect(!WhisperModelFiles.isInstalled(at: directory))
        try completeWhisper(in: directory)
        #expect(WhisperModelFiles.isInstalled(at: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"))
        #expect(!WhisperModelFiles.isInstalled(at: directory))
    }

    @Test func deletingWhisperVariantRemovesOnlyItsHiddenCache() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = root.appendingPathComponent("openai_whisper-tiny")
        let retained = root.appendingPathComponent("openai_whisper-base")
        try completeWhisper(in: removed)
        try completeWhisper(in: retained)
        let removedCache = WhisperModelFiles.cacheDirectory(for: removed)
        let retainedCache = WhisperModelFiles.cacheDirectory(for: retained)
        try write("weights.hash.incomplete", in: removedCache)
        try write("weights.hash.incomplete", in: retainedCache)
        #expect(Set(ModelStorage.whisperCaches(in: root).map { $0.resolvingSymlinksInPath().path })
            == Set([removedCache, retainedCache].map { $0.resolvingSymlinksInPath().path }))
        try WhisperModelFiles.uninstall(at: removed)
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(!FileManager.default.fileExists(atPath: removedCache.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(FileManager.default.fileExists(atPath: retainedCache.path))
        try WhisperModelFiles.uninstall(at: removed) // Already absent is success.
    }

    @Test func cleanupAttemptsEveryPathAndReportsFailures() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["model.partial", "model.cache", "model"].map { root.appendingPathComponent($0) }
        for path in paths { try write("weights", in: path) }
        var attempted: [URL] = []
        #expect(throws: ModelFileCleanup.Failure.self) {
            try ModelFileCleanup.remove(paths) { path in
                attempted.append(path)
                if path == paths[0] { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: path)
            }
        }
        #expect(attempted == paths)
        #expect(FileManager.default.fileExists(atPath: paths[0].path))
        #expect(!FileManager.default.fileExists(atPath: paths[1].path))
        try ModelFileCleanup.remove(paths)
        #expect(!FileManager.default.fileExists(atPath: paths[0].path))
    }

    @Test(arguments: ["model.partial", "model.cache", "model"])
    func hubUninstallPropagatesFilesystemFailureAndRetries(_ name: String) throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let retained = root.appendingPathComponent(name)
        try write("weights", in: retained)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: ModelFileCleanup.Failure.self) { try HubSnapshot.uninstall(root.appendingPathComponent("model")) }
        #expect(FileManager.default.fileExists(atPath: retained.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try HubSnapshot.uninstall(root.appendingPathComponent("model"))
        #expect(!FileManager.default.fileExists(atPath: retained.path))
        try HubSnapshot.uninstall(root.appendingPathComponent("model"))
    }

    @Test func startupCleanupReturnsErrorsAndLeavesCompletedModelsAlone() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try write("weights", in: root.appendingPathComponent("model.partial"))
        try write("weights", in: root.appendingPathComponent("complete-model"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(!HubSnapshot.removeLeftovers(in: root).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(HubSnapshot.removeLeftovers(in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("complete-model/weights").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("model.partial").path))
    }

    @Test func vocabularyDeletionCannotRaceTheWriterAndInvalidatesLoadedGeneration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = VocabularyModelFiles(directory: root.appendingPathComponent("booster"))
        for path in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "vocab.json", "tokenizer.json"] {
            try write(path, in: files.directory)
        }
        #expect(files.assetsExist)
        let generation = try #require(files.beginLoad())
        #expect(files.beginLoad() == nil)
        #expect(throws: ModelFileCleanup.Failure.self) { try files.delete() }
        #expect(files.assetsExist)
        #expect(files.generation == generation)
        files.finishLoad()
        try files.delete()
        #expect(files.generation != generation)
        #expect(!files.assetsExist)
        #expect(files.beginLoad() == files.generation)
        files.finishLoad()
        try files.delete()
    }
}
