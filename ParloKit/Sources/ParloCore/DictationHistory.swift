import Foundation

/// One dictation (or transcribed file) as it was recorded, kept so a failed transcription or a lost paste is never unrecoverable.
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
    /// False once the audio was pruned (or for a transcribed file): the entry keeps its text but can't be retried.
    public var hasAudio: Bool
    /// Set for entries made by transcribing an audio file.
    public let fileName: String?
    /// The text a command was applied to, so Retry can apply it again.
    public var selection: String?

    public init(
        id: String, date: Date, duration: Double, command: Bool, status: Status, text: String? = nil,
        hasAudio: Bool = true, fileName: String? = nil, selection: String? = nil
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.command = command
        self.status = status
        self.text = text
        self.hasAudio = hasAudio
        self.fileName = fileName
        self.selection = selection
    }

    /// Index files written before text-only entries existed have no `hasAudio`: all of those kept their audio.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(Double.self, forKey: .duration)
        command = try c.decode(Bool.self, forKey: .command)
        status = try c.decode(Status.self, forKey: .status)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        selection = try c.decodeIfPresent(String.self, forKey: .selection)
    }
}

/// Every dictation's text (up to `textLimit`) in a JSON index, plus the audio of the newest `audioLimit`
/// as 16 kHz mono float WAV files, for retry.
public final class DictationHistory: Sendable {
    public let directory: URL
    public let audioLimit: Int
    public let textLimit: Int

    public init(directory: URL, audioLimit: Int = 20, textLimit: Int = 2000) {
        self.directory = directory
        self.audioLimit = audioLimit
        self.textLimit = textLimit
    }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parlo/History", directoryHint: .isDirectory)
    }

    private var indexURL: URL { directory.appending(path: "history.json") }

    public func audioURL(_ id: String) -> URL { directory.appending(path: "\(id).wav") }

    /// Newest first. Never touches the index, so a damaged one is left for the next write to back up.
    public func entries() -> [HistoryEntry] { readIndex().entries }

    /// Writes the audio before anything else touches it, then prunes old audio and old entries.
    @discardableResult
    public func add(samples: [Float], command: Bool, date: Date = .now) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = Self.id(for: date)
        try WAV.encode(samples).write(to: audioURL(id), options: .atomic)
        let entry = HistoryEntry(
            id: id, date: date, duration: Double(samples.count) / 16_000, command: command, status: .processing
        )
        try insert(entry)
        return entry
    }

    /// A transcribed audio file: text only, the file itself stays where it is.
    @discardableResult
    public func addFile(name: String, duration: Double, date: Date = .now) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = HistoryEntry(
            id: Self.id(for: date), date: date, duration: duration, command: false, status: .processing,
            hasAudio: false, fileName: name
        )
        try insert(entry)
        return entry
    }

    public func update(_ id: String, status: HistoryEntry.Status, text: String?, selection: String? = nil) {
        var all = writableEntries()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].status = status
        if let text { all[i].text = text }
        if let selection { all[i].selection = selection }
        try? save(all)
    }

    public func delete(_ id: String) {
        var all = writableEntries()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: audioURL(id))
        all.remove(at: i)
        try? save(all)
    }

    /// Entries left transcribing by a quit or crash become failures, retryable when they still have audio.
    public func markInterrupted() {
        var all = readIndex().entries
        guard all.contains(where: { $0.status == .processing }) else { return }
        all = writableEntries()
        for i in all.indices where all[i].status == .processing { all[i].status = .failed("Interrupted") }
        try? save(all)
    }

    public func samples(_ id: String) -> [Float]? {
        (try? Data(contentsOf: audioURL(id))).flatMap(WAV.decode)
    }

    // MARK: - Index

    private func insert(_ entry: HistoryEntry) throws {
        var all = [entry] + writableEntries(besides: entry.id)
        while all.filter(\.hasAudio).count > audioLimit {
            // Recordings that never produced text are the ones worth keeping longest.
            let i = all.lastIndex { $0.hasAudio && $0.status == .done } ?? all.lastIndex { $0.hasAudio }!
            try? FileManager.default.removeItem(at: audioURL(all[i].id))
            all[i].hasAudio = false
            if all[i].text == nil { all.remove(at: i) }
        }
        while all.count > textLimit {
            try? FileManager.default.removeItem(at: audioURL(all.removeLast().id))
        }
        try save(all)
    }

    private func save(_ all: [HistoryEntry]) throws {
        try JSONEncoder().encode(all).write(to: indexURL, options: .atomic)
    }

    /// One malformed entry must not take the others with it.
    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: any Decoder) { entry = try? HistoryEntry(from: decoder) }
    }

    /// `damaged`: the index could not be read as a whole, or some entries in it could not be decoded.
    private func readIndex() -> (entries: [HistoryEntry], damaged: Bool) {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return ([], false) }
        guard let data = try? Data(contentsOf: indexURL), let items = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return ([], true) }
        let entries = items.compactMap(\.entry)
        return (entries, entries.count != items.count)
    }

    /// The entries a write starts from. A damaged index is copied aside first, and recordings it no longer
    /// lists are put back as failed entries, so saving never orphans audio. `newID` is an entry
    /// being added, whose audio is already on disk.
    private func writableEntries(besides newID: String? = nil) -> [HistoryEntry] {
        let (entries, damaged) = readIndex()
        guard damaged else { return entries }
        let backup = directory.appending(path: "history.damaged-\(Self.id(for: .now)).json")
        try? FileManager.default.copyItem(at: indexURL, to: backup)
        return (entries + orphanedRecordings(known: Set(entries.map(\.id) + [newID].compactMap { $0 }))).sorted { $0.date > $1.date }
    }

    private func orphanedRecordings(known: Set<String>) -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "wav", !known.contains(id), let ms = Int64(id) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 44
            return HistoryEntry(
                id: id, date: Date(timeIntervalSince1970: Double(ms) / 1000),
                duration: Double(max(bytes - 44, 0) / 4) / 16_000, command: false,
                status: .failed("Recovered from a damaged history file")
            )
        }
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
