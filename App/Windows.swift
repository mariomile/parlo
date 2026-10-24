import AppKit
import SwiftUI

/// The app's own windows, built on first use and kept for the session. Owned here rather than as SwiftUI
/// scenes: those don't open from a menu bar–only app.
final class Windows {
    enum Slot { case onboarding, settings, history }

    private var windows: [Slot: NSWindow] = [:]

    func present(
        _ slot: Slot, title: String, size: NSSize, style: NSWindow.StyleMask = [.titled, .closable],
        minSize: NSSize? = nil, content: () -> some View
    ) {
        if windows[slot] == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            if let minSize { window.contentMinSize = minSize }
            window.contentView = NSHostingView(rootView: content())
            window.center()
            windows[slot] = window
        }
        NSApp.activate()
        windows[slot]?.makeKeyAndOrderFront(nil)
    }

    func hide(_ slot: Slot) { windows[slot]?.orderOut(nil) }

    func close(_ slot: Slot) { windows[slot]?.close() }
}
