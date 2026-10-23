public enum HotkeyAction: Equatable, Sendable {
    case startDictation
    case startCommand
    case stop
}

/// Turns modifier-flag snapshots into start/stop actions. The mode is fixed when Fn goes down:
/// Ctrl already held means command mode. Releasing Fn always stops.
public struct HotkeyStateMachine: Sendable {
    private var active = false

    public init() {}

    public mutating func handle(fn: Bool, ctrl: Bool) -> HotkeyAction? {
        switch (active, fn) {
        case (false, true):
            active = true
            return ctrl ? .startCommand : .startDictation
        case (true, false):
            active = false
            return .stop
        default:
            return nil
        }
    }

    public mutating func reset() {
        active = false
    }
}
