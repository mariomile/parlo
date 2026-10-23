import SwiftUI

struct MenuView: View {
    @Bindable var controller: AppController

    var body: some View {
        Text(controller.statusText)
        Text("Model: \(controller.models.activeInfo.displayName)")
        Divider()
        Toggle("AI Cleanup", isOn: aiCleanup)
        if controller.aiNeedsKey {
            Button("AI Cleanup needs an API key…") { show(.ai) }
        }
        Divider()
        Button("Copy Last Dictation") { controller.copyLastDictation() }
            .disabled(controller.lastDictation == nil)
        Divider()
        Button("Settings…") { show(.general) }
            .keyboardShortcut(",")
        Button("Permissions & Setup…") { controller.showOnboarding() }
        Divider()
        Button("Quit Parlo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Turning cleanup on without a key jumps straight to the AI tab to set one.
    private var aiCleanup: Binding<Bool> {
        Binding(
            get: { controller.settings.llm.enabled },
            set: { on in
                controller.settings.llm.enabled = on
                if controller.aiNeedsKey { show(.ai) }
            }
        )
    }

    private func show(_ tab: SettingsTab) { controller.showSettings(tab) }
}
