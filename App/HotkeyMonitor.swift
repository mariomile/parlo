import CoreGraphics
import Foundation
import ParloCore

/// Listens to modifier-flag changes system-wide (needs Input Monitoring) and turns Fn / Ctrl+Fn into actions.
final class HotkeyMonitor {
    var onAction: (HotkeyAction) -> Void = { _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var machine = HotkeyStateMachine()

    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    isolated deinit {
        disposeTap()
    }

    /// Returns false when macOS refuses the tap (Input Monitoring not granted yet).
    @discardableResult
    func start() -> Bool {
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            if isRunning { return true }
        }
        disposeTap()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isRunning else {
            disposeTap()
            return false
        }
        return true
    }

    /// Retire the callback source before its unretained monitor pointer can become stale.
    /// Tap recovery leaves the state machine intact so an active recording can still finish.
    private func disposeTap() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func reset() {
        machine.reset()
    }

    /// Called while recording: catches a release the tap missed (it is switched off while the system is busy),
    /// and stops a hands-free recording at its time limit.
    func poll() {
        let fnHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        if let action = machine.poll(fnHeld: fnHeld, at: ProcessInfo.processInfo.systemUptime) { onAction(action) }
    }

    /// `fromHardware` is false for synthetic events, like our own Cmd+C in command mode.
    /// `keycode` is the event's key: Escape for a key press, Fn (63) or another modifier for a flags change.
    fileprivate func handle(type: CGEventType, flags: CGEventFlags, time: Double, fromHardware: Bool, keycode: Int64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            start()
            return
        }
        if type == .keyDown {
            guard fromHardware else { return }
            if let action = machine.keyPressed(at: time, escape: keycode == 53) { onAction(action) } // kVK_Escape
            return
        }
        guard type == .flagsChanged else { return }
        if let action = machine.handle(
            fn: flags.contains(.maskSecondaryFn), ctrl: flags.contains(.maskControl), at: time, fnKey: keycode == 63 // kVK_Function
        ) {
            onAction(action)
        }
    }
}

private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let flags = event.flags
        let time = Double(event.timestamp) / 1_000_000_000
        let fromHardware = event.getIntegerValueField(.eventSourceStateID)
            == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let address = UInt(bitPattern: userInfo)
        // The tap's run loop source is on the main run loop.
        MainActor.assumeIsolated {
            let pointer = UnsafeMutableRawPointer(bitPattern: address)!
            Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue().handle(type: type, flags: flags, time: time, fromHardware: fromHardware, keycode: keycode)
        }
    }
    return Unmanaged.passUnretained(event)
}
