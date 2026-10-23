import SwiftUI

struct MenuView: View {
    let controller: AppController

    var body: some View {
        Text(controller.statusText)
        Text("Model: \(controller.models.activeInfo.displayName)")
        Divider()
        Button("Copy Last Dictation") { controller.copyLastDictation() }
            .disabled(controller.lastDictation == nil)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Permissions & Setup…") { controller.showOnboarding() }
        Divider()
        Button("Quit Parlo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
