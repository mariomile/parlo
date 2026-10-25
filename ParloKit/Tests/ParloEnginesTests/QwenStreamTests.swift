import Foundation
import MLXAudioSTT
import Synchronization
import Testing
@testable import ParloEngines

@Suite struct QwenStreamTests {
    @Test func onlyFinalOutputIsReturned() async throws {
        let stream = AsyncThrowingStream<STTGeneration, any Error> { continuation in
            continuation.yield(.token("unfinished"))
            continuation.yield(.result(STTOutput(text: "complete", generationTokens: 3)))
            continuation.finish()
        }
        #expect(try await Qwen3ASRTranscriber.result(from: stream, tokenBudget: 256) == "complete")
    }

    @Test func partialOrBudgetExhaustedResultsAreErrors() async {
        let partial = AsyncThrowingStream<STTGeneration, any Error> { continuation in
            continuation.yield(.token("partial"))
            continuation.finish()
        }
        await #expect(throws: STTError.self) { try await Qwen3ASRTranscriber.result(from: partial, tokenBudget: 256) }
        let exhausted = AsyncThrowingStream<STTGeneration, any Error> { continuation in
            continuation.yield(.result(STTOutput(text: "truncated", generationTokens: 256)))
            continuation.finish()
        }
        await #expect(throws: STTError.self) { try await Qwen3ASRTranscriber.result(from: exhausted, tokenBudget: 256) }
    }

    @Test func cancellationTerminatesProducerAndNeverReturnsPartialText() async {
        let terminated = Mutex(false)
        let pair = AsyncThrowingStream<STTGeneration, any Error>.makeStream()
        pair.continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        let caller = Task { try await Qwen3ASRTranscriber.result(from: pair.stream, tokenBudget: 256) }
        pair.continuation.yield(.token("partial"))
        await Task.yield()
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(terminated.withLock { $0 })
    }

    @Test func tokenBudgetScalesWithAudioAndHasAnUpperBound() {
        #expect(Qwen3ASRTranscriber.tokenBudget(sampleCount: 0) == 256)
        #expect(Qwen3ASRTranscriber.tokenBudget(sampleCount: 16_000 * 10) == 448)
        #expect(Qwen3ASRTranscriber.tokenBudget(sampleCount: 16_000 * 60) == 2048)
        #expect(Qwen3ASRTranscriber.tokenBudget(sampleCount: 16_000 * 600) == 8192)
    }
}
