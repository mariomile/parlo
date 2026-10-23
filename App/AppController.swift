import AppKit
import ParloCore
import ParloEngines
import SwiftUI

/// Owns app state and wires hotkey -> recorder -> pipeline -> paste / HUD.
@Observable
final class AppController {
    enum Phase: Equatable { case idle, recording, processing }

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            try? store.save(settings)
        }
    }
    /// Cached so the keychain is read once per launch.
    var apiKey: String? {
        didSet { KeychainStore.save(apiKey) }
    }
    private(set) var phase: Phase = .idle
    private(set) var lastDictation: String?
    private(set) var hotkeyActive = false
    let models: ModelManager

    private let store: SettingsStore
    private let hud = HUDController()
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private var current: (command: Bool, bundleID: String?, selection: Task<String?, Never>?)?
    private var levelTimer: Timer?
    private var tapRetryTimer: Timer?
    private var onboardingWindow: NSWindow?

    init() {
        let store = SettingsStore(directory: SettingsStore.appSupportDirectory)
        self.store = store
        let loaded = store.load()
        settings = loaded
        apiKey = KeychainStore.read()
        var onActiveChange: (ModelID) -> Void = { _ in }
        models = ModelManager(installer: EngineInstaller(), activeModelID: loaded.activeModelID) { onActiveChange($0) }
        onActiveChange = { [weak self] id in
            self?.settings.activeModelID = id
            self?.models.warmUp()
        }
    }

    func launch() {
        hotkey.onAction = { [weak self] action in self?.handle(action) }
        startHotkey()
        Task {
            await models.refresh()
            models.warmUp()
        }
        if !settings.hasCompletedOnboarding || !Permissions.allGranted { showOnboarding() }
    }

    /// The event tap can only be created once Input Monitoring is granted; retry until it is.
    private func startHotkey() {
        hotkeyActive = hotkey.start()
        guard !hotkeyActive, tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryHotkey() }
        }
    }

    private func retryHotkey() {
        hotkeyActive = hotkey.start()
        guard hotkeyActive else { return }
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
    }

    var llm: (any ChatCompleting)? {
        settings.llm.enabled ? LLMClient(settings: settings.llm, apiKey: apiKey) : nil
    }

    var statusText: String {
        switch phase {
        case .idle: hotkeyActive ? "Ready: hold fn to dictate" : "Needs Input Monitoring permission"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    func copyLastDictation() {
        guard let lastDictation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastDictation, forType: .string)
    }

    // MARK: - Dictation flow

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .startDictation: begin(command: false)
        case .startCommand: begin(command: true)
        case .stop: end()
        }
    }

    private func begin(command: Bool) {
        guard phase == .idle else { return }
        if let problem = blocker(command: command) {
            hud.show(.message(problem, isError: true))
            hotkey.reset()
            return
        }
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            hud.show(.message(error.localizedDescription, isError: true))
            hotkey.reset()
            return
        }
        phase = .recording
        current = (command, FrontmostApp.bundleID, command ? Task { await SelectionReader.read() } : nil)
        hud.show(.recording(command: command))
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hud.model.pushLevel(self.recorder.level)
            }
        }
    }

    /// Why a dictation can't start right now, as a HUD message.
    private func blocker(command: Bool) -> String? {
        if !Permissions.microphone { showOnboarding(); return "Parlo needs microphone access" }
        if !Permissions.accessibility { showOnboarding(); return "Parlo needs Accessibility access to paste" }
        let info = models.activeInfo
        if case let .downloading(p) = models.states[info.id] {
            return "\(info.displayName) is downloading (\(Int(p * 100))%)"
        }
        if info.requiresExplicitLanguage && settings.languageCode == nil {
            return "\(info.displayName) needs a language: set it in Settings → General"
        }
        if command && llm == nil { return CommandError.llmNotConfigured.localizedDescription }
        return nil
    }

    private func end() {
        guard phase == .recording, let current else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        let samples = recorder.stop()
        self.current = nil
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else {
            current.selection?.cancel()
            phase = .idle
            hud.hide()
            return
        }
        phase = .processing
        hud.show(.processing)
        Task {
            defer { phase = .idle }
            do {
                let transcriber = try await models.transcriber()
                if current.command {
                    let selection = await current.selection?.value
                    let outcome = try await CommandPipeline(
                        transcriber: transcriber, llm: llm, languageCode: settings.languageCode
                    ).run(samples: samples, selection: selection)
                    switch outcome {
                    case .discarded: hud.hide()
                    case .empty: hud.show(.message("Nothing heard", isError: false))
                    case let .result(text): await deliver(text, warning: nil)
                    }
                } else {
                    let outcome = try await DictationPipeline(
                        transcriber: transcriber, llm: llm, settings: settings
                    ).run(samples: samples, bundleID: current.bundleID)
                    switch outcome {
                    case .discarded: hud.hide()
                    case .empty: hud.show(.message("Nothing heard", isError: false))
                    case let .inserted(text, cleanupError):
                        await deliver(text, warning: cleanupError.map { "Pasted without AI cleanup: \($0)" })
                    }
                }
            } catch {
                hud.show(.message(error.localizedDescription, isError: true))
            }
        }
    }

    private func deliver(_ text: String, warning: String?) async {
        lastDictation = text
        await TextInserter.insert(text)
        if let warning { hud.show(.message(warning, isError: true)) } else { hud.hide() }
    }

    // MARK: - Windows

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Welcome to Parlo"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(controller: self))
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
    }
}
