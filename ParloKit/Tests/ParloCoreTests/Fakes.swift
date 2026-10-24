import Foundation
@testable import ParloCore

struct FakeTranscriber: Transcriber {
    var text: String
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String { text }
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

let oneSecond = [Float](repeating: 0.1, count: Audio.sampleRate)

struct FakeSpeechDetector: SpeechDetector {
    var speech: Bool
    func containsSpeech(_ samples: [Float]) async throws -> Bool { speech }
}

/// Never answers, like a detector stuck in its model.
struct StalledSpeechDetector: SpeechDetector {
    func containsSpeech(_ samples: [Float]) async throws -> Bool {
        while true { try? await Task.sleep(for: .seconds(1)) }
    }
}

final class RecordingTranscriber: Transcriber, @unchecked Sendable {
    let text: String
    let dictionaries = LockedBox<[[DictionaryEntry]]>([])
    init(text: String) { self.text = text }
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        dictionaries.value.append(dictionary)
        return text
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
