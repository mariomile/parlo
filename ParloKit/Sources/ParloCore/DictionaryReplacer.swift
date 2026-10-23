import Foundation

/// Deterministic "heard as -> write as" replacements, applied before the LLM so they work with cleanup off.
public enum DictionaryReplacer {
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        let pairs = entries
            .flatMap { entry in entry.heardAs.map { ($0.trimmingCharacters(in: .whitespaces), entry.term) } }
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
}

extension [DictionaryEntry] {
    /// The terms to write, trimmed, without blanks.
    public var terms: [String] {
        map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
