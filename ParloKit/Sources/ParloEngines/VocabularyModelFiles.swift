import Foundation
import Synchronization

/// Coordinates explicit deletion with the optional booster's writer. A synchronous Delete reports a
/// retryable error while a download is still writing; it must not race those writes or claim success.
final class VocabularyModelFiles: Sendable {
    private struct State {
        var generation = 0
        var loading = false
    }
    private let state = Mutex(State())
    let directory: URL

    init(directory: URL) { self.directory = directory }

    var generation: Int { state.withLock { $0.generation } }

    var assetsExist: Bool {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "vocab.json", "tokenizer.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func beginLoad() -> Int? {
        state.withLock { state in
            guard !state.loading else { return nil }
            state.loading = true
            return state.generation
        }
    }

    func finishLoad() {
        state.withLock { $0.loading = false }
    }

    func delete() throws {
        try state.withLock { state in
            guard !state.loading else {
                throw ModelFileCleanup.Failure(problems: ["Vocabulary booster is still loading. Retry Delete when it finishes"])
            }
            // Even a partial removal failure invalidates cached sessions that read tokenizer files.
            state.generation += 1
            try ModelFileCleanup.remove([directory])
        }
    }
}
