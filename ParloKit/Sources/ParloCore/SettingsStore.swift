import Foundation
import Synchronization

/// Reads and writes `settings.json`. Failed reads block writes until a successful load/recovery.
public struct SettingsStore: Sendable {
    public let directory: URL
    private let files: PersistenceIO
    private final class State: Sendable {
        let error = Mutex<String?>(nil)
    }
    private let state = State()

    public init(directory: URL) {
        self.init(directory: directory, files: PersistenceIO())
    }

    init(directory: URL, files: PersistenceIO) {
        self.directory = directory
        self.files = files
    }

    /// Defaults may be in use, but the original file is still protected. Reload after resolving this error.
    public var loadError: String? { state.error.withLock { $0 } }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Parlo", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// A corrupt file is moved aside before defaults become writable. An unreadable file stays untouched
    /// and exposes `loadError`; it is never treated as a missing file.
    public func load() -> (settings: AppSettings, quarantined: URL?) {
        state.error.withLock { failure in
            let data: Data
            do { data = try files.read(fileURL) }
            catch where PersistenceIO.isMissing(error) {
                failure = nil
                return (.default, nil)
            } catch {
                failure = "Couldn't read settings: \(error.localizedDescription). Reload settings before saving changes."
                return (.default, nil)
            }
            do {
                let settings = try JSONDecoder().decode(AppSettings.self, from: data)
                failure = nil
                return (settings, nil)
            } catch {
                let aside = directory.appendingPathComponent("settings.corrupt-\(UUID().uuidString).json")
                do {
                    // Keep the actual bytes before allowing any edit to replace the original.
                    try files.write(data, aside)
                    try files.removeIfPresent(fileURL)
                    failure = nil
                    return (.default, aside)
                } catch {
                    failure = "Couldn't preserve unreadable settings: \(error.localizedDescription). Reload settings before saving changes."
                    return (.default, nil)
                }
            }
        }
    }

    public func save(_ settings: AppSettings) throws {
        try state.error.withLock { failure in
            if let failure { throw SettingsRecoveryError(reason: failure) }
            // Also protect callers that save without loading, or a file that became unreadable after load.
            do { _ = try files.read(fileURL) }
            catch where PersistenceIO.isMissing(error) { }
            catch {
                let reason = "Couldn't read existing settings: \(error.localizedDescription). Reload settings before saving changes."
                failure = reason
                throw SettingsRecoveryError(reason: reason)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try files.write(encoder.encode(settings), fileURL)
        }
    }
}

private struct SettingsRecoveryError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
