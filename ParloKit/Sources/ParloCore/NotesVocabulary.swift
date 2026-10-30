import Foundation

/// Finds the names and terms a folder of Markdown notes keeps using ("Alice Morrone", "DeepAgent", "Next.js"),
/// for the user to pick into the dictionary. A term counts when it shows up in several notes and is almost
/// always written with its capitals: a capitalized word that's often written lowercase too ("Product") is
/// an ordinary word at the start of a sentence or title, not a name.
public enum NotesVocabulary {
    public struct Candidate: Equatable, Sendable {
        public let term: String
        /// Notes it appears in.
        public let notes: Int
    }

    static let minNotes = 3
    static let maxLowercaseShare = 0.25
    static let maxPhraseWords = 3
    static let maxLineLength = 2_000
    static let maxFileBytes = 1_000_000
    static let maxFiles = 20_000
    static let skippedFolders: Set<String> = ["node_modules", "Templates", "templates"]
    static let fileSuffixes = [".md", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".base", ".txt", ".json", ".csv", ".canvas"]

    /// Scans `folder` and its subfolders. `isKnownWord` tells ordinary dictionary words ("October", "Notion"),
    /// which speech models already spell, from names; terms with their own spelling skip that check.
    public static func candidates(
        in folder: URL, excluding dictionary: [DictionaryEntry], limit: Int = 150, isKnownWord: (String) -> Bool
    ) -> [Candidate] {
        candidates(in: markdownTexts(in: folder), excluding: dictionary, limit: limit, isKnownWord: isKnownWord)
    }

    static func candidates(
        in notes: some Sequence<String>, excluding dictionary: [DictionaryEntry], limit: Int, isKnownWord: (String) -> Bool
    ) -> [Candidate] {
        var written: [String: [String: Int]] = [:] // lowercased → spelling → occurrences
        var noteCounts: [String: Int] = [:] // lowercased → notes with a capitalized spelling
        var lowercase: [String: Int] = [:] // lowercased → occurrences written all lowercase
        var openings: [String: Int] = [:] // lowercased phrase → occurrences starting a sentence

        for note in notes {
            var seen = Set<String>()
            // Very long lines are data (base64 images, minified tables), not prose.
            for line in plainText(note).split(whereSeparator: \.isNewline) where line.count <= maxLineLength {
                let tokens = words(in: line)
                for (i, token) in tokens.enumerated() {
                    let key = token.lowercased()
                    if token == key { lowercase[key, default: 0] += 1 }
                    guard isTermLike(token) else { continue }
                    record(token, key: key, written: &written, seen: &seen)
                    // Runs of capitalized words: "Alice Morrone", "Opportunity Solution Tree".
                    let opensSentence = i == 0 || tokens[i - 1].isEmpty
                    var phrase = [token]
                    for next in tokens.dropFirst(i + 1).prefix(maxPhraseWords - 1) {
                        guard isTermLike(next), next.first?.isUppercase == true else { break }
                        phrase.append(next)
                        let text = phrase.joined(separator: " ")
                        record(text, key: text.lowercased(), written: &written, seen: &seen)
                        if opensSentence { openings[text.lowercased(), default: 0] += 1 }
                    }
                }
            }
            for key in seen { noteCounts[key, default: 0] += 1 }
        }

        let known = Set(dictionary.terms.map { $0.lowercased() })
        // A word often written lowercase too ("product", "ciao"): ordinary, capitalized only to open a sentence or title.
        func isOrdinary(_ word: some StringProtocol) -> Bool {
            let key = word.lowercased()
            return Double(lowercase[key, default: 0]) > Double(written[key, default: [:]].values.reduce(0, +)) * maxLowercaseShare
        }
        var kept: [Candidate] = []
        for (key, spellings) in written {
            let notes = noteCounts[key, default: 0]
            let capitalized = spellings.values.reduce(0, +)
            guard notes >= minNotes, !known.contains(key),
                  Double(lowercase[key, default: 0]) <= Double(capitalized) * maxLowercaseShare,
                  let term = spellings.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
            else { continue }
            if term.contains(" ") {
                // A name has a word hardly ever written lowercase: "Alice Morrone" does, the title "Reference
                // Library" doesn't. Surnames are often dictionary words too ("Negri"), so spelling can't tell.
                let words = term.split(separator: " ")
                if words.allSatisfy(isOrdinary) { continue }
                // "Ciao Mario", "Ask Carlotta Negri": an ordinary word opening the sentence in front of a name.
                if isOrdinary(words[0]), openings[key, default: 0] * 2 >= capitalized { continue }
            } else if !DictionaryReplacer.hasOwnSpelling(term), isKnownWord(term) {
                continue
            }
            kept.append(Candidate(term: term, notes: notes))
        }

        // A word mostly seen inside a longer name ("Morrone" in "Alice Morrone") is covered by that name.
        let phrases = kept.filter { $0.term.contains(" ") }
        kept.removeAll { part in
            phrases.contains { whole in
                whole.term != part.term && whole.notes * 2 > part.notes
                    && (" " + whole.term + " ").contains(" " + part.term + " ")
            }
        }
        return Array(kept.sorted { ($0.notes, $1.term) > ($1.notes, $0.term) }.prefix(limit))
    }

