# Where the wait comes from

Everything between releasing the key and seeing text is serial. This is the
measured budget, taken on the owner's own machine (Apple Silicon, macOS 26,
Apple engine, `cleanupLevel` 2), so the numbers below are the reason the
defaults are what they are. Re-measure before changing any of them.

## Measured stages

| Stage | Cost | Notes |
|---|---|---|
| Vocabulary read (4 JSON files) | ~5 ms | `LearnedStore.biasTerms()` |
| Transcription of a finished file | 230 ms | 11 s of speech, `SpeechAnalyzer` |
| Rules pipeline (all regex passes) | under 5 ms | `TextFormatter`, learned, snippets |
| Model polish pass | 520 ms at 10 words, 1260 ms at 39, 2020 ms at 110, 2760 ms at 340 | `RewriteEngine.rewrite` |
| Insertion | ~10 ms | AX path; clipboard restore is async and off the path |

The model pass is the whole story. Its cost tracks **output** length, because
generation is token by token, so it grows with how much the user said.

## What the defaults do about it

**`streamingTranscription` defaults on.** Recognition runs while the user
speaks instead of after release, and the vocabulary read moves to key-down.
Removes the 230 ms and the 5 ms from the post-release path. The temporary
`.caf` is still written, so a streaming failure falls back to the file and
costs only the time it saved. This is the one default here that has never
been verified against live hardware: revert with
`defaults write local.murmur streamingTranscription -bool false`.

**The polish prompt is kept short.** Prompt, transcript and output share one
context window, and generation time tracks the total. Trimming the prose
version of the voice rules from 2976 to 2569 characters took a 39-word
dictation from 1584 ms to 1263 ms. It made no difference at 110 words, where
output generation dominates. Anything the code already enforces
deterministically was cut rather than stated twice: `bannedPhrases` and
`introducedBannedPhrasing` cover the corporate-register list and the em dash
and semicolon bans.

**`RewriteEngine.needsPolish` skips the pass when it has nothing to do.** The
prompt already tells the model to "never rewrite a sentence that was already
fine"; this decides the same thing in code, before paying for the round trip.
On the owner's last 50 real dictations it skips 30% of them, all between 1 and
24 words. Those insert with no model pass at all.

The gate is conservative by construction. It skips only on positive evidence:
at or under 25 words, no sentence over 25 words, no paragraph break, no
assembly markers (self-corrections, restarts, scaffolding), no residual
filler, no adjacent duplicate word. Everything else gets the model exactly as
before. A wrong skip costs a little polish; a wrong run costs only time, so
the bias runs toward running.

Only the automatic cleanup pass is gated. A My Voice preset or an app Style is
an explicit choice by the user and always applies, however short the text.

## What was tried and rejected

**Reusing one `LanguageModelSession` across dictations.** Measured *worse*:
3607 to 3869 ms against 1161 ms for a fresh session. A session keeps its
transcript, so every dictation prefills the whole conversation so far. Build a
fresh session per rewrite.

**`prewarm()` at key-down.** No measurable improvement, and noisier than
doing nothing.

**Inserting rules-only text immediately and replacing it when the model
returns.** This would hide the entire model pass. Rejected: it breaks the
app's hardest rule, that a dictation never erases or rewrites text already
placed in another app.

## Re-measuring

```
Murmur --transcribe <file>          # transcription stage
Murmur --needs-polish "<text>"      # would this pay for a model pass?
Murmur --selftest                   # formatter rules
```
