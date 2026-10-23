import Combine
import ParloCore
import SwiftUI

/// First-run checklist: permissions, the Fn key setting, and a model offer.
struct OnboardingView: View {
    let controller: AppController
    @State private var mic = Permissions.microphone
    @State private var accessibility = Permissions.accessibility
    @State private var inputMonitoring = Permissions.inputMonitoring
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Parlo").font(.title.bold())
                Text("Hold fn, speak, release. Your words land in whatever app you're typing in.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Permissions") {
                VStack(spacing: 10) {
                    PermissionRow(title: "Microphone", detail: "To hear you.", granted: mic) {
                        Task { await Permissions.requestMicrophone(); mic = Permissions.microphone }
                    }
                    PermissionRow(title: "Accessibility", detail: "To paste into other apps.", granted: accessibility) {
                        Permissions.requestAccessibility()
                    }
                    PermissionRow(title: "Input Monitoring", detail: "To notice when you hold fn.", granted: inputMonitoring) {
                        Permissions.requestInputMonitoring()
                    }
                    if inputMonitoring && !controller.hotkeyActive {
                        HStack {
                            Text("macOS applies Input Monitoring after a restart.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart Parlo") { controller.relaunch() }
                        }
                    }
                }
                .padding(6)
            }

            GroupBox("The fn key") {
                HStack(alignment: .top) {
                    Text("In System Settings → Keyboard, set **Press 🌐 key to: Do Nothing**, so fn doesn't open the emoji picker. Hold **ctrl**, then **fn**, for command mode.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Keyboard") { Permissions.open(.keyboard) }
                }
                .padding(6)
            }

            GroupBox("Speech model") {
                ModelOffer(controller: controller).padding(6)
            }

            HStack {
                Spacer()
                Button("Done") { controller.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(poll) { _ in
            mic = Permissions.microphone
            accessibility = Permissions.accessibility
            inputMonitoring = Permissions.inputMonitoring
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: request) }
        }
    }
}

/// Offers Parakeet v3, the recommended model.
private struct ModelOffer: View {
    let controller: AppController
    private let id = ModelID.parakeetV3

    var body: some View {
        let info = ModelCatalog.info(id)
        let models = controller.models
        HStack {
            VStack(alignment: .leading) {
                Text("\(info.displayName) (recommended)")
                Text("Active: \(models.activeInfo.displayName). \(info.sizeLabel) download, works offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ModelActions(models: models, id: id)
        }
    }
}
