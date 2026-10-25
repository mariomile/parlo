import Foundation
import HuggingFace
import ParloCore

/// Downloads a Hugging Face repo into Parlo's own Models folder.
enum HubSnapshot {
    static var root: URL { SettingsStore.appSupportDirectory.appendingPathComponent("Models", isDirectory: true) }

    static func directory(_ folder: String) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }

    /// Downloads only ever move a complete folder into place, so a folder that exists is a finished download.
    static func isInstalled(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    /// Files land in `<folder>.partial` first and move to `directory` when complete, so a half-finished download never
    /// counts as installed. The Hub client copies the snapshot out of its cache, so the cache lives next to the
    /// download and is deleted afterwards.
    static func install(
        _ repo: String, to directory: URL, matching patterns: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let (partial, scratchCache) = leftovers(of: directory)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        let client = HubClient(cache: HubCache(cacheDirectory: scratchCache))
        do {
            _ = try await client.downloadSnapshot(of: Repo.ID(rawValue: repo)!, to: partial, matching: patterns) {
                progress($0.fractionCompleted)
            }
            try Task.checkCancellation()
            try ModelFileCleanup.remove([scratchCache])
            try ModelFileCleanup.remove([directory])
            try fm.moveItem(at: partial, to: directory)
        } catch {
            // Nothing resumes from a partial download: the cache it would need is deleted too.
            do { try ModelFileCleanup.remove([partial, scratchCache]) }
            catch let cleanup {
                throw ModelFileCleanup.Failure(problems: [error.localizedDescription, "Cleanup failed: \(cleanup.localizedDescription)"])
            }
            throw error
        }
    }

    static func uninstall(_ directory: URL) throws {
        let (partial, scratchCache) = leftovers(of: directory)
        try ModelFileCleanup.remove([partial, scratchCache, directory])
    }

    /// Quitting Parlo mid-download leaves these folders behind, up to the model's size.
    @discardableResult static func removeLeftovers(in root: URL = root) -> [String] {
        do {
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            try ModelFileCleanup.remove(children.filter { ["partial", "cache"].contains($0.pathExtension) })
            return []
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return [] }
            return [error.localizedDescription]
        }
    }

    static func leftovers(of directory: URL) -> (partial: URL, cache: URL) {
        let parent = directory.deletingLastPathComponent(), name = directory.lastPathComponent
        return (
            parent.appendingPathComponent(name + ".partial", isDirectory: true),
            parent.appendingPathComponent(name + ".cache", isDirectory: true)
        )
    }
}
