import Foundation
import CoreFoundation
import Observation
@testable import ParloCore

// Every OS/engine adapter in this file is in memory. No AppKit, Keychain, network or audio device calls.
final class NSPasteboardItem {
    var values: [NSPasteboard.PasteboardType: Data] = [:]
    var types: [NSPasteboard.PasteboardType] { Array(values.keys) }
    @discardableResult func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        values[type] = data; return true
    }
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        setData(Data(string.utf8), forType: type)
    }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { values[type] }
}

final class NSPasteboard {
    nonisolated struct PasteboardType: Hashable, Sendable {
        let rawValue: String
        init(_ value: String) { rawValue = value }
        static let string = PasteboardType("public.utf8-plain-text")
    }
    static let general = NSPasteboard()
    var changeCount = 0
    var pasteboardItems: [NSPasteboardItem]? = []
    @discardableResult func clearContents() -> Int {
        changeCount += 1; pasteboardItems = []; return changeCount
    }
    @discardableResult func writeObjects(_ items: [NSPasteboardItem]) -> Bool {
        changeCount += 1; pasteboardItems = items; return true
    }
    @discardableResult func setString(_ string: String, forType type: PasteboardType) -> Bool {
        let item = NSPasteboardItem(); item.setString(string, forType: type)
        return writeObjects([item])
    }
    func string(forType type: PasteboardType) -> String? {
        pasteboardItems?.first?.data(forType: type).flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum KeyPoster {
    static var posts: [pid_t?] = []
    static var onPaste: () -> Void = {}
    static func paste() { posts.append(FrontmostApp.processID); onPaste() }
}
enum FrontmostApp {
    static var processID: pid_t? = 10
    static let bundleID: String? = "test.editor"
}
nonisolated struct WatchedField: Sendable {
    let id: Int
    @MainActor func valueByInserting(_ text: String) async -> String? {
        guard let before = FocusedElement.values[id], let range = FocusedElement.ranges[id] else { return nil }
        let value = before as NSString
        guard range.location <= value.length, range.length <= value.length - range.location else { return nil }
        let result = value.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        return result == before ? nil : result
    }
    @MainActor func hasValue(_ expected: String) async -> Bool { FocusedElement.values[id] == expected }
}
enum FocusedElement {
    static var field: WatchedField? = WatchedField(id: 1)
    static var focus: PasteTarget.Focus = .unknown
    static var values: [Int: String] = [:]
    static var ranges: [Int: CFRange] = [:]
    static var selected = ""
    static var selectionResult: CommandSelection = .unavailable
    static var holdFocus: (() async -> Void)?
    static var holdSelection: (() async -> Void)?

    static func current() async -> (field: WatchedField?, focus: PasteTarget.Focus) {
        let snapshot = (field, focus)
        await holdFocus?()
        return snapshot
    }
    static func selection(expectedPID: pid_t) async -> CommandSelection {
        await holdSelection?()
        return selectionResult
    }
    static func matches(_ expected: WatchedField?, selection: SelectionContext?) -> Bool {
        guard expected?.id == field?.id else { return false }
        guard let selection else { return true }
        return selection.processID == FrontmostApp.processID && selection.field.id == field?.id
            && selection.text == selected && selection.range?.location == ranges[selection.field.id]?.location
            && selection.range?.length == ranges[selection.field.id]?.length
    }
}

final class SampleSink {
    var level: Float { 0 }
    func reset() {}
    func drain() -> [Float] { Fixtures.audio }
    func tail(_ count: Int) -> [Float] { Array(Fixtures.audio.suffix(count)) }
}
final class AudioRecorder {
    var onFailure: (String) -> Void = { _ in }
    var usedFallback = false
    init(sink: SampleSink) {}
    func start(deviceUID: String?) throws {}
    func stop() {}
}
enum AudioFileDecoder {
    static var reads = 0
    static var hold: (() async -> Void)?
    static var unreadableTracks: Set<String> = []
    static var trackSamples: [String: [Float]] = [:]
    static func duration(of url: URL) throws -> Double { 1 }
    static func decode(_ url: URL) async throws -> [Float] {
        reads += 1
        await hold?()
        if unreadableTracks.contains(url.lastPathComponent) { throw AudioFileError.unreadable(url.lastPathComponent) }
        return trackSamples[url.lastPathComponent] ?? Fixtures.audio
    }
}
nonisolated struct SileroSpeechDetector: SpeechDetector, SpeechSegmenting {
    @MainActor static var loadFailure = false
    @MainActor static var loadCalls = 0
    @MainActor static var holdLoad: (() async -> Void)?
    @MainActor static func load() async throws -> SileroSpeechDetector {
        loadCalls += 1
        await holdLoad?()
        if loadFailure { throw CocoaError(.fileReadCorruptFile) }
        return Self()
    }
    func containsSpeech(_ samples: [Float]) async throws -> Bool { true }
    func speechRanges(_ samples: [Float]) async throws -> [Range<Int>] { [samples.indices] }
}
final class MeetingRecorder {
    static var latest: MeetingRecorder?
    var onFailure: (String) -> Void = { _ in }
    var onSystemAudioLost: (String) -> Void = { _ in }
    var systemAudioProblem: String?
    var duration: Double = 12
    var writeError: (any Error)?
    init(me: URL, them: URL, deviceUID: String?) throws { Self.latest = self }
    func stop() -> (any Error)? { writeError }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    static let willSleepNotification = Notification.Name("fake-sleep")
    let notificationCenter = NotificationCenter()
}

enum HUDState: Equatable { case message(String, isError: Bool), processing(command: Bool), done }
struct HUD { func show(_ value: HUDState) {} }
struct Hotkey { func reset() {} }

final class ControllerProbe {
    struct HistoryWork { let lifetime: HistoryWorkLifetime; var task: Task<Void, Never>? }
    enum Delivery: Equatable { case paste, copy, file(name: String) }
    let history: DictationHistory
    let gate: TranscriberGate
    let session: RecordingSession
    let meetings: MeetingController
    var historyWork: [String: HistoryWork] = [:]
    var selectionSaves: [String: Task<Void, Never>] = [:]
    var unsavedTerminationRecordings: [(entryID: String, recording: RecordingSession.Finished)] = []
    var isTerminating = false
    var fileQueue: Task<Void, Never>?
    var fileProgress: [String: Double] = [:]
    var llm: (any ChatCompleting)?
    var settings = AppSettings.default
    let speechDetector: (any SpeechDetector)? = nil
    var messages: [HUDState?] = []
    let hud = HUD()
    let hotkey = Hotkey()
    static let copiedHint = "Copied: press ⌘V to paste"

    init(history: DictationHistory, gate: TranscriberGate, meetingStore: MeetingStore, llm: (any ChatCompleting)? = nil) {
        self.history = history; self.gate = gate; self.llm = llm
        session = RecordingSession(gate: gate)
        meetings = MeetingController(gate: gate, store: meetingStore, context: {
            .init(languageCode: nil, dictionary: [], writeNotes: nil, notesProblem: nil)
        }, report: { _, _ in })
    }
    func updatePhase() {}
    func loadSpeechDetector() {}
    func show(_ state: HUDState?) { messages.append(state) }
    func watchForCorrection(of text: String, in field: WatchedField) {}

    // PRODUCTION_CONTROLLER_METHODS
}

final class SettingsControllerProbe {
    var settings = AppSettings.default
    var apiKey: String?
    var saved: [(String?, EndpointKeyDraft.Identity?)] = []
    let localLLM = LocalLLM()
    func setAPIKey(_ key: String?, for endpoint: EndpointKeyDraft.Identity? = nil) {
        guard endpoint == EndpointKeyDraft.Identity(settings.llm) else { return }
        saved.append((key, endpoint)); apiKey = key
    }
}
struct LocalLLM {}
extension LLMSettings {
    func providerClient(apiKey: String?, local: LocalLLM) -> any ChatCompleting {
        EndpointClient(endpoint: baseURL, key: apiKey)
    }
}
nonisolated struct EndpointClient: ChatCompleting {
    let endpoint: String
    let key: String?
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        await EndpointSpy.shared.record(endpoint: endpoint, key: key)
        return "OK"
    }
}
actor EndpointSpy {
    static let shared = EndpointSpy()
    var sent: [(String, String?)] = []
    func record(endpoint: String, key: String?) { sent.append((endpoint, key)) }
}
final class SettingsProbe {
    let controller = SettingsControllerProbe()
    var llm: LLMSettings { controller.settings.llm }
    var keyDraft = EndpointKeyDraft()
    var testResult: (ok: Bool, text: String)?
    var testing = false
    var testTask: Task<Void, Never>?
    var testID = UUID()
    // PRODUCTION_SETTINGS_METHODS
}

struct StoredFiles {
    enum Kind { case model(ModelID), cleanupModel, vocabulary, voiceDetection, other }
    let kind: Kind
    let name = "fixture files"
}
enum ModelStorage {
    static var deleted: [StoredFiles] = []
    static func delete(_ item: StoredFiles) throws { deleted.append(item) }
}
final class StorageOwnerProbe {
    var deletions = 0
    var failure = false
    var latch: Latch?
    func delete(_ id: ModelID) async throws { try await delete() }
    func delete() async throws {
        deletions += 1
        await latch?.wait()
        if failure { throw CocoaError(.fileWriteNoPermission) }
    }
}
final class StorageDeleteProbe {
    let models = StorageOwnerProbe()
    let cleanupModel = StorageOwnerProbe()
    var deleteError: String?
    var scans = 0
    func rescan() async { scans += 1 }
    // PRODUCTION_STORAGE_DELETE
}

actor Latch {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
actor HeldTranscriber: Transcriber {
    var calls = 0
    var waiting: [CheckedContinuation<String, Never>] = []
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ text: String) { let pending = waiting; waiting = []; pending.forEach { $0.resume(returning: text) } }
}
actor ChatSpy: ChatCompleting {
    var calls = 0
    var hold = false
    var waiting: CheckedContinuation<String, Never>?
    func setHeld() { hold = true }
    func complete(system: String, user: String, timeout: TimeInterval) async throws -> String {
        calls += 1
        if hold { return await withCheckedContinuation { waiting = $0 } }
        return user
    }
    func release(_ text: String) { waiting?.resume(returning: text); waiting = nil }
}
actor PartialTranscriber: Transcriber {
    var calls = 0
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadCorruptFile) }
        return "A surviving statement"
    }
}
actor FailingTranscriber: Transcriber {
    var calls = 0
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String {
        calls += 1
        throw CocoaError(.fileReadCorruptFile)
    }
}
nonisolated struct FixedTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float], languageCode: String?, dictionary: [DictionaryEntry]) async throws -> String { text }
}
nonisolated final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ enabled: Bool) { lock.withLock { value = enabled } }
    var enabled: Bool { lock.withLock { value } }
}
enum Fixtures {
    static let audio = [Float](repeating: 0.1, count: Audio.sampleRate)
    static func resetDesktop() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("USER_CLIPBOARD", forType: .string)
        FrontmostApp.processID = 10
        FocusedElement.field = WatchedField(id: 1); FocusedElement.focus = .unknown
        FocusedElement.values = [:]; FocusedElement.ranges = [:]; FocusedElement.selected = ""
        FocusedElement.selectionResult = .unavailable; FocusedElement.holdFocus = nil; FocusedElement.holdSelection = nil
        KeyPoster.posts = []; KeyPoster.onPaste = {}
        AudioFileDecoder.reads = 0; AudioFileDecoder.hold = nil
        AudioFileDecoder.unreadableTracks = []; AudioFileDecoder.trackSamples = [:]
        SileroSpeechDetector.loadFailure = false; SileroSpeechDetector.loadCalls = 0; SileroSpeechDetector.holdLoad = nil
    }
    static func selection(_ text: String = "ORIGINAL_SELECTION") -> CommandSelection {
        let range = CFRange(location: 0, length: text.utf16.count)
        FocusedElement.ranges[1] = range; FocusedElement.selected = text
        return .available(SelectionContext(field: WatchedField(id: 1), processID: 10, text: text, range: range))
    }
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "parlo-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func partialMeeting(in store: MeetingStore) throws -> Meeting {
        let meeting = try store.create()
        store.update(meeting.id) {
            $0.status = .done
            $0.duration = 40
            $0.title = "Earlier partial meeting"
            $0.turns = [.init(speaker: .me, start: 0, end: 4, text: "Useful retained statement"),
                        .init(speaker: .them, start: 35, end: 40, text: "Useful retained follow-up")]
            $0.notes = "Earlier notes describe the retained transcript."
            $0.notesError = "Earlier notes cover only part of the meeting"
            $0.captureWarnings = ["[0:39] Original capture warning"]
            $0.transcriptionWarnings = ["[0:24–0:31] Them: Transcription missing (earlier ASR failure)"]
        }
        return store.meeting(meeting.id)!
    }
    static func fullHistory(in directory: URL) throws -> [HistoryEntry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = DictationHistory(directory: directory)
        var entries: [HistoryEntry] = []
        for i in 0..<defaults.textLimit {
            let date = Date(timeIntervalSince1970: Double(2_000 + i))
            let entry = HistoryEntry(
                id: String(Int(date.timeIntervalSince1970 * 1_000)), date: date, duration: 1,
                kind: .dictation, status: .done, text: "Saved text \(i)",
                hasAudio: i == 0 || i > defaults.textLimit - defaults.audioLimit
            )
            entries.append(entry)
            if entry.hasAudio { try WAV.encode(audio).write(to: defaults.audioURL(entry.id)) }
        }
        try JSONEncoder().encode(entries).write(to: directory.appending(path: "history.json"), options: .atomic)
        return entries
    }
    static func controller(in directory: URL, transcriber: any Transcriber = FixedTranscriber(text: "NEW_RESULT"),
                           llm: (any ChatCompleting)? = nil, textLimit: Int? = nil, files: PersistenceIO = PersistenceIO()) -> ControllerProbe {
        let historyDirectory = directory.appending(path: "History")
        let history = if let textLimit {
            DictationHistory(directory: historyDirectory, textLimit: textLimit, files: files)
        } else {
            DictationHistory(directory: historyDirectory, files: files)
        }
        let gate = TranscriberGate(transcriber: { transcriber }, reload: {}, acquisitionTimeout: 2)
        let store = MeetingStore(directory: directory.appending(path: "Meetings"), files: files)
        return ControllerProbe(history: history, gate: gate, meetingStore: store, llm: llm)
    }
}
