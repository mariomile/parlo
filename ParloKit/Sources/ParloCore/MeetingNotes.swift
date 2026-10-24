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
            points.append(try await ask(Self.extractPrompt, "Part \(i + 1) of \(parts.count).\n\n" + part))
        }
        // Merging must shrink the points, or a model that only repeats them would loop forever.
        while true {
            let groups = Self.chunks(points, maxCharacters: budget)
            if groups.count == 1 { break }
            var merged: [String] = []
            for group in groups { merged.append(try await ask(Self.mergePrompt, group)) }
            guard merged.joined().count < points.joined().count else { break }
            points = merged
        }
        return Self.parse(try await ask(Self.finalPrompt, header + Self.pointsIntro + points.joined(separator: "\n")))
    }

    static func header(_ duration: Double) -> String {
        "Meeting length: \(MeetingTranscript.timestamp(duration)). Speakers: Me (the user) and Them (everyone else on the call)."
    }

    static let transcriptIntro = "\n\nTranscript:\n"
    static let pointsIntro = "\n\nPoints from each part of the meeting:\n"

    /// What every request carries besides the meeting's own text, at most.
    static func overhead(_ duration: Double) -> Int {
        header(duration).count + max(transcriptIntro.count, pointsIntro.count)
    }

    private func ask(_ system: String, _ user: String) async throws -> String {
        try await llm.complete(system: system, user: user, timeout: timeout)
    }

    // MARK: - Pieces

    /// Lines joined into texts of at most `maxCharacters`. A line longer than that is cut at word breaks.
    static func chunks(_ lines: [String], maxCharacters: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func add(_ line: String) {
            if !current.isEmpty, current.count + 1 + line.count > maxCharacters {
                out.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        for line in lines {
            if line.count <= maxCharacters { add(line); continue }
            var piece = ""
            for word in line.split(separator: " ") {
                if !piece.isEmpty, piece.count + 1 + word.count > maxCharacters {
                    add(piece)
                    piece = ""
                }
                piece += piece.isEmpty ? String(word) : " " + word
            }
            if !piece.isEmpty { add(piece) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Splits a "Title: …" first line off the notes and drops a code fence around them.
    static func parse(_ response: String) -> Result {
        var lines = response.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        var title: String?
        if let first = lines.first, let range = first.range(of: "title:", options: [.caseInsensitive, .anchored]) {
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
