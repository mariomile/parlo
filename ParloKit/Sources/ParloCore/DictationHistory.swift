import Foundation
import Observation

/// One dictation, command or transcribed file as it was recorded, kept so a failed transcription or a lost paste is never unrecoverable.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case dictation
        /// `selection`: the text the command was applied to, so Retry can apply it again.
        case command(selection: String?)
        /// `path`: where the file was, so Retry can transcribe it again while it is still there.
        case file(name: String, path: String?)
    }

    public enum Status: Codable, Equatable, Sendable {
        case processing
        case done
        case nothingHeard
        case failed(String)
    }

    public let id: String
    public let date: Date
    public let duration: Double
    public var kind: Kind
    public var status: Status
    public var text: String?
    /// False once the audio was pruned (or for a transcribed file): the entry keeps its text but can't be retried.
    public var hasAudio: Bool

    public init(
        id: String, date: Date, duration: Double, kind: Kind, status: Status, text: String? = nil, hasAudio: Bool = true
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.kind = kind
        self.status = status
        self.text = text
        self.hasAudio = hasAudio
    }

    public var isCommand: Bool {
        if case .command = kind { true } else { false }
    }

    public var isFile: Bool {
        if case .file = kind { true } else { false }
    }

    /// The recording is kept, or the transcribed file is still where it was.
    public var canRetry: Bool {
        guard case let .file(_, path) = kind else { return hasAudio }
        return path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    /// "Dictation", "Command" or "File: memo.m4a".
    public var label: String {
        switch kind {
        case .dictation: "Dictation"
        case .command: "Command"
        case let .file(name, _): "File: \(name)"
        }
    }

    // The index keeps the flat keys it always had, so history written by any version still loads.
    private enum CodingKeys: String, CodingKey {
        case id, date, duration, command, status, text, hasAudio, fileName, filePath, selection
    }

    /// Index files written before text-only entries existed have no `hasAudio`: all of those kept their audio.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(Double.self, forKey: .duration)
        status = try c.decode(Status.self, forKey: .status)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        if let name = try c.decodeIfPresent(String.self, forKey: .fileName) {
            kind = .file(name: name, path: try c.decodeIfPresent(String.self, forKey: .filePath))
        } else if try c.decode(Bool.self, forKey: .command) {
            kind = .command(selection: try c.decodeIfPresent(String.self, forKey: .selection))
        } else {
            kind = .dictation
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(duration, forKey: .duration)
        try c.encode(isCommand, forKey: .command)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(hasAudio, forKey: .hasAudio)
        switch kind {
        case .dictation: break
        case let .command(selection): try c.encodeIfPresent(selection, forKey: .selection)
        case let .file(name, path):
            try c.encode(name, forKey: .fileName)
            try c.encodeIfPresent(path, forKey: .filePath)
        }
    }
}

/// Every dictation's text (up to `textLimit`) in a JSON index, plus the audio of the newest `audioLimit`
/// as 16 kHz mono float WAV files, for retry. The index is read once; `entries` is what it holds now.
@MainActor @Observable
public final class DictationHistory {
    public let directory: URL
    public let audioLimit: Int
    public let textLimit: Int
    /// Newest first.
    public private(set) var entries: [HistoryEntry]
    /// The index on disk could not be fully read: the first write backs it up and puts orphaned recordings back.
    private var damaged: Bool
    /// Why the last save of the index failed; nil once one succeeds. Changes stay in memory meanwhile.
    public private(set) var saveError: String?

