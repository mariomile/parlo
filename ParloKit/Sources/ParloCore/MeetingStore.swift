import Foundation

/// Every meeting in its own folder: `meeting.json` with the transcript and notes, and the two recorded
/// tracks, kept for the newest `audioLimit` finished meetings so they can be processed again.
@MainActor @Observable
public final class MeetingStore {
    public let directory: URL
    public let audioLimit: Int
    /// Newest first.
    public private(set) var meetings: [Meeting]
    /// Why the last save failed; nil once one succeeds.
    public private(set) var saveError: String?

    public init(directory: URL, audioLimit: Int = 5) {
        self.directory = directory
        self.audioLimit = audioLimit
        meetings = Self.read(directory)
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
        try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true)
        meetings.insert(meeting, at: 0)
        save(meeting)
        pruneAudio()
        return meeting
    }

    public func update(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        save(meetings[i])
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        meetings.removeAll { $0.id == id }
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
            try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: folder(meeting.id).appending(path: "meeting.json"), options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Failed meetings keep their recordings however old: those are the ones still worth processing again.
    private func pruneAudio() {
        let finished = meetings.filter { $0.hasAudio && $0.status == .done }
        for meeting in finished.dropFirst(audioLimit) {
            for speaker in [MeetingTurn.Speaker.me, .them] { try? FileManager.default.removeItem(at: trackURL(meeting.id, speaker)) }
            update(meeting.id) { $0.hasAudio = false }
        }
    }

    private static func read(_ directory: URL) -> [Meeting] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appending(path: "meeting.json"))).flatMap { try? JSONDecoder().decode(Meeting.self, from: $0) }
        }
        .sorted { $0.date > $1.date }
    }
}
