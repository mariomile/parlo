import Foundation
import HuggingFace

/// Downloads a Hugging Face repo into Parlo's own Models folder.
enum HubSnapshot {
    /// Files land in `<folder>.partial` first and move to `directory` when complete, so a half-finished download never
    /// counts as installed. The Hub client copies the snapshot out of its cache, so the cache lives next to the
    /// download and is deleted afterwards.
    static func install(
        _ repo: String, to directory: URL, matching patterns: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let partial = parent.appendingPathComponent(directory.lastPathComponent + ".partial", isDirectory: true)
        let scratchCache = parent.appendingPathComponent(directory.lastPathComponent + ".cache", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratchCache) }
        let client = HubClient(cache: HubCache(cacheDirectory: scratchCache))
        _ = try await client.downloadSnapshot(of: Repo.ID(rawValue: repo)!, to: partial, matching: patterns) {
            progress($0.fractionCompleted)
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: partial, to: directory)
    }
}
