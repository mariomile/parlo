import Foundation

/// One dictation as it was recorded, kept so a failed transcription or a lost paste is never unrecoverable.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case processing
        case done
        case nothingHeard
        case failed(String)
    }

    public let id: String
    public let date: Date
    public let duration: Double
    public let command: Bool
    public var status: Status
    public var text: String?
    /// The text a command was applied to, so Retry can apply it again.
    public var selection: String?
}

/// The last `limit` recordings on disk: 16 kHz mono float WAV plus a JSON index.
public final class DictationHistory: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 20) {
        self.directory = directory
        self.limit = limit
    }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parlo/History", directoryHint: .isDirectory)
    }

    private var indexURL: URL { directory.appending(path: "history.json") }

    public func audioURL(_ id: String) -> URL { directory.appending(path: "\(id).wav") }

    /// Newest first.
    public func entries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Writes the audio before anything else touches it, then drops the oldest entries past `limit`.
    @discardableResult
    public func add(samples: [Float], command: Bool, date: Date = .now) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.id(for: date)
        try WAV.encode(samples).write(to: audioURL(id), options: .atomic)
        let entry = HistoryEntry(
            id: id, date: date, duration: Double(samples.count) / 16_000, command: command, status: .processing
        )
        var all = [entry] + entries()
        while all.count > limit {
            // Recordings that never produced text are the ones worth keeping longest.
            let i = all.lastIndex { $0.status == .done } ?? all.count - 1
            try? FileManager.default.removeItem(at: audioURL(all[i].id))
            all.remove(at: i)
        }
        try save(all)
        return entry
    }

    public func update(_ id: String, status: HistoryEntry.Status, text: String?, selection: String? = nil) {
        var all = entries()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].status = status
        if let text { all[i].text = text }
        if let selection { all[i].selection = selection }
        try? save(all)
    }

    /// Entries left transcribing by a quit or crash become retryable failures.
    public func markInterrupted() {
        var all = entries()
        guard all.contains(where: { $0.status == .processing }) else { return }
        for i in all.indices where all[i].status == .processing { all[i].status = .failed("Interrupted") }
        try? save(all)
    }

    public func samples(_ id: String) -> [Float]? {
        (try? Data(contentsOf: audioURL(id))).flatMap(WAV.decode)
    }

    private func save(_ all: [HistoryEntry]) throws {
        try JSONEncoder().encode(all).write(to: indexURL, options: .atomic)
    }

    private static func id(for date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}

/// 16 kHz mono 32-bit float WAV, readable by QuickTime and any audio tool.
enum WAV {
    static let sampleRate: UInt32 = 16_000

    static func encode(_ samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 4)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3) // IEEE float
        u16(1); u32(sampleRate); u32(sampleRate * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
