# Parlo

Voice dictation for macOS, in the style of FluidVoice and Wispr Flow. Hold **fn**, speak, release: Parlo transcribes on this Mac, optionally cleans the text up with an LLM, and pastes it into whatever field has focus, in any app.

- **Local transcription** with a downloadable model catalog: Apple Speech (built in), Parakeet v3 / Ultra / Redux / v2, Cohere Transcribe, Nemotron Multilingual, Whisper tiny → large-v3-turbo.
- **AI cleanup** (optional) with Apple Intelligence on-device, or any OpenAI-compatible endpoint: Groq, OpenAI, OpenRouter, local Ollama. Removes fillers, fixes punctuation and self-corrections.
- **Per-app tone**: formal in Mail, casual in Slack, technical in Cursor/Xcode/Terminal. Editable.
- **Personal dictionary**: "heard as → write as" replacements, plus terms the AI must spell exactly.
- **Voice snippets**: say a trigger phrase, get saved text, alone or mid-sentence.
- **Command mode**: hold **ctrl**, then **fn**, and say an instruction. It rewrites the selected text, or generates new text when nothing is selected. Needs AI cleanup configured.

Design: [`docs/superpowers/specs/2026-10-23-parlo-design.md`](docs/superpowers/specs/2026-10-23-parlo-design.md).

## Requirements

macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```sh
./scripts/run.sh
```

Generates the Xcode project, builds Release, installs to `~/Applications/Parlo.app` and launches it. Parlo lives in the menu bar (waveform icon).

## First launch

The welcome window walks through:

1. **Microphone**, **Accessibility** (to paste), **Input Monitoring** (to see the fn key). Grant all three.
2. **System Settings → Keyboard → Press 🌐 key to: Do Nothing**, so fn doesn't open the emoji picker.
3. A speech model. Parakeet TDT v3 is recommended; if FluidVoice is installed it is probably already on disk.

Reopen it any time from the menu: **Permissions & Setup…**

### Signing and permissions

There is no Developer ID signature yet. `run.sh` signs the app with a local self-signed certificate, "Parlo Development", created in your login keychain on the first run (`scripts/make-signing-identity.sh`). Because the certificate stays the same, macOS keeps the privacy permissions across rebuilds. If Input Monitoring is granted but fn does nothing, use **Restart Parlo** in the welcome window: macOS applies that permission only after a relaunch.

If permissions ever look on but don't work, reset them and grant again: `tccutil reset All com.mariomiletta.parlo`.

## Models

Settings → Models: download, cancel, delete, and pick the active one.

- Parakeet, Cohere and Nemotron models live in `~/Library/Application Support/FluidAudio/Models`, the folder FluidVoice also uses. Models FluidVoice already downloaded show up as installed; deleting one here deletes it for FluidVoice too.
- Whisper models live in `~/Library/Application Support/Parlo/Models/whisperkit`.
- Apple Speech downloads its language assets through macOS on first use. Until they finish, dictation shows a message instead of waiting.
- Cohere Transcribe can't auto-detect the language: set one in Settings → General.

## AI cleanup

Settings → AI (or **AI Cleanup** in the menu bar): turn it on and pick a provider. **Apple Intelligence** is the default: it runs on the Mac with no key, once Apple Intelligence is on in System Settings and its model has finished downloading. For a cloud or Ollama provider, pick a preset (or a custom OpenAI-compatible URL), set the model and API key, then **Test connection**. The key is stored in the macOS keychain. If the AI call fails or times out (5 s), Parlo pastes the raw transcript and says so: a dictation is never lost.

## Data

Settings, styles, dictionary and snippets: `~/Library/Application Support/Parlo/settings.json`. Nothing leaves the Mac except the text sent to the AI provider you configure.

## Tests

```sh
cd ParloKit
swift test                                   # unit tests
PARLO_INTEGRATION=1 swift test --filter EngineIntegrationTests
                                             # real models, Italian + English audio from `say`
PARLO_INTEGRATION=1 PARLO_DOWNLOAD=whisperTiny,parakeetRedux swift test --filter EngineIntegrationTests
                                             # also downloads the listed models first
```

## Layout

- `App/`: the macOS app (menu bar, HUD, hotkey, recording, paste, settings UI).
- `ParloKit/Sources/ParloCore`: pure logic (settings, prompts, dictionary, snippets, pipelines, model manager, LLM client). Unit-tested.
- `ParloKit/Sources/ParloEngines`: transcription backends (Apple Speech, FluidAudio, WhisperKit).
