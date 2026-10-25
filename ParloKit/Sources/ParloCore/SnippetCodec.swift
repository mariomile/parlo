import Foundation

/// Swaps spoken snippet triggers for opaque tokens (`⟦S1⟧`) so the LLM can't rewrite the saved text,
/// then expands the tokens back after cleanup.
public enum SnippetCodec {
    private struct Match {
        let order: Int
        let snippet: Snippet
        let range: NSRange
    }

    public static func encode(_ text: String, snippets: [Snippet]) -> (text: String, used: [String: Snippet]) {
        var used: [String: Snippet] = [:]
        // Find candidates only in the original text, then rewrite accepted, non-overlapping spans once.
        let matches: [Match] = snippets.enumerated().flatMap { (index, snippet) -> [Match] in
            guard let regex = triggerRegex(snippet.trigger) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                Match(order: index, snippet: snippet, range: $0.range)
            }
        }
        let ordered = matches.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.order < $1.order
        }
        guard !ordered.isEmpty else { return (text, used) }
        let literalTokens = try! NSRegularExpression(pattern: "⟦[^⟧]*⟧")
        let literals = literalTokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        var out = ""
        var last = text.startIndex
        var tokenNumber = 0
        for match in ordered {
            guard !literals.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: text), range.lowerBound >= last
            else { continue }
            var token: String
            repeat {
                tokenNumber += 1
                token = "⟦S\(tokenNumber)⟧"
            } while text.range(of: token, options: .caseInsensitive) != nil
            used[token] = match.snippet
            out += text[last..<range.lowerBound] + token
            last = range.upperBound
        }
        return (out + text[last...], used)
    }

    public static func decode(_ text: String, used: [String: Snippet]) -> String {
        guard !used.isEmpty else { return text }
        let pattern = used.keys.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let snippet = used[String(text[range])] else { continue }
            out += text[last..<range.lowerBound] + snippet.text
            last = range.upperBound
        }
        return out + text[last...]
    }

    public static func allTokensPresent(_ text: String, used: [String: Snippet]) -> Bool {
        // Each original occurrence has its own token. Missing and duplicated occurrences both fail.
        used.keys.allSatisfy { text.components(separatedBy: $0).count == 2 }
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
