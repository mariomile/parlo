import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }

    /// Quit from the menu, Cmd+Q, logout or a system update: the dictation in progress is kept for Retry,
    /// the meeting in progress to process again with ↻.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let flush = controller.prepareForTermination() else {
            return controller.terminationSaveSucceeded() ? .terminateNow : .terminateCancel
        }
        terminationPending = true
        Task {
            await flush.value
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: controller.terminationSaveSucceeded())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Idempotent final drain; normal quit/logout already flushed via applicationShouldTerminate.
        _ = controller.prepareForTermination()
    }
}

@main
struct ParloApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: delegate.controller)
        } label: {
            if delegate.controller.phase == .idle {
                Image("MenuBarMark")
            } else {
                Image(systemName: "mic.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
