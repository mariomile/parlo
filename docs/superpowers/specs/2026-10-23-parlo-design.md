# Parlo: design

Date: 2026-10-23
Status: implemented

## What it is

Parlo is a macOS dictation app in the style of [FluidVoice](https://fluidvoice.com/) and [Wispr Flow](https://wisprflow.ai). Hold a key, speak, release: the speech is transcribed on-device, optionally cleaned up by an LLM, and pasted into whatever text field has focus, in any app.

Audience: the author's personal use first, product later. It is built clean enough to distribute, but is not yet signed with a Developer ID or notarized.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Platform | Native macOS app, Swift 6 + SwiftUI, menu bar only (`LSUIElement`) | Best integration with global hotkeys, Accessibility, paste |
| Codebase | Written from scratch, not a FluidVoice fork | FluidVoice is GPLv3; a fork would force any distributed version to stay open source |
| Transcription | On-device, user picks from a catalog of downloadable models | Privacy, offline, no per-word cost |
| Cleanup | Optional LLM: Apple Intelligence on-device, Qwen3 4B bundled and run with MLX, or an OpenAI-compatible endpoint | On-device options need no key and send nothing out; one client covers Groq, OpenAI, OpenRouter, local Ollama |
| Project generation | XcodeGen (`project.yml`) | No hand-edited `.pbxproj` |
| Sandbox | Off | Needs CGEvent tap, synthetic key events, Accessibility |
| Min OS | macOS 26 | Apple SpeechAnalyzer; dev machine runs macOS 27 |

## Scope

### Built
1. Hold-to-talk dictation (Fn) with paste into the focused field. Double-tap Fn to keep recording hands-free; Fn again stops, Esc cancels and keeps the audio.
2. Local transcription with a model catalog: download, progress, cancel, delete, select active. Silero VAD skips silence and room noise before transcribing.
3. Live text in the HUD while speaking, with the faster models.
4. LLM cleanup: filler removal, punctuation, mid-sentence self-corrections, list/email formatting, spoken layout ("new line", "new paragraph", "bullet point"). Providers: Apple Intelligence, Qwen3 4B bundled (MLX, ~2.3 GB download, no key), or any OpenAI-compatible endpoint.
5. Per-app styles: tone chosen from the frontmost app.
6. Personal dictionary: terms the LLM must spell right, plus deterministic "heard as → write as" replacements. Terms are also passed to Qwen3-ASR and Parakeet as hints. After a paste, a word the user fixes is offered for the dictionary.
7. Voice snippets: a trigger phrase expands to saved text, standalone or inline.
8. Command mode (Ctrl, then Fn): spoken instruction applied to the selected text, or a generation request when nothing is selected.
9. Dictation history: every dictation's text, searchable, with stats, re-paste and Markdown export; audio of the last 20 kept for retry. Any audio file can be transcribed from the History window.
10. Meeting notetaker (below).
11. Settings window, first-run permissions checklist, microphone picker, open at login.
12. Automatic updates (Sparkle) from GitHub releases, EdDSA-signed; `scripts/release.sh` publishes one. A scheduled check that finds an update shows it in the menu rather than over other apps.

### Not built
Developer ID signing and notarization, Windows/iOS.

### Meeting notetaker
Started and stopped from the menu bar, for a call in any app.
1. **Capture.** The microphone is "Me". Everything the Mac plays except Parlo is "Them", through a Core Audio process tap on a private aggregate device built on the current output and rebuilt when the output changes. It needs "System Audio Recording Only" permission (`NSAudioCaptureUsageDescription`); when that's denied the buffers are silent, so a silent "Them" track is reported in the meeting.
2. **Storage.** Each track is written to its own 16-bit CAF as it is captured (`TrackWriter`), padded with silence to the meeting's clock so the two tracks stay aligned. A quit, logout or crash keeps what was written; the meeting is marked interrupted, to process again.
3. **Transcription.** After stop, each track is split at speech by Silero VAD (pieces of at most 14 s), and a meeting fails with a clear error if Silero can't load. The pieces are transcribed with the active model in the background, behind any dictation, then merged into timed turns, Me and Them.
4. **Notes.** These come from the AI provider chosen in Settings → AI. Cleanup can stay off when that provider runs on this Mac; a hosted one needs it on. Long meetings are read in parts that fit the provider (Apple Intelligence 4k characters, the MLX model 12k, a hosted model 48k), then the parts' points are merged. The result has a title, a summary, decisions and action items. A notes failure keeps the transcript and says why.
5. **UI.** A Meetings window lists the meetings, with progress, notes, the transcript, copy and export as Markdown, process again, and delete. The five newest finished meetings keep their audio; older ones keep only the text.

## Model catalog

| Model | Engine | Download | Languages | Notes |
|---|---|---|---|---|
| Apple Speech | Apple SpeechAnalyzer | none (system asset) | it, en, many more | Active on first launch |
| Parakeet TDT v3 | FluidAudio | ~460 MB | 25 European incl. it, auto-detect | Recommended default |
| Parakeet Ultra | FluidAudio | ~630 MB | same as v3 | Higher accuracy than v3 |
| Parakeet Redux | FluidAudio | ~215 MB | same as v3 | Lightest Parakeet |
| Parakeet TDT v2 | FluidAudio | ~440 MB | en only | Best English |
| Cohere Transcribe | FluidAudio | ~2.2 GB | 14 incl. it | Slow, and garbled most Italian in tests; language must be set explicitly |
| Nemotron Speech Multilingual | FluidAudio | ~610 MB | en, es, fr, it, pt, de, zh, ja | |
| Qwen3-ASR 1.7B | mlx-audio-swift (MLX) | ~1.5 GB | 30, auto-detect | Most accurate in tests; uses dictionary terms as hints |
| Whisper Tiny | WhisperKit | ~77 MB | 99 | Fastest Whisper, lowest accuracy |
| Whisper Base | WhisperKit | ~150 MB | 99 | |
| Whisper Small | WhisperKit | ~490 MB | 99 | |
| Whisper Large v3 Turbo (compact) | WhisperKit | ~650 MB | 99 | Turbo at a third of the size |
| Whisper Large v3 | WhisperKit | ~950 MB | 99 | Most accurate Whisper on Italian |
| Whisper Large v3 Turbo | WhisperKit | ~1.6 GB | 99 | Widest language coverage |

Sizes are approximate; Settings shows the size on disk once a model is downloaded. Each model also has 1 to 5 ratings for Italian, English and speed, from public benchmarks and tests on Apple Silicon. The authoritative list is `ModelCatalog.swift`. Exact FluidAudio/WhisperKit identifiers are in the implementation plan.

Sources: [FluidAudio models](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [WhisperKit](https://github.com/argmaxinc/WhisperKit).

## Architecture

Pure logic lives in the `ParloCore` package target and is unit-tested; engine wrappers in `ParloEngines`; system I/O and SwiftUI in `App/`.

**System I/O (`App/`)**
- `HotkeyMonitor`: CGEvent tap on `flagsChanged` and key-down, plus polling for missed Fn releases. Events feed `HotkeyStateMachine` (Core): Fn down/up starts/stops dictation; Ctrl held at Fn down means command mode; double-tap locks hands-free; another key within 0.6 s of Fn down, or Esc, cancels.
- `AudioRecorder`: AVAudioEngine input tap on the chosen microphone, converts to 16 kHz mono Float32, accumulates samples, publishes an input level for the HUD. `RecordingSession` wraps it with the frontmost app, the selection read for command mode, and the live preview.
- `SystemAudioTap` and `MeetingRecorder`: the meeting capture described above.
- `TextInserter`: saves the pasteboard, writes the text, posts Cmd+V, restores the pasteboard. `PasteTarget` (Core) checks first that the focused element takes text; if not, the text is copied and the HUD says to press Cmd+V.
- `SelectionReader`: saves the pasteboard, posts Cmd+C, reads the selection, restores the pasteboard. Cmd+C is used instead of the Accessibility selected-text attribute because it works in Electron and browser apps.
- `FrontmostApp`: bundle ID of the frontmost app, captured at key-down.
- `HUD`: non-activating panel shaped as an island growing out of the notch, at the top of the screen. States: recording (waveform, live text, hands-free marker), processing, done, message or error.
- `AppController` wires hotkey, recording, transcription jobs, paste, history, meetings and settings.

**Transcription (`ParloCore` + `ParloEngines`)**
- `Transcriber` protocol (samples, language, dictionary terms in; text out) with six implementations: `ParakeetTranscriber`, `CohereTranscriber`, `NemotronTranscriber`, `Qwen3ASRTranscriber`, `WhisperKitTranscriber`, `AppleSpeechTranscriber`. `EngineInstaller` maps each catalog model to its backend. `SileroSpeechDetector` implements `SpeechDetector` and `SpeechSegmenting`.
- `ModelManager`: owns the catalog and the active model, with one `Installable` (download state, progress, cancel, delete) per model. Persists the active model, loads it and keeps it warm. FluidAudio models live in FluidAudio's default cache `~/Library/Application Support/FluidAudio/Models`, shared with FluidVoice; WhisperKit models in `~/Library/Application Support/Parlo/Models/whisperkit`; Qwen3-ASR and the cleanup model in `~/Library/Application Support/Parlo/Models`; Apple Speech assets via the system.
- `TranscriberGate`: one caller at a time on the shared transcriber: dictations first, then background work (files, meetings), live previews only when idle.
- `TranscriptionJob`: one recording through the whole pipeline (see Data flow), with deadlines so a stuck engine can't hold the queue. `ChunkedTranscriber` splits long audio.
- `LLMClient`: OpenAI-compatible `chat/completions`; API key in Keychain, per server. `AppleIntelligenceClient` and `LocalLLMClient` (Qwen3 4B on MLX, `CleanupModel`) implement the same `ChatCompleting` protocol. Cleanup timeout 5 s plus 1 s per 100 characters; command mode 15 s.

**Pure logic (unit-tested)**
- `PromptBuilder`: system prompt from base cleanup rules + style + dictionary terms. Separate builder for command mode.
- `StyleResolver`: bundle ID → style (formal, casual, very casual, technical, neutral). User table over built-in defaults (Mail formal, Slack casual, Messages very casual, Cursor/Xcode/Terminal technical); unknown apps get neutral.
- `DictionaryReplacer`: case-insensitive whole-word "heard as → write as" replacements. `CorrectionDetector` and `SuggestionInbox` propose dictionary entries from edits made right after a paste.
- `SnippetCodec`: replaces trigger phrases with placeholder tokens before the LLM and expands them after. Matching ignores case and punctuation.
- `VoiceFormatting`: spoken layout commands. `CleanupOutput` rejects cleanup replies that look wrong.
- `RecordingGuard`: discards recordings shorter than 0.3 s.
- `DictationHistory`, `MeetingStore`, `MeetingNotes`, `MeetingTrack`: history and meeting storage and processing.

**Persistence**
Settings, styles table, dictionary and snippets as JSON in `~/Library/Application Support/Parlo/settings.json`. History in `.../History`, meetings in `.../Meetings`. API key in Keychain. No database.

**UI**
Menu bar window: status, active model, language, AI cleanup toggle, meeting start/stop and list, dictionary suggestions, Recent dictations with copy and retry, Settings, Permissions, Quit. Settings tabs: General (shortcuts, language, microphone, open at login, permissions), Models, AI, Styles, Dictionary, Snippets. History window and Meetings window. First-run window: permissions checklist and the Parakeet v3 download offer.

## Data flow

### Dictation (hold Fn, or double-tap for hands-free)
1. Fn down: capture frontmost bundle ID, start recording, show HUD.
2. Fn up: stop recording. If shorter than 0.3 s, discard silently. If Silero finds no speech, "Nothing heard".
3. Transcribe with the active model, passing dictionary terms to engines that take hints.
4. Apply dictionary replacements, then spoken layout commands.
5. Encode snippet triggers as placeholders.
6. If LLM is enabled: clean up with the style for the captured app and the dictionary terms.
7. Expand snippet placeholders.
8. Paste into the focused field; store in history.

### Command mode (hold Ctrl, then Fn)
1. Key down: capture the selection via Cmd+C, start recording.
2. Key up: transcribe the instruction.
3. With selection: LLM applies the instruction to the selected text and returns only the result, which replaces the selection.
4. Without selection: the instruction is a generation request; the result is pasted.
5. LLM disabled or not configured: HUD error, nothing pasted.

## Permissions and errors

| Situation | Behavior |
|---|---|
| First launch | Checklist: Microphone, Accessibility, Input Monitoring (needed by the Fn key event tap), and instruction to set "Press 🌐 key to: Do nothing" so Fn doesn't open the emoji picker |
| Permission missing at use time | HUD error naming the permission; menu → Permissions reopens the checklist with buttons to the right System Settings panes |
| Active model still downloading | HUD: model name and progress; nothing recorded |
| Download fails or is cancelled | Partial files deleted; model stays "not downloaded" |
| Active model deleted | Active model reverts to Apple Speech |
| Empty transcript | HUD "Nothing heard"; nothing pasted; the audio stays in Recent |
| LLM error, timeout or odd output | Paste the transcript with dictionary replacements and expanded snippets; HUD warns that cleanup was skipped. A dictation is never lost |
| Paste fails or nothing takes text | The text is copied and the HUD says to press Cmd+V; Recent in the menu also copies it |
| No microphone | HUD error; nothing recorded |

## Testing

- Unit tests (Swift Testing, `swift test` in `ParloKit/`): `PromptBuilder`, `StyleResolver`, `DictionaryReplacer`, `SnippetCodec` round-trip, `RecordingGuard` and `TranscriptionJob`, `HotkeyStateMachine`, `LLMClient` against a stubbed `URLProtocol`, `ModelManager` state transitions with a fake installer, `DictationHistory`, live preview, meetings and meeting notes.
- Integration tests (`PARLO_INTEGRATION=1`), one per catalog model: generate Italian and English audio with macOS `say`, transcribe, assert key words are present. Skipped when the model isn't downloaded, unless listed in `PARLO_DOWNLOAD`. Further ones cover speech detection, vocabulary hints, file transcription and meetings.
- Manual end-to-end on a real Mac: dictate in TextEdit, Slack and Chrome in Italian and English; snippet standalone and inline; command mode on a selection and without one; LLM off.

## Size

Large: roughly 7,900 lines of Swift across about 65 files in `App/` and `ParloKit/Sources`, plus tests. Dependencies: FluidAudio, WhisperKit, mlx-audio-swift and the MLX language-model stack, with swift-huggingface and swift-transformers, and Sparkle for updates.