    /// A capitalized or camel-case word with at least three letters. Acronyms ("PMF"), file names, versions and
    /// numbers are left out: speech models write acronyms already, and the rest isn't vocabulary.
    static func isTermLike(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter, token.filter(\.isLetter).count >= 3,
              first.isUppercase || token.dropFirst().contains(where: \.isUppercase),
              token.contains(where: \.isLowercase)
        else { return false }
        let lower = token.lowercased()
        if fileSuffixes.contains(where: lower.hasSuffix) { return false }
        // Plural acronyms: "KPIs", "LLMs".
        if token.last == "s", token.dropLast().allSatisfy(\.isUppercase) { return false }
        return true
    }

    /// Words, keeping inner dots: "Next.js", "Captoo.io". Apostrophes split "l'AI" and "Lenny's"; hyphens also
    /// end a run of capitalized words, so "AI-native" and "Tier-1" are no terms.
    static func words(in line: Substring) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if c == ".", !current.isEmpty, i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1].isNumber {
                current.append(c)
            } else {
                if !current.isEmpty { result.append(current) }
                current = ""
                // Sentence ends and list punctuation break a run of capitalized words.
                if !c.isWhitespace, !"'’".contains(c) { result.append("") }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The prose of a note: no front matter, code, links' targets or URLs. Wiki links keep their text.
    static func plainText(_ note: String) -> String {
        let text = NSMutableString(string: note)
        for (regex, template) in cleanups {
            regex.replaceMatches(in: text, range: NSRange(location: 0, length: text.length), withTemplate: template)
        }
        return text as String
    }

    /// In order: front matter, then code, so nothing inside it is read as a link. The email pattern caps its
    /// local part so a long token without "@" can't make matching quadratic.
    private static let cleanups: [(NSRegularExpression, String)] = [
        ("\\A---\\n[\\s\\S]*?\\n---[ \\t]*(?:\\n|\\z)", ""),
        ("```[\\s\\S]*?```", " "), ("`[^`\\n]*`", " "),
        ("\\[\\[([^\\]|#\\n]*)[^\\]\\n]*\\]\\]", "$1"), ("\\]\\([^)\\n]*\\)", "]"),
        ("https?://\\S+", " "), ("[\\w.+-]{1,64}@[\\w-]+(?:\\.[\\w-]+)*", " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static func record(_ spelling: String, key: String, written: inout [String: [String: Int]], seen: inout Set<String>) {
        written[key, default: [:]][spelling, default: 0] += 1
        seen.insert(key)
    }

    /// The Markdown files under `folder`, read lazily, skipping hidden folders (.obsidian, .git, .trash).
    static func markdownTexts(in folder: URL) -> some Sequence<String> {
        let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )
        var count = 0
        return AnySequence {
            AnyIterator {
                while count < maxFiles, let url = files?.nextObject() as? URL {
                    if skippedFolders.contains(url.lastPathComponent) { files?.skipDescendants(); continue }
                    guard url.pathExtension.lowercased() == "md",
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileBytes,
                          let text = try? String(contentsOf: url, encoding: .utf8)
                    else { continue }
                    count += 1
                    return text
                }
                return nil
            }
        }
    }
}
