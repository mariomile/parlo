import Foundation

/// Reads and writes `settings.json`. A corrupt file is moved aside so the user's data is never silently overwritten.
public struct SettingsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Parlo", isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// The saved settings. When the file is not JSON at all it is moved to `quarantined` and the defaults
    /// come back, so the app can tell the user instead of silently starting over.
    public func load() -> (settings: AppSettings, quarantined: URL?) {
        guard let data = try? Data(contentsOf: fileURL) else { return (.default, nil) }
        do {
            return (try JSONDecoder().decode(AppSettings.self, from: data), nil)
        } catch {
            let ts = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("settings.corrupt-\(ts).json")
            // The bytes already read are kept even when the file can't be moved.
            let kept = (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
                || (try? data.write(to: aside, options: .atomic)) != nil
            return (.default, kept ? aside : nil)
        }
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
