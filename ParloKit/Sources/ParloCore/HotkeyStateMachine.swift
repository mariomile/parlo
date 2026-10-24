public enum HotkeyAction: Equatable, Sendable {
    case startDictation
    case startCommand
    case stop
    /// Another key was pressed right after Fn went down (fn+Delete, fn+arrows), or Esc during a hands-free
    /// recording: discard the recording.
    case cancel
    /// Fn was tapped twice: keep the recording the first tap started going without holding the key
    /// (or start one, if it already stopped).
    case lock(command: Bool)
}

/// Turns modifier-flag snapshots into start/stop actions. The mode is fixed when Fn goes down:
/// Ctrl already held means command mode. Releasing Fn stops, unless a key press cancelled first.
/// A short tap followed quickly by a second press locks the recording on (hands-free) until Fn is pressed again.
/// Times are event timestamps in seconds.
public struct HotkeyStateMachine: Sendable {
    /// A key within this long of Fn going down is a Fn shortcut. Later keys are stray presses
    /// mid-dictation and must not throw the recording away.
    public static let shortcutWindow: Double = 0.6
    /// A press this short can be the first half of a double tap.
    public static let tapDuration: Double = 0.3
    /// The second press of a double tap comes this soon after the first release. No longer than the app's 250 ms
    /// tail after a release, so the second press finds the first tap's recording still running and continues it.
    public static let doubleTapWindow: Double = 0.25

    private enum State {
        case idle
        case active(since: Double, command: Bool, locked: Bool)
        /// Hands-free: recording with Fn up.
        case locked
        /// Fn's release does nothing: the recording was cancelled, or this press stopped a hands-free one.
        case cancelled
    }

    private var state = State.idle
    private var lastTap: (releasedAt: Double, command: Bool)?

    public init() {}

    public mutating func handle(fn: Bool, ctrl: Bool, at time: Double) -> HotkeyAction? {
        switch (state, fn) {
        case (.idle, true):
            let tap = lastTap
            lastTap = nil
            if let tap, tap.command == ctrl, time - tap.releasedAt <= Self.doubleTapWindow {
                state = .active(since: time, command: ctrl, locked: true)
                return .lock(command: ctrl)
            }
            state = .active(since: time, command: ctrl, locked: false)
            return ctrl ? .startCommand : .startDictation
        case let (.active(since, command, locked), false):
            if locked {
                state = .locked
                return nil
            }
            state = .idle
            lastTap = time - since <= Self.tapDuration ? (time, command) : nil
            return .stop
        case (.locked, true):
            state = .cancelled
            return .stop
        case (.cancelled, false):
            state = .idle
            return nil
        default:
            return nil
        }
    }

    public mutating func keyPressed(at time: Double, escape: Bool = false) -> HotkeyAction? {
        // A key between two taps means they weren't a double tap.
        lastTap = nil
        switch state {
        case let .active(since, _, locked) where time - since < Self.shortcutWindow || (locked && escape):
            state = .cancelled
            return .cancel
        case .locked where escape:
            state = .idle
            return .cancel
        default:
            return nil
        }
    }

    /// Fn is up but its release was missed: the second press of a double tap stays hands-free, and the next
    /// press stops the recording instead of being taken for that release.
    public mutating func fnIsUp() {
        if case .active(_, _, locked: true) = state { state = .locked }
    }

    public mutating func reset() {
        state = .idle
        lastTap = nil
    }
}
