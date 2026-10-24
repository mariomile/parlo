import Foundation

/// Swaps spoken snippet triggers for opaque tokens (`⟦S1⟧`) so the LLM can't rewrite the saved text,
/// then expands the tokens back after cleanup.
public enum SnippetCodec {
    public static func encode(_ text: String, snippets: [Snippet]) -> (text: String, used: [String: Snippet]) {
        var result = text
        var used: [String: Snippet] = [:]
        let ordered = snippets
            .filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        for snippet in ordered {
            guard let regex = triggerRegex(snippet.trigger) else { continue }
            // One token per occurrence, so a cleanup that drops one of two is caught.
            let ns = result as NSString
            var out = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let token = "⟦S\(used.count + 1)⟧"
                used[token] = snippet
                out += token
                last = NSMaxRange(match.range)
            }
            result = out + ns.substring(from: last)
        }
        return (result, used)
    }

    public static func decode(_ text: String, used: [String: Snippet]) -> String {
        used.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value.text) }
    }

    public static func allTokensPresent(_ text: String, used: [String: Snippet]) -> Bool {
        used.keys.allSatisfy { text.contains($0) }
    }

    /// Words of the trigger, matched case-insensitively with any whitespace or punctuation between them.
    static func triggerRegex(_ trigger: String) -> NSRegularExpression? {
        let words = trigger
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
            .map(NSRegularExpression.escapedPattern(for:))
        guard !words.isEmpty else { return nil }
        let pattern = "(?<![\\p{L}\\p{N}_])" + words.joined(separator: "[\\s\\p{P}]+") + "(?![\\p{L}\\p{N}_])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
