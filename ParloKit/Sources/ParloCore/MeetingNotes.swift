import Foundation

/// Writes meeting notes with any chat model. A transcript longer than the model takes at once is read in
/// parts (split between turns, never inside one), each part is boiled down to its points, and the points
/// are merged, in rounds if they are still too long, into the final notes.
public struct MeetingNotes: Sendable {
    let llm: any ChatCompleting
    /// The most text one request may carry, which keeps small on-device models inside their context.
    let maxCharacters: Int
    let timeout: TimeInterval

    public init(llm: any ChatCompleting, maxCharacters: Int, timeout: TimeInterval = 180) {
        self.llm = llm
        self.maxCharacters = maxCharacters
        self.timeout = timeout
    }

    public struct Result: Equatable, Sendable {
        public let title: String?
        public let notes: String
        /// False when the model couldn't shorten a long meeting enough: the notes then cover only its start.
        public internal(set) var coversWholeMeeting = true
    }

    /// `lines`: the transcript, one turn per line.
    public func write(_ lines: [String], duration: Double) async throws -> Result {
        let header = Self.header(duration)
        // Room left in a request once the header and the line introducing the text are in.
        let budget = maxCharacters - Self.overhead(duration)
        precondition(budget > 0, "maxCharacters leaves no room for the transcript")
        let parts = Self.chunks(lines, maxCharacters: budget)
        guard parts.count > 1 else {
            return Self.parse(try await ask(Self.finalPrompt, header + Self.transcriptIntro + (parts.first ?? "")))
        }
        var points: [String] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            points.append(try await ask(Self.extractPrompt, Self.partLabel(i + 1, of: parts.count) + part))
        }
        // Merging must shrink the points, or a model that only repeats them would loop forever.
        while true {
            let groups = Self.chunks(points, maxCharacters: budget)
            if groups.count == 1 { break }
            var merged: [String] = []
            for group in groups { merged.append(try await ask(Self.mergePrompt, group)) }
            guard Self.size(merged.joined()) < Self.size(points.joined()) else { break }
            points = merged
        }
        // When the model wouldn't shrink them, only the points that fit go into the last request.
        let groups = Self.chunks(points, maxCharacters: budget)
        var result = Self.parse(try await ask(Self.finalPrompt, header + Self.pointsIntro + groups[0]))
        result.coversWholeMeeting = groups.count == 1
        return result
    }

    static func header(_ duration: Double) -> String {
        "Meeting length: \(MeetingTranscript.timestamp(duration)). Speakers: Me (the user) and Them (everyone else on the call)."
    }

    static let transcriptIntro = "\n\nTranscript:\n"
    static let pointsIntro = "\n\nPoints from each part of the meeting:\n"

    static func partLabel(_ part: Int, of count: Int) -> String { "Part \(part) of \(count).\n\n" }

    /// What every request carries besides the meeting's own text, at most.
    static func overhead(_ duration: Double) -> Int {
        header(duration).count + max(transcriptIntro.count, pointsIntro.count, partLabel(9999, of: 9999).count)
    }

    /// Roughly what text costs a model, in characters: scripts written without spaces (Chinese, Japanese, Korean)
    /// spend about a token per character, three or four times what a Latin character does.
    static func size(_ text: some StringProtocol) -> Int {
        text.reduce(0) { total, character in
            let value = character.unicodeScalars.first?.value ?? 0
            let wide = (0x2E80..<0xD7B0).contains(value) || (0xF900..<0xFB00).contains(value) || (0xFF00..<0xFFF0).contains(value)
            return total + (wide ? 3 : 1)
        }
    }

    private func ask(_ system: String, _ user: String) async throws -> String {
        try await llm.complete(system: system, user: user, timeout: timeout)
    }

    // MARK: - Pieces

    /// Lines joined into texts of at most `maxCharacters`, counted by `size`. A line longer than that is cut at
    /// word breaks, and a word longer than that between characters.
    static func chunks(_ lines: [String], maxCharacters: Int) -> [String] {
        joined(lines.flatMap { size($0) <= maxCharacters ? [$0] : pieces($0, maxCharacters) }, "\n", maxCharacters)
    }

    private static func pieces(_ line: String, _ maxCharacters: Int) -> [String] {
        let words = line.split(separator: " ").flatMap { word in
            size(word) <= maxCharacters ? [String(word)] : joined(word.map(String.init), "", maxCharacters)
        }
        return joined(words, " ", maxCharacters)
    }

    /// Consecutive items joined while the result stays within `maxCharacters`.
    private static func joined(_ items: [String], _ separator: String, _ maxCharacters: Int) -> [String] {
        var out: [String] = []
        var current = ""
        var currentSize = 0
        for item in items {
            let itemSize = size(item)
            if !current.isEmpty, currentSize + separator.count + itemSize > maxCharacters {
                out.append(current)
                current = ""
                currentSize = 0
            }
            if current.isEmpty {
                current = item
                currentSize = itemSize
            } else {
                current += separator + item
                currentSize += separator.count + itemSize
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Splits a title line off the notes and drops a code fence around them.
    static func parse(_ response: String) -> Result {
        var lines = response.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        var title: String?
        // "Title: X", also as "**Title:** X" or "# Title: X".
        if let first = lines.first?.drop(while: { "#* ".contains($0) }),
           let range = first.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            let value = first[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " *#\"").union(.whitespaces))
            title = value.isEmpty ? nil : value
            lines.removeFirst()
        }
        return Result(title: title, notes: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Prompts

    static let rules = """
    Use only what is in the text. Never invent names, owners, dates, numbers or decisions.
    "Me" is the user who recorded the meeting; "Them" is everyone else on the call.
    Write in the language the meeting was held in. Ignore small talk, filler and repeated lines.
    """

    static let extractPrompt = """
    You read one part of a meeting transcript and list what matters in it, as short Markdown bullets under these headings:
    Points, Decisions, Action items, Open questions. Leave a heading out when it has nothing.
    For an action item, give the owner (Me, Them, or a name said in the meeting) and the due date only if one was said.
    \(rules)
    """

    static let mergePrompt = """
    You merge notes taken on consecutive parts of one meeting. Combine duplicates, keep every distinct decision,
    action item and open question, and keep the same headings: Points, Decisions, Action items, Open questions.
    \(rules)
    """

    static let finalPrompt = """
    You write the notes of a meeting. Reply with exactly this, in Markdown:
    Title: a short title for the meeting, at most 8 words
    ## Summary
    3 to 5 bullets on what the meeting was about and where it ended up.
    ## Decisions
    One bullet per decision. Write "None" if there were none.
    ## Action items
    One bullet per task: "- [ ] Owner: task (due date)". Owner is Me, Them, or a name said in the meeting;
    write "Unassigned" if it isn't clear. Give the due date only if one was said.
    ## Open questions
    One bullet per question left open. Write "None" if there were none.
    \(rules)
    """
}
