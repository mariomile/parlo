import Foundation
@testable import ParloCore

struct FakeTranscriber: Transcriber {
    var text: String
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String { text }
}

struct FailingError: Error {}

final class FakeLLM: ChatCompleting, @unchecked Sendable {
    var reply: (String, String) throws -> String
    var calls: [(system: String, user: String, timeout: TimeInterval)] = []
    init(reply: @escaping (String, String) throws -> String) { self.reply = reply }
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        calls.append((system, user, timeout))
        return try reply(system, user)
    }
}

let oneSecond = [Float](repeating: 0.1, count: 16_000)

struct FakeSpeechDetector: SpeechDetector {
    var speech: Bool
    func containsSpeech(_ samples: [Float]) async throws -> Bool { speech }
}
