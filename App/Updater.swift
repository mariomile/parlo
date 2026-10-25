import Sparkle

/// Checks the GitHub releases feed for a newer Parlo and installs it, through Sparkle's standard windows.
/// Parlo has no Dock icon, so a scheduled check that finds an update while Parlo is in the background
/// doesn't throw a window over other apps: the menu shows `availableVersion` and the user opens it from there.
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    /// A newer version found by a scheduled check that the user hasn't looked at yet.
    private(set) var availableVersion: String?
    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    override init() {
        checksAutomatically = false
        super.init()
        // Debug builds run from DerivedData: an update would replace them with the release build.
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: self)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    func check() { controller.checkForUpdates(nil) }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { availableVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { availableVersion = nil }

    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil }
}
