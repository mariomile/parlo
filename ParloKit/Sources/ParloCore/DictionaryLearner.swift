import Foundation

/// Saves a word the user fixed right after a paste straight into the dictionary, so the next
/// dictation spells it their way. No confirmation: fixing the word is the confirmation.
public enum DictionaryLearner {
    public enum Outcome: Equatable, Sendable {
        /// A new entry for `term`.
        case added(term: String)
        /// `term` was already in the dictionary; the misheard spelling now maps to it too.
        case extended(term: String)
        /// Nothing new to save.
        case known
    }

    /// Merges `entry` into `dictionary`, matching terms and misheard spellings ignoring case.
    public static func learn(_ entry: DictionaryEntry, into dictionary: inout [DictionaryEntry]) -> Outcome {
        let term = entry.term.lowercased()
        guard let index = dictionary.firstIndex(where: { $0.term.lowercased() == term }) else {
            dictionary.append(entry)
            return .added(term: entry.term)
        }
        let known = Set(dictionary[index].heardAs.map { $0.lowercased() })
        let new = entry.heardAs.filter { !known.contains($0.lowercased()) && $0.lowercased() != term }
        guard !new.isEmpty else { return .known }
        dictionary[index].heardAs.append(contentsOf: new)
        return .extended(term: dictionary[index].term)
    }
}
