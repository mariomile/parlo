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

let oneSecond = [Float](repeating: 0.1, count: 16_000)

struct FakeSpeechDetector: SpeechDetector {
    var speech: Bool
    func containsSpeech(_ samples: [Float]) async throws -> Bool { speech }
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
