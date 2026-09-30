# Murmur — shared AI handoff

This is the shared, public-safe handoff for Codex and Claude. It records project
decisions, verified work, and the next useful step so either agent can resume
without relying on chat history. Never put credentials, signing keys, private
transcripts, or other secrets in this file; the GitHub repository is public.

## Current state

- Repository: `callmefoad/murmur`; default branch: `main`.
- Last verified sync: 2026-09-29. Full build and XCTest suite run: 375 tests,
  0 failures.
- Repository visibility is public; `main` has no branch protection or rulesets.
- Latest change clarified that dictation stays on-device while app updates and
  optional model downloads use the network (`README.md`, `MainView.swift`, and
  `scripts/make_app.sh`).
- Verification for that copy change: `MainView.swift` parsed with the installed
  Xcode Swift compiler and `git diff --check` passed. Full build and XCTest suite
  were not run in that turn.

## Product decisions to preserve

- Dictation is push-to-talk. Preserve the user's words in Fast mode; do not add
  hands-free behavior or voice-command/screen-action automation.
- Polished mode is armed for the next hold and then returns to Fast.
- Spoken “period” and “question mark” should become punctuation. Spoken symbols
  are enabled by default; Settings can disable them when words like “star” or
  “dash” need to remain literal.
- FN blocking is enabled by default to prevent macOS Dictation from competing
  with Murmur. It can interfere with `fn`+arrow, `fn`+Delete, and `fn`+F-key
  shortcuts; the Settings toggle is the user's escape hatch.
- Audio and transcript content stay on-device. Network requests are for signed
  app updates and optional/macOS speech-model downloads, not dictation content.
- Keep the Sparkle automatic-update behavior: the user wants testers' apps to
  update without resending ZIPs. Do not switch it off without asking.

## Open work / known blockers

1. Run a full build and XCTest suite once the active Mac's Xcode license/toolchain
   gate is resolved. Do not claim the suite passes until it has actually run.
2. External tester releases still require a valid Developer ID Application
   identity, Apple notarization credentials, and Keychain approval for Sparkle's
   private signing key. The private key must remain in Keychain, never in this
   repository. The release script should fail closed until these are ready.
3. The Sparkle updater code is wired in, but the tester release is not complete
   until a signed, notarized build and signed appcast are published.

## Handoff protocol

1. Work one agent at a time. Before editing, read this file and inspect the
   current branch, working tree, and recent commits. If another agent has
   uncommitted work, preserve it and coordinate before touching overlapping files.
2. After work, append a dated entry below with: what changed, files touched,
   exact verification performed and its result, commit/push status, and the next
   recommended step. Append; do not erase another agent's notes.
3. Commit and push verified changes when the user has asked for shared GitHub
   handoff. Include the commit SHA in the entry. If not pushed, say why.
4. Keep entries factual. Separate tested behavior from assumptions, and never
   copy secrets or user dictation into the handoff.

## Copy/paste handoff prompt

“Read `AI_HANDOFF.md` and the latest Git state first. Continue the next useful
step recorded there without undoing another agent's work. When finished, append
a dated handoff entry with exact files changed, verification/results,
commit/push status, and the next step so the other agent can resume.”

## Recent handoffs

### 2026-09-29 — Claude Parakeet recognition engine

- Files: `Package.swift`, `Package.resolved`, `Sources/Murmur/ParakeetEngine.swift`
  (new), `Sources/Murmur/AppDelegate.swift`, `Sources/Murmur/MainView.swift`,
  `Sources/Murmur/Main.swift`, `README.md`.
- Added FluidAudio 0.17.4 (Apache 2.0, full build only, like WhisperKit) and a
  third engine, "Parakeet — fast + accurate", using Parakeet Ultra (`.ultra`).
  Same rules as Whisper: Apple covers dictations until the model is loaded, and
  any Parakeet failure falls back to Apple. Streaming stays Apple-only.
- Parakeet also ends sentences at long pauses, so the Punctuator still runs
  after it. Dictionary/learned corrections still apply after recognition
  (FluidAudio vocabulary boosting only exists for the 110M model).
- Verification: `--transcribe <file> --engine parakeet` on a synthetic
  recording with 0.7-0.9 s pauses: model download plus first load 31 s, then
  236 ms per run including load in a fresh process. It caught a leading "I"
  Apple dropped. Parakeet plus Punctuator output was correct. XCTest: 375
  tests, 0 failures. `--selftest` exit 0. App rebuilt, engine default for this
  Mac set to `parakeet` via `defaults write local.murmur engine parakeet`, app
  relaunched and running.
