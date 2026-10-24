import FluidAudio
import Foundation
import ParloCore

/// One folder of downloaded model files and what it's for.
public struct StoredFiles: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A voice model from the catalog; delete it through `ModelManager` so its state updates.
        case model(ModelID)
        /// The on-device AI cleanup model; delete it through `LocalLLM.files` so its state updates.
        case cleanupModel
        /// The small model that recognises your dictionary words with Parakeet. Downloads again when needed.
        case vocabulary
        /// Voice detection, needed for every dictation.
        case voiceDetection
        /// Files in a model folder that Parlo doesn't use, often left by FluidVoice or an older download.
        case other
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    public let bytes: Int64
    public var id: String { url.path }
}

/// Everything Parlo and FluidAudio have downloaded to this Mac, with sizes measured on disk.
public enum ModelStorage {
    static var fluidAudioRoot: URL { MLModelConfigurationUtils.defaultModelsDirectory() }
    static var whisperRoot: URL { WhisperKitBackend.downloadBase.appendingPathComponent("models/\(WhisperKitBackend.repo)") }

    /// Biggest first. Reads the disk, so call it off the main thread.
    public static func scan() -> [StoredFiles] {
        var items: [StoredFiles] = []
        var claimed: Set<String> = []
        func add(_ url: URL, _ name: String, _ kind: StoredFiles.Kind) {
            let url = topFolder(url)
            let path = url.standardizedFileURL.path
            guard !claimed.contains(path), FileManager.default.fileExists(atPath: path) else { return }
            claimed.insert(path)
            items.append(StoredFiles(url: url, name: name, kind: kind, bytes: size(of: url)))
        }

        for info in ModelCatalog.all {
            if let dir = EngineInstaller.directory(info.id) { add(dir, info.displayName, .model(info.id)) }
        }
        add(HubSnapshot.directory(CleanupModel.folder), CleanupModel.displayName, .cleanupModel)
        add(CtcModels.defaultCacheDirectory(for: .ctc110m), "Vocabulary booster", .vocabulary)
        add(MLModelConfigurationUtils.defaultModelsDirectory(for: .vad), "Voice detection", .voiceDetection)
        for root in [fluidAudioRoot, whisperRoot] {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                add(child, child.lastPathComponent, .other)
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    public static func delete(_ item: StoredFiles) throws {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return }
        try FileManager.default.removeItem(at: item.url)
    }

    /// The folder directly under a model root that holds `url`, so a model's leftovers count and go with it.
    static func topFolder(_ url: URL) -> URL {
        for root in [fluidAudioRoot, whisperRoot] {
            let rootComponents = root.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            if components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents {
                return root.appendingPathComponent(components[rootComponents.count], isDirectory: true)
            }
        }
        return url
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
