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

    /// The user's clipboard goes back once the target app has read the text, not after a guessed delay:
    /// a busy app that pastes late would otherwise paste the user's old clipboard instead.
    private static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let provider = PasteProvider(text: text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: PasteboardSnapshot.transientType)
        pb.clearContents()
        pb.writeObjects([item])
        let ours = pb.changeCount
        KeyPoster.paste()
        // Up to 3 s for the read (a field that can't take text never reads), then a beat for apps that read twice.
        for _ in 0..<150 where !provider.wasRead {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if provider.wasRead { try? await Task.sleep(for: .milliseconds(150)) }
        if pb.changeCount == ours { saved.restore(pb) }
    }
}

/// Supplies the pasted text only when an app asks for it, and notes that it did.
private final class PasteProvider: NSObject, @MainActor NSPasteboardItemDataProvider {
    let text: String
    private(set) var wasRead = false

    init(text: String) {
        self.text = text
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        wasRead = true
    }
}

enum SelectionReader {
    /// The selected text, read through Accessibility when the app exposes it; otherwise copied with Cmd+C,
    /// restoring the clipboard. Nil when nothing is selected.
    static func read() async -> String? {
        if let text = await FocusedElement.selectedText() { return text }
        return await ClipboardTurn.take { await copySelection() }
    }

    /// Waits up to 1 s: busy Electron apps can take a while to answer Cmd+C.

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

/// The element with keyboard focus, through Accessibility. Off the main thread: a slow app can take
/// a quarter second per call, and the hotkey tap runs on the main run loop.
nonisolated enum FocusedElement {
    /// Larger fields aren't read back: comparing them every few seconds isn't worth it.
    static let maxReadLength = 100_000

    @concurrent static func current() async -> (field: WatchedField?, focus: PasteTarget.Focus) {
        guard let element = focused() else { return (nil, focusError()) }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let focus = PasteTarget.Focus.element(
            role: string(element, kAXRoleAttribute),
            hasTextSelection: attribute(element, kAXSelectedTextRangeAttribute) != nil,
            valueSettable: settable.boolValue
        )
        return (WatchedField(element: element), focus)
    }

    static func focused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Why `focused()` found nothing: no focus at all, or no answer.
    private static func focusError() -> PasteTarget.Focus {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        return AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .noValue
            ? .nothing : .unknown
    }

    /// The focused element's selected text; nil when it has none, doesn't expose it, or is a password field.
    @concurrent static func selectedText() async -> String? {
        guard let element = focused(), !isSecure(element),
              let text = string(element, kAXSelectedTextAttribute), !text.isEmpty
        else { return nil }
        return text
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// The element's text, or nil for password fields, very long text, or no answer.
    static func text(_ element: AXUIElement) -> String? {
        guard !isSecure(element) else { return nil }
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count > maxReadLength { return nil }
        guard let text = string(element, kAXValueAttribute), text.count <= maxReadLength else { return nil }
        return text
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

/// The field Parlo just pasted into, watched for the user fixing a word.
nonisolated struct WatchedField: @unchecked Sendable { // AXUIElement can be used from any thread.
    let element: AXUIElement

    /// The field's text right after the paste, and again after 30 s or as soon as the user leaves the
    /// field or changes the text around the paste (a sent message, a cleared field).
    @concurrent func edit(of pasted: String) async -> (before: String, after: String)? {
        guard let before = FocusedElement.text(element), before.contains(pasted) else { return nil }
        var after = before
        for _ in 0..<15 {
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
            guard let now = FocusedElement.focused(), CFEqual(now, element),
                  let text = FocusedElement.text(element),
                  CorrectionDetector.isEditing(pasted: pasted, before: before, now: text)
            else { break }
            after = text
        }
        return (before, after)
    }
}

/// Opening Parlo when the user logs in, as a login item they can also see in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// Registered, including while it waits for the user's approval in System Settings.
    static var isOn: Bool { isEnabled || needsApproval }
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
