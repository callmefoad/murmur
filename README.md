# Murmur 🎙️

**Private, unlimited voice dictation for macOS — 100% on-device.**

Hold `fn`, speak, release — clean text appears at your cursor in any app.
No cloud, no subscription, no word limits. Your audio and transcripts never
leave your Mac.

![Murmur dashboard](Resources/screenshot.png)

Murmur is an open-source, fully local take on the modern AI dictation app
(in the spirit of Wispr Flow), built natively in Swift on Apple's on-device
speech and language models, with an optional local Whisper engine.

## Features

- **Two-speed dictation** — hold `fn` (or right ⌥) for instant rules-only
  cleanup; tap once, then hold the second press while speaking for one tuned
  Polished rewrite that resolves false starts, repetition, and jumbled
  thoughts. Two quick taps still arm the next hold. Murmur then automatically
  returns to Fast.
- **Undo** — off by default. A fumbled hotkey press that ended the previous
  dictation a moment early is indistinguishable from a deliberate "undo
  that", and guessing wrong destroys spoken work, so the shortcut stays
  disabled and ⌘Z is the answer. Opt in with
  `defaults write local.murmur undoWindowSeconds -float 2`.
- **Dictation HUD** — optional floating microphone and waveform indicator while
  you speak; it never displays transcript text.
- **Two recognition engines**, both offline:
  - **Apple** — instant, built into macOS (SpeechAnalyzer, macOS 26).
  - **Whisper** — optional precision engine via
    [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML on the
    Neural Engine). Your vocabulary is fed into the decoder prompt.
- **Pronunciation learning** — a Voice Training page learns how *you* say
  tricky words; corrections you make to transcripts are diffed and learned
  automatically; everything biases future recognition.
- **Cleanup pipeline** — filler-word removal, spoken "new line"/"new
  paragraph", auto-capitalization, personal dictionary, snippets
  (say a trigger phrase → paste a saved block). Cleanup rules are
  locale-aware (English, Spanish, French, German, Italian, Portuguese).
- **Cleanup levels** — Verbatim, Cleaned (default; rules only, no model),
  Polished and Tightened. Polished and above add one on-device model pass
  that cleans up dictated speech in the owner's own register. Short, clean
  dictations skip that pass entirely so they insert with no model latency;
  see [docs/latency.md](docs/latency.md).
