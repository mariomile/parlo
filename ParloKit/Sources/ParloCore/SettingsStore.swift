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

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            let ts = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("settings.corrupt-\(ts).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return .default
        }
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
