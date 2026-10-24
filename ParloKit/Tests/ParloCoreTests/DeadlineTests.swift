import Foundation
import Testing
@testable import ParloCore

@Suite struct DeadlineTests {
    @Test func returnsTheResultInTime() async throws {
        #expect(try await Deadline.run(seconds: 5) { 42 } == 42)
    }

    @Test func passesErrorsThrough() async {
        await #expect(throws: FailingError.self) { try await Deadline.run(seconds: 5) { throw FailingError() } }
    }

    @Test func givesUpOnAnOperationThatNeverReturns() async {
        let start = Date.now
        await #expect(throws: DeadlineExceeded(seconds: 0.2)) {
            try await Deadline.run(seconds: 0.2) {
                // Ignores cancellation, like a wedged model.
                while true { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        #expect(Date.now.timeIntervalSince(start) < 2)
    }

    @Test func cancellingTheCallerStopsTheWait() async {
        let task = Task {
            try await Deadline.run(seconds: 60) {
                while true { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
