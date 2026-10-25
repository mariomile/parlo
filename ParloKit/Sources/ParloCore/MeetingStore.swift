import Foundation
@preconcurrency import AVFoundation

/// Every meeting in its own folder: `meeting.json` with the transcript and notes, and the two recorded
/// tracks, kept for the newest `audioLimit` finished meetings so they can be processed again.
@MainActor @Observable
public final class MeetingStore {
    public let directory: URL
    public let audioLimit: Int
    /// Newest first.
    public private(set) var meetings: [Meeting]
    /// A successful write for another meeting cannot clear these unsaved changes.
    public private(set) var saveErrors: [String: String] = [:]
    public private(set) var deletionErrors: [String: String] = [:]
    public private(set) var retentionErrors: [String: String] = [:]
    /// Unreadable metadata without a recoverable track is a load problem, not an unsaved in-memory result.
    public private(set) var loadErrors: [String: String] = [:]
    private var readError: String?
    private var creationError: String?
    private var needsMetadataBackup: Set<String>
    private let files: PersistenceIO

    /// All outstanding disk failures, including the affected meeting. Kept for existing UI callers.
    public var saveError: String? {
        let messages = [readError, creationError].compactMap { $0 }
            + Set(saveErrors.keys).union(deletionErrors.keys).union(retentionErrors.keys).union(loadErrors.keys).sorted().compactMap { id in
                error(for: id).map { "Meeting \(id): \($0)" }
            }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    public func error(for id: String) -> String? {
        let messages = [saveErrors[id], deletionErrors[id], retentionErrors[id], loadErrors[id]].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    public convenience init(directory: URL, audioLimit: Int = 5) {
        self.init(directory: directory, audioLimit: audioLimit, files: PersistenceIO())
    }

    init(directory: URL, audioLimit: Int = 5, files: PersistenceIO) {
        self.directory = directory
        self.audioLimit = max(0, audioLimit)
        self.files = files
        let loaded = Self.read(directory, files: files)
        meetings = loaded.meetings
        saveErrors = loaded.errors
        loadErrors = loaded.loadErrors
        needsMetadataBackup = loaded.needsBackup
        readError = loaded.readError
    }

    public static var appSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parlo/Meetings", directoryHint: .isDirectory)
    }

    public func trackURL(_ id: String, _ speaker: MeetingTurn.Speaker) -> URL {
        folder(id).appending(path: "\(speaker.rawValue).caf")
    }

    public func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    /// A new meeting being recorded. Older finished meetings beyond `audioLimit` lose their recordings.
    public func create(date: Date = .now) throws -> Meeting {
        var ms = Int64(date.timeIntervalSince1970 * 1000)
        while FileManager.default.fileExists(atPath: folder(String(ms)).path) { ms += 1 }
        let meeting = Meeting(id: String(ms), date: date, status: .recording)
        do {
            try persist(meeting)
            creationError = nil
        } catch {
            creationError = "Couldn't create meeting \(meeting.id): \(error.localizedDescription)"
            throw error
        }
        // The caller must not start capture until the first metadata write is durable.
        meetings.insert(meeting, at: 0)
        pruneAudio()
        return meeting
    }

    public func update(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        save(meetings[i])
    }

    /// Only successful removal (or confirmed absence) makes the row disappear. The caller can retry.
    @discardableResult
    public func delete(_ id: String) -> Bool {
        do { try files.removeIfPresent(folder(id)) }
        catch {
            deletionErrors[id] = "Couldn't delete the recording: \(error.localizedDescription)"
            return false
        }
        meetings.removeAll { $0.id == id }
        saveErrors[id] = nil
        deletionErrors[id] = nil
        retentionErrors[id] = nil
        loadErrors[id] = nil
        needsMetadataBackup.remove(id)
        return true
    }

    /// Retry all dirty metadata without requiring the user to recreate a transcript or notes.
    public func retryFailedSaves() {
        for id in saveErrors.keys.sorted() {
            if let meeting = meeting(id) { save(meeting) }
        }
    }

    /// A failed retention removal leaves its recording listed and can be retried independently.
    public func retryRetention() {
        pruneAudio()
    }

    /// Meetings left recording or processing by a quit or crash become failures, to be processed again.
    public func markInterrupted() {
        for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
            update(meeting.id) { $0.status = .failed("Interrupted") }
        }
    }

