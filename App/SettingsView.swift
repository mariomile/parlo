import AppKit
import Combine
import ParloCore
import ParloEngines
import SwiftUI

enum SettingsTab: Hashable { case general, models, ai, styles, dictionary, snippets }

struct SettingsView: View {
    @Bindable var controller: AppController

    var body: some View {
        TabView(selection: $controller.settingsTab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralTab(controller: controller) }
            Tab("Models", systemImage: "square.and.arrow.down", value: .models) { ModelsTab(models: controller.models, localLLM: controller.localLLM) }
            Tab("AI", systemImage: "sparkles", value: .ai) { AITab(controller: controller) }
            Tab("Styles", systemImage: "textformat", value: .styles) { StylesTab(controller: controller) }
            Tab("Dictionary", systemImage: "character.book.closed", value: .dictionary) { DictionaryTab(controller: controller) }
            Tab("Snippets", systemImage: "text.badge.plus", value: .snippets) { SnippetsTab(controller: controller) }
        }
        .frame(width: 640, height: 500)
    }
}

// MARK: - General

let languages: [(code: String?, name: String)] = [
    (nil, "Auto-detect"), ("it", "Italian"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
    ("de", "German"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("ja", "Japanese"), ("zh", "Chinese"),
]

private struct GeneralTab: View {
    @Bindable var controller: AppController
    @State private var devices = AudioDevices.inputDevices()

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Dictate", value: "Hold fn")
                LabeledContent("Command mode", value: "Hold ctrl, then fn")
            }
            Section {
                Picker("Language", selection: $controller.settings.languageCode) {
                    ForEach(languages, id: \.name) { Text($0.name).tag($0.code) }
                }
                Picker("Microphone", selection: $controller.settings.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { Text($0.name).tag(Optional($0.id)) }
                }
            } footer: {
                if controller.models.activeInfo.requiresExplicitLanguage && controller.settings.languageCode == nil {
                    Text("\(controller.models.activeInfo.displayName) can't auto-detect: pick a language.")
                        .foregroundStyle(.orange)
                }
            }
            Section("Startup") {
                LoginItemToggle()
            }
            Section("Permissions") {
                PermissionStatus(title: "Microphone", granted: Permissions.microphone, pane: .microphone)
                PermissionStatus(title: "Accessibility", granted: Permissions.accessibility, pane: .accessibility)
                PermissionStatus(title: "Input Monitoring", granted: Permissions.inputMonitoring, pane: .inputMonitoring)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

private struct LoginItemToggle: View {
    @State private var on = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { on }, set: { newValue in
            do { try LoginItem.set(newValue); error = nil } catch { self.error = error.localizedDescription }
            refresh()
        }))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if needsApproval {
            LabeledContent("Allow Parlo in Login Items to finish") {
                Button("Open Settings") { LoginItem.openSystemSettings() }
            }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    /// The user can approve or remove the login item in System Settings while this is open.
    private func refresh() {
        on = LoginItem.isOn
        needsApproval = LoginItem.needsApproval
    }
}

private struct PermissionStatus: View {
    let title: String
    let granted: Bool
    let pane: Permissions.Pane

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings") { Permissions.open(pane) }
            }
        }
    }
}

// MARK: - Models

private struct ModelsTab: View {
    let models: ModelManager
    let localLLM: LocalLLMManager
    @State private var stored: [StoredFiles] = []
    @State private var pendingDelete: StoredFiles?
    @State private var deleteError: String?

    private var installedIDs: Set<ModelID> {
        Set(models.states.filter { $0.value == .installed }.keys)
    }