    public init(directory: URL, audioLimit: Int = 20, textLimit: Int = 2000) {
        self.directory = directory
        self.audioLimit = audioLimit
        self.textLimit = textLimit
        (entries, damaged) = Self.readIndex(directory.appending(path: "history.json"))
    }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parlo/History", directoryHint: .isDirectory)
    }

    private var indexURL: URL { directory.appending(path: "history.json") }

    public func audioURL(_ id: String) -> URL { directory.appending(path: "\(id).wav") }

    /// Writes the audio before anything else touches it, then prunes old audio and old entries.
    /// The entry is kept even when the disk refuses the audio: it just can't be retried. `audioError` says why.
    @discardableResult
    public func add(
        samples: [Float], kind: HistoryEntry.Kind, status: HistoryEntry.Status = .processing, date: Date = .now
    ) -> (entry: HistoryEntry, audioError: (any Error)?) {
        let id = newID(for: date)
        var audioError: (any Error)?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WAV.encode(samples).write(to: audioURL(id), options: .atomic)
        } catch {
            audioError = error
        }
        let entry = HistoryEntry(
            id: id, date: date, duration: Audio.seconds(samples.count), kind: kind, status: status, hasAudio: audioError == nil
        )
        insert(entry)
        return (entry, audioError)
    }

    /// A transcribed audio file: text only, the file itself stays where it is.
    @discardableResult
    public func addFile(_ url: URL, duration: Double, date: Date = .now) -> HistoryEntry {
        let entry = HistoryEntry(
            id: newID(for: date), date: date, duration: duration, kind: .file(name: url.lastPathComponent, path: url.path),
            status: .processing,
            hasAudio: false
        )
        insert(entry)
        return entry
    }

    public func update(_ id: String, status: HistoryEntry.Status, text: String?) {
        mutate(id) {
            $0.status = status
            if let text { $0.text = text }
        }
    }

    /// Saves the text a command was applied to, so Retry can apply it again.
    public func setSelection(_ id: String, _ selection: String) {
        mutate(id) { if $0.isCommand { $0.kind = .command(selection: selection) } }
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: audioURL(id))
        write { $0.removeAll { $0.id == id } }
    }

    /// Entries left transcribing by a quit or crash become failures, retryable when they still have audio.
    public func markInterrupted() {
        guard entries.contains(where: { $0.status == .processing }) else { return }
        write { all in
            for i in all.indices where all[i].status == .processing { all[i].status = .failed("Interrupted") }
        }
    }

    public func samples(_ id: String) -> [Float]? {
        (try? Data(contentsOf: audioURL(id))).flatMap(WAV.decode)
    }

    // MARK: - Index

    private func mutate(_ id: String, _ change: (inout HistoryEntry) -> Void) {
        guard entries.contains(where: { $0.id == id }) else { return }
        write { all in
            if let i = all.firstIndex(where: { $0.id == id }) { change(&all[i]) }
        }
    }

    private func insert(_ entry: HistoryEntry) {
        write(adding: entry.id) { all in
            all.insert(entry, at: 0)
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
        }
    }

    /// Every change goes through here. A save that fails keeps the change in memory for the next one to write.
    /// `newID`: an entry being added, whose audio is already on disk.
    private func write(adding newID: String? = nil, _ change: (inout [HistoryEntry]) -> Void) {
        var all = entries
        if damaged { all = recoverDamagedIndex(all, besides: newID) }
        change(&all)
        entries = all
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: indexURL, options: .atomic)
            damaged = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// One malformed entry must not take the others with it.
    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: any Decoder) { entry = try? HistoryEntry(from: decoder) }
    }

    /// `damaged`: the index could not be read as a whole, or some entries in it could not be decoded.
    private static func readIndex(_ url: URL) -> (entries: [HistoryEntry], damaged: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        guard let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return ([], true) }
        let entries = items.compactMap(\.entry)
        return (entries, entries.count != items.count)
    }

    /// Copies the damaged index aside, and puts back recordings it no longer lists as failed entries,
    /// so saving never orphans audio.
    private func recoverDamagedIndex(_ entries: [HistoryEntry], besides newID: String?) -> [HistoryEntry] {
        let backup = directory.appending(path: "history.damaged-\(Self.id(for: .now)).json")
        try? FileManager.default.copyItem(at: indexURL, to: backup)
        let known = Set(entries.map(\.id) + [newID].compactMap { $0 })
        return (entries + orphanedRecordings(known: known)).sorted { $0.date > $1.date }
    }

    private func orphanedRecordings(known: Set<String>) -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "wav", !known.contains(id), let ms = Int64(id) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return HistoryEntry(
                id: id, date: Date(timeIntervalSince1970: Double(ms) / 1000), duration: WAV.duration(byteCount: bytes),
                kind: .dictation, status: .failed("Recovered from a damaged history file")
            )
        }
    }

    private static func id(for date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }

    /// The entry's millisecond timestamp, moved past ids already taken: files added in the same millisecond,
    /// or a clock set back onto an older recording, must never share an entry or overwrite its audio.
    private func newID(for date: Date) -> String {
        var ms = Int64(date.timeIntervalSince1970 * 1000)
        let taken = Set(entries.map(\.id))
        while taken.contains(String(ms)) || FileManager.default.fileExists(atPath: audioURL(String(ms)).path) { ms += 1 }
        return String(ms)
    }
}

/// 16 kHz mono 32-bit float WAV, readable by QuickTime and any audio tool.
enum WAV {
    static let sampleRate = UInt32(Audio.sampleRate)

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

    static let headerSize = 44

    /// Seconds of audio in a file of `byteCount` bytes written by `encode`.
    static func duration(byteCount: Int) -> Double {
        Audio.seconds(max(byteCount - headerSize, 0) / MemoryLayout<Float>.size)
    }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count >= headerSize, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        return data.dropFirst(headerSize).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
