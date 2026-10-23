import Foundation

/// Checks and tidies what the cleanup model returned before it replaces the raw transcript.
enum CleanupOutput {
    /// Cleaned text may be this much shorter or longer than the transcript; beyond it the model
    /// probably answered, summarized or commented instead of cleaning.
    static let lengthRatioRange = 0.5...1.8

    /// The usable cleaned text, or nil when its length is implausible for a cleanup of `input`.
    static func accepted(_ output: String, input: String) -> String? {
        let text = stripWrappers(output, input: input)
        guard !text.isEmpty, !input.isEmpty else { return nil }
        let ratio = Double(text.count) / Double(input.count)
        return lengthRatioRange.contains(ratio) ? text : nil
    }

    private static let preamble = try! NSRegularExpression(
        pattern: #"^\s*(ecco|here is|here's|here are|sure|certo|ok|okay)\b[^\n:]{0,60}:[ \t]*\n?"#,
        options: [.caseInsensitive]
    )
    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]

    /// Drops <transcript> tags, an introduction line such as "Ecco il testo:" and surrounding quotes,
    /// unless the speaker's own text starts that way.
    static func stripWrappers(_ output: String, input: String) -> String {
        var text = output
            .replacingOccurrences(of: "</?transcript>", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let inputStart = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let range = NSRange(text.startIndex..., in: text)
        if let match = preamble.firstMatch(in: text, range: range), let word = Range(match.range(at: 1), in: text),
           !inputStart.hasPrefix(text[word].lowercased()) {
            text = String(text[text.index(text.startIndex, offsetBy: match.range.length)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (open, close) in quotePairs where text.count > 1 && text.first == open && text.last == close
            && inputStart.first != open {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }
}
