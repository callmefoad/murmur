# Murmur — shared AI handoff

This is the shared, public-safe handoff for Codex and Claude. It records project
decisions, verified work, and the next useful step so either agent can resume
without relying on chat history. Never put credentials, signing keys, private
transcripts, or other secrets in this file; the GitHub repository is public.

## Current state

- Repository: `callmefoad/murmur`; default branch: `main`.
- Last verified sync: 2026-09-28, commit `d025464` (`origin/main`); working tree
  was clean at handoff-file creation.
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
- This handoff setup has not yet been committed or pushed.
- Next: review this file, then commit and push the handoff setup so both agents
  can read and append to it.

### 2026-09-28 — Claude review (reported by user)

- Flagged an overbroad “100% on-device” headline, FN modifier side effects, and
  spoken-symbol ambiguity. Privacy copy was clarified in `d025464`.
- Confirmed code review through GitHub; Claude reported that its local Xcode
  license gate prevented a build/test run. This is not evidence of a passing or
  failing test suite.
