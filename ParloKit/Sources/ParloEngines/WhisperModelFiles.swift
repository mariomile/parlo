import Foundation

/// The downloader writes bundles file by file. Only a completed download may publish this inventory.
/// Older caches without it need a fresh download; Argmax's metadata cache hits don't verify bytes.
/// Directory existence alone cannot prove that a legacy snapshot contains every repository file.
enum WhisperModelFiles {
    static let marker = ".parlo-complete.json"
    private static let bundles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]

    private struct Manifest: Codable {
        let version: Int
        let files: [String: Int64]
    }

    /// The owner serializes this mutation with deletion. An invalid or absent manifest means none
    /// of this variant's existing files/metadata can certify a repair, including resumable bytes.
    static func install(at directory: URL, download: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !isInstalled(at: directory) else { return }
        try uninstall(at: directory)
        try Task.checkCancellation()
        try await download()
        try Task.checkCancellation()
        try markComplete(at: directory)
    }

    static func isInstalled(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(marker)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, hasRequiredAssets(manifest.files) else { return false }
        return manifest.files.allSatisfy { path, size in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), size >= 0 else { return false }
            let file = directory.appendingPathComponent(path)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return false }
            return Int64(values.fileSize ?? -1) == size
        }
    }

    static func markComplete(at directory: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var readError: (any Error)?
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            errorHandler: { _, error in readError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var inventory: [String: Int64] = [:]
        let prefix = directory.standardizedFileURL.path + "/"
        for case let file as URL in files {
            guard file.lastPathComponent != marker else { continue }
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            inventory[String(path.dropFirst(prefix.count))] = Int64(values.fileSize ?? 0)
        }
        if let readError { throw readError }
        guard hasRequiredAssets(inventory) else {
            throw ModelFileCleanup.Failure(problems: ["Whisper download is incomplete; download the model again to repair it"])
        }
        try JSONEncoder().encode(Manifest(version: 1, files: inventory))
            .write(to: directory.appendingPathComponent(marker), options: .atomic)
    }

    private static func hasRequiredAssets(_ files: [String: Int64]) -> Bool {
        guard bundles.allSatisfy({ (files[$0 + "/coremldata.bin"] ?? 0) > 0 }) else { return false }
        return bundles.prefix(2).allSatisfy { bundle in
            files.contains { $0.key.hasPrefix(bundle + "/weights/") && $0.value > 0 }
        }
    }

    /// Argmax keeps resumable downloads beside the variant, not in HubSnapshot's `<name>.cache`.
    static func cacheDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
    }

    static func uninstall(at directory: URL) throws {
        try ModelFileCleanup.remove([directory, cacheDirectory(for: directory)])
    }
}
