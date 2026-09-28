# Murmur — shared AI handoff

This is the shared, public-safe handoff for Codex and Claude. It records project
decisions, verified work, and the next useful step so either agent can resume
without relying on chat history. Never put credentials, signing keys, private
transcripts, or other secrets in this file; the GitHub repository is public.

## Current state

- Repository: `callmefoad/murmur`; default branch: `main`.
- Last verified sync: 2026-09-28. Full build and XCTest suite run: 360 tests,
  0 failures (see the Claude pause-join entry).
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
