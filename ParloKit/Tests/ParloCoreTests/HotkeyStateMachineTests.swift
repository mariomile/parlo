import Testing
@testable import ParloCore

@Suite struct HotkeyStateMachineTests {
    @Test func fnAloneDictates() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.handle(fn: true, ctrl: false, at: 0) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 0) == .stop)
        #expect(m.handle(fn: false, ctrl: false, at: 0) == nil)
    }

    @Test func ctrlHeldAtPressIsCommand() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: false, ctrl: true, at: 0) == nil)
        #expect(m.handle(fn: true, ctrl: true, at: 0) == .startCommand)
        #expect(m.handle(fn: true, ctrl: false, at: 0) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 0) == .stop)
    }

    @Test func ctrlAddedAfterFnStaysDictation() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.handle(fn: true, ctrl: true, at: 0) == nil)
        #expect(m.handle(fn: false, ctrl: true, at: 0) == .stop)
    }

    @Test func keyWhileFnHeldCancels() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.keyPressed(at: 0.2) == .cancel)
        #expect(m.keyPressed(at: 0.2) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 0) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
    }

    @Test func keyLateInRecordingKeepsIt() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 10) == .startDictation)
        #expect(m.keyPressed(at: 12) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 15) == .stop)
    }

    @Test func keyWhileIdleIsIgnored() {
        var m = HotkeyStateMachine()
        #expect(m.keyPressed(at: 0.2) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
    }

    @Test func cancelResets() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        m.reset()
        #expect(m.handle(fn: false, ctrl: false, at: 0) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
    }
}
