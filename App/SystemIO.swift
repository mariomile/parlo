import AppKit
import ApplicationServices
import AVFoundation

/// Synthesized keyboard shortcuts (needs Accessibility).
enum KeyPoster {
    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func paste() { post(keyCode: 9, flags: .maskCommand) } // V
    static func copy() { post(keyCode: 8, flags: .maskCommand) } // C
}

/// Saves and restores the general pasteboard around our temporary writes.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init(_ pb: NSPasteboard = .general) {
        items = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    func restore(_ pb: NSPasteboard = .general) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        })
    }
}

enum TextInserter {
    /// Pastes `text` into the focused field, then puts the user's clipboard back.
    static func insert(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: PasteboardSnapshot.transientType)
        let ours = pb.changeCount
        KeyPoster.paste()
        try? await Task.sleep(for: .milliseconds(600))
        if pb.changeCount == ours { saved.restore(pb) }
    }
}

enum SelectionReader {
    /// Copies the current selection with Cmd+C and restores the clipboard. Nil when nothing is selected.
    /// Waits up to 1 s: busy Electron apps can take a while to answer Cmd+C.
    static func read() async -> String? {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let before = pb.changeCount
        KeyPoster.copy()
        for _ in 0..<50 where pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        saved.restore(pb)
        return text?.isEmpty == false ? text : nil
    }
}

enum FrontmostApp {
    static var bundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
}

enum Permissions {
    enum Pane: String {
        case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    }

    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var allGranted: Bool { microphone && accessibility && inputMonitoring }

    static func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            open(.microphone)
        }
    }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { open(.accessibility) }
    }

    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { open(.inputMonitoring) }
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: pane.rawValue)!)
    }
}
