import CoreGraphics
import Foundation
import ParloCore

/// Listens to modifier-flag changes system-wide (needs Input Monitoring) and turns Fn / Ctrl+Fn into actions.
final class HotkeyMonitor {
    var onAction: (HotkeyAction) -> Void = { _ in }
    private var tap: CFMachPort?
    private var machine = HotkeyStateMachine()

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses the tap (Input Monitoring not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    func reset() {
        machine.reset()
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        if let action = machine.handle(fn: flags.contains(.maskSecondaryFn), ctrl: flags.contains(.maskControl)) {
            onAction(action)
        }
    }
}

private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let flags = event.flags
        let address = UInt(bitPattern: userInfo)
        // The tap's run loop source is on the main run loop.
        MainActor.assumeIsolated {
            let pointer = UnsafeMutableRawPointer(bitPattern: address)!
            Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue().handle(type: type, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}
