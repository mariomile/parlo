public enum HotkeyAction: Equatable, Sendable {
    case startDictation
    case startCommand
    case stop
    /// Another key was pressed while Fn was held (fn+Delete, fn+arrows): discard the recording.
    case cancel
}

/// Turns modifier-flag snapshots into start/stop actions. The mode is fixed when Fn goes down:
/// Ctrl already held means command mode. Releasing Fn stops, unless a key press cancelled first.
public struct HotkeyStateMachine: Sendable {
    private enum State { case idle, active, cancelled }
    private var state = State.idle

    public init() {}

    public mutating func handle(fn: Bool, ctrl: Bool) -> HotkeyAction? {
        switch (state, fn) {
        case (.idle, true):
            state = .active
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

    public mutating func keyPressed() -> HotkeyAction? {
        guard state == .active else { return nil }
        state = .cancelled
        return .cancel
    }

    public mutating func reset() {
        state = .idle
    }
}
