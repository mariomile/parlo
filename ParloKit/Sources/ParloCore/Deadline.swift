import Foundation
import Synchronization

public struct DeadlineExceeded: Error, Equatable, LocalizedError {
    public let seconds: Double
    public var errorDescription: String? { "Transcription took longer than \(Int(seconds)) s and was stopped" }
}

public enum Deadline {
    /// Runs `operation`, giving up after `seconds` even if it never returns (a wedged model ignores
    /// cancellation), so one stuck job can't hold the queue. The operation is cancelled but may keep running.
    public static func run<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = Mutex<CheckedContinuation<T, any Error>?>(nil)
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            once.withLock { pending in
                pending?.resume(with: result)
                pending = nil
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            once.withLock { $0 = continuation }
            let work = Task {
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                finish(.failure(DeadlineExceeded(seconds: seconds)))
            }
        }
    }

    /// Time allowed to transcribe and clean up `duration` seconds of audio: slower than every engine we ship.
    public static func forAudio(duration: Double) -> Double { 30 + duration }
}
