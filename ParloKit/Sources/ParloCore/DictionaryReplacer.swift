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
        var result = text
        for (heard, term) in pairs {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
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