- Next: owner compares Parakeet against Apple on real dictation. If it holds up,
  consider making Parakeet the default for new installs.

### 2026-09-29 — Claude punctuation model replaces the LLM pass, HUD stays put

- Files: `Package.swift`, `Package.resolved`,
  `Sources/PunctuationRuntime/` (new C target), `Sources/Murmur/Punctuator.swift`
  (new), `Sources/Murmur/AppDelegate.swift`, `Sources/Murmur/RewriteEngine.swift`
  (restored to its pre-`c3809d4` state), `Sources/Murmur/CleanupLevel.swift`,
  `Sources/Murmur/MainView.swift`, `Sources/Murmur/Main.swift`,
  `Sources/Murmur/DictationHUD.swift`, `README.md`,
  `Tests/MurmurTests/PunctuatorTests.swift` (new),
  `Tests/MurmurTests/GrammarPunctuationTests.swift` (deleted).
- The FoundationModels punctuation pass was slow (1 to 2.5 s) and uneven. It is
  gone. "Punctuate by grammar" now runs
  `1-800-BAD-CODE/punctuation_fullstop_truecase_english` (Apache 2.0), a token
  classifier via ONNX Runtime (`onnxruntime-swift-package-manager` 1.24.2,
  static). It labels words, it cannot generate text, and the rebuild only
  changes trailing punctuation and first-letter case, then checks the word
  sequence is identical or returns the input.
- The ORT Objective-C bindings can't read bool tensors (`cap_preds`), so
  `PunctuationRuntime` calls the ORT C API directly.
- Model files are pinned to revision `b26fd1c4` and SHA-256 verified, downloaded
  once (about 210 MB) into Application Support at launch while the setting is on.
  English locale only, skipped for Verbatim. Until installed, dictation keeps
  rules-only punctuation.
- A mid-sentence model capital is ignored on common function words (it
  capitalized "the" after "she said"). Recognizer "?" and "!" are kept.
- HUD: `NSHostingView.sizingOptions = []` and a fixed waveform height, so the
  notch HUD no longer resizes (and bobs) with every syllable.
- Verification: Swift output matched the Python `punctuators` reference exactly
  on the same input; tokenizer ids match SentencePiece (test). `--punctuate` over
  50 real history entries: 0 failures, median 10 ms, max 130 ms. XCTest: 375
  tests, 0 failures. `--selftest` exit 0. `make_app.sh` built and relaunched;
  no errors in the `local.murmur` log. HUD not yet confirmed by eye.
- Next: owner dictates a few run-on messages and confirms the HUD stays still.

### 2026-09-28 — Claude app launch fix

- File: `scripts/make_app.sh`.
- Every local build since the Sparkle commit (`f82662d`) crashed at launch:
  "Library not loaded: @rpath/Sparkle.framework". Two causes. SwiftPM only
  sets `@loader_path`, so the script now adds `@executable_path/../Frameworks`.
  The local signing identity has no Team ID, so hardened-runtime library
  validation rejected Sparkle. Local identities now sign with
  `disable-library-validation`. Developer ID builds do not.
- Verification: `./scripts/make_app.sh` built, signed with "WhisperFlow Dev",
  `codesign --verify --deep --strict` OK, and the app stayed running.
- Next: before any tester release, confirm a Developer ID build launches.
  That path still has not been run on this Mac.

### 2026-09-28 — Claude grammar punctuation pass

- Files: `Sources/Murmur/RewriteEngine.swift`, `AppDelegate.swift`,
  `MainView.swift`, `CleanupLevel.swift`, `TextFormatter.swift`,
  `Tests/MurmurTests/GrammarPunctuationTests.swift` (new),
  `PauseFragmentTests.swift`.
- Why: the owner talks in run-on thoughts and pauses to think. Apple's
  recognizer puts a period at every pause. He wants punctuation by grammar,
  not by pauses. Rules can't place commas, so Cleaned now gets one model pass
  that may only move punctuation and capitals.
- How: strip pause periods/commas (keep "?", numbers, "p.m."), few-shot
  prompt, greedy sampling. `acceptedPunctuation` rejects any word added,
  dropped, reordered or changed, lost line breaks, em dashes, semicolons,
  altered numbers or deliberate casing, or output with no sentence marks.
  `mergedPunctuation` then undoes two model habits: "?" on statements, and
  lowercased mid-sentence names.
