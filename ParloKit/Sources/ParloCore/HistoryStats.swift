import Foundation

extension HistoryEntry {
    public var wordCount: Int { text.map { $0.split(whereSeparator: \.isWhitespace).count } ?? 0 }
}

/// Totals over finished dictations. Commands and transcribed files are left out: they aren't speech typed for you.
public struct HistoryStats: Equatable, Sendable {
    public static let typingWordsPerMinute = 40.0

    public let dictations: Int
    public let words: Int
    public let speakingSeconds: Double

    public init(_ entries: [HistoryEntry]) {
        let spoken = entries.filter { $0.status == .done && $0.kind == .dictation }
        dictations = spoken.count
        words = spoken.reduce(0) { $0 + $1.wordCount }
        speakingSeconds = spoken.reduce(0) { $0 + $1.duration }
    }

    /// What typing the same words at `typingWordsPerMinute` would have taken, minus the time spent speaking.
    public var timeSavedSeconds: Double {
        max(0, Double(words) / Self.typingWordsPerMinute * 60 - speakingSeconds)
    }
}

public enum HistoryExport {
    /// One Markdown section per entry, newest first as given.
    public static func markdown(_ entries: [HistoryEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Parlo history\n"
        for entry in entries {
            out += "\n## \(formatter.string(from: entry.date)) · \(Int(entry.duration.rounded())) s · \(entry.label)\n\n"
            switch entry.status {
            case .done: out += (entry.text ?? "") + "\n"
            case .processing: out += "_Still transcribing._\n"
            case .nothingHeard: out += "_Nothing heard._\n"
            case let .failed(reason): out += "_Failed: \(reason)_\n"
            }
        }
        return out
    }
}