    // MARK: - Disk

    private func folder(_ id: String) -> URL { directory.appending(path: id, directoryHint: .isDirectory) }

    private func save(_ meeting: Meeting) {
        do {
            try persist(meeting)
            saveErrors[meeting.id] = nil
        } catch {
            saveErrors[meeting.id] = "Unsaved changes: \(error.localizedDescription)"
        }
    }

    private func persist(_ meeting: Meeting) throws {
        let metadata = folder(meeting.id).appending(path: "meeting.json")
        try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true)
        if needsMetadataBackup.contains(meeting.id) {
            let original: Data?
            do { original = try files.read(metadata) }
            catch where PersistenceIO.isMissing(error) { original = nil }
            if let original {
                try files.write(original, folder(meeting.id).appending(path: "meeting.damaged-\(UUID().uuidString).json"))
            }
            // An unreadable original cannot be replaced until its bytes have been preserved.
            needsMetadataBackup.remove(meeting.id)
        }
        try files.write(JSONEncoder().encode(meeting), metadata)
    }

    /// Failed, incomplete and unsaved meetings keep their recordings for recovery.
    private func pruneAudio() {
        let finished = meetings.filter {
            $0.hasAudio && $0.status == .done && $0.warnings.isEmpty && saveErrors[$0.id] == nil && deletionErrors[$0.id] == nil
        }
        for meeting in finished.dropFirst(audioLimit) {
            do {
                for speaker in [MeetingTurn.Speaker.me, .them] { try files.removeIfPresent(trackURL(meeting.id, speaker)) }
            } catch {
                retentionErrors[meeting.id] = "Couldn't remove older audio: \(error.localizedDescription)"
                continue
            }
            retentionErrors[meeting.id] = nil
            update(meeting.id) { $0.hasAudio = false }
        }
    }

    private struct Loaded {
        var meetings: [Meeting] = []
        var errors: [String: String] = [:]
        var loadErrors: [String: String] = [:]
        var needsBackup: Set<String> = []
        var readError: String?
    }

    /// Recovery only inspects files. Original metadata and CAF bytes remain untouched until an explicit save.
    private static func read(_ directory: URL, files: PersistenceIO) -> Loaded {
        var loaded = Loaded()
        let folders: [URL]
        do { folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) }
        catch where PersistenceIO.isMissing(error) { return loaded }
        catch {
            loaded.readError = "Couldn't read meetings: \(error.localizedDescription)"
            return loaded
        }
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let id = folder.lastPathComponent
            do {
                let meeting = try JSONDecoder().decode(Meeting.self, from: files.read(folder.appending(path: "meeting.json")))
                guard meeting.id == id else { throw CocoaError(.fileReadCorruptFile) }
                loaded.meetings.append(meeting)
            } catch {
                let missing = PersistenceIO.isMissing(error)
                let reason = missing ? "Meeting metadata is missing" : "Couldn't read meeting metadata: \(error.localizedDescription)"
                // Opening the CAF checks its header and frame length, without loading an entire meeting into RAM.
                let speakers = [MeetingTurn.Speaker.me, .them]
                let tracks = speakers.compactMap { speaker -> (MeetingTurn.Speaker, Double)? in
                    let url = folder.appending(path: "\(speaker.rawValue).caf")
                    guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
                    return (speaker, Double(file.length) / file.fileFormat.sampleRate)
                }
                guard let duration = tracks.map({ $0.1 }).max() else {
                    if !missing { loaded.loadErrors[id] = reason }
                    continue
                }
                let date = Int64(id).map { Date(timeIntervalSince1970: Double($0) / 1000) }
                    ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let missingTracks = speakers.filter { speaker in !tracks.contains { $0.0 == speaker } }
                    .map { "\($0.label): No recoverable audio in this track. This recovered meeting may be incomplete." }
                loaded.meetings.append(Meeting(
                    id: id, date: date, duration: duration, status: .failed("Recovered recording: \(reason)"),
                    captureWarnings: missingTracks.isEmpty ? nil : missingTracks
                ))
                loaded.errors[id] = "Recovered recording; metadata needs saving. \(reason)"
                if !missing { loaded.needsBackup.insert(id) }
            }
        }
        loaded.meetings.sort { $0.date > $1.date }
        return loaded
    }
}
