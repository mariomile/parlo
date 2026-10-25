import Foundation
import Sparkle

// Uses a disposable host bundle and preference domain. The updater is never started.
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "parlo-update-policy-\(UUID().uuidString)")
let app = root.appending(path: "PolicyTest.app")
let contents = app.appending(path: "Contents")
let id = "com.example.parlo.policy.\(UUID().uuidString)"
try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
defer {
    UserDefaults.standard.removePersistentDomain(forName: id)
    try? FileManager.default.removeItem(at: root)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as! [String: Any]
info["CFBundleIdentifier"] = id
info["CFBundleExecutable"] = "PolicyTest"
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: contents.appending(path: "Info.plist"))
UserDefaults.standard.setPersistentDomain(["SUAutomaticallyUpdate": true, "SUEnableAutomaticChecks": true], forName: id)
let bundle = Bundle(url: app)!
let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
precondition(updater.automaticallyChecksForUpdates, "Update checks must remain available")
precondition(!updater.allowsAutomaticUpdates, "Automatic installation must require explicit product opt-in")
precondition(!updater.automaticallyDownloadsUpdates, "A previously saved automatic-update preference must not override policy")
print("PASS: update checks enabled; automatic downloads/installation disabled even with a saved opt-in")
