// OS seams only. No live taps, input events, recorder, permissions, or app startup.
final class FakeTap {
    var valid = true
    var enabled = false
    var acceptsEnable = true
    var invalidations = 0
}
final class FakeSource {
    let tap: FakeTap
    var valid = true
    init(_ tap: FakeTap) { self.tap = tap }
}
enum FakeMode { case commonModes }
enum FakeOS {
    static let mainLoop = 1
    static var taps: [FakeTap] = []
    static var attached: [FakeSource] = []
    static var removed: [FakeSource] = []
    static var failCreate = false
    static var failSource = false
    static var rejectNewEnable = false
    static var flags: CGEventFlags = []
    static var now: Double = 0
    static func reset() {
        taps = []; attached = []; removed = []
        failCreate = false; failSource = false; rejectNewEnable = false
        flags = []; now = 0
    }
    static func create(tap: CGEventTapLocation, place: CGEventTapPlacement,
                       options: CGEventTapOptions, eventsOfInterest: CGEventMask,
                       callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> FakeTap? {
        precondition(tap == .cgSessionEventTap && place == .headInsertEventTap && options == .listenOnly)
        precondition(eventsOfInterest == 5120 && userInfo != nil)
        if failCreate { return nil }
        let port = FakeTap(); port.acceptsEnable = !rejectNewEnable
        taps.append(port)
        return port
    }
    static func enable(tap: FakeTap, enable: Bool) {
        tap.enabled = enable && tap.valid && tap.acceptsEnable
    }
    static func isEnabled(tap: FakeTap) -> Bool { tap.enabled }
    static func isValid(_ tap: FakeTap) -> Bool { tap.valid }
    static func createSource(_ allocator: CFAllocator?, _ tap: FakeTap, _ order: CFIndex) -> FakeSource? {
        failSource ? nil : FakeSource(tap)
    }
    static func addSource(_ loop: Int, _ source: FakeSource?, _ mode: FakeMode) {
        precondition(loop == mainLoop)
        if let source { attached.append(source) }
    }
    static func removeSource(_ loop: Int, _ source: FakeSource?, _ mode: FakeMode) {
        precondition(loop == mainLoop)
        if let source {
            precondition(attached.contains { $0 === source }, "Removing the wrong run loop source")
            attached.removeAll { $0 === source }; removed.append(source)
        }
    }
    static func invalidateSource(_ source: FakeSource) {
        precondition(!attached.contains { $0 === source }, "Source must be detached first")
        source.valid = false
    }
    static func invalidateTap(_ tap: FakeTap) {
        precondition(!attached.contains { $0.tap === tap }, "Callback source must be detached before port invalidation")
        tap.valid = false; tap.enabled = false; tap.invalidations += 1
    }
}

// Timer and run loop seams for the extracted parent-owned controller methods.
final class FakeTimer {
    let interval: Double
    let repeats: Bool
    private let block: @Sendable (FakeTimer) -> Void
    var invalidated = false
    init(timeInterval: Double, repeats: Bool, block: @escaping @Sendable (FakeTimer) -> Void) {
        interval = timeInterval; self.repeats = repeats; self.block = block
    }
    static func scheduledTimer(withTimeInterval: Double, repeats: Bool,
                               block: @escaping @Sendable (FakeTimer) -> Void) -> FakeTimer {
        FakeTimer(timeInterval: withTimeInterval, repeats: repeats, block: block)
    }
    func invalidate() { invalidated = true }
    func fire() { if !invalidated { block(self) } }
}
final class FakeRunLoop {
    enum Mode { case common }
    static let main = FakeRunLoop()
    var registrations: [FakeTimer] = []
    func add(_ timer: FakeTimer, forMode: Mode) { registrations.append(timer) }
}
final class ControllerHotkey {
    var allowed = true
    var starts = 0
    var polls = 0
    func start() -> Bool { starts += 1; return allowed }
    func poll() { polls += 1 }
}
final class ControllerProbe {
    var hotkeyActive = false
    var tapRetryTimer: FakeTimer?
    var isTerminating = false
    let hotkey = ControllerHotkey()
    // PRODUCTION_CONTROLLER_METHODS
}

@main struct HotkeyMonitorRegressions {
    @MainActor static func main() {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            if value() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
        }
        func withMonitor(_ body: (HotkeyMonitor) -> Void) {
            FakeOS.reset()
            let monitor = HotkeyMonitor()
            body(monitor)
        }
        withMonitor { monitor in
            check(monitor.start(), "initial creation")
            let original = FakeOS.taps[0]
            original.enabled = false // No disabled callback arrives.
            check(!monitor.isRunning, "lost notification reports unhealthy")
            check(monitor.start() && monitor.isRunning && original.enabled, "repeated start restores disabled tap")
            for _ in 0..<20 { _ = monitor.start() }
            check(FakeOS.taps.count == 1 && FakeOS.attached.count == 1, "healthy checks never duplicate tap/source")
        }
        withMonitor { monitor in
            _ = monitor.start()
            let old = FakeOS.taps[0]
            let source = FakeOS.attached[0]
            old.enabled = false; old.acceptsEnable = false
            check(monitor.start() && monitor.isRunning && FakeOS.taps.count == 2, "failed enable replaces tap")
            check(!old.valid && old.invalidations == 1 && !source.valid && FakeOS.removed.contains { $0 === source },
                  "replacement removes and invalidates exact old source and port")
            check(FakeOS.attached.count == 1, "replacement leaves exactly one source")
        }
        withMonitor { monitor in
            _ = monitor.start()
            let old = FakeOS.taps[0]
            old.valid = false // Deliberately stale enabled readback.
            check(!monitor.isRunning, "invalid tap reports unhealthy even if enabled")
            check(monitor.start() && FakeOS.taps.count == 2, "invalid tap recreated")
        }
        withMonitor { monitor in
            FakeOS.failCreate = true
            check(!monitor.start() && !monitor.isRunning && FakeOS.attached.isEmpty, "creation failure is retryable")
            FakeOS.failCreate = false
            check(monitor.start() && monitor.isRunning, "creation retry succeeds")
        }
        withMonitor { monitor in
            var actions: [HotkeyAction] = []
            monitor.onAction = { actions.append($0) }
            _ = monitor.start()
            monitor.handle(type: .flagsChanged, flags: [.maskSecondaryFn, .maskControl], time: 10, fromHardware: true, keycode: 63)
            FakeOS.taps[0].valid = false; FakeOS.failCreate = true
            check(!monitor.start() && !monitor.isRunning && FakeOS.attached.isEmpty,
                  "replacement creation failure retires stale callback source")
            check(actions == [.startCommand], "failed recovery does not discard active command")
            FakeOS.failCreate = false
            check(monitor.start() && monitor.isRunning, "repeated start retries failed replacement")
            monitor.handle(type: .flagsChanged, flags: [], time: 12, fromHardware: true, keycode: 63)
            check(actions == [.startCommand, .stop], "replacement retry preserves command release")
        }
        withMonitor { monitor in
            FakeOS.rejectNewEnable = true
            check(!monitor.start() && !monitor.isRunning, "new tap enable failure reports failure")
            check(FakeOS.attached.isEmpty && FakeOS.taps.allSatisfy { !$0.valid }, "failed new tap releases resources")
            FakeOS.rejectNewEnable = false
            check(monitor.start(), "retry after new enable failure")
        }
        withMonitor { monitor in
            FakeOS.failSource = true
            check(!monitor.start() && !monitor.isRunning, "source creation failure reports failure")
            check(FakeOS.taps.allSatisfy { !$0.valid } && FakeOS.attached.isEmpty, "source failure invalidates port")
            FakeOS.failSource = false
            check(monitor.start(), "source creation retry")
        }
        for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            withMonitor { monitor in
                var actions: [HotkeyAction] = []
                monitor.onAction = { actions.append($0) }
                _ = monitor.start()
                monitor.handle(type: .flagsChanged, flags: .maskSecondaryFn, time: 10, fromHardware: true, keycode: 63)
                let old = FakeOS.taps[0]; old.enabled = false; old.acceptsEnable = false
                monitor.handle(type: disabled, flags: [], time: 11, fromHardware: false, keycode: 0)
                check(monitor.isRunning && FakeOS.taps.count == 2, "disabled callback recovers \(disabled.rawValue)")
                monitor.handle(type: .flagsChanged, flags: [], time: 12, fromHardware: true, keycode: 63)
                check(actions == [.startDictation, .stop], "callback recovery preserves active hold \(disabled.rawValue)")
            }
        }
        withMonitor { monitor in
            var actions: [HotkeyAction] = []
            monitor.onAction = { actions.append($0) }
            _ = monitor.start()
            monitor.handle(type: .flagsChanged, flags: .maskSecondaryFn, time: 10, fromHardware: true, keycode: 63)
            FakeOS.flags = .maskSecondaryFn; FakeOS.now = 100; monitor.poll()
            FakeOS.taps[0].valid = false; _ = monitor.start()
            FakeOS.flags = []; FakeOS.now = 101; monitor.poll()
            check(actions == [.startDictation], "missed release waits for debounce")
            FakeOS.now = 101.6; monitor.poll(); monitor.poll()
            check(actions == [.startDictation, .stop], "idle timer poll stops missed release once without recorder")
        }
        withMonitor { monitor in
            var actions: [HotkeyAction] = []
            monitor.onAction = { actions.append($0) }
            _ = monitor.start()
            monitor.handle(type: .flagsChanged, flags: .maskSecondaryFn, time: 1, fromHardware: true, keycode: 63)
            monitor.handle(type: .flagsChanged, flags: [], time: 1.1, fromHardware: true, keycode: 63)
            monitor.handle(type: .flagsChanged, flags: .maskSecondaryFn, time: 1.2, fromHardware: true, keycode: 63)
            FakeOS.taps[0].enabled = false; _ = monitor.start()
            monitor.handle(type: .flagsChanged, flags: [], time: 1.3, fromHardware: true, keycode: 63)
            monitor.handle(type: .keyDown, flags: [], time: 2, fromHardware: false, keycode: 53)
            check(actions == [.startDictation, .stop, .lock(command: false)], "recovery preserves hands-free and ignores synthetic escape")
            monitor.handle(type: .keyDown, flags: [], time: 2, fromHardware: true, keycode: 53)
            check(actions.last == .cancel(handsFree: true), "hardware escape keeps existing action")
        }
        FakeOS.reset()
        var monitor: HotkeyMonitor? = HotkeyMonitor()
        weak let weakMonitor = monitor
        _ = monitor?.start()
        let port = FakeOS.taps[0]; let source = FakeOS.attached[0]
        monitor = nil
        check(weakMonitor == nil && !port.valid && !source.valid && FakeOS.attached.isEmpty,
              "deinit detaches callback source and invalidates tap without retaining monitor")
        let controller = ControllerProbe()
        controller.startHotkey()
        let timer = controller.tapRetryTimer
        check(controller.hotkeyActive && timer != nil, "controller keeps health timer after initial success")
        check(timer?.interval == 0.25 && timer?.repeats == true && FakeRunLoop.main.registrations.count == 1,
              "controller registers one repeating quarter-second timer in common modes")
        controller.hotkey.allowed = false; timer?.fire()
        check(!controller.hotkeyActive && controller.hotkey.polls == 2,
              "controller checks tap and polls release while idle even when tap fails")
        controller.hotkey.allowed = true; timer?.fire()
        check(controller.hotkeyActive && controller.tapRetryTimer === timer && timer?.invalidated == false,
              "controller recovery keeps original timer alive")
        controller.startHotkey()
        check(controller.tapRetryTimer === timer && FakeRunLoop.main.registrations.count == 1,
              "repeated controller setup never duplicates timer")
        let starts = controller.hotkey.starts; let polls = controller.hotkey.polls
        controller.isTerminating = true; timer?.fire()
        check(controller.hotkey.starts == starts && controller.hotkey.polls == polls,
              "termination suppresses both recovery and polling")
        print("\(failures) failures")
        if failures > 0 { exit(1) }
    }
}