    var body: some View {
        Form {
            Section {
                if stored.isEmpty {
                    Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                }
                ForEach(stored) { item in
                    StoredRow(item: item, active: isActive(item)) { pendingDelete = item }
                }
            } header: {
                HStack {
                    Text("On this Mac")
                    Spacer()
                    Text("\(bytes(stored.reduce(0) { $0 + $1.bytes })) used").monospacedDigit()
                }
            } footer: {
                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                ForEach(ModelCatalog.all) { info in
                    ModelRow(models: models, info: info)
                }
            } header: {
                Text("All models")
            } footer: {
                Text("Ratings come from public benchmarks (Open ASR Leaderboard, model cards) and tests on Apple Silicon. Parakeet, Cohere and Nemotron models are stored in FluidAudio's shared folder, also used by FluidVoice. Deleting one here deletes it for FluidVoice too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await models.refresh()
            await rescan()
        }
        .onChange(of: installedIDs) { Task { await rescan() } }
        .onChange(of: localLLM.state) { Task { await rescan() } }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete \(bytes(item.bytes))", role: .destructive) { delete(item) }
        } message: { item in
            Text(deleteMessage(item))
        }
    }

    private func isActive(_ item: StoredFiles) -> Bool {
        if case let .model(id) = item.kind { return id == models.activeModelID }
        return false
    }

    private func deleteMessage(_ item: StoredFiles) -> String {
        switch item.kind {
        case .model:
            isActive(item)
                ? "Parlo switches to Apple Speech. You can download it again from the list below."
                : "You can download it again from the list below."
        case .cleanupModel: "AI cleanup with \(LocalLLM.displayName) stops working until you download it again in AI."
        case .vocabulary: "It downloads again the next time you dictate with Parakeet and have dictionary words."
        case .voiceDetection: "It downloads again on the next dictation."
        case .other: "Parlo doesn't use these files. If FluidVoice needs them, it downloads them again."
        }
    }

    private func delete(_ item: StoredFiles) {
        Task {
            if case let .model(id) = item.kind { await models.delete(id) }
            if case .cleanupModel = item.kind { await localLLM.delete() }
            do {
                try ModelStorage.delete(item)
                deleteError = nil
            } catch {
                deleteError = "Couldn't delete \(item.name): \(error.localizedDescription)"
            }
            await rescan()
        }
    }

    private func rescan() async {
        stored = await Task.detached { ModelStorage.scan() }.value
    }
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// One downloaded folder: what it is, its size on disk, and a delete button.
private struct StoredRow: View {
    let item: StoredFiles
    let active: Bool
    let onDelete: () -> Void

    private var detail: String {
        switch item.kind {
        case .model: active ? "Voice model, in use" : "Voice model"
        case .cleanupModel: "AI cleanup model"
        case .vocabulary: "Recognises your dictionary words with Parakeet"
        case .voiceDetection: "Needed for every dictation"
        case .other: "Not used by Parlo. May belong to FluidVoice or an old download."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(bytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if case .voiceDetection = item.kind {
                Image(systemName: "trash").foregroundStyle(.quaternary).help("Needed for dictation")
            } else {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete these files")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ModelRow: View {
    let models: ModelManager
    let info: ModelInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName).fontWeight(.medium)
                    if models.activeModelID == info.id {
                        Text("Active").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
                HStack(spacing: 12) {
                    Rating(label: "Italian", value: info.italian)
                    Rating(label: "English", value: info.english)
                    Rating(label: "Speed", value: info.speed)
                }
                .padding(.vertical, 2)
                Text("\(info.sizeLabel) · \(info.languages)").font(.caption).foregroundStyle(.secondary)
                if !info.note.isEmpty { Text(info.note).font(.caption).foregroundStyle(.secondary) }
                if case let .failed(message) = models.states[info.id] {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            ModelActions(models: models, id: info.id)
        }
        .padding(.vertical, 2)
    }
}

/// Five dots, or "No" when the model doesn't understand that language.
private struct Rating: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if value == 0 {
                Text("No").font(.caption).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { i in
                        Circle()
                            .fill(i <= value ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value == 0 ? "\(label): not supported" : "\(label): \(value) out of 5")
    }
}

/// Download / progress+cancel / use / delete for one model.
struct ModelActions: View {
    let models: ModelManager
    let id: ModelID

    var body: some View {
        let needsDownload = ModelCatalog.info(id).needsDownload
        HStack(spacing: 8) {
            switch models.states[id] ?? .notInstalled {
            case .notInstalled:
                Button("Download") { Task { await models.download(id) } }
            case let .downloading(fraction):
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption)
                Button("Cancel") { models.cancel(id) }
            case .failed:
                Button("Retry") { Task { await models.download(id) } }
            case .installed:
                if models.activeModelID != id { Button("Use") { models.select(id) } }
                if needsDownload {
                    Button(role: .destructive) { Task { await models.delete(id) } } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete model files")
                }
            }
        }
    }
}

// MARK: - AI

private struct Provider: Identifiable {
    let name: String
    let baseURL: String
    let model: String
    var id: String { name }
}

private let providers = [
    Provider(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
    Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    Provider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
    Provider(name: "Ollama (local)", baseURL: "http://localhost:11434/v1", model: "llama3.2"),
]

private struct AITab: View {
    @Bindable var controller: AppController
    @State private var key = ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var appleStatus = AppleIntelligenceClient.unavailableReason

    private static let apple = "Apple Intelligence"
    private static let local = "Local"
    private var llm: LLMSettings { controller.settings.llm }

    var body: some View {
        Form {
            Section {
                Toggle("Clean up dictation with AI", isOn: $controller.settings.llm.enabled)
            } footer: {
                Text("Removes filler words, fixes punctuation and self-corrections, adapts tone per app. Also required for command mode. Without it, Parlo pastes the raw transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Provider", selection: providerBinding) {
                    Text("Apple Intelligence (on-device)").tag(Self.apple)
                    Text("\(LocalLLM.displayName) (on this Mac)").tag(Self.local)
                    Divider()
                    ForEach(providers) { Text($0.name).tag($0.name) }
                    Text("Custom (OpenAI-compatible)").tag("Custom")
                }
                if llm.provider == .apple {
                    appleRows
                } else if llm.provider == .local {
                    localRows
                } else {
                    TextField("Base URL", text: $controller.settings.llm.baseURL)
                    TextField("Model", text: $controller.settings.llm.model)
                    LabeledContent("API key") {
                        HStack {
                            SecureField("Not set", text: $key).frame(maxWidth: 260)
                            Button("Save") { controller.apiKey = key.isEmpty ? nil : key }
                                .disabled(key == (controller.apiKey ?? ""))
                        }
                    }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing)
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .red).lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { key = controller.apiKey ?? "" }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            appleStatus = AppleIntelligenceClient.unavailableReason
        }
    }

    @ViewBuilder private var appleRows: some View {
        if let appleStatus {
            LabeledContent("Status") {
                HStack {
                    Label(appleStatus, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
            }
        } else {
            LabeledContent("Status") {
                Label("Ready. Runs on this Mac, no key needed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder private var localRows: some View {
        Text("Runs an open model inside Parlo: no key, no server, nothing leaves this Mac. Uses about 2.5 GB of memory while selected.")
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Model") {
            HStack(spacing: 8) {
                switch controller.localLLM.state {
                case .notInstalled:
                    Button("Download \(LocalLLM.sizeLabel)") { Task { await controller.downloadLocalLLM() } }
                case let .downloading(fraction):
                    ProgressView(value: fraction).frame(width: 90)
                    Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption)
                    Button("Cancel") { controller.localLLM.cancel() }
                case let .failed(message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("Retry") { Task { await controller.downloadLocalLLM() } }
                case .installed:
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(role: .destructive) { Task { await controller.localLLM.delete() } } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete model files")
                }
            }
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: {
                if llm.provider == .apple { return Self.apple }
                if llm.provider == .local { return Self.local }
                return providers.first { $0.baseURL == llm.baseURL }?.name ?? "Custom"
            },
            set: { name in
                testResult = nil
                if name == Self.apple {
                    controller.settings.llm.provider = .apple
                    return
                }
                if name == Self.local {
                    controller.settings.llm.provider = .local
                    return
                }
                controller.settings.llm.provider = .openAICompatible
                guard let p = providers.first(where: { $0.name == name }) else { return }
                controller.settings.llm.baseURL = p.baseURL
                controller.settings.llm.model = p.model
            }
        )
    }

    private func test() {
        testing = true
        testResult = nil
        let client: any ChatCompleting = switch llm.provider {
        case .apple: AppleIntelligenceClient()
        case .local: LocalLLMClient()
        case .openAICompatible: LLMClient(settings: llm, apiKey: key.isEmpty ? nil : key)
        }
        Task {
            do {
                let reply = try await client.complete(system: "Reply with the single word OK.", user: "ping", timeout: 10)
                testResult = (true, "Connected: \(reply.prefix(40))")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: - Styles

private struct StylesTab: View {
    @Bindable var controller: AppController
    @State private var adding = ""

    var body: some View {
        Form {
            let bundleIDs = allBundleIDs
            Section {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    HStack {
                        Picker(selection: styleBinding(bundleID)) {
                            ForEach(Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        } label: {
                            AppLabel(bundleID: bundleID)
                        }
                        RemoveButton(help: StyleResolver.defaults[bundleID] == nil ? "Remove" : "Reset to default") {
                            controller.settings.styleOverrides[bundleID] = nil
                        }
                        .opacity(controller.settings.styleOverrides[bundleID] == nil ? 0 : 1)
                        .disabled(controller.settings.styleOverrides[bundleID] == nil)
                    }
                }
            } header: {
                Text("Tone per app")
            } footer: {
                Text("Used by AI cleanup. Apps not listed get Neutral.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Add an app") {
                Picker("Running app", selection: $adding) {
                    Text("Choose…").tag("")
                    ForEach(runningApps(excluding: Set(bundleIDs)), id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                .onChange(of: adding) { _, bundleID in
                    guard !bundleID.isEmpty else { return }
                    controller.settings.styleOverrides[bundleID] = StyleResolver.style(for: bundleID, overrides: [:])
                    adding = ""
                }
            }
        }
        .formStyle(.grouped)
    }

    private var allBundleIDs: [String] {
        Set(StyleResolver.defaults.keys).union(controller.settings.styleOverrides.keys)
            .map { (id: $0, name: AppLabel.name(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(\.id)
    }

    private func runningApps(excluding listed: Set<String>) -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !listed.contains($0.0) }
            .sorted { $0.1 < $1.1 }
    }

    private func styleBinding(_ bundleID: String) -> Binding<Style> {
        Binding(
            get: { StyleResolver.style(for: bundleID, overrides: controller.settings.styleOverrides) },
            set: { controller.settings.styleOverrides[bundleID] = $0 }
        )
    }
}

private struct AppLabel: View {
    let bundleID: String

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed").frame(width: 18)
            }
            Text(Self.name(for: bundleID))
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @Bindable var controller: AppController
    @State private var term = ""
    @State private var heardAs = ""

    var body: some View {
        Form {
            Section {
                ForEach($controller.settings.dictionary) { $entry in
                    HStack {
                        TextField("Term", text: $entry.term).frame(maxWidth: 180)
                        HeardAsField(heardAs: $entry.heardAs)
                        RemoveButton(help: "Remove") {
                            controller.settings.dictionary.removeAll { $0.id == entry.id }
                        }
                    }
                }
            } header: {
                Text("Words Parlo should spell your way")
            } footer: {
                Text("“Heard as” variants are replaced exactly, even with AI off. Terms are also passed to the AI so it spells them right.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add") {
                HStack {
                    TextField("Term, e.g. Kubernetes", text: $term).frame(maxWidth: 180)
                    TextField("Heard as, e.g. deep agent, dip agent", text: $heardAs)
                    Button("Add") {
                        controller.settings.dictionary.append(DictionaryEntry(term: term, heardAs: Self.split(heardAs)))
                        term = ""
                        heardAs = ""
                    }
                    .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Edits the variants as free text; splits into the list when editing ends, so commas and spaces survive typing.
private struct HeardAsField: View {
    @Binding var heardAs: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Often heard as (comma-separated)", text: $text)
            .focused($focused)
            .onAppear { text = heardAs.joined(separator: ", ") }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let parsed = DictionaryTab.split(text)
        if parsed != heardAs { heardAs = parsed }
    }
}

private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: - Snippets

private struct SnippetsTab: View {
    @Bindable var controller: AppController
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                ForEach($controller.settings.snippets) { $snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            TextField("Trigger phrase", text: $snippet.trigger)
                            TextField("Expands to", text: $snippet.text, axis: .vertical).lineLimit(1...4)
                        }
                        RemoveButton(help: "Remove") {
                            controller.settings.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                }
            } header: {
                Text("Say a trigger phrase, get the saved text")
            } footer: {
                Text("Works on its own (“my calendar link”) or mid-sentence (“book a slot here my calendar link”).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add") {
                TextField("Trigger, e.g. my calendar link", text: $trigger)
                TextField("Text, e.g. https://cal.com/you", text: $text, axis: .vertical).lineLimit(1...4)
                Button("Add") {
                    controller.settings.snippets.append(Snippet(trigger: trigger, text: text))
                    trigger = ""
                    text = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}