- Setting: "Punctuate by grammar", `grammarPunctuation`, default ON. Skips
  dictations under 12 words.
- Measured live on this Mac: about 0.9–1.2 s for a normal message, 2.4 s for
  a ~60-word ramble. The "caveman mode" injection case came back punctuated
  only.
- Also: joining "p.m. On Tuesday" no longer drops the final period.
- Verification: 371 tests, 0 failures. `Murmur --selftest` 10/10.
- Next: owner tries it for a day. If the delay bugs him, the toggle is in
  Settings. Do not loosen `acceptedPunctuation`; it is what keeps the
  no-commands rule true.

### 2026-09-28 — Claude pause-join and capitalization fixes

- Files: `Sources/Murmur/TextFormatter.swift`,
  `Tests/MurmurTests/PauseFragmentTests.swift`.
- First full suite run after the Sep 11–22 work: 353/354 passed. The failure
  (`testChainedPauseFragmentsStayInOneThought`) predates Sparkle: "us" was on
  the abbreviation list, so "save us. An unmeasurable…" never joined. Everyday
  words on that list (us, no, am, …) now count only when capitalized.
- Stopped wrong joins: "Sounds good. Talk soon." and "Great job today.
  Seriously." were merged. Two-word fragments now join only after a
  determiner ("The manager."), lone "-ly" words stay, more common verbs and
  interjections are recognized.
- Added safe joins: whenever/wherever/whereas clauses, trailing time phrases
  ("Two weeks ago.", "Later today.", "Sometime next week."), and any period
  after the/my/your/our/their/its.
- Fixed "3 p.m. tomorrow" becoming "3 p.M. Tomorrow".
- Verification: `swift build --build-tests` then
  `xcrun xctest .build/debug/MurmurTests.xctest` — 360 tests, 0 failures.
  `Murmur --selftest` 10/10 PASS. Note the bundle is `MurmurTests.xctest`,
  not `MurmurPackageTests.xctest`.
- Next: when adding a pause rule, add a must-survive case next to it. Missed
  joins are harmless, wrong joins change what the user said.

### 2026-09-28 — Codex privacy-copy correction (`d025464`)

- Files: `README.md`, `Sources/Murmur/MainView.swift`,
  `scripts/make_app.sh`.
- Replaced absolute “100% on-device/no data leaves” wording with the accurate
  distinction: dictation remains local, while update and optional model
  downloads use the network. No runtime behavior changed.
- Verification: Xcode `swiftc -frontend -parse` on `MainView.swift` passed;
  `git diff --check` passed. No full build or tests run. Pushed to `origin/main`.
- Next: preserve automatic updates; complete a signed/notarized tester release
  only after signing prerequisites are configured.

### 2026-09-22 — Codex Sparkle updater (`f82662d`)

- Files: `Package.swift`, `Package.resolved`, `README.md`,
  `Sources/Murmur/AppDelegate.swift`, `Sources/Murmur/TextFormatter.swift`,
  `Tests/MurmurTests/PauseFragmentTests.swift`, `scripts/make_app.sh`,
  `scripts/make_release.sh`, `appcast.xml`.
- Added Sparkle updater/menu integration and a release/appcast workflow; added
  a regression repair for the false period in “the way. This conversation…”.
- Formatter type-check and standalone harness passed; Sparkle framework and
  metadata were packaged. Full suite was not run. Release is still blocked on
  Developer ID, notarization, and private-key Keychain authorization.
- Pushed to `origin/main`.

### 2026-09-28 — Codex

- Created this shared handoff and the small Codex/Claude repository instructions.
- `AGENTS.md` and `CLAUDE.md` point both agents to this same file and require
  append-only handoff notes after work.
- Shared handoff files were introduced in `161d034`; this log update records
  that commit before the first push to `origin/main`.
- Next: have either agent resume from this file, append verified work, and hand
  back the latest commit SHA.

### 2026-09-28 — Claude review (reported by user)

- Flagged an overbroad “100% on-device” headline, FN modifier side effects, and
  spoken-symbol ambiguity. Privacy copy was clarified in `d025464`.
- Confirmed code review through GitHub; Claude reported that its local Xcode
  license gate prevented a build/test run. This is not evidence of a passing or
  failing test suite.
