import Foundation

/// Spoken layout commands ("a capo", "nuovo paragrafo", "punto elenco") turned into line breaks and list items.
/// A phrase is a command only where it starts a clause (start of text or after punctuation, as a pause
/// transcribes), so "è a capo del progetto" stays as it is.
public enum VoiceFormatting {
    static let commands: [(phrases: [String], output: String)] = [
        (["nuovo paragrafo", "new paragraph"], "\n\n"),
        (["punto elenco", "bullet point"], "\n- "),
        (["vai a capo", "a capo", "nuova riga", "new line", "newline"], "\n"),
    ]

    private static let regex: NSRegularExpression = {
        let alternatives = commands
            .map { command in
                let phrases = command.phrases
                    .sorted { $0.count > $1.count }
                    .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+") }
                return "(" + phrases.joined(separator: "|") + ")"
            }
            .joined(separator: "|")
        // A preposition or article after the phrase means it's a normal phrase: "a capo del progetto",
        // ", a capo dell'ufficio,", "new line of products".
        let normalUse = "(?!\\s+(?:(?:del|della|dello|dei|degli|delle|di|of|for)(?![\\p{L}])|dell['’]|d['’]))"
        // 1: punctuation before the phrase (or none at the start); 2...: one group per command, in order.
        let pattern = "(?:^|([.!?:,;]))\\s*(?:" + alternatives + ")(?![\\p{L}\\p{N}_])" + normalUse + "[\\s,.;:]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public static func apply(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        var capitalizeNext = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += capitalizeFirst(ns.substring(with: NSRange(location: last, length: match.range.location - last)), capitalizeNext)
            let punctuation = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            // A comma before the command is the pause, not punctuation the speaker wanted.
            if ![",", ";"].contains(punctuation) { result += punctuation }
            result += output(of: match)
            last = match.range.location + match.range.length
            capitalizeNext = true
        }
        return result + capitalizeFirst(ns.substring(from: last), capitalizeNext)
    }

    /// The output of the command whose group matched.
    private static func output(of match: NSTextCheckingResult) -> String {
        commands[commands.indices.first { match.range(at: $0 + 2).location != NSNotFound }!].output
    }

    private static func capitalizeFirst(_ s: String, _ apply: Bool) -> String {
        guard apply, let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
