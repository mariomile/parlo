import Foundation

public enum JobKind: Equatable, Sendable {
    /// Cleaned up in the style of the app it is pasted into.
    case dictation(bundleID: String?)
    /// A spoken instruction applied by the LLM to the selected text, or a generation request with no selection.
    case command(selection: String?)
}

public enum JobOutcome: Equatable, Sendable {
    /// Too short to be a recording.
    case discarded
    /// No speech, or nothing the engine could make out.
    case empty
    /// `warning`: AI cleanup was on but its output wasn't used, and why.
    case text(String, warning: String?)
}

public enum CommandError: Error, Equatable, LocalizedError {
    case llmNotConfigured

    public var errorDescription: String? {
        "Command mode needs AI cleanup turned on in Settings → AI"
    }
}

/// One recording or file, transcribed and finished: dictation goes through
/// transcribe -> dictionary -> spoken layout -> snippet tokens -> LLM cleanup -> expand snippets.
public struct TranscriptionJob: Sendable {
    public static let commandTimeout: TimeInterval = 15
    /// Longer text is pasted without AI cleanup. Covers the longest hands-free dictation (ten minutes).
    public static let cleanupMaxCharacters = 10_000

    /// Local cleanup gets an interactive deadline; long dictations still get time proportional
    /// to their output. Hosted providers retain their existing network allowance.
    public static func cleanupTimeout(for text: String, provider: LLMProvider = .apple) -> TimeInterval {
        provider == .local ? 2 + Double(text.count) / 200 : 5 + Double(text.count) / 100
    }

    /// Time the engine gets for `seconds` of audio: slower than every engine we ship.
    /// nil when the transcriber keeps its own deadlines, as `BackgroundTranscriber` does per piece.
    public var transcriptionDeadline: (@Sendable (_ seconds: Double) -> Double)? = Self.engineDeadline

    public static let engineDeadline: @Sendable (_ seconds: Double) -> Double = { 30 + $0 }

    let transcriber: any Transcriber
    let llm: (any ChatCompleting)?
    let settings: AppSettings
    /// Checked first so silence never reaches the engine (Parakeet invents words on it); nil skips the check.
    let speech: (any SpeechDetector)?

    public init(
        transcriber: any Transcriber, llm: (any ChatCompleting)?, settings: AppSettings, speech: (any SpeechDetector)?
    ) {
        self.transcriber = transcriber
        self.llm = llm
        self.settings = settings
        self.speech = speech
    }

    /// Throws `DeadlineExceeded` when the engine stops answering, so one stuck job can't hold the queue.
    /// The LLM calls have their own timeouts.
    /// Longest the speech check may take before the recording is transcribed anyway.
    static let speechCheckTimeout: Double = 10

    /// A detector that stops answering must not hold the dictation: the engine gets the audio regardless.
    static func heardSpeech(
        _ speech: any SpeechDetector, _ samples: [Float], timeout: Double = speechCheckTimeout
    ) async throws -> Bool {
        do {
            return try await Deadline.run(seconds: timeout) { try await speech.containsSpeech(samples) }
        } catch is DeadlineExceeded {
            return true
        }
    }

    public func run(_ samples: [Float], _ kind: JobKind) async throws -> JobOutcome {
        if case .command = kind, llm == nil { throw CommandError.llmNotConfigured }
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else { return .discarded }
        if let speech, try await !Self.heardSpeech(speech, samples) { return .empty }
        switch kind {
        case let .dictation(bundleID):
            let raw = try await transcribe(samples, dictionary: settings.dictionary)
            return raw.isEmpty ? .empty : await clean(raw, bundleID: bundleID)
        case let .command(selection):
            let instruction = try await transcribe(samples, dictionary: [])
            guard let llm, !instruction.isEmpty else { return .empty }
            let result = try await llm.complete(
                system: PromptBuilder.commandSystemPrompt(),
                user: PromptBuilder.commandUserMessage(instruction: instruction, selection: selection),
                timeout: Self.commandTimeout
            )
            return .text(result.trimmingCharacters(in: .whitespacesAndNewlines), warning: nil)
        }
    }

    private func transcribe(_ samples: [Float], dictionary: [DictionaryEntry]) async throws -> String {
        let transcriber = transcriber, languageCode = settings.languageCode
        let text = if let transcriptionDeadline {
            try await Deadline.run(seconds: transcriptionDeadline(Audio.seconds(samples.count))) {
                try await transcriber.transcribe(samples, languageCode: languageCode, dictionary: dictionary)
            }
        } else {
            try await transcriber.transcribe(samples, languageCode: languageCode, dictionary: dictionary)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clean(_ raw: String, bundleID: String?) async -> JobOutcome {
        let replaced = VoiceFormatting.apply(DictionaryReplacer.apply(raw, entries: settings.dictionary))
        let (encoded, used) = SnippetCodec.encode(replaced, snippets: settings.snippets)
        let uncleaned = SnippetCodec.decode(encoded, used: used)

        guard let llm else { return .text(uncleaned, warning: nil) }
        guard encoded.count <= Self.cleanupMaxCharacters else { return .text(uncleaned, warning: "Too long for AI cleanup") }

        let system = PromptBuilder.cleanupSystemPrompt(
            style: StyleResolver.style(for: bundleID, overrides: settings.styleOverrides),
            dictionary: settings.dictionary,
            hasPlaceholders: !used.isEmpty
        )
        do {
            let reply = try await llm.complete(
                system: system, user: PromptBuilder.cleanupUserMessage(encoded),
                timeout: Self.cleanupTimeout(for: encoded, provider: settings.llm.provider)
            )
            guard let cleaned = CleanupOutput.accepted(reply, input: encoded) else {
                return .text(uncleaned, warning: "Cleanup output looked wrong")
            }
            guard SnippetCodec.allTokensPresent(cleaned, used: used) else {
                return .text(uncleaned, warning: "Cleanup dropped a snippet")
            }
            return .text(SnippetCodec.decode(cleaned, used: used), warning: nil)
        } catch {
            return .text(uncleaned, warning: error.localizedDescription)
        }
    }
}
