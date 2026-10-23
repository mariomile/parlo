import Foundation

public enum DictationOutcome: Equatable, Sendable {
    case discarded
    case empty
    /// `cleanupError` is set when the LLM was enabled but its output wasn't used.
    case inserted(text: String, cleanupError: String?)
}

/// transcribe -> dictionary -> snippet tokens -> LLM cleanup -> expand snippets.
public struct DictationPipeline: Sendable {
    public static let cleanupTimeout: TimeInterval = 5

    let transcriber: any Transcriber
    let llm: (any ChatCompleting)?
    let settings: AppSettings

    public init(transcriber: any Transcriber, llm: (any ChatCompleting)?, settings: AppSettings) {
        self.transcriber = transcriber
        self.llm = llm
        self.settings = settings
    }

    public func run(samples: [Float], bundleID: String?) async throws -> DictationOutcome {
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else { return .discarded }
        let raw = try await transcriber.transcribe(samples, languageCode: settings.languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .empty }

        let replaced = DictionaryReplacer.apply(raw, entries: settings.dictionary)
        let (encoded, used) = SnippetCodec.encode(replaced, snippets: settings.snippets)
        let uncleaned = SnippetCodec.decode(encoded, used: used)

        guard let llm else { return .inserted(text: uncleaned, cleanupError: nil) }

        let system = PromptBuilder.cleanupSystemPrompt(
            style: StyleResolver.style(for: bundleID, overrides: settings.styleOverrides),
            terms: settings.dictionary.map(\.term),
            hasPlaceholders: !used.isEmpty
        )
        do {
            let cleaned = try await llm.complete(system: system, user: encoded, timeout: Self.cleanupTimeout)
            guard SnippetCodec.allTokensPresent(cleaned, used: used) else {
                return .inserted(text: uncleaned, cleanupError: "Cleanup dropped a snippet")
            }
            return .inserted(text: SnippetCodec.decode(cleaned, used: used), cleanupError: nil)
        } catch {
            return .inserted(text: uncleaned, cleanupError: error.localizedDescription)
        }
    }
}
