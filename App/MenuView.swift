import ParloCore
import ParloEngines
import SwiftUI

/// The menu bar panel: what Parlo is doing, the three choices that change a dictation, and the last result.
struct MenuView: View {
    @Bindable var controller: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            VStack(spacing: 2) {
                if let problem = setupProblem { problemRow(problem) }
                modelRow
                languageRow
                aiRow
            }
            .padding(6)
            if !controller.suggestions.isEmpty {
                Divider().opacity(0.5)
                suggestionsSection
            }
            if !controller.recent.isEmpty {
                Divider().opacity(0.5)
                recentSection
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Parlo").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    StatusPill(phase: controller.phase, ready: controller.hotkeyActive && setupProblem == nil)
                }
                HStack(spacing: 4) {
                    Key("fn")
                    Text("dictate").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Key("ctrl")
                    Key("fn")
                    Text("command").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Settings rows

    private var modelRow: some View {
        Row(icon: "waveform", tint: .blue, title: "Voice model") {
            Menu {
                ForEach(installedModels) { info in
                    Button {
                        controller.models.select(info.id)
                    } label: {
                        if info.id == controller.models.activeModelID {
                            Label(info.displayName, systemImage: "checkmark")
                        } else {
                            Text(info.displayName)
                        }
                    }
                }
                Divider()
                Button("Get more models…") { open(.models) }
            } label: {
                Text(controller.models.activeInfo.displayName)
            }
        }
    }

    private var languageRow: some View {
        Row(icon: "globe", tint: .teal, title: "Language") {
            Picker("", selection: $controller.settings.languageCode) {
                ForEach(languages, id: \.name) { Text($0.name).tag($0.code) }
            }
        }
    }

    private var aiRow: some View {
        Row(
            icon: "sparkles", tint: .purple, title: "AI cleanup",
            subtitle: controller.settings.llm.enabled ? providerName : "Pastes the raw transcript"
        ) {
            Toggle("", isOn: $controller.settings.llm.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func problemRow(_ problem: (text: String, tab: SettingsTab?)) -> some View {
        Button {
            if let tab = problem.tab { open(tab) } else { controller.showOnboarding(); dismiss() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem.text).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressableStyle())
        .padding(.bottom, 4)
    }

    // MARK: Dictionary suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ADD TO DICTIONARY?")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
            ForEach(controller.suggestions.prefix(3)) { entry in
                SuggestionRow(
                    entry: entry,
                    add: { controller.acceptSuggestion(entry) },
                    dismiss: { controller.dismissSuggestion(entry) }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Show all") {
                    controller.showHistory()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            ForEach(controller.recent.prefix(5)) { entry in
                RecentRow(entry: entry, copy: { controller.copy(entry) }, retry: { controller.retry(entry) })
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Settings", icon: "gearshape") { open(.general) }
                .keyboardShortcut(",")
            FooterButton(title: "Permissions", icon: "lock.shield") {
                controller.showOnboarding()
                dismiss()
            }
            Spacer()
            FooterButton(title: "Quit", icon: "power") { controller.quit() }
                .keyboardShortcut("q")
        }
        .padding(6)
    }

    // MARK: Helpers

    private var installedModels: [ModelInfo] {
        ModelCatalog.all.filter { !$0.needsDownload || controller.models.states[$0.id] == .installed }
    }

    private var providerName: String {
        let llm = controller.settings.llm
        if llm.provider == .apple { return "Apple Intelligence, on this Mac" }
        if llm.provider == .local { return "\(CleanupModel.displayName), on this Mac" }
        return URL(string: llm.baseURL)?.host().map { "\(llm.model) via \($0)" } ?? llm.model
    }

    /// The one thing blocking a dictation right now, with where to fix it.
    private var setupProblem: (text: String, tab: SettingsTab?)? {
        if !controller.hotkeyActive || !Permissions.microphone || !Permissions.accessibility {
            return ("Finish setup: permissions missing", nil)
        }
        if Permissions.globeKeyConflicts { return ("Set “Press 🌐 key to” to Do Nothing", nil) }
        return controller.aiProblem.map { ($0, .ai) }
    }

    private func open(_ tab: SettingsTab) {
        controller.showSettings(tab)
        dismiss()
    }
}

// MARK: - Pieces

private struct Row<Accessory: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory
                .labelsHidden()
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

/// A word the user fixed after a paste, offered as a dictionary entry.
private struct SuggestionRow: View {
    let entry: DictionaryEntry
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term).font(.system(size: 12.5, weight: .medium))
                Text(entry.heardAs.isEmpty ? "Spelling you used" : "Heard as “\(entry.heardAs.joined(separator: ", "))”")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add", action: add).controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Not this one")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// One saved dictation: its text, or why there is none, with copy and retry.
private struct RecentRow: View {
    let entry: HistoryEntry
    let copy: () -> Void
    let retry: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = entry.statusLine
        return
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(label.dimmed ? .secondary : .primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.text != nil {
                CopyButton(copy: copy, label: icon)
                    .buttonStyle(PressableStyle())
            }
            if entry.hasAudio && entry.status != .processing {
                iconButton("arrow.clockwise", help: "Transcribe again and copy", action: retry)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(name) }
            .buttonStyle(PressableStyle())
            .help(help)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 24)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct StatusPill: View {
    let phase: AppController.Phase
    let ready: Bool

    private var label: (String, Color) {
        switch phase {
        case .recording: ("Listening", .red)
        case .processing: ("Working", .purple)
        case .idle: ready ? ("Ready", .green) : ("Setup", .orange)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(label.1).frame(width: 6, height: 6)
            Text(label.0).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(label.1.opacity(0.14), in: Capsule())
        .animation(.easeOut(duration: 0.2), value: phase)
    }
}

private struct Key: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
