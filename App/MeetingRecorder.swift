import Foundation
import ParloCore

/// Records a meeting: the microphone as "Me" and everything the Mac plays as "Them", each straight to its
/// own file on the meeting's clock.
final class MeetingRecorder {
    private let mic: AudioRecorder
    private let system: SystemAudioTap
    private let me: TrackWriter
    private let them: TrackWriter

    /// Called once when either side stopped and could not restart.
    var onFailure: (String) -> Void = { _ in }

    init(me meURL: URL, them themURL: URL, deviceUID: String?) throws {
        let start = ContinuousClock.now
        let elapsed: @Sendable () -> Double = { (ContinuousClock.now - start) / .seconds(1) }
        me = try TrackWriter(url: meURL, elapsed: elapsed)
        them = try TrackWriter(url: themURL, elapsed: elapsed)
        mic = AudioRecorder(sink: me)
        system = SystemAudioTap(sink: them)
        mic.onFailure = { [weak self] in self?.fail("Microphone stopped: \($0)") }
        system.onFailure = { [weak self] in self?.fail($0) }
        // The microphone first: AirPods switch to their headset profile now, not after the tap is built on them.
        try mic.start(deviceUID: deviceUID)
        do { try system.start() } catch {
            _ = stop()
            throw error
        }
    }

    var duration: Double { max(me.duration, them.duration) }

    /// Stops both sides and finishes the files. Returns the first write error, if any.
    func stop() -> (any Error)? {
        mic.stop()
        system.stop()
        let errors = [me.close(), them.close()]
        return errors.compactMap { $0 }.first
    }

    private func fail(_ reason: String) {
        let report = onFailure
        onFailure = { _ in }
        report(reason)
    }
}
