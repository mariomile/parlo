public enum HotkeyAction: Equatable, Sendable {
    case startDictation
    case startCommand
    case stop
    /// Another key was pressed right after Fn went down (fn+Delete, fn+arrows): discard the recording.
    case cancel
}

/// Turns modifier-flag snapshots into start/stop actions. The mode is fixed when Fn goes down:
/// Ctrl already held means command mode. Releasing Fn stops, unless a key press cancelled first.
/// Times are event timestamps in seconds.
public struct HotkeyStateMachine: Sendable {
    /// A key within this long of Fn going down is a Fn shortcut. Later keys are stray presses
    /// mid-dictation and must not throw the recording away.
    public static let shortcutWindow: Double = 0.6

    private enum State { case idle, active(since: Double), cancelled }
    private var state = State.idle

    public init() {}

    public mutating func handle(fn: Bool, ctrl: Bool, at time: Double) -> HotkeyAction? {
        switch (state, fn) {
        case (.idle, true):
            state = .active(since: time)
            return ctrl ? .startCommand : .startDictation
        case (.active, false):
            state = .idle
            return .stop
        case (.cancelled, false):
            state = .idle
            return nil
        default:
            return nil
        }
    }

    public mutating func keyPressed(at time: Double) -> HotkeyAction? {
        guard case let .active(since) = state, time - since < Self.shortcutWindow else { return nil }
        state = .cancelled
        return .cancel
    }

    public mutating func reset() {
        state = .idle
    }
}
