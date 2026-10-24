import Foundation

public enum DictationOutcome: Equatable, Sendable {
    case discarded
    case empty
    /// `cleanupError` is set when the LLM was enabled but its output wasn't used.
    case inserted(text: String, cleanupError: String?)
}

/// transcribe -> dictionary -> spoken layout -> snippet tokens -> LLM cleanup -> expand snippets.
public struct DictationPipeline: Sendable {
    /// Time the LLM gets to clean up `text`: 5 s for a sentence, more for minutes of hands-free dictation.
    public static func cleanupTimeout(for text: String) -> TimeInterval {
        5 + Double(text.count) / 100
    }

    let transcriber: any Transcriber
    let llm: (any ChatCompleting)?
    let settings: AppSettings
    let speech: (any SpeechDetector)?

    public init(
        transcriber: any Transcriber, llm: (any ChatCompleting)?, settings: AppSettings,
        speech: (any SpeechDetector)? = nil
    ) {
        self.transcriber = transcriber
        self.llm = llm
        self.settings = settings
        self.speech = speech
    }

    public func run(samples: [Float], bundleID: String?) async throws -> DictationOutcome {
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else { return .discarded }
        if let speech, try await !speech.containsSpeech(samples) { return .empty }
        let raw = try await transcriber.transcribe(
            samples, languageCode: settings.languageCode, dictionary: settings.dictionary
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .empty }

        let replaced = VoiceFormatting.apply(DictionaryReplacer.apply(raw, entries: settings.dictionary))
        let (encoded, used) = SnippetCodec.encode(replaced, snippets: settings.snippets)
        let uncleaned = SnippetCodec.decode(encoded, used: used)

        guard let llm else { return .inserted(text: uncleaned, cleanupError: nil) }

        let system = PromptBuilder.cleanupSystemPrompt(
            style: StyleResolver.style(for: bundleID, overrides: settings.styleOverrides),
            dictionary: settings.dictionary,
            hasPlaceholders: !used.isEmpty
        )
        do {
            let reply = try await llm.complete(
                system: system, user: PromptBuilder.cleanupUserMessage(encoded), timeout: Self.cleanupTimeout(for: encoded)
            )
            guard let cleaned = CleanupOutput.accepted(reply, input: encoded) else {
                return .inserted(text: uncleaned, cleanupError: "Cleanup output looked wrong")
            }
            guard SnippetCodec.allTokensPresent(cleaned, used: used) else {
                return .inserted(text: uncleaned, cleanupError: "Cleanup dropped a snippet")
            }
            return .inserted(text: SnippetCodec.decode(cleaned, used: used), cleanupError: nil)
        } catch {
            return .inserted(text: uncleaned, cleanupError: error.localizedDescription)
        }
    }
}
