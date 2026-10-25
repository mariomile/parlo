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
    /// True when a command's original selection was unavailable or still pending. Nil is legacy data.
    public var commandSelectionUnavailable: Bool?
    /// Interrupted/recovered work keeps its text/audio beyond retention limits until it succeeds or is deleted.
    public var recoveryPending: Bool?

    public init(
        id: String, date: Date, duration: Double, kind: Kind, status: Status, text: String? = nil, hasAudio: Bool = true,
        commandSelectionUnavailable: Bool? = nil, recoveryPending: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.kind = kind
        self.status = status
        self.text = text
        self.hasAudio = hasAudio
        self.commandSelectionUnavailable = commandSelectionUnavailable
        self.recoveryPending = recoveryPending
    }

    fileprivate var isProtectedFromRetention: Bool { status == .processing || recoveryPending == true }

    public var isCommand: Bool {
        if case .command = kind { true } else { false }
    }

    public var isFile: Bool {
        if case .file = kind { true } else { false }
    }

    /// The recording is kept, or the transcribed file is still where it was.
    public var canRetry: Bool {
        if isCommand, commandSelectionUnavailable == true { return false }
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
        case id, date, duration, command, status, text, hasAudio, fileName, filePath, selection, commandSelectionUnavailable, recoveryPending
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
        commandSelectionUnavailable = try c.decodeIfPresent(Bool.self, forKey: .commandSelectionUnavailable)
        recoveryPending = try c.decodeIfPresent(Bool.self, forKey: .recoveryPending)
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
        try c.encodeIfPresent(commandSelectionUnavailable, forKey: .commandSelectionUnavailable)
        try c.encodeIfPresent(recoveryPending, forKey: .recoveryPending)
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
/// as 16 kHz mono float WAV files. Active/interrupted work may overflow both limits for recovery.
/// The index is read once; `entries` is what it holds now.
@MainActor @Observable
public final class DictationHistory {
    public let directory: URL
    public let audioLimit: Int
    public let textLimit: Int
    /// Newest first.
    public private(set) var entries: [HistoryEntry]
    /// The index on disk could not be fully read: the first write backs it up and puts orphaned recordings back.
    private var damaged: Bool
    private var indexError: String?
    /// Metadata durability only; deletion/retention errors stay separate in `audioErrors`.
    public var indexSaveError: String? { indexError }
    /// A successful index write must not hide a failed recording removal.
    public private(set) var audioErrors: [String: String] = [:]
    private let files: PersistenceIO
    public var saveError: String? {
        let messages = [indexError].compactMap { $0 } + audioErrors.keys.sorted().compactMap { id in
            audioErrors[id].map { "Recording \(id): \($0)" }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    public convenience init(directory: URL, audioLimit: Int = 20, textLimit: Int = 2000) {
        self.init(directory: directory, audioLimit: audioLimit, textLimit: textLimit, files: PersistenceIO())
    }

    init(directory: URL, audioLimit: Int = 20, textLimit: Int = 2000, files: PersistenceIO) {
        self.directory = directory
        self.audioLimit = max(0, audioLimit)
        self.textLimit = max(0, textLimit)
        self.files = files
        let (read, damaged) = Self.readIndex(directory.appending(path: "history.json"))
        // Audio the index never got to list, because its save failed before a quit, comes back as a failure to retry.
        entries = (read + Self.orphanedRecordings(in: directory, known: Set(read.map(\.id)))).sorted { $0.date > $1.date }
        self.damaged = damaged
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
        samples: [Float], kind: HistoryEntry.Kind, commandSelectionUnavailable: Bool? = nil,
        status: HistoryEntry.Status = .processing, date: Date = .now, recoveryPending: Bool = false
    ) -> (entry: HistoryEntry, audioError: (any Error)?) {
        let id = newID(for: date)
        var audioError: (any Error)?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.write(WAV.encode(samples), audioURL(id))
        } catch {
            audioError = error
        }
        let entry = HistoryEntry(
            id: id, date: date, duration: Audio.seconds(samples.count), kind: kind, status: status, hasAudio: audioError == nil,
            commandSelectionUnavailable: commandSelectionUnavailable, recoveryPending: recoveryPending ? true : nil
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
            if status == .done || status == .nothingHeard { $0.recoveryPending = nil }
        }
    }

    /// Saves the text a command was applied to, so Retry can apply it again.
    public func setSelection(_ id: String, _ selection: String) {
        mutate(id) {
            if $0.isCommand {
                $0.kind = .command(selection: selection)
                $0.commandSelectionUnavailable = false
            }
        }
    }

    public func setSelectionUnavailable(_ id: String, _ unavailable: Bool) {
        mutate(id) { if $0.isCommand { $0.commandSelectionUnavailable = unavailable } }
    }

    /// A recording that can't be removed keeps its entry, even if old metadata says its audio was pruned.
    @discardableResult
    public func delete(_ id: String) -> Bool {
        guard removeAudio(id) else { return false }
        write { $0.removeAll { $0.id == id } }
        return indexError == nil
    }

    public func retryRetention() {
        write { all in pruneAudio(&all) }
    }

    /// Retry a failed index write; all in-memory changes are saved together.
    public func retrySave() {
        guard indexError != nil else { return }
        write { _ in }
    }

    private func removeAudio(_ id: String) -> Bool {
        do { try files.removeIfPresent(audioURL(id)) }
        catch {
            audioErrors[id] = "Couldn't remove audio: \(error.localizedDescription)"
            return false
        }
        audioErrors[id] = nil
        return true
    }

    /// Entries left transcribing by a quit or crash become failures, retryable when they still have audio.
    public func markInterrupted() {
        guard entries.contains(where: { $0.status == .processing }) else { return }
        write { all in
            for i in all.indices where all[i].status == .processing {
                all[i].status = .failed("Interrupted")
                all[i].recoveryPending = true
            }
        }
    }

    public func samples(_ id: String) -> [Float]? {
        (try? Data(contentsOf: audioURL(id))).flatMap(WAV.decode)
    }

    // MARK: - Index

    private func mutate(_ id: String, _ change: (inout HistoryEntry) -> Void) {
        guard entries.contains(where: { $0.id == id }) else { return }
        write(protecting: id) { all in
            if let i = all.firstIndex(where: { $0.id == id }) { change(&all[i]) }
        }
    }

    private func insert(_ entry: HistoryEntry) {
        write(adding: entry.id) { all in
            all.insert(entry, at: 0)
            pruneAudio(&all)
        }
    }

    private func pruneAudio(_ all: inout [HistoryEntry]) {
        while all.filter(\.hasAudio).count > audioLimit {
            // Recovery protection survives later saves, selection flushes, retention retries and restarts.
            guard let i = all.lastIndex(where: { $0.hasAudio && !$0.isProtectedFromRetention && $0.status == .done })
                ?? all.lastIndex(where: { $0.hasAudio && !$0.isProtectedFromRetention }) else { break }
            guard removeAudio(all[i].id) else { break }
            all[i].hasAudio = false
            if all[i].text == nil { all.remove(at: i) }
        }
    }

    private func pruneText(_ all: inout [HistoryEntry], protecting protectedID: String?) {
        // In-flight and interrupted jobs stay outside the quota until recovery succeeds or explicit deletion.
        while all.filter({ !$0.isProtectedFromRetention }).count > textLimit {
            // A just-completed retry may have the oldest recording date. Keep the new result in this
            // write; native delivery keeps it processing until paste/copy has finished.
            guard let i = all.lastIndex(where: { !$0.isProtectedFromRetention && $0.id != protectedID }) else { break }
            guard removeAudio(all[i].id) else { break }
            all.remove(at: i)
        }
    }

    /// Every change goes through here. A save that fails keeps the change in memory for the next one to write.
    /// `newID`: an entry being added, whose audio is already on disk.
    private func write(adding newID: String? = nil, protecting protectedID: String? = nil, _ change: (inout [HistoryEntry]) -> Void) {
        var all = entries
        if damaged { all = recoverDamagedIndex(all, besides: newID) }
        change(&all)
        pruneText(&all, protecting: protectedID ?? newID)
        entries = all
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.write(JSONEncoder().encode(all), indexURL)
            damaged = false
            indexError = nil
        } catch {
            indexError = error.localizedDescription
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
        return (entries + Self.orphanedRecordings(in: directory, known: known)).sorted { $0.date > $1.date }
    }

    private static func orphanedRecordings(in directory: URL, known: Set<String>) -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "wav", !known.contains(id), let ms = Int64(id) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return HistoryEntry(
                id: id, date: Date(timeIntervalSince1970: Double(ms) / 1000), duration: WAV.duration(byteCount: bytes),
                kind: .dictation, status: .failed("Recovered recording"), recoveryPending: true
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
