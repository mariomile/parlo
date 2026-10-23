# Parlo: design

Date: 2026-10-23
Status: approved in chat, pending spec review

## What it is

Parlo is a macOS dictation app in the style of [FluidVoice](https://fluidvoice.com/) and [Wispr Flow](https://wisprflow.ai). Hold a key, speak, release: the speech is transcribed on-device, optionally cleaned up by an LLM, and pasted into whatever text field has focus, in any app.

Audience: the author's personal use first, product later. v1 is built clean enough to distribute, but skips signing, notarization and auto-update.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Platform | Native macOS app, Swift 6 + SwiftUI, menu bar only (`LSUIElement`) | Best integration with global hotkeys, Accessibility, paste |
| Codebase | Written from scratch, not a FluidVoice fork | FluidVoice is GPLv3; a fork would force any distributed version to stay open source |
| Transcription | On-device, user picks from a catalog of downloadable models | Privacy, offline, no per-word cost |
| Cleanup | Optional LLM over an OpenAI-compatible endpoint | One client covers Groq, OpenAI, OpenRouter, local Ollama |
| Project generation | XcodeGen (`project.yml`) | No hand-edited `.pbxproj` |
| Sandbox | Off | Needs CGEvent tap, synthetic key events, Accessibility |
| Min OS | macOS 26 | Apple SpeechAnalyzer; dev machine runs macOS 27 |

## Scope

### In v1
1. Hold-to-talk dictation (Fn) with paste into the focused field.
2. Local transcription with a model catalog: download, progress, cancel, delete, select active.
3. LLM cleanup: filler removal, punctuation, mid-sentence self-corrections, list/email formatting.
4. Per-app styles: tone chosen from the frontmost app.
5. Personal dictionary: terms the LLM must spell right, plus deterministic "heard as → write as" replacements.
6. Voice snippets: a trigger phrase expands to saved text, standalone or inline.
7. Command mode (Fn+Ctrl): spoken instruction applied to the selected text, or a generation request when nothing is selected.
8. Settings window and first-run permissions checklist.

### Out of v1
Meeting notetaker, dictation history, code signing/notarization/auto-update (Sparkle), Windows/iOS, live streaming transcription while speaking, bundled local LLM (Ollama works through the endpoint setting).

## Model catalog

| Model | Engine | Download | Languages | Notes |
|---|---|---|---|---|
| Apple Speech | Apple SpeechAnalyzer | none (system asset) | it, en, many more | Active on first launch |
| Parakeet TDT v3 | FluidAudio | ~600 MB | 25 European incl. it, auto-detect | Recommended default |
| Parakeet Ultra | FluidAudio | ~600 MB | same as v3 | Higher accuracy than v3 |
| Parakeet Redux | FluidAudio | ~220 MB | multilingual | Lightest |
| Parakeet TDT v2 | FluidAudio | ~600 MB | en only | Best English |
| Cohere Transcribe | FluidAudio | ~1.8 GB | 14 incl. it | Top accuracy; language must be set explicitly |
| Nemotron Speech Multilingual | FluidAudio | ~600 MB | en, es, fr, it, pt, de, zh, ja | |
| Whisper tiny / base / small / large-v3-turbo | WhisperKit | 40 MB to 1.6 GB | 99 | Widest language coverage, slower |

Sizes are approximate; the catalog shows the real size reported at download time. Exact FluidAudio/WhisperKit identifiers are pinned in the implementation plan after checking each library's current API.

Sources: [FluidAudio models](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [WhisperKit](https://github.com/argmaxinc/WhisperKit).

## Architecture

One component per file, each with one job. Pure logic is separated from system I/O so it can be unit-tested.

**System I/O**
- `HotkeyMonitor`: CGEvent tap on `flagsChanged`. Fn down/up starts/stops dictation; Fn+Ctrl starts/stops command mode.
- `AudioRecorder`: AVAudioEngine input tap, converts to 16 kHz mono Float32, accumulates samples, publishes an input level for the HUD.
- `Transcriber` protocol with three implementations: `FluidAudioTranscriber`, `WhisperKitTranscriber`, `AppleSpeechTranscriber`. Input: samples + language setting. Output: text.
- `ModelManager`: owns the catalog, downloads models (FluidAudio models into FluidAudio's default cache `~/Library/Application Support/FluidAudio/Models`, shared with FluidVoice; WhisperKit models into `~/Library/Application Support/Parlo/Models/whisperkit`; Apple Speech assets via the system), reports progress, supports cancel and delete, persists the active model, loads it and keeps it warm.
- `LLMClient`: OpenAI-compatible `chat/completions`. Base URL, model and on/off in settings; API key in Keychain. 5 s timeout.
- `TextInserter`: saves the pasteboard, writes the text, posts Cmd+V, restores the pasteboard.
- `SelectionReader`: saves the pasteboard, posts Cmd+C, reads the selection, restores the pasteboard. Cmd+C is used instead of the Accessibility selected-text attribute because it works in Electron and browser apps.
- `FrontmostApp`: bundle ID of the frontmost app, captured at key-down.
- `HUD`: non-activating floating panel, bottom center. States: recording (waveform), processing, error message.

**Pure logic (unit-tested)**
- `PromptBuilder`: system prompt from base cleanup rules + style + dictionary terms. Separate builder for command mode.
- `StyleResolver`: bundle ID → style (formal, casual, very casual, technical, neutral). User table over built-in defaults (Mail formal, Slack casual, Messages very casual, Cursor/Xcode/Terminal technical); unknown apps get neutral.
- `DictionaryReplacer`: case-insensitive whole-word "heard as → write as" replacements.
- `SnippetCodec`: replaces trigger phrases with placeholder tokens before the LLM and expands them after. Matching ignores case and punctuation.
- `RecordingGuard`: discards recordings shorter than 0.3 s.

**Persistence**
Settings, styles table, dictionary and snippets as JSON in `~/Library/Application Support/Parlo/`. API key in Keychain. No database.

**UI**
Menu bar menu: status, active model, "Copy last dictation", Settings, Quit. Settings tabs: General (hotkeys info, microphone, language), Models, AI, Styles, Dictionary, Snippets. First-run window: permissions checklist and the Parakeet v3 download offer.

## Data flow

### Dictation (hold Fn)
1. Fn down: capture frontmost bundle ID, start recording, show HUD.
2. Fn up: stop recording. If shorter than 0.3 s, discard silently.
3. Transcribe with the active model.
4. Apply dictionary replacements.
5. Encode snippet triggers as placeholders.
6. If LLM is enabled: clean up with the style for the captured app and the dictionary terms.
7. Expand snippet placeholders.
8. Paste into the focused field; store as "last dictation".

### Command mode (hold Fn+Ctrl)
1. Key down: capture the selection via Cmd+C, start recording.
2. Key up: transcribe the instruction.
3. With selection: LLM applies the instruction to the selected text and returns only the result, which replaces the selection.
4. Without selection: the instruction is a generation request; the result is pasted.
5. LLM disabled or not configured: HUD error, nothing pasted.

## Permissions and errors

| Situation | Behavior |
|---|---|
| First launch | Checklist: Microphone, Accessibility, Input Monitoring (needed by the Fn key event tap), and instruction to set "Press 🌐 key to: Do nothing" so Fn doesn't open the emoji picker |
| Permission missing at use time | HUD error naming the permission; menu → Permissions & Setup reopens the checklist with buttons to the right System Settings panes |
| Active model still downloading | HUD: "Model downloading" with progress; nothing recorded |
| Download fails or is cancelled | Partial files deleted; model stays "not downloaded" |
| Active model deleted | Active model reverts to Apple Speech |
| Empty transcript | HUD "Nothing heard"; nothing pasted |
| LLM error or timeout | Paste the transcript with dictionary replacements and expanded snippets; HUD warns that cleanup was skipped. A dictation is never lost |
| Paste fails | "Copy last dictation" in the menu |
| No microphone | HUD error; nothing recorded |

## Testing

- Unit tests (Swift Testing): `PromptBuilder`, `StyleResolver`, `DictionaryReplacer`, `SnippetCodec` round-trip, `RecordingGuard`, `LLMClient` against a stubbed `URLProtocol`, `ModelManager` state transitions with a fake downloader.
- Integration tests, one per engine: generate Italian and English audio with macOS `say`, transcribe, assert key words are present. Skipped when the model isn't downloaded.
- Manual end-to-end on a real Mac: dictate in TextEdit, Slack and Chrome in Italian and English; snippet standalone and inline; command mode on a selection and without one; LLM off.

## Size

Large: roughly 4,000 to 5,000 lines of Swift across about 20 files, two external packages (FluidAudio, WhisperKit).
