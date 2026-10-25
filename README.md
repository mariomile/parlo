<img src="assets/parlo-mark.svg" width="56" alt="">

# Parlo

Voice dictation for macOS, in the style of FluidVoice and Wispr Flow. Hold **fn**, speak, release: Parlo transcribes on this Mac, optionally cleans the text up with an LLM, and pastes it into whatever field has focus, in any app.

- **Local transcription** with a downloadable model catalog: Apple Speech (built in), Parakeet v3 / Ultra / Redux / v2, Qwen3-ASR, Cohere Transcribe, Nemotron Multilingual, Whisper tiny → large-v3-turbo.
- **AI cleanup** (optional) with Apple Intelligence on-device, Qwen3 4B running inside Parlo (MLX, no key, ~2.3 GB download), or any OpenAI-compatible endpoint: Groq, OpenAI, OpenRouter, local Ollama. Removes fillers, fixes punctuation and self-corrections.
- **Hands-free**: double-tap **fn** to keep recording without holding it; press fn again to stop, Esc to cancel (the audio stays in Recent).
- **Live text** in the notch while you speak, with the faster models.
- **Spoken layout**: say "a capo" / "new line", "nuovo paragrafo" / "new paragraph", "punto elenco" / "bullet point" after a pause.
- **Per-app tone**: formal in Mail, casual in Slack, technical in Cursor/Xcode/Terminal. Editable.
- **Personal dictionary**: "heard as → write as" replacements, plus terms the AI must spell exactly. Qwen3-ASR also gets the terms as hints. When you fix a word right after a paste, Parlo offers to add it.
- **Voice snippets**: say a trigger phrase, get saved text, alone or mid-sentence.
- **Command mode**: hold **ctrl**, then **fn**, and say an instruction. It rewrites the selected text, or generates new text when nothing is selected. Needs AI cleanup configured.
- **History**: every dictation's text, searchable, with stats, re-paste and Markdown export. Audio of the last 20 is kept for retry.
- **Transcribe a file**: drop any audio file macOS can read on the History window.

Design: [`docs/superpowers/specs/2026-10-23-parlo-design.md`](docs/superpowers/specs/2026-10-23-parlo-design.md).

## Requirements

macOS 26+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```sh
./scripts/run.sh
```

Builds and signs Release (`scripts/build.sh`), installs to `~/Applications/Parlo.app` and launches it. Parlo lives in the menu bar (waveform icon).

Or download `Parlo-x.y.z.zip` from [Releases](https://github.com/mariomile/parlo/releases), unzip it and move Parlo to Applications. It isn't notarized, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**.

## First launch

The welcome window walks through:

1. **Microphone**, **Accessibility** (to paste), **Input Monitoring** (to see the fn key). Grant all three.
2. **System Settings → Keyboard → Press 🌐 key to: Do Nothing**, so fn doesn't open the emoji picker.
3. A speech model. Parakeet TDT v3 downloads on its own and Parlo switches to it when it's ready; until then it uses Apple Speech. If FluidVoice is installed it is probably already on disk.
4. **Open Parlo at login**, on by default. Change it later in Settings → General.

Reopen it any time from the menu: **Permissions & Setup…**

### Signing and permissions

There is no Developer ID signature yet. `build.sh` signs the app with a local self-signed certificate, "Parlo Development", created in your login keychain on the first run (`scripts/make-signing-identity.sh`). Because the certificate stays the same, macOS keeps the privacy permissions across rebuilds. If Input Monitoring is granted but fn does nothing, use **Restart Parlo** in the welcome window: macOS applies that permission only after a relaunch.

If permissions ever look on but don't work, reset them and grant again: `tccutil reset All com.mariomiletta.parlo`.

## Updates

Parlo checks the latest GitHub release once a day (Sparkle) and offers to install a newer version. Settings → General → Updates turns the check off or runs it now.

To publish a release, from a clean `main`:

```sh
scripts/release.sh 0.2.0
```

It bumps the version in `project.yml`, builds and signs, zips the app, signs the zip with the EdDSA key "parlo" from the login keychain, commits, tags `v0.2.0`, pushes, and uploads the zip and `appcast.xml` to a GitHub release. Installed copies only accept updates signed with that key: back it up with `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account parlo -x ~/parlo-key.txt` and keep the file outside the repo. Back up the "Parlo Development" certificate too (Keychain Access → My Certificates → Export, as .p12): a release signed with a different certificate still installs, but macOS revokes the microphone, Accessibility and Input Monitoring permissions of everyone who updates.

Built Parlo yourself? Turn the update check off in Settings → General. An update replaces your build with the published one, signed by a different certificate, and macOS drops the permissions. Debug builds never check.

## Models

Settings → Models: download, cancel, delete, and pick the active one.

- Parakeet, Cohere and Nemotron models live in `~/Library/Application Support/FluidAudio/Models`, the folder FluidVoice also uses. Models FluidVoice already downloaded show up as installed; deleting one here deletes it for FluidVoice too.
- Whisper models live in `~/Library/Application Support/Parlo/Models/whisperkit`.
- Apple Speech downloads its language assets through macOS on first use. Until they finish, dictation shows a message instead of waiting.
- Cohere Transcribe can't auto-detect the language: set one in Settings → General.

## AI cleanup

Settings → AI (or **AI Cleanup** in the menu bar): turn it on and pick a provider. **Apple Intelligence** is the default: it runs on the Mac with no key, once Apple Intelligence is on in System Settings and its model has finished downloading. For a cloud or Ollama provider, pick a preset (or a custom OpenAI-compatible URL), set the model and API key, then **Test connection**. The key is stored in the macOS keychain. If the AI call fails or times out (5 s for a sentence, more for long dictations), Parlo pastes the raw transcript and says so: a dictation is never lost.

## Meetings

**Meeting → Start** in the menu bar records your microphone as "Me" and what the Mac plays (the call) as "Them". **Stop** transcribes both on this Mac and writes notes with the AI provider set in Settings → AI: a title, a summary, decisions and action items. **Meeting → ☰** opens every meeting, where you can copy or export it as Markdown. The first meeting asks for System Audio Recording; if it's denied, only your side is transcribed, and the meeting says so.

## Pasting

Parlo pastes with ⌘V and then puts your clipboard back. When nothing that takes text has focus (the desktop, a button, a list), it copies the text instead and says "press ⌘V". A transcription that hangs is stopped after 30 s plus the length of the recording, and the audio stays in Recent for Retry.

## Data

Settings, styles, dictionary and snippets: `~/Library/Application Support/Parlo/settings.json`. History: `~/Library/Application Support/Parlo/History`. Meetings: `~/Library/Application Support/Parlo/Meetings`. Nothing leaves the Mac except the text sent to the AI provider you configure.

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
