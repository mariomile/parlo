import Testing
@testable import ParloCore

@Suite struct HotkeyStateMachineTests {
    @Test func fnAloneDictates() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
        #expect(m.handle(fn: true, ctrl: false) == nil)
        #expect(m.handle(fn: false, ctrl: false) == .stop)
        #expect(m.handle(fn: false, ctrl: false) == nil)
    }

    @Test func ctrlHeldAtPressIsCommand() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: false, ctrl: true) == nil)
        #expect(m.handle(fn: true, ctrl: true) == .startCommand)
        #expect(m.handle(fn: true, ctrl: false) == nil)
        #expect(m.handle(fn: false, ctrl: false) == .stop)
    }

    @Test func ctrlAddedAfterFnStaysDictation() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
        #expect(m.handle(fn: true, ctrl: true) == nil)
        #expect(m.handle(fn: false, ctrl: true) == .stop)
    }

    @Test func keyWhileFnHeldCancels() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
        #expect(m.keyPressed() == .cancel)
        #expect(m.keyPressed() == nil)
        #expect(m.handle(fn: false, ctrl: false) == nil)
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
    }

    @Test func keyWhileIdleIsIgnored() {
        var m = HotkeyStateMachine()
        #expect(m.keyPressed() == nil)
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
    }

    @Test func cancelResets() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false)
        m.reset()
        #expect(m.handle(fn: false, ctrl: false) == nil)
        #expect(m.handle(fn: true, ctrl: false) == .startDictation)
    }
}
