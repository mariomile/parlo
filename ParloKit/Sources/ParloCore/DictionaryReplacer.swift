import Foundation

/// Deterministic "heard as -> write as" replacements, applied before the LLM so they work with cleanup off.
/// A term with its own spelling ("CLAUDE.md", "GitHub") also fixes the case of the term itself, as speech
/// models write it ("Claude.md", "github"). Plain words ("Parlo") don't, so the verb "parlo" stays.
public enum DictionaryReplacer {
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        let pairs = entries
            .flatMap { entry in
                let spelling = hasOwnSpelling(entry.term) ? [entry.term] : []
                return (entry.heardAs + spelling).map { ($0.trimmingCharacters(in: .whitespaces), entry.term) }
            }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        guard !pairs.isEmpty else { return text }
        // One pass over the text, longest phrase first: text a rule wrote is never matched again by another.
        let alternatives = pairs.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let found = text[range]
            let term = pairs.first { $0.0.compare(found, options: .caseInsensitive) == .orderedSame }?.1 ?? String(found)
            result += text[last..<range.lowerBound] + term
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// Capitals after the first letter, digits or symbols: case a speech model won't guess. Also what
    /// CorrectionDetector counts as a term, besides a capitalized first letter.
    static func hasOwnSpelling(_ term: String) -> Bool {
        term.dropFirst().contains(where: \.isUppercase) || term.contains { $0.isNumber || !($0.isLetter || $0 == " ") }
    }
}

extension [DictionaryEntry] {
    /// The terms to write, trimmed, without blanks.
    public var terms: [String] {
        map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