- **My Voice presets** — write your own rewrite instructions ("tighten my
  phrasing, always contractions, no exclamation marks") and apply them to
  every dictation with the on-device model. Bind presets to specific apps,
  quick-switch from the menu bar.
- **Snippets** — say a trigger phrase → paste a saved block, now with
  `{{date}}`, `{{time}}`, `{{datetime}}`, and `{{clipboard}}` variables.
- **Styles** — per-app tone rewriting (formal / casual / very casual) using
  Apple Intelligence's on-device model.
- **Transforms** — select text in any app, press ⌃⌥1 to polish grammar or
  ⌃⌥2 to turn rough notes into a structured AI prompt, rewritten in place.
  Control+Option+digit is unmapped on the US layout, so nothing is typed
  over the selection before the transform reads it.
- **Dashboard** — history with search and correction-learning, usage stats
  (words, WPM, day streak), insights chart, a Voice Profile persona derived
  locally from what you dictate, scratchpad, and the My Voice preset editor.
  Export history as JSON or Markdown; keep 50–1000 transcripts.
- **Quiet failure handling** — transcription, microphone, and permission
  errors surface as macOS notifications (requested only when first needed)
  plus the dashboard caption.

## Requirements

- macOS 26 (Tahoe) or newer
- Apple Silicon Mac
- Xcode 26 command-line tools (`xcode-select --install`)
- For Styles / Transforms / Voice Profile: Apple Intelligence enabled
- For the Whisper engine: a one-time model download (150 MB – 1.6 GB)

## Build & run

```bash
git clone <this-repo>
cd murmur
./scripts/make_app.sh     # builds build/Murmur.app and hot-swaps any
                          # running instance with the new build
```

### Sending updates to testers

Murmur uses Sparkle for in-app updates. The first Sparkle-enabled build must be
installed once by hand; after that, Murmur checks for updates and can download
and install signed releases automatically. Distribution is not ready until a
Developer ID Application identity and Apple notarization credentials are
configured on the release Mac. To publish a later release:

```bash
MURMUR_RELEASE_NOTES="Pause handling and transcription improvements." \
MURMUR_PUBLISH=1 ./scripts/make_release.sh 0.1.1
```

The release script requires Developer ID signing and notarization, then signs
its update archive with the Sparkle EdDSA key in your login Keychain, creates a
GitHub Release, and pushes the signed appcast. macOS must be allowed to read
the private Sparkle key from Keychain during release. Keep that private key in
Keychain; only the public key is embedded in Murmur. Use the same Developer ID
signer and Sparkle key for every release. For friend testing, send the first
Sparkle-enabled, notarized app once;
future releases appear in Murmur's `Check for Updates…` menu item or install
automatically according to the user's update preference.

For a faster clean build with no WhisperKit dependency, build the Apple-only
edition with `MURMUR_LITE=1 swift build -c release`. The app hides Whisper
automatically; Apple on-device recognition remains fully functional.

Optional: run `./scripts/make_signing_cert.sh` once to create a local
self-signed signing certificate — this keeps macOS permission grants valid
across rebuilds and enables hardened-runtime signing (applied automatically
when a signing identity is found). Set `MURMUR_VERSION=x.y.z` to override
the bundle version, or `MURMUR_NORESTART=1` to skip the automatic
restart of a running instance after each build.

### One-time permissions

1. **Microphone** — allow when prompted on first dictation.
2. **Accessibility** — allow when prompted (needed for the global hotkey and
   for pasting). If the app still shows it as missing, use *Settings →
   Reset Grant & Relaunch* inside Murmur.

## CLI test modes

```bash
.build/debug/Murmur --selftest                          # formatter + learning tests
.build/debug/Murmur --transcribe audio.wav              # Apple engine
.build/debug/Murmur --transcribe audio.wav --engine whisper
.build/debug/Murmur --format "um hello new line hi"     # cleanup pipeline only
.build/debug/Murmur --transform "fix this grammer pls"  # on-device LLM polish
.build/debug/Murmur --needs-polish "yeah that works"   # would this pay for a model pass?
```

## Privacy

Everything runs on this Mac: recognition (Apple SpeechAnalyzer or local
Whisper), cleanup, tone rewriting (Apple Intelligence), and the Voice
Profile analysis. Murmur checks its signed update feed and downloads updates
when available. Other network requests are limited to one-time model downloads
by macOS itself (Apple speech assets) and, if you opt into the Whisper engine,
the model fetch from Hugging Face. Dictation data is stored only in
`~/Library/Application Support/Murmur/`.

## Architecture

Swift Package, with Sparkle for updates and WhisperKit only when the Whisper
engine is included:

```
HotkeyMonitor  →  AudioRecorder  →  Transcriber (Apple) / WhisperEngine
                                        ↓
     TextFormatter → LearnedStore → SnippetStore → RewriteEngine (model)
                                        ↓
                     TextInserter (direct AX, clipboard + ⌘V fallback)
```

`TextFormatter` is a pure function of its arguments: every gate that reads
speech content is threaded in explicitly rather than read from settings
inside it, so the whole rules pipeline is unit-testable. `RewriteEngine`
runs only when `needsPolish` says the text would benefit, and it discards
any rewrite that diverges too far from what was actually said.

## Design documents

- [PLAN.md](PLAN.md) — the original design document.
- [docs/voice.md](docs/voice.md) — which parts of the owner's writing style
  are guaranteed in code and which are only requested of the model, and why
  the line falls where it does.
- [docs/latency.md](docs/latency.md) — the measured cost of every stage
  between key release and text appearing, what the defaults do about it, and
  which optimizations were measured and rejected.

## A note on reading this code

Two constraints shape more of it than anything else, and changes that ignore
them tend to be wrong:

1. **Murmur must never act on the content of speech.** It transcribes,
   cleans by rule, and pastes. A transcript containing "caveman mode" once
   came back rewritten in caveman style: prompt injection where the injected
   text is the user's own voice. Any feature that reads the transcript will
   fire on words the user merely said, so it has to be gated and default
   off. See the defences listed in [docs/voice.md](docs/voice.md).
2. **A dictation must never erase or rewrite text already placed in another
   app.** This rules out several otherwise attractive optimizations, which
   is why they are recorded as rejected rather than missing.

## License

[MIT](LICENSE). Not affiliated with Wispr Flow, OpenAI, or Apple.
