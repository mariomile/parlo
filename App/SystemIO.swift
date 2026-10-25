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
}

/// Saves and restores the general pasteboard around our temporary writes.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Set by password managers on what they copy.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

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

/// Every Parlo clipboard write takes a turn, including explicit History and Meeting copies.
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

    @discardableResult
    static func copy(_ text: String, if isCurrent: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        await take {
            guard isCurrent() else { return false }
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

enum TextInserter {
    enum Outcome: Sendable {
        /// The expected field changed to the exact text produced by replacing its selection.
        case pasted(WatchedField)
        /// A paste was sent but insertion could not be verified. Keep the text available for a manual paste.
        case leftOnClipboard
        case noTarget
        case targetChanged
        /// Insertion wasn't verified, and something else wrote the clipboard meanwhile.
        case lost
        case cancelled
    }

    /// Target and lifetime are checked inside the clipboard turn, after all asynchronous focus reads.
    static func insert(
        _ text: String, expectedPID: pid_t? = nil, selection: SelectionContext? = nil,
        if isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> Outcome {
        await ClipboardTurn.take {
            await paste(text, expectedPID: expectedPID, selection: selection, isCurrent: isCurrent)
        }
    }

    private static func paste(
        _ text: String, expectedPID: pid_t?, selection: SelectionContext?, isCurrent: @MainActor () -> Bool
    ) async -> Outcome {
        guard isCurrent() else { return .cancelled }
        let pid = selection?.processID ?? expectedPID ?? FrontmostApp.processID
        let target = await FocusedElement.current()
        let expectedValue = await target.field?.valueByInserting(text)
        guard isCurrent() else { return .cancelled }

        let pb = NSPasteboard.general
        // Reading a pasteboard provider can itself be slow. Save it before the final target check.
        let saved = PasteboardSnapshot(pb)
        guard isCurrent() else { return .cancelled }
        let acceptsText = PasteTarget.acceptsText(target.focus)
        let matches = FocusedElement.matches(target.field, selection: selection)
        // No suspension between this check and Cmd+V. History supplies its intended app; commands
        // also require the original field and selection. An unverifiable command is never pasted.
        let sameApp = pid != nil && FrontmostApp.processID == pid

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if acceptsText && matches && sameApp { item.setData(Data(), forType: PasteboardSnapshot.transientType) }
        pb.clearContents()
        guard pb.writeObjects([item]) else { return .lost }
        guard sameApp && matches else { return .targetChanged }
        guard acceptsText else { return .noTarget }
        // Pasteboard IPC can also take time. Revalidate after writing it, at the actual event boundary.
        guard FocusedElement.matches(target.field, selection: selection), FrontmostApp.processID == pid else { return .targetChanged }
        guard isCurrent() else { return .cancelled }
        let ours = pb.changeCount
        KeyPoster.paste()

        // A pasteboard read has no reader identity and proves nothing about insertion. Only a change
        // to the expected AX value allows restoration. Otherwise leave our text for even a late reader.
        for _ in 0..<30 {
            guard isCurrent() else { return .cancelled }
            if let expectedValue, let field = target.field, await field.hasValue(expectedValue) {
                guard isCurrent() else { return .cancelled }
                if pb.changeCount == ours { saved.restore(pb) }
                return .pasted(field)
            }
            guard pb.changeCount == ours else { return .lost }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return pb.changeCount == ours ? .leftOnClipboard : .lost
    }
}

/// An AX-verified command input. Empty text means a verified empty selection, not a failed read.
nonisolated struct SelectionContext: Sendable {
    let field: WatchedField
    let processID: pid_t
    let text: String
    let range: CFRange?
}

nonisolated enum CommandSelection: Sendable {
    case available(SelectionContext)
    case unavailable

    var context: SelectionContext? {
        if case let .available(context) = self { context } else { nil }
    }
    var text: String? { context.flatMap { $0.text.isEmpty ? nil : $0.text } }
}

enum SelectionReader {
    /// Cmd+C cannot identify the writer of a clipboard change. Never use it as command input.
    static func read(expectedPID: pid_t?) async -> CommandSelection {
        guard let expectedPID else { return .unavailable }
        let result = await FocusedElement.selection(expectedPID: expectedPID)
        guard FrontmostApp.processID == expectedPID else { return .unavailable }
        return result
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

    @concurrent static func selection(expectedPID: pid_t) async -> CommandSelection {
        guard let element = focused(), processID(element) == expectedPID, !isSecure(element),
              let text = selectedText(element), text.count <= maxReadLength else { return .unavailable }
        let context = SelectionContext(
            field: WatchedField(element: element), processID: expectedPID,
            text: text, range: selectedRange(element)
        )
        // AX can suspend while the user changes field or selection. Do not combine different contexts.
        guard matches(context.field, selection: context) else { return .unavailable }
        return .available(context)
    }

    static func processID(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        if let text = string(element, kAXSelectedTextAttribute) { return text }
        guard let range = selectedRange(element) else { return nil }
        if range.length == 0 { return "" }
        guard let value = text(element) as NSString?, range.location <= value.length,
              range.length <= value.length - range.location else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// Synchronous and bounded by the AX timeout: called immediately before the paste event.
    static func matches(_ field: WatchedField?, selection: SelectionContext?) -> Bool {
        guard let field else { return selection == nil }
        guard let now = focused(), CFEqual(now, field.element) else { return false }
        guard let selection else { return true }
        guard CFEqual(now, selection.field.element), processID(now) == selection.processID, !isSecure(now),
              selectedText(now) == selection.text else { return false }
        let range = selectedRange(now)
        return range?.location == selection.range?.location && range?.length == selection.range?.length
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

    @concurrent func valueByInserting(_ text: String) async -> String? {
        guard let before = FocusedElement.text(element), let range = FocusedElement.selectedRange(element) else { return nil }
        let value = before as NSString
        guard range.location <= value.length, range.length <= value.length - range.location else { return nil }
        let after = value.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        return after == before ? nil : after
    }

    @concurrent func hasValue(_ expected: String) async -> Bool {
        FocusedElement.text(element) == expected
    }

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
    static var processID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
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
