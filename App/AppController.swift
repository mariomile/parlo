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
            do { try store.save(settings) } catch {
                hud.show(.message("Couldn't save settings: \(error.localizedDescription)", isError: true))
            }
        }
    }
    /// Cached so the keychain is read once per launch.
    var apiKey: String? {
        didSet {
            if !KeychainStore.save(apiKey) { hud.show(.message("Couldn't save the API key to the Keychain", isError: true)) }
        }
    }
    private(set) var phase: Phase = .idle
    /// Every kept entry, newest first, as on disk.
    private(set) var recent: [HistoryEntry] = []
    private(set) var hotkeyActive = false
    /// Words the user fixed right after a paste, offered for the dictionary. Newest first.
    private(set) var suggestions: [DictionaryEntry] = []
    /// Progress (0 to 1) of audio files being transcribed, by history entry id. Absent while queued.
    private(set) var fileProgress: [String: Double] = [:]
    var settingsTab: SettingsTab = .general
    let models: ModelManager

    private let store: SettingsStore
    private let hud = HUDController()
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let preview = LivePreviewer()
    private struct Recording {
        let command: Bool
        let bundleID: String?
        let selection: Task<String?, Never>?
        let startedAt: Date
        /// Set once the system reports fn held, so the stuck-key check can trust it.
        var sawFnHeld = false
        var fnUpTicks = 0
        /// Hands-free after a double tap: fn is up while recording.
        var locked = false
    }

    /// A forgotten hands-free recording stops here and is transcribed like any other.
    private static let handsFreeLimit: TimeInterval = 10 * 60

    private var recording: Recording?
    /// The short wait after fn is released, before the microphone stops.
    private var stopping: Task<Void, Never>?
    /// Dictations are transcribed and pasted one at a time, in order, while new ones can already record.
    private var queue: Task<Void, Never>?
    private var pendingJobs = 0
    private let history = DictationHistory(directory: DictationHistory.appSupportDirectory)
    private var levelTimer: Timer?
    private var tapRetryTimer: Timer?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private let previousApp = PreviousAppTracker()
    /// Loaded at launch; until it is, recordings go straight to the transcriber.
    private var speechDetector: SileroSpeechDetector?
    /// Watches the field after a paste for a fixed word; see `watchForCorrection`.
    private var correctionWatch: Task<Void, Never>?
    /// Terms the user said no to, not offered again until Parlo restarts.
    private var dismissedSuggestions: Set<String> = []

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
        recorder.onFailure = { [weak self] reason in self?.microphoneFailed(reason) }
        history.markInterrupted()
        recent = history.entries()
        startHotkey()
        Task {
            await models.refresh()
            models.warmUp()
            if !settings.hasCompletedOnboarding { await installRecommendedModel() }
        }
        Task { speechDetector = try? await SileroSpeechDetector.load() }
        if !settings.hasCompletedOnboarding || !Permissions.allGranted { showOnboarding() }
    }

    /// New users start on Apple Speech, which works at once, and switch to Parakeet v3 when it's downloaded.
    private func installRecommendedModel() async {
        let id = ModelID.parakeetV3
        guard models.states[id] == .notInstalled else { return }
        await models.download(id)
        if models.states[id] == .installed, models.activeModelID == .appleSpeech { models.select(id) }
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

    /// Cleanup is on but a cloud provider has no key yet, so every call would fail.
    var aiNeedsKey: Bool {
        settings.llm.enabled && settings.llm.provider == .openAICompatible
            && apiKey == nil && !settings.llm.baseURL.contains("localhost")
    }

    var llm: (any ChatCompleting)? {
        guard settings.llm.enabled else { return nil }
        return switch settings.llm.provider {
        case .apple: AppleIntelligenceClient()
        case .openAICompatible: LLMClient(settings: settings.llm, apiKey: apiKey)
        }
    }

    var statusText: String {
        switch phase {
        case .idle: hotkeyActive ? "Ready: hold fn to dictate" : "Needs Input Monitoring permission"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    func copy(_ entry: HistoryEntry) {
        if let text = entry.text { copy(text) }
    }

    /// Waits for any paste or selection read in progress, so their clipboard restore can't undo this copy.
    private func copy(_ text: String) {
        Task {
            await ClipboardTurn.take {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    func delete(_ entry: HistoryEntry) {
        history.delete(entry.id)
        recent = history.entries()
    }

    /// Hides the History window, brings back the app that was in front before it, and pastes there.
    func paste(_ entry: HistoryEntry) {
        guard let text = entry.text else { return }
        guard Permissions.accessibility, let app = previousApp.app, !app.isTerminated else {
            copy(text)
            show(.message("Copied: press ⌘V to paste", isError: false))
            return
        }
        historyWindow?.orderOut(nil)
        app.activate(from: .current, options: [])
        Task {
            for _ in 0..<25 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(for: .milliseconds(40))
            }
            await TextInserter.insert(text)
        }
    }

    // MARK: - Dictation flow

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .startDictation: begin(command: false)
        case .startCommand: begin(command: true)
        case .stop: end()
        case .cancel: cancel()
        case let .lock(command): lock(command: command)
        }
    }

    private func begin(command: Bool) {
        // Pressed again during the short wait after release: close the previous recording now,
        // and save it only once the new one is listening, so disk work doesn't clip its first word.
        let previous = stopping != nil ? stopRecording() : nil
        defer { if let previous { save(previous) } }
        guard recording == nil else { return }
        correctionWatch?.cancel()
        if let problem = blocker(command: command) {
            hud.show(.message(problem, isError: true))
            return
        }
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            hud.show(.message(error.localizedDescription, isError: true))
            return
        }
        recording = Recording(
            command: command, bundleID: FrontmostApp.bundleID,
            selection: command ? Task { await SelectionReader.read() } : nil, startedAt: .now
        )
        updatePhase()
        hud.show(.recording(command: command))
        startPreview()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hud.model.pushLevel(self.recorder.level)
                self.checkFnStillHeld()
                self.checkHandsFreeLimit()
            }
        }
    }

    /// Double tap: the recording the first tap started keeps going hands-free, or a new one starts if it already stopped.
    private func lock(command: Bool) {
        if stopping != nil, recording?.command == command {
            stopping?.cancel()
            stopping = nil
        } else {
            begin(command: command)
        }
        // Couldn't start (a blocker, or the microphone): don't leave the hotkey waiting to stop a hands-free recording.
        guard recording != nil else { return hotkey.reset() }
        recording?.locked = true
        hud.model.handsFree = true
    }

    /// Shows the words recognized so far in the HUD. Display only: the pasted text comes from `process`.
    private func startPreview() {
        guard LivePreview.supports(models.activeInfo) else { return }
        preview.start(
            transcriber: { [weak self] in try? await self?.models.transcriber() },
            languageCode: settings.languageCode,
            samples: { [weak self] in self?.recorder.recentSamples($0) ?? [] },
            isBusy: { [weak self] in (self?.pendingJobs ?? 0) > 0 },
            show: { [weak self] text in
                guard let self, recording != nil else { return }
                hud.model.liveText = text
            }
        )
    }

    /// The event tap can miss fn's release (it is switched off while the system is busy). If the keyboard
    /// says fn has been up for a while, stop as if it had been released.
    private func checkFnStillHeld() {
        guard var rec = recording, !rec.locked, stopping == nil else { return }
        let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        if held { rec.sawFnHeld = true }
        rec.fnUpTicks = held ? 0 : rec.fnUpTicks + 1
        recording = rec
        guard rec.sawFnHeld, rec.fnUpTicks >= 15 else { return }
        hotkey.reset()
        end()
    }

    private func checkHandsFreeLimit() {
        guard let rec = recording, rec.locked, stopping == nil,
              Date.now.timeIntervalSince(rec.startedAt) >= Self.handsFreeLimit else { return }
        hotkey.reset()
        end()
    }

    /// Why a dictation can't start right now, as a HUD message.
    private func blocker(command: Bool) -> String? {
        if !Permissions.microphone { return "Parlo needs microphone access: menu → Permissions & Setup" }
        if !Permissions.accessibility { return "Parlo needs Accessibility access to paste: menu → Permissions & Setup" }
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
        guard recording != nil, stopping == nil else { return }
        // Keep listening a moment: people let go of fn while still saying the last word.
        stopping = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            // Cancelled after the sleep ended but before this resumed: a new recording may be running.
            guard !Task.isCancelled else { return }
            finishRecording()
        }
    }

    /// Stops the microphone, saves the audio to history, then queues it for transcription.
    private func finishRecording() {
        if let finished = stopRecording() { save(finished) }
    }

    private func stopRecording() -> (Recording, [Float])? {
        stopping?.cancel()
        stopping = nil
        guard let rec = recording else { return nil }
        preview.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        let samples = recorder.stop()
        recording = nil
        updatePhase()
        return (rec, samples)
    }

    private func save(_ finished: (Recording, [Float])) {
        let (rec, samples) = finished
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else {
            if Date.now.timeIntervalSince(rec.startedAt) > 1 {
                show(.message("The microphone captured no audio. Check the input in Settings.", isError: true))
            } else {
                show(nil)
            }
            return
        }
        var entryID: String?
        do {
            entryID = try history.add(samples: samples, command: rec.command).id
            recent = history.entries()
            show(.processing(command: rec.command))
        } catch {
            show(.message("Couldn't save the recording: \(error.localizedDescription). Transcribing anyway.", isError: true))
        }
        // Kept for Retry even if this job fails before it runs, or Parlo quits while it's queued.
        if let entryID, let selection = rec.selection {
            Task { if let text = await selection.value { history.setSelection(entryID, text) } }
        }
        enqueue { [weak self] in await self?.process(samples, rec, entryID: entryID) }
    }

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        pendingJobs += 1
        updatePhase()
        let previous = queue
        queue = Task {
            await previous?.value
            await preview.idle()
            await job()
            pendingJobs -= 1
            updatePhase()
        }
    }

    private func process(_ samples: [Float], _ rec: Recording, entryID: String?) async {
        let limit = Deadline.forAudio(duration: Double(samples.count) / 16_000)
        do {
            let transcriber = try await models.transcriber()
            if rec.command {
                let selection = await rec.selection?.value
                let pipeline = CommandPipeline(
                    transcriber: transcriber, llm: llm, languageCode: settings.languageCode,
                    speech: speechDetector
                )
                let outcome = try await Deadline.run(seconds: limit) {
                    try await pipeline.run(samples: samples, selection: selection)
                }
                switch outcome {
                case .discarded: record(entryID, .nothingHeard); show(nil)
                case .empty: record(entryID, .nothingHeard); show(.message(nothingHeard(entryID), isError: false))
                case let .result(text): record(entryID, .done, text); await deliver(text, warning: nil)
                }
            } else {
                let pipeline = DictationPipeline(
                    transcriber: transcriber, llm: llm, settings: settings, speech: speechDetector
                )
                let bundleID = rec.bundleID
                let outcome = try await Deadline.run(seconds: limit) {
                    try await pipeline.run(samples: samples, bundleID: bundleID)
                }
                switch outcome {
                case .discarded: record(entryID, .nothingHeard); show(nil)
                case .empty: record(entryID, .nothingHeard); show(.message(nothingHeard(entryID), isError: false))
                case let .inserted(text, cleanupError):
                    record(entryID, .done, text)
                    await deliver(text, warning: cleanupError.map { "Pasted without AI cleanup: \($0)" })
                }
            }
        } catch {
            if error is DeadlineExceeded { models.reload() }
            record(entryID, .failed(error.localizedDescription))
            let kept = entryID == nil ? "" : ". The audio is kept in Recent."
            show(.message(error.localizedDescription + kept, isError: true))
        }
    }

    private func nothingHeard(_ entryID: String?) -> String {
        entryID == nil ? "Nothing heard" : "Nothing heard. The audio is kept in Recent."
    }

    /// Transcribes a saved recording again, without the speech check, and copies the result.
    /// A command is applied again to the text it was first applied to.
    func retry(_ entry: HistoryEntry) {
        guard let samples = history.samples(entry.id) else { return }
        record(entry.id, .processing)
        show(.processing(command: entry.command))
        let limit = Deadline.forAudio(duration: entry.duration)
        enqueue { [weak self] in
            guard let self else { return }
            do {
                let transcriber = try await models.transcriber()
                let text: String?
                if entry.command {
                    let pipeline = CommandPipeline(transcriber: transcriber, llm: llm, languageCode: settings.languageCode)
                    let outcome = try await Deadline.run(seconds: limit) {
                        try await pipeline.run(samples: samples, selection: entry.selection)
                    }
                    if case let .result(result) = outcome { text = result } else { text = nil }
                } else {
                    let pipeline = DictationPipeline(transcriber: transcriber, llm: llm, settings: settings)
                    let outcome = try await Deadline.run(seconds: limit) {
                        try await pipeline.run(samples: samples, bundleID: nil)
                    }
                    if case let .inserted(result, _) = outcome { text = result } else { text = nil }
                }
                guard let text else {
                    record(entry.id, .nothingHeard)
                    show(.message("Still nothing heard in that recording", isError: false))
                    return
                }
                record(entry.id, .done, text)
                copy(text)
                show(.message("Copied: press ⌘V to paste", isError: false))
            } catch {
                if error is DeadlineExceeded { models.reload() }
                record(entry.id, .failed(error.localizedDescription))
                show(.message(error.localizedDescription, isError: true))
            }
        }
    }

    /// Transcribes an audio file with the active model and adds the result to History. Runs in the same queue as dictations.
    func transcribeFile(_ url: URL) {
        let entry: HistoryEntry
        do {
            entry = try history.addFile(name: url.lastPathComponent, duration: AudioFileDecoder.duration(of: url))
        } catch {
            show(.message(error.localizedDescription, isError: true))
            return
        }
        recent = history.entries()
        enqueue { [weak self] in await self?.processFile(url, entry) }
    }

    private func processFile(_ url: URL, _ entry: HistoryEntry) async {
        fileProgress[entry.id] = 0
        defer { fileProgress[entry.id] = nil }
        let name = url.lastPathComponent
        do {
            let transcriber = try await models.transcriber()
            let samples = try await AudioFileDecoder.decode(url)
            let id = entry.id
            let chunked = ChunkedTranscriber(base: transcriber) { [weak self] fraction in
                Task { @MainActor in self?.fileProgress[id] = fraction }
            }
            // AI cleanup is for a sentence or two, with a few seconds to answer.
            let cleanup = entry.duration <= FileTranscription.cleanupMaxSeconds ? llm : nil
            let outcome = try await DictationPipeline(transcriber: chunked, llm: cleanup, settings: settings)
                .run(samples: samples, bundleID: nil)
            guard case let .inserted(text, cleanupError) = outcome else {
                record(entry.id, .nothingHeard)
                show(.message("Nothing heard in \(name)", isError: false))
                return
            }
            record(entry.id, .done, text)
            let skipped = llm != nil && cleanup == nil ? " (AI cleanup skipped: long file)" : ""
            show(cleanupError.map { .message("Transcribed \(name) without AI cleanup: \($0)", isError: true) }
                ?? .message("Transcribed \(name)\(skipped)", isError: false))
        } catch {
            record(entry.id, .failed(error.localizedDescription))
            show(.message(error.localizedDescription, isError: true))
        }
    }

    private func record(_ id: String?, _ status: HistoryEntry.Status, _ text: String? = nil) {
        guard let id else { return }
        history.update(id, status: status, text: text)
        recent = history.entries()
    }

    /// Results of earlier dictations must not cover the HUD of one being recorded now.
    private func show(_ state: HUDModel.State?) {
        guard recording == nil else { return }
        if let state { hud.show(state) } else { hud.hide() }
    }

    /// fn was combined with another key right away (fn+Delete, fn+arrow), or Esc while hands-free: drop the recording.
    private func cancel() {
        guard recording != nil, stopping == nil else { return }
        preview.stop()
        levelTimer?.invalidate()
        levelTimer = nil
        _ = recorder.stop()
        recording = nil
        updatePhase()
        hud.hide()
    }

    /// The microphone stopped mid-recording and could not restart: keep what was captured.
    private func microphoneFailed(_ reason: String) {
        guard recording != nil else { return }
        if recording?.locked == true { hotkey.reset() }
        finishRecording()
        hud.show(.message("Microphone stopped: \(reason)", isError: true))
    }

    private func updatePhase() {
        phase = recording != nil ? .recording : pendingJobs > 0 ? .processing : .idle
    }

    /// Pastes into the focused field. With no field to paste into, the text stays on the clipboard instead.
    private func deliver(_ text: String, warning: String?) async {
        let target = await FocusedElement.current()
        guard PasteTarget.acceptsText(target.focus) else {
            copy(text)
            show(.message("No text field to paste into. Copied: press ⌘V to paste", isError: false))
            return
        }
        await TextInserter.insert(text)
        show(warning.map { .message($0, isError: true) } ?? .done)
        if let field = target.field { watchForCorrection(of: text, in: field) }
    }

    // MARK: - Dictionary suggestions

    /// Reads the field again every 2 s for 30 s, while it keeps focus and until the next dictation,
    /// and offers a word the user fixed as a dictionary entry.
    private func watchForCorrection(of pasted: String, in field: WatchedField) {
        correctionWatch?.cancel()
        correctionWatch = Task { [weak self] in
            guard let edit = await field.edit(of: pasted),
                  let entry = CorrectionDetector.suggestion(pasted: pasted, before: edit.before, after: edit.after)
            else { return }
            self?.suggest(entry)
        }
    }

    private func suggest(_ entry: DictionaryEntry) {
        let known = settings.dictionary.map { $0.term.lowercased() } + suggestions.map { $0.term.lowercased() }
        guard !known.contains(entry.term.lowercased()), !dismissedSuggestions.contains(entry.term.lowercased())
        else { return }
        suggestions.insert(entry, at: 0)
        // Don't cover the HUD of a dictation that's still being transcribed.
        if phase == .idle { show(.message("Add “\(entry.term)” to your dictionary? It's in Parlo's menu", isError: false)) }
    }

    func acceptSuggestion(_ entry: DictionaryEntry) {
        suggestions.removeAll { $0.id == entry.id }
        settings.dictionary.append(entry)
    }

    func dismissSuggestion(_ entry: DictionaryEntry) {
        suggestions.removeAll { $0.id == entry.id }
        dismissedSuggestions.insert(entry.term.lowercased())
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

    /// Owned here like onboarding: SwiftUI's Settings scene doesn't open from a menu bar–only app.
    func showSettings(_ tab: SettingsTab) {
        settingsTab = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Parlo Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "Parlo History"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 400)
            window.contentView = NSHostingView(rootView: HistoryView(controller: self))
            window.center()
            historyWindow = window
        }
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    /// Saves a recording still in progress before quitting, so it can be retried from Recent.
    func quit() {
        finishRecording()
        NSApp.terminate(nil)
    }

    func relaunch() {
        finishRecording()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// `openAtLogin` is only offered on the first run; later visits leave the Settings choice alone.
    func finishOnboarding(openAtLogin: Bool?) {
        if let openAtLogin, openAtLogin != LoginItem.isOn { try? LoginItem.set(openAtLogin) }
        settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
    }
}
