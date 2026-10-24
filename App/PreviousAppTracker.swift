import AppKit

/// The last app other than Parlo to be frontmost, so the History window can paste back into it.
final class PreviousAppTracker {
    private(set) var app: NSRunningApplication?
    private var observer: (any NSObjectProtocol)?

    init() {
        app = Self.external(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app = Self.external(activated) { self?.app = app }
            }
        }
    }

    private static func external(_ app: NSRunningApplication?) -> NSRunningApplication? {
        app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }
}
