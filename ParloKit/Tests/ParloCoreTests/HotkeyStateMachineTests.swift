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
        #expect(m.keyPressed(at: 0.2) == .cancel(handsFree: false))
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

    // MARK: Hands-free

    @Test func holdIsNotADoubleTap() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 2) == .stop)
        // Pressed again right away after a real dictation: a new one, not hands-free.
        #expect(m.handle(fn: true, ctrl: false, at: 2.1) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 4) == .stop)
    }

    @Test func doubleTapLocksAndTapStops() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 10) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 10.1) == .stop)
        #expect(m.handle(fn: true, ctrl: false, at: 10.3) == .lock(command: false))
        // Releasing the second press keeps recording.
        #expect(m.handle(fn: false, ctrl: false, at: 10.4) == nil)
        // Ctrl alone while hands-free does nothing.
        #expect(m.handle(fn: false, ctrl: true, at: 20) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 20.1) == nil)
        // The next press stops; its release is swallowed.
        #expect(m.handle(fn: true, ctrl: false, at: 60) == .stop)
        #expect(m.handle(fn: false, ctrl: false, at: 60.1) == nil)
        // And the press after that is an ordinary dictation again.
        #expect(m.handle(fn: true, ctrl: false, at: 70) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 72) == .stop)
    }

    @Test func singleTapStopsLikeToday() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 0.1) == .stop)
        // Too late for a double tap.
        #expect(m.handle(fn: true, ctrl: false, at: 0.4) == .startDictation)
        #expect(m.handle(fn: false, ctrl: false, at: 3) == .stop)
    }

    @Test func keyBetweenTapsIsNotADoubleTap() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        #expect(m.keyPressed(at: 0.2) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 0.3) == .startDictation)
    }

    @Test func doubleTapWithCtrlLocksCommand() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: true, at: 0) == .startCommand)
        #expect(m.handle(fn: false, ctrl: true, at: 0.1) == .stop)
        #expect(m.handle(fn: true, ctrl: true, at: 0.3) == .lock(command: true))
        #expect(m.handle(fn: false, ctrl: false, at: 0.4) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 30) == .stop)
    }

    @Test func mixedModesAreNotADoubleTap() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        #expect(m.handle(fn: true, ctrl: true, at: 0.3) == .startCommand)
        #expect(m.handle(fn: false, ctrl: true, at: 0.4) == .stop)
        #expect(m.handle(fn: true, ctrl: false, at: 0.6) == .startDictation)
    }

    @Test func escapeCancelsHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        _ = m.handle(fn: false, ctrl: false, at: 0.4)
        // Typing while hands-free keeps the recording; Esc throws it away.
        #expect(m.keyPressed(at: 5) == nil)
        #expect(m.keyPressed(at: 6, escape: true) == .cancel(handsFree: true))
        #expect(m.handle(fn: true, ctrl: false, at: 7) == .startDictation)
    }

    @Test func escapeWhileHoldingIsAStrayKey() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        #expect(m.keyPressed(at: 2, escape: true) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 3) == .stop)
    }

    @Test func shortcutOnSecondPressCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        #expect(m.handle(fn: true, ctrl: false, at: 0.3) == .lock(command: false))
        // fn+Delete right after the second press is a shortcut, not hands-free dictation.
        #expect(m.keyPressed(at: 0.4) == .cancel(handsFree: false))
        #expect(m.handle(fn: false, ctrl: false, at: 0.5) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 2) == .startDictation)
    }

    @Test func resetLeavesHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        _ = m.handle(fn: false, ctrl: false, at: 0.4)
        m.reset()
        #expect(m.handle(fn: true, ctrl: false, at: 600) == .startDictation)
    }

    // MARK: Poll

    @Test func missedReleaseStopsAHeldDictation() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        #expect(m.poll(fnHeld: true, at: 100) == nil)
        #expect(m.poll(fnHeld: false, at: 100.1) == nil)
        #expect(m.poll(fnHeld: false, at: 100.4) == nil)
        #expect(m.poll(fnHeld: false, at: 100.6) == .stop)
        // The machine is idle: no double tap from the missed release, and the late release does nothing.
        #expect(m.handle(fn: false, ctrl: false, at: 3) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 3.1) == .startDictation)
    }

    @Test func pollDoesNotStopBeforeFnWasSeenHeld() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        for tick in 0..<100 {
            #expect(m.poll(fnHeld: false, at: Double(tick) * 0.1) == nil)
        }
        #expect(m.handle(fn: false, ctrl: false, at: 10) == .stop)
    }

    @Test func briefUpBlipsDoNotStop() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        #expect(m.poll(fnHeld: true, at: 0) == nil)
        #expect(m.poll(fnHeld: false, at: 1) == nil)
        #expect(m.poll(fnHeld: false, at: 1.4) == nil)
        #expect(m.poll(fnHeld: true, at: 1.5) == nil)
        // The up time starts over after the blip.
        #expect(m.poll(fnHeld: false, at: 1.6) == nil)
        #expect(m.poll(fnHeld: false, at: 2.0) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 2.1) == .stop)
    }

    @Test func missedReleaseOfTheSecondPressStillLetsTheNextPressStop() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        #expect(m.handle(fn: true, ctrl: false, at: 0.3) == .lock(command: false))
        // The tap never saw the release; the keyboard says fn is up.
        #expect(m.poll(fnHeld: false, at: 50) == nil)
        #expect(m.poll(fnHeld: false, at: 50.6) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 20) == .stop)
        #expect(m.handle(fn: false, ctrl: false, at: 20.1) == nil)
    }

    @Test func pollWithFnHeldKeepsTheSecondPressLocked() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        #expect(m.poll(fnHeld: true, at: 0) == nil)
        #expect(m.poll(fnHeld: false, at: 1) == nil)
        #expect(m.poll(fnHeld: true, at: 1.4) == nil)
        #expect(m.poll(fnHeld: false, at: 1.6) == nil)
        #expect(m.poll(fnHeld: false, at: 2.0) == nil)
        // Fn is still down for the machine: its release is the second press's release.
        #expect(m.handle(fn: false, ctrl: false, at: 2.1) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 30) == .stop)
    }

    @Test func recordingLimitStops() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        _ = m.handle(fn: false, ctrl: false, at: 0.4)
        // Poll times are on their own clock: the limit counts from the first poll.
        #expect(m.poll(fnHeld: false, at: 5000) == nil)
        #expect(m.poll(fnHeld: false, at: 5000 + HotkeyStateMachine.recordingLimit - 1) == nil)
        #expect(m.poll(fnHeld: false, at: 5000 + HotkeyStateMachine.recordingLimit) == .stop)
        #expect(m.handle(fn: true, ctrl: false, at: 700) == .startDictation)
    }

    @Test func heldRecordingStopsAtTheLimitWhenFnIsNeverSeen() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.poll(fnHeld: false, at: 100) == nil)
        #expect(m.poll(fnHeld: false, at: 100 + HotkeyStateMachine.recordingLimit) == .stop)
        #expect(m.handle(fn: false, ctrl: false, at: 700) == nil)
    }

    @Test func otherModifierAfterACancelDoesNotStartAgain() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.keyPressed(at: 0.1) == .cancel(handsFree: false))
        // Shift while Fn is still down reports Fn unchanged.
        #expect(m.handle(fn: true, ctrl: false, at: 0.5, fnKey: false) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 0.6) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 2) == .startDictation)
    }

    @Test func fnPressAfterAMissedReleaseStartsAgain() {
        var m = HotkeyStateMachine()
        #expect(m.handle(fn: true, ctrl: false, at: 0) == .startDictation)
        #expect(m.keyPressed(at: 0.1) == .cancel(handsFree: false))
        #expect(m.handle(fn: true, ctrl: false, at: 3, fnKey: true) == .startDictation)
    }

    @Test func recordingLimitWithFnDownIgnoresItsRelease() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        #expect(m.poll(fnHeld: true, at: 0) == nil)
        #expect(m.poll(fnHeld: true, at: HotkeyStateMachine.recordingLimit) == .stop)
        #expect(m.handle(fn: false, ctrl: false, at: 601) == nil)
        #expect(m.handle(fn: true, ctrl: false, at: 602) == .startDictation)
    }

    @Test func pollInIdleAndCancelledDoesNothing() {
        var m = HotkeyStateMachine()
        #expect(m.poll(fnHeld: false, at: 0) == nil)
        #expect(m.poll(fnHeld: true, at: 1) == nil)
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.keyPressed(at: 0.2)
        #expect(m.poll(fnHeld: true, at: 2) == nil)
        #expect(m.poll(fnHeld: false, at: 3) == nil)
        #expect(m.poll(fnHeld: false, at: 4) == nil)
        #expect(m.handle(fn: false, ctrl: false, at: 5) == nil)
    }

    @Test func missedReleaseAfterStoppingHandsFreeDoesNotSwallowTheNextPress() {
        var m = HotkeyStateMachine()
        _ = m.handle(fn: true, ctrl: false, at: 0)
        _ = m.handle(fn: false, ctrl: false, at: 0.1)
        _ = m.handle(fn: true, ctrl: false, at: 0.3)
        _ = m.handle(fn: false, ctrl: false, at: 0.4)
        #expect(m.handle(fn: true, ctrl: false, at: 20) == .stop)
        // The release of that press never arrived.
        #expect(m.handle(fn: true, ctrl: false, at: 30) == .startDictation)
    }
}
