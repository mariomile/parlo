import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
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
        .menuBarExtraStyle(.menu)
    }
}
