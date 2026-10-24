import Foundation

/// Notices when the user fixes a word Parlo just pasted ("Cloud MD" → "CLAUDE.md") and turns the fix
/// into a dictionary suggestion. Only small, similar-sounding edits to term-like words count: rewrites,
/// style changes, grammar fixes ("andato" → "andata") and number or day changes don't.
public enum CorrectionDetector {
    static let maxWords = 3
    static let minSimilarity = 0.5
    static let minLetters = 4

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
        let heardWords = heard.split(separator: " ").count, termWords = term.split(separator: " ").count
        guard !heard.isEmpty, !term.isEmpty, heard != term,
              heardWords <= maxWords + 1, termWords <= maxWords,
              letters(heard).count >= minLetters, letters(term).count >= minLetters,
              similarity(heard, term) >= minSimilarity
        else { return nil }
        let caseOnly = heard.lowercased() == term.lowercased()
        if !caseOnly {
            // An ordinary lowercase word replaced by another is a wording fix, not a misheard term.
            let termLike = term.contains { $0.isUppercase || $0.isNumber || !($0.isLetter || $0 == " ") }
            guard termLike || heardWords != termWords else { return nil }
            guard !onlyEndingDiffers(heard, term) else { return nil }
        }
        return DictionaryEntry(term: term, heardAs: caseOnly ? [] : [heard])
    }

    /// Whether `now`, a later reading of the field, still looks like the user editing the paste: the
    /// text before and after it is unchanged. Sending a message or clearing the field ends the edit.
    public static func isEditing(pasted: String, before: String, now: String) -> Bool {
        guard let range = before.range(of: pasted, options: .backwards) else { return false }
        let head = before[..<range.lowerBound], tail = before[range.upperBound...]
        return now.count > head.count + tail.count && now.hasPrefix(head) && now.hasSuffix(tail)
    }

    /// "Marco" → "Mario", "andato" → "andata": only the last letter or two changed, as in inflection.
    private static func onlyEndingDiffers(_ a: String, _ b: String) -> Bool {
        let x = letters(a), y = letters(b)
        var shared = 0
        while shared < min(x.count, y.count), x[shared] == y[shared] { shared += 1 }
        return shared >= 3 && x.count - shared <= 2 && y.count - shared <= 2
    }

    private static func letters(_ s: String) -> [Character] {
        Array(s.lowercased().filter(\.isLetter))
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
