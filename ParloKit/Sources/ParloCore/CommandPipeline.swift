import Foundation

public enum CommandOutcome: Equatable, Sendable {
    case discarded
    case empty
    case result(String)
}

public enum CommandError: Error, Equatable, LocalizedError {
    case llmNotConfigured

    public var errorDescription: String? {
        "Command mode needs AI cleanup turned on in Settings → AI"
    }
}

/// Spoken instruction applied by the LLM to the selected text, or a generation request with no selection.
public struct CommandPipeline: Sendable {
    public static let timeout: TimeInterval = 15

    let transcriber: any Transcriber
    let llm: (any ChatCompleting)?
    let languageCode: String?

    public init(transcriber: any Transcriber, llm: (any ChatCompleting)?, languageCode: String?) {
        self.transcriber = transcriber
        self.llm = llm
        self.languageCode = languageCode
    }

    public func run(samples: [Float], selection: String?) async throws -> CommandOutcome {
        guard let llm else { throw CommandError.llmNotConfigured }
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else { return .discarded }
        let instruction = try await transcriber.transcribe(samples, languageCode: languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return .empty }
        let result = try await llm.complete(
            system: PromptBuilder.commandSystemPrompt(),
            user: PromptBuilder.commandUserMessage(instruction: instruction, selection: selection),
            timeout: Self.timeout
        )
        return .result(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
