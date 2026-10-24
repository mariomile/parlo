import AppKit
import ParloCore
import ParloEngines
import SwiftUI

/// Owns app state and wires hotkey -> recording session -> transcription queue -> paste / HUD.
@Observable
final class AppController {
    enum Phase: Equatable { case idle, recording, processing }

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.llm.keyScope != oldValue.llm.keyScope { apiKey = Self.readKey(settings.llm) }
            do { try store.save(settings) } catch {
                hud.show(.message("Couldn't save settings: \(error.localizedDescription)", isError: true))
            }
            localLLM.inUse = settings.llm.usesLocalModel
        }
    }
    /// The key saved for the current base URL's server. Cached so the keychain is read once per server.
    private(set) var apiKey: String?
    private(set) var phase: Phase = .idle
    private(set) var hotkeyActive = false
    /// Words the user fixed right after a paste, offered for the dictionary.
    private(set) var inbox = SuggestionInbox()
    /// Audio files transcribe one at a time, outside the dictation queue.
    private var fileQueue: Task<Void, Never>?
    /// Progress (0 to 1) of audio files being transcribed, by history entry id. Absent while queued.
    private(set) var fileProgress: [String: Double] = [:]
    var settingsTab: SettingsTab = .general
    let models: ModelManager
    let localLLM = LocalLLM()
    let meetings: MeetingController

    private let store: SettingsStore
    private let hud = HUDController()
    private let hotkey = HotkeyMonitor()
    private let history = DictationHistory(directory: DictationHistory.appSupportDirectory)
    /// Dictations are transcribed and pasted one at a time, in order, while new ones can already record.
    private let gate: TranscriberGate
    private let session: RecordingSession
    private let windows = Windows()
    private var tapRetryTimer: Timer?
    private let previousApp = PreviousAppTracker()
    /// Loaded at launch, and again after a recording if that failed (say, offline on first launch).
    /// Until it is, recordings go straight to the transcriber.
    private var speechDetector: SileroSpeechDetector?
    private var loadingSpeechDetector = false
    /// Watches the field after a paste for a fixed word; see `watchForCorrection`.
    private var correctionWatch: Task<Void, Never>?

    /// The settings file could not be read at launch and was moved aside.
    private let settingsWereReset: Bool

    private static let copiedHint = "Copied: press ⌘V to paste"

    private static func readKey(_ llm: LLMSettings) -> String? {
        llm.keyScope.flatMap(KeychainStore.read(for:))
    }

    /// Saves the key for the current base URL's server; nil removes it.
    func setAPIKey(_ key: String?) {
        guard let scope = settings.llm.keyScope else {
            return hud.show(.message("Enter a valid base URL before saving the API key", isError: true))
        }
        guard KeychainStore.save(key, for: scope) else {
            return hud.show(.message("Couldn't save the API key to the Keychain", isError: true))
        }
        apiKey = key
    }

    init() {
        let store = SettingsStore(directory: SettingsStore.appSupportDirectory)
        self.store = store
        let (loaded, quarantined) = store.load()
        settings = loaded
        settingsWereReset = quarantined != nil
        apiKey = Self.readKey(loaded.llm)
        var onActiveChange: (ModelID) -> Void = { _ in }
        let models = ModelManager(installer: EngineInstaller(), activeModelID: loaded.activeModelID) { onActiveChange($0) }
        self.models = models
        gate = TranscriberGate(transcriber: { try await models.transcriber() }, reload: { models.reload() })
        session = RecordingSession(gate: gate)
        var meetingContext: () -> MeetingController.Context = { fatalError("Set before init returns") }
        var report: (String, Bool) -> Void = { _, _ in }
        meetings = MeetingController(gate: gate, context: { meetingContext() }, report: { report($0, $1) })
        onActiveChange = { [weak self] id in
            self?.settings.activeModelID = id
            self?.models.warmUp()
        }
        meetingContext = { [unowned self] in self.meetingContext }
        report = { [weak self] text, isError in self?.show(.message(text, isError: isError)) }
    }

    func launch() {
        hotkey.onAction = { [weak self] action in self?.handle(action) }
        gate.onChange = { [weak self] in self?.updatePhase() }
        session.onTick = { [weak self] in
            guard let self else { return }
            hud.model.pushLevel(session.level)
            hotkey.poll()
        }
        session.onFailure = { [weak self] reason in self?.microphoneFailed(reason) }
        history.markInterrupted()
        meetings.launch()
        EngineInstaller.prepare()
        startHotkey()
        Task {
            await models.refresh()
            models.warmUp()
            if !settings.hasCompletedOnboarding { await installRecommendedModel() }
        }
        loadSpeechDetector()
        localLLM.inUse = settings.llm.usesLocalModel
        Task { await localLLM.files.refresh() }
        if !settings.hasCompletedOnboarding || !Permissions.allGranted { showOnboarding() }
        if settingsWereReset {
            show(.message("Settings were unreadable and have been reset. The old file was kept next to them.", isError: true))
        }
    }

    private func loadSpeechDetector() {
        guard speechDetector == nil, !loadingSpeechDetector else { return }
        loadingSpeechDetector = true
        Task {
            speechDetector = try? await SileroSpeechDetector.load()
            loadingSpeechDetector = false
        }
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

    var llm: (any ChatCompleting)? { settings.llm.client(apiKey: apiKey, local: localLLM) }

    /// Why AI cleanup would fail right now; nil when it can run or is off.
    var aiProblem: String? { settings.llm.problem(apiKey: apiKey, local: localLLM) }

    var statusText: String {
        switch phase {
        case .idle: hotkeyActive ? "Ready: hold fn to dictate" : "Needs Input Monitoring permission"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    /// Every kept entry, newest first.
    var recent: [HistoryEntry] { history.entries }
    /// Why the history could not be saved to disk; it still works in memory until the next save succeeds.
    var historySaveError: String? { history.saveError }

    var suggestions: [DictionaryEntry] { inbox.pending }

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
    }

    /// Hides the History window, brings back the app that was in front before it, and pastes there.
    func paste(_ entry: HistoryEntry) {
        guard let text = entry.text else { return }
        guard Permissions.accessibility, let app = previousApp.app, !app.isTerminated else {
            copy(text)
            show(.message(Self.copiedHint, isError: false))
            return
        }
        windows.hide(.history)
        app.activate(from: .current, options: [])
        Task {
            for _ in 0..<25 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(for: .milliseconds(40))
            }
            // The app didn't come forward: pasting now would land in whatever did.
            guard NSWorkspace.shared.frontmostApplication == app else {
                copy(text)
                return show(.message(Self.copiedHint, isError: false))
            }
            await deliver(text, warning: nil)
        }
    }

    // MARK: - Dictation flow

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .startDictation: begin(command: false)
        case .startCommand: begin(command: true)
        case .stop: session.stopAfterTail { [weak self] in self?.save($0) }
        case let .cancel(handsFree): cancel(keepingAudio: handsFree)
        case let .lock(command): lock(command: command)
        }
        updatePhase()
    }

    private func begin(command: Bool) {
        // Pressed again during the short wait after release: close the previous recording now,
        // and save it only once the new one is listening, so disk work doesn't clip its first word.
        let previous = session.isStopping ? session.stop() : nil
        defer { if let previous { save(previous) } }
        guard session.current == nil else { return }
        correctionWatch?.cancel()
        if let problem = blocker(command: command) {
            hud.show(.message(problem, isError: true))
            return
        }
        // Display only: the pasted text comes from the job.
        let show: (String) -> Void = { [weak self] text in self?.hud.model.liveText = text }
        let preview = LivePreview.supports(models.activeInfo) ? (languageCode: settings.languageCode, show: show) : nil
        do {
            try session.start(command: command, deviceUID: settings.microphoneUID, preview: preview)
        } catch {
            hud.show(.message(error.localizedDescription, isError: true))
            return
        }
        hud.show(.recording(command: command))
    }

    /// Double tap: the recording the first tap started keeps going hands-free, or a new one starts if it already stopped.
    private func lock(command: Bool) {
        if !session.continueRecording(command: command) { begin(command: command) }
        // Couldn't start (a blocker, or the microphone): don't leave the hotkey waiting to stop a hands-free recording.
        guard session.current != nil else { return hotkey.reset() }
        hud.model.handsFree = true
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

    /// Stops the microphone now, saves the audio to history, then queues it for transcription.
    func finishRecording() {
        if let finished = session.stop() { save(finished) }
    }

    private func save(_ finished: RecordingSession.Finished) {
        updatePhase()
        let rec = finished.recording, samples = finished.samples
        guard RecordingGuard.isLongEnough(sampleCount: samples.count) else {
            if Date.now.timeIntervalSince(rec.startedAt) > 1 {
                show(.message("The microphone captured no audio. Check the input in Settings.", isError: true))
            } else {
                show(nil)
            }
            return
        }
        guard !RecordingGuard.isDigitalSilence(samples) else {
            return show(.message("The microphone sent no signal. Is the lid closed, or the input muted?", isError: true))
        }
        let (entry, audioError) = history.add(samples: samples, kind: rec.command ? .command(selection: nil) : .dictation)
        show(audioError.map { .message("Couldn't save the recording (\($0.localizedDescription)). Transcribing anyway.", isError: true) }
            ?? (finished.usedFallback ? .message("Your chosen microphone wasn't available, so the default one was used.", isError: false) : nil)
            ?? .processing(command: rec.command))
        // Kept for Retry even if this job fails before it runs, or Parlo quits while it's queued.
        if let selection = rec.selection {
            Task { if let text = await selection.value { history.setSelection(entry.id, text) } }
        }
        let speech = speechDetector
        loadSpeechDetector()
        enqueue(entry, via: .paste) { [weak self] transcriber in
            let kind: JobKind = rec.command ? .command(selection: await rec.selection?.value) : .dictation(bundleID: rec.bundleID)
            return try await self?.job(transcriber, speech: speech).run(samples, kind)
        }
    }

    /// Transcribes a saved recording again, without the speech check, and copies the result.
    /// A command is applied again to the text it was first applied to; a file is read again from where it was.
    func retry(_ entry: HistoryEntry) {
        if case let .file(_, path?) = entry.kind {
            history.update(entry.id, status: .processing, text: nil)
            return queueFile(entry, URL(filePath: path))
        }
        guard let samples = history.samples(entry.id) else { return }
        history.update(entry.id, status: .processing, text: nil)
        show(.processing(command: entry.isCommand))
        let kind: JobKind = if case let .command(selection) = entry.kind { .command(selection: selection) } else { .dictation(bundleID: nil) }
        enqueue(entry, via: .copy) { [weak self] transcriber in
            try await self?.job(transcriber, speech: nil).run(samples, kind)
        }
    }

    /// Transcribes an audio file with the active model and adds the result to History.
    func transcribeFile(_ url: URL) {
        let duration: Double
        do { duration = try AudioFileDecoder.duration(of: url) } catch {
            show(.message(error.localizedDescription, isError: true))
            return
        }
        queueFile(history.addFile(url, duration: duration), url)
    }

    /// Files go one after another, a minute of audio at a time, and a dictation made meanwhile is
    /// transcribed after the current minute instead of after the whole file.
    private func queueFile(_ entry: HistoryEntry, _ url: URL) {
        let previous = fileQueue
        fileQueue = Task { [weak self] in
            await previous?.value
            await self?.runFile(entry, url)
        }
    }

    private func runFile(_ entry: HistoryEntry, _ url: URL) async {
        let id = entry.id, delivery = Delivery.file(name: url.lastPathComponent)
        fileProgress[id] = 0
        defer { fileProgress[id] = nil }
        do {
            let samples = try await AudioFileDecoder.decode(url)
            let chunked = ChunkedTranscriber(base: BackgroundTranscriber(gate: gate)) { [weak self] fraction in
                Task { @MainActor in if self?.fileProgress[id] != nil { self?.fileProgress[id] = fraction } }
            }
            var job = job(chunked, speech: nil)
            job.transcriptionDeadline = nil
            await present(try await job.run(samples, .dictation(bundleID: nil)), for: entry, via: delivery)
        } catch {
            failed(error, entry, via: delivery)
        }
    }

    private func job(_ transcriber: any Transcriber, speech: (any SpeechDetector)?) -> TranscriptionJob {
        TranscriptionJob(transcriber: transcriber, llm: llm, settings: settings, speech: speech)
    }

    /// Where a job's text goes: pasted into the focused field, copied (Retry), or only noted (a file, read in History).
    private enum Delivery: Equatable { case paste, copy, file(name: String) }

    /// Runs `work` in the transcription queue, records its outcome in history and shows it.
    private func enqueue(
        _ entry: HistoryEntry, via delivery: Delivery, _ work: @escaping (any Transcriber) async throws -> JobOutcome?
    ) {
        gate.enqueue({ [weak self] transcriber in
            guard let outcome = try await work(transcriber) else { return }
            await self?.present(outcome, for: entry, via: delivery)
        }, onError: { [weak self] error in
            self?.failed(error, entry, via: delivery)
        })
    }

    private func present(_ outcome: JobOutcome, for entry: HistoryEntry, via delivery: Delivery) async {
        guard case let .text(text, warning) = outcome else {
            history.update(entry.id, status: .nothingHeard, text: nil)
            switch delivery {
            case .paste:
                guard outcome == .empty else { return show(nil) }
                show(.message(entry.hasAudio ? "Nothing heard. The audio is kept in Recent." : "Nothing heard", isError: false))
            case .copy: show(.message("Still nothing heard in that recording", isError: false))
            case let .file(name): show(.message("Nothing heard in \(name)", isError: false))
            }
            return
        }
        history.update(entry.id, status: .done, text: text)
        switch delivery {
        case .paste:
            await deliver(text, warning: warning.map { "Pasted without AI cleanup: \($0)" })
        case .copy:
            copy(text)
            show(.message(Self.copiedHint, isError: false))
        case let .file(name):
            show(warning.map { .message("Transcribed \(name) without AI cleanup: \($0)", isError: true) }
                ?? .message("Transcribed \(name)", isError: false))
        }
    }

    private func failed(_ error: any Error, _ entry: HistoryEntry, via delivery: Delivery) {
        history.update(entry.id, status: .failed(error.localizedDescription), text: nil)
        let kept = delivery == .paste && entry.hasAudio ? ". The audio is kept in Recent." : ""
        show(.message(error.localizedDescription + kept, isError: true))
    }

    /// Results of earlier dictations, and suggestions, must not cover the HUD of one being recorded now.
    private func show(_ state: HUDModel.State?) {
        guard session.current == nil else { return }
        if let state { hud.show(state) } else { hud.hide() }
    }

    /// fn was combined with another key right away (fn+Delete, fn+arrow): drop the recording.
    /// Esc while hands-free keeps the audio in Recent, untranscribed: it may be minutes of dictation.
    private func cancel(keepingAudio: Bool) {
        guard !session.isStopping, let finished = session.stop() else { return }
        guard keepingAudio, RecordingGuard.isLongEnough(sampleCount: finished.samples.count) else { return hud.hide() }
        let rec = finished.recording
        let kind: HistoryEntry.Kind = rec.command ? .command(selection: nil) : .dictation
        let (entry, audioError) = history.add(samples: finished.samples, kind: kind, status: .failed("Cancelled"))
        if let audioError {
            history.delete(entry.id)
            return hud.show(.message("Cancelled. Couldn't keep the audio: \(audioError.localizedDescription)", isError: true))
        }
        // Retry applies the command to the same text.
        if let selection = rec.selection {
            Task { if let text = await selection.value { history.setSelection(entry.id, text) } }
        }
        hud.show(.message("Cancelled. The audio is kept in Recent if you need it.", isError: false))
    }

    /// The microphone stopped mid-recording and could not restart: keep what was captured.
    private func microphoneFailed(_ reason: String) {
        guard session.current != nil else { return }
        hotkey.reset()
        finishRecording()
        hud.show(.message("Microphone stopped: \(reason)", isError: true))
    }

    private func updatePhase() {
        phase = session.current != nil ? .recording : gate.pendingJobs > 0 ? .processing : .idle
    }

    /// Pastes into the focused field. With no field to paste into, the text stays on the clipboard instead.
    private func deliver(_ text: String, warning: String?) async {
        let target = await FocusedElement.current()
        guard PasteTarget.acceptsText(target.focus) else {
            copy(text)
            show(.message("No text field to paste into. \(Self.copiedHint)", isError: false))
            return
        }
        switch await TextInserter.insert(text) {
        case .pasted: break
        case .leftOnClipboard: return show(.message("The app didn't take the text. \(Self.copiedHint)", isError: false))
        case .lost: return show(.message("The app didn't take the text. It's in Recent, in the menu bar.", isError: true))
        }
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
        guard inbox.offer(entry, dictionary: settings.dictionary) else { return }
        show(.message("Add “\(entry.term)” to your dictionary? It's in Parlo's menu", isError: false))
    }

    func acceptSuggestion(_ entry: DictionaryEntry) {
        inbox.remove(entry)
        settings.dictionary.append(entry)
    }

    func dismissSuggestion(_ entry: DictionaryEntry) {
        inbox.dismiss(entry)
    }

    // MARK: - Windows

    func showOnboarding() {
        windows.present(.onboarding, title: "Welcome to Parlo", size: NSSize(width: 520, height: 560)) {
            OnboardingView(controller: self)
        }
    }

    func showSettings(_ tab: SettingsTab) {
        settingsTab = tab
        windows.present(.settings, title: "Parlo Settings", size: NSSize(width: 640, height: 500)) {
            SettingsView(controller: self)
        }
    }

    func showHistory() {
        windows.present(
            .history, title: "Parlo History", size: NSSize(width: 720, height: 600),
            style: [.titled, .closable, .miniaturizable, .resizable], minSize: NSSize(width: 560, height: 400)
        ) {
            HistoryView(controller: self)
        }
    }

    /// The recording in progress is saved by `AppDelegate.applicationWillTerminate`.
    func quit() {
        NSApp.terminate(nil)
    }

    func relaunch() {
        // Saved before the new instance reads the history, not when this one terminates.
        finishRecording()
        meetings.terminate()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Meetings

    func startMeeting() {
        guard Permissions.microphone else { return showOnboarding() }
        meetings.start(deviceUID: settings.microphoneUID)
    }

    func showMeetings() {
        windows.present(
            .meetings, title: "Parlo Meetings", size: NSSize(width: 880, height: 620),
            style: [.titled, .closable, .miniaturizable, .resizable], minSize: NSSize(width: 720, height: 460)
        ) {
            MeetingsView(meetings: meetings) { [weak self] in self?.startMeeting() }
        }
    }

    /// Notes are what a meeting is for, so a model on this Mac writes them even with cleanup off. A hosted provider
    /// only gets the transcript while cleanup is on: turning cleanup off keeps every word on this Mac.
    private var meetingContext: MeetingController.Context {
        var llm = settings.llm
        if llm.runsOnThisMac { llm.enabled = true }
        let problem = llm.enabled
            ? llm.problem(apiKey: apiKey, local: localLLM)
            : "Notes need AI cleanup on, or a model that runs on this Mac (Settings → AI)"
        // Characters per request: Apple's on-device model reads about 4k tokens, an MLX model on this Mac
        // stays quick to about 12k characters, a hosted model reads far more.
        let limit = switch llm.provider {
        case .apple: 4000
        case .local: 12000
        case .openAICompatible: 48000
        }
        var writeNotes: (([String], Double) async throws -> MeetingNotes.Result)?
        if problem == nil {
            let notes = MeetingNotes(llm: llm.providerClient(apiKey: apiKey, local: localLLM), maxCharacters: limit)
            let localLLM = localLLM
            // A long meeting is several requests: the local model stays loaded for all of them, not reloaded for each.
            writeNotes = llm.provider == .local
                ? { lines, duration in try await localLLM.keepLoaded { try await notes.write(lines, duration: duration) } }
                : { lines, duration in try await notes.write(lines, duration: duration) }
        }
        return MeetingController.Context(
            languageCode: settings.languageCode, dictionary: settings.dictionary, writeNotes: writeNotes, notesProblem: problem
        )
    }

    /// `openAtLogin` is only offered on the first run; later visits leave the Settings choice alone.
    func finishOnboarding(openAtLogin: Bool?) {
        if let openAtLogin, openAtLogin != LoginItem.isOn { try? LoginItem.set(openAtLogin) }
        settings.hasCompletedOnboarding = true
        windows.close(.onboarding)
    }
}
