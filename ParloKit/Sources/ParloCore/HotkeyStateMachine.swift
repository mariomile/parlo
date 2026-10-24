public enum HotkeyAction: Equatable, Sendable {
    case startDictation
    case startCommand
    case stop
    /// Another key was pressed right after Fn went down (fn+Delete, fn+arrows), or Esc during a hands-free
    /// recording. `handsFree` is true for Esc: the audio recorded so far is kept. Otherwise it is discarded.
    case cancel(handsFree: Bool)
    /// Fn was tapped twice: keep the recording the first tap started going without holding the key
    /// (or start one, if it already stopped).
    case lock(command: Bool)
}

/// Turns modifier-flag snapshots into start/stop actions. The mode is fixed when Fn goes down:
/// Ctrl already held means command mode. Releasing Fn stops, unless a key press cancelled first.
/// A short tap followed quickly by a second press locks the recording on (hands-free) until Fn is pressed again.
/// `handle` and `keyPressed` take event timestamps in seconds. `poll` takes the poller's own timestamps, which
/// may come from another clock: the two are never compared.
public struct HotkeyStateMachine: Sendable {
    /// A key within this long of Fn going down is a Fn shortcut. Later keys are stray presses
    /// mid-dictation and must not throw the recording away.
    public static let shortcutWindow: Double = 0.6
    /// A press this short can be the first half of a double tap.
    public static let tapDuration: Double = 0.3
    /// The second press of a double tap comes this soon after the first release. Also the app's tail after a
    /// release (it keeps recording this long), so the second press finds the first tap's recording still running
    /// and continues it.
    public static let doubleTapWindow: Double = 0.25
    /// Fn reported up by polls for this long means its release was missed by the event tap.
    public static let missedRelease: Double = 0.5
    /// A recording is stopped after this long, held or hands-free: a release the poller can't see
    /// (keyboards whose Fn it never reports) must not leave the microphone on for good.
    public static let recordingLimit: Double = 10 * 60

    private struct Tap {
        var releasedAt: Double
        var command: Bool
    }

    private enum State {
        case idle(lastTap: Tap?)
        case held(since: Double, command: Bool)
        /// Second press of a double tap, Fn still down.
        case lockedHeld(since: Double)
        /// Hands-free: recording with Fn up.
        case locked
        /// Fn's release does nothing: the recording was cancelled, or this press stopped a hands-free one.
        case cancelled
    }

    /// What `poll` has seen since the recording started. Times are poll times.
    private struct Polls {
        var sawFnHeld = false
        var fnUpSince: Double?
        var startedAt: Double?
    }

    private var state = State.idle(lastTap: nil)
    private var polls = Polls()
    /// Fn as the last event reported it.
    private var fnDown = false

    public init() {}

    /// `fnKey`: the event is the Fn key's own. Any other modifier (Shift, Option) reports Fn unchanged and does
    /// nothing; the Fn key reporting Fn still down means its release was missed.
    public mutating func handle(fn: Bool, ctrl: Bool, at time: Double, fnKey: Bool = true) -> HotkeyAction? {
        defer { fnDown = fn }
        if fn == fnDown, !fnKey { return nil }
        switch (state, fn) {
        case let (.idle(tap), true):
            polls = Polls()
            if let tap, tap.command == ctrl, time - tap.releasedAt <= Self.doubleTapWindow {
                state = .lockedHeld(since: time)
                return .lock(command: ctrl)
            }
            state = .held(since: time, command: ctrl)
            return ctrl ? .startCommand : .startDictation
        case let (.held(since, command), false):
            state = .idle(lastTap: time - since <= Self.tapDuration ? Tap(releasedAt: time, command: command) : nil)
            return .stop
        case (.lockedHeld, false):
            state = .locked
            return nil
        case (.locked, true):
            state = .cancelled
            return .stop
        case (.cancelled, false):
            state = .idle(lastTap: nil)
            return nil
        case (.cancelled, true):
            // Fn went down again, so its release was missed: this is a new press.
            state = .idle(lastTap: nil)
            return handle(fn: true, ctrl: ctrl, at: time)
        default:
            return nil
        }
    }

    public mutating func keyPressed(at time: Double, escape: Bool = false) -> HotkeyAction? {
        switch state {
        case .idle:
            // A key between two taps means they weren't a double tap.
            state = .idle(lastTap: nil)
            return nil
        case let .held(since, _) where time - since < Self.shortcutWindow:
            state = .cancelled
            return .cancel(handsFree: false)
        case let .lockedHeld(since) where escape || time - since < Self.shortcutWindow:
            state = .cancelled
            return .cancel(handsFree: escape)
        case .locked where escape:
            state = .idle(lastTap: nil)
            return .cancel(handsFree: true)
        default:
            return nil
        }
    }

    /// Reports whether Fn is physically down, as seen by a poller of the keyboard state, for releases the event
    /// tap missed. `time` is the poller's clock. Call it regularly while recording.
    /// - Held: Fn seen down, then up continuously for `missedRelease` stops the recording.
    /// - Second press of a double tap: Fn up for `missedRelease` makes it hands-free, so the next press stops it.
    /// - Any recording stops after `recordingLimit`.
    public mutating func poll(fnHeld: Bool, at time: Double) -> HotkeyAction? {
        switch state {
        case .idle, .cancelled: return nil
        case .held, .lockedHeld, .locked: break
        }
        let start = polls.startedAt ?? time
        polls.startedAt = start
        if time - start >= Self.recordingLimit {
            // If Fn is down, its release must not do anything.
            state = fnHeld ? .cancelled : .idle(lastTap: nil)
            return .stop
        }
        switch state {
        case .held:
            if fnHeld {
                polls.sawFnHeld = true
                polls.fnUpSince = nil
            } else if polls.sawFnHeld, fnUpLongEnough(at: time) {
                state = .idle(lastTap: nil)
                return .stop
            }
        case .lockedHeld:
            if fnHeld {
                polls.fnUpSince = nil
            } else if fnUpLongEnough(at: time) {
                state = .locked
            }
        default:
            break
        }
        return nil
    }

    private mutating func fnUpLongEnough(at time: Double) -> Bool {
        let since = polls.fnUpSince ?? time
        polls.fnUpSince = since
        return time - since >= Self.missedRelease
    }

    public mutating func reset() {
        state = .idle(lastTap: nil)
    }
}
