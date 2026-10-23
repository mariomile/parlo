import AppKit
import ApplicationServices
import AVFoundation
import ParloCore
import ServiceManagement

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

/// Pasting and reading the selection both borrow the clipboard. They take turns, so neither saves
/// the other's temporary text as the user's clipboard and restores that instead.
enum ClipboardTurn {
    private static var last: Task<Void, Never>?

    static func take<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = last
        let turn = Task { @MainActor in
            await previous?.value
            return await body()
        }
        last = Task { _ = await turn.value }
        return await turn.value
    }
}

enum TextInserter {
    /// Pastes `text` into the focused field, then puts the user's clipboard back.
    static func insert(_ text: String) async {
        await ClipboardTurn.take { await paste(text) }
    }

    private static func paste(_ text: String) async {
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
        await ClipboardTurn.take { await copySelection() }
    }

    private static func copySelection() async -> String? {
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

/// The element with keyboard focus, through Accessibility.
enum FocusedElement {
    /// Larger fields aren't read back: comparing them every few seconds isn't worth it.
    static let maxReadLength = 100_000

    static func current() -> (element: AXUIElement?, focus: PasteTarget.Focus) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, .unknown) }
            let element = value as! AXUIElement
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            let focus = PasteTarget.Focus.element(
                role: string(element, kAXRoleAttribute),
                hasTextSelection: attribute(element, kAXSelectedTextRangeAttribute) != nil,
                valueSettable: settable.boolValue
            )
            return (element, focus)
        case .noValue: return (nil, .nothing)
        default: return (nil, .unknown)
        }
    }

    /// The element's text, or nil for password fields, very long text, or no answer.
    static func text(_ element: AXUIElement) -> String? {
        guard string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole as String,
              string(element, kAXRoleAttribute) != "AXSecureTextField",
              let text = string(element, kAXValueAttribute), text.count <= maxReadLength
        else { return nil }
        return text
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        guard let now = current().element else { return false }
        return CFEqual(now, element)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}

/// Opening Parlo when the user logs in, as a login item they can also see in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
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
    /// "Press 🌐 key to" opens the emoji picker or Apple Dictation (2, 3), which fights the fn hotkey.
    static var globeKeyConflicts: Bool {
        [2, 3].contains(UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType"))
    }

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
