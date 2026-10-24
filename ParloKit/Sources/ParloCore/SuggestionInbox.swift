import Foundation

/// Words the user fixed right after a paste, waiting to be added to the dictionary or dismissed.
public struct SuggestionInbox: Equatable, Sendable {
    /// Newest first.
    public private(set) var pending: [DictionaryEntry] = []
    /// Terms the user said no to, not offered again until Parlo restarts.
    private var dismissed: Set<String> = []

    public init() {}

    /// Adds `entry` unless its term is already in `dictionary`, already offered, or dismissed. True when added.
    public mutating func offer(_ entry: DictionaryEntry, dictionary: [DictionaryEntry]) -> Bool {
        let term = entry.term.lowercased()
        let known = (dictionary + pending).map { $0.term.lowercased() }
        guard !known.contains(term), !dismissed.contains(term) else { return false }
        pending.insert(entry, at: 0)
        return true
    }

    /// The entry was accepted: it leaves the inbox.
    public mutating func remove(_ entry: DictionaryEntry) {
        pending.removeAll { $0.id == entry.id }
    }

    public mutating func dismiss(_ entry: DictionaryEntry) {
        remove(entry)
        dismissed.insert(entry.term.lowercased())
    }
}
