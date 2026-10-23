import Foundation

/// Notices when the user fixes a word Parlo just pasted ("Cloud MD" → "CLAUDE.md") and turns the fix
/// into a dictionary suggestion. Only small, similar-sounding edits count: rewrites and style changes don't.
public enum CorrectionDetector {
    static let maxWords = 3
    static let minSimilarity = 0.5

    /// `before`: the text field right after pasting `pasted`; `after`: the same field a little later.
    public static func suggestion(pasted: String, before: String, after: String) -> DictionaryEntry? {
        let old = Array(before), new = Array(after)
        guard old != new, let pastedRange = before.range(of: pasted, options: .backwards) else { return nil }
        let pastedStart = before.distance(from: before.startIndex, to: pastedRange.lowerBound)
        let pastedEnd = pastedStart + pasted.count

        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        guard prefix >= pastedStart, old.count - suffix <= pastedEnd else { return nil }
        // Text only added or only removed counts when it's inside a word ("Clade" → "Claude"); between
        // words it's the user writing on, not fixing what was heard.
        if old.count - suffix == prefix || new.count - suffix == prefix {
            let inside = prefix > 0 && prefix < old.count && !old[prefix - 1].isWhitespace && !old[prefix].isWhitespace
            guard inside else { return nil }
        }

        let heard = word(in: old, from: prefix, to: old.count - suffix)
        let term = word(in: new, from: prefix, to: new.count - suffix)
        guard !heard.isEmpty, !term.isEmpty, heard != term,
              heard.split(separator: " ").count <= maxWords + 1, term.split(separator: " ").count <= maxWords,
              similarity(heard, term) >= minSimilarity
        else { return nil }
        return DictionaryEntry(term: term, heardAs: heard.lowercased() == term.lowercased() ? [] : [heard])
    }

    /// The changed span `start..<end` widened to whole words, without surrounding punctuation.
    private static func word(in chars: [Character], from start: Int, to end: Int) -> String {
        var lo = start, hi = max(start, end)
        while lo > 0, !chars[lo - 1].isWhitespace { lo -= 1 }
        while hi < chars.count, !chars[hi].isWhitespace { hi += 1 }
        return String(chars[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// 1 minus the edit distance between the letters of `a` and `b`, relative to the longer one.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        let distance = x.isEmpty ? y.count : row[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }
}
