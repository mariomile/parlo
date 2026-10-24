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
        defer { try? fm.removeItem(at: scratchCache) }
        let client = HubClient(cache: HubCache(cacheDirectory: scratchCache))
        do {
            _ = try await client.downloadSnapshot(of: Repo.ID(rawValue: repo)!, to: partial, matching: patterns) {
                progress($0.fractionCompleted)
            }
            try Task.checkCancellation()
        } catch {
            // Nothing resumes from a partial download: the cache it would need is deleted too.
            try? fm.removeItem(at: partial)
            throw error
        }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: partial, to: directory)
    }

    static func uninstall(_ directory: URL) throws {
        let (partial, scratchCache) = leftovers(of: directory)
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: scratchCache)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Quitting Parlo mid-download leaves these folders behind, up to the model's size.
    static func removeLeftovers() {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children where ["partial", "cache"].contains(child.pathExtension) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func leftovers(of directory: URL) -> (partial: URL, cache: URL) {
        let parent = directory.deletingLastPathComponent(), name = directory.lastPathComponent
        return (
            parent.appendingPathComponent(name + ".partial", isDirectory: true),
            parent.appendingPathComponent(name + ".cache", isDirectory: true)
        )
    }
}
