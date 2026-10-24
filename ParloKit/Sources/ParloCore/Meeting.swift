import Foundation

/// One stretch of speech in a meeting. "Me" is the microphone, "Them" is everything the Mac played.
public struct MeetingTurn: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable {
        case me, them

        public var label: String {
            switch self {
            case .me: "Me"
            case .them: "Them"
            }
        }
    }

    public let speaker: Speaker
    /// Seconds from the start of the meeting.
    public let start: Double
    public let end: Double
    public let text: String

    public init(speaker: Speaker, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A recorded meeting: both tracks' transcript, interleaved, and the notes written from it.
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case recording
        case processing
        case done
        case failed(String)
    }

    public let id: String
    public let date: Date
    public var duration: Double
    public var title: String?
    public var status: Status
    public var turns: [MeetingTurn]
    public var notes: String?
    /// Why the notes couldn't be written. The transcript is kept either way.
    public var notesError: String?
    /// Nothing at all came from the Mac's audio, usually because System Audio Recording isn't allowed.
    public var othersSilent: Bool
    /// False once the recordings were pruned: the meeting keeps its transcript and notes but can't be redone.
    public var hasAudio: Bool

    public init(
        id: String, date: Date, duration: Double = 0, title: String? = nil, status: Status, turns: [MeetingTurn] = [],
        notes: String? = nil, notesError: String? = nil, othersSilent: Bool = false, hasAudio: Bool = true
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.title = title
        self.status = status
        self.turns = turns
        self.notes = notes
        self.notesError = notesError
        self.othersSilent = othersSilent
        self.hasAudio = hasAudio
    }

    public var displayTitle: String {
        title ?? "Meeting, \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Notes and transcript as one Markdown document.
    public var markdown: String {
        var out = "# \(displayTitle)\n\n"
        out += "\(date.formatted(date: .complete, time: .shortened)) · \(MeetingTranscript.timestamp(duration))\n\n"
        if let notes { out += notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
        out += "## Transcript\n\n"
        out += turns.map { "**[\(MeetingTranscript.timestamp($0.start))] \($0.speaker.label):** \($0.text)" }
            .joined(separator: "\n\n")
        return out + "\n"
    }
}

public enum MeetingTranscript {
    /// Both tracks in order of time, without the other side's words that the microphone picked up
    /// from the speakers.
    public static func merge(me: [MeetingTurn], them: [MeetingTurn]) -> [MeetingTurn] {
        let mine = me.filter { !isEcho($0, of: them) }
        return (mine + them).sorted { ($0.start, $0.speaker == .them ? 1 : 0) < ($1.start, $1.speaker == .them ? 1 : 0) }
    }

    /// A turn of mine is an echo when most of it happens while they speak, in turns that contain most of its
    /// words: the speakers reach the microphone at once. A reply that reuses their words comes after them.
    /// Short turns ("yes", "right") are always kept: too few words to tell.
    public static func isEcho(_ turn: MeetingTurn, of them: [MeetingTurn]) -> Bool {
        guard words(turn.text).count >= 4 else { return false }
        let mine = Set(contentWords(turn.text))
        guard !mine.isEmpty else { return false }
        let overlapping = them.filter { $0.start < turn.end && turn.start < $0.end }
        let together = overlapping.reduce(0) { $0 + min($1.end, turn.end) - max($1.start, turn.start) }
        guard together >= (turn.end - turn.start) / 2 else { return false }
        let theirs = Set(overlapping.flatMap { contentWords($0.text) })
        let shared = mine.intersection(theirs).count
        return shared >= 2 && Double(shared) / Double(mine.count) >= 0.5
    }

    /// One line per turn, "[mm:ss] Me: …", as the notes are written from.
    public static func lines(_ turns: [MeetingTurn]) -> [String] {
        turns.map { "[\(timestamp($0.start))] \($0.speaker.label): \($0.text)" }
    }

    /// "4:05" or "1:02:09".
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words long enough to carry meaning in any language: "the", "di", "und" don't count as a match.
    static func contentWords(_ text: String) -> [String] {
        words(text).filter { $0.count >= 4 }
    }
}
