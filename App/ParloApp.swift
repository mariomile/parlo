import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }

    /// Quit from the menu, Cmd+Q, logout or a system update: the dictation in progress is kept for Retry,
    /// the meeting in progress to process again with ↻.
    func applicationWillTerminate(_ notification: Notification) {
        controller.finishRecording()
        controller.meetings.terminate()
    }
}

@main
struct ParloApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.phase == .idle ? "waveform" : "mic.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
