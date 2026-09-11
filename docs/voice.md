# Voice: what Murmur enforces, and how

The full written guide is `~/.claude/taylor-voice.md` — several thousand
words, owner-authored, canonical. It is not duplicated here, because two
copies of a spec drift. This file records how much of it Murmur actually
guarantees, which is the only question that matters when reading the code.

The guide splits into three kinds of rule, and each lands somewhere
different.

## 1. Rules the prompt asks for

`RewriteEngine.voiceCore` is the compressed operative half of the guide, and
it is what levels 2 and 3 send to the on-device model.

It is compressed on purpose. Apple's on-device model shares one small context
window across instructions, transcript and output, so a four-thousand-word
prompt would both overflow the budget and bury the rules that matter inside
the ones that don't. What is enumerable lives in the prompt; what is
judgement stays in the guide.

A prompt is a request. Everything in this category is best-effort.

## 2. Rules the code guarantees

Four defences, none of which is a prompt:

| Defence | What it stops |
|---|---|
| Delimited transcript + lookalike neutralization | The transcript being read as a conversational turn. This is the caveman fix. |
| `isPlausibleRewrite` | Output that diverges from the input in length, content-word recall, or precision. |
| `introducedBannedPhrasing` | Output reaching for vocabulary or punctuation the speaker did not use. |
| Silent degradation | Any rejection falling back to the rules-only text, with no notification and no retry. |

`introducedBannedPhrasing` is the direct mechanical expression of the guide's
vocabulary bans. It only fires on phrasing the rewrite **introduced** — if he
said "utilize" himself, that is his word and it stays. Em dashes and
semicolons are treated the same way.

The list is deliberately enforced rather than requested, because "never write
utilize" is a rule, and a prompt cannot hold a rule.

## 3. Rules that are already rules-only

These never touch the model, so they cannot be subverted by anything in the
transcript:

- Filler removal, capitalization, punctuation tidying — `TextFormatter`.
- Pause-fragment rejoining — `TextFormatter.joinPauseFragments`, which
  repairs periods the recognizer invented at a breath.
- Personal dictionary, snippets, learned corrections — `PhraseReplacer`.

## What is deliberately NOT enforced

- **Tone judgement.** Whether a rewrite "sounds like him" cannot be checked
  mechanically. That is what the prompt and the guide are for.
- **Spoken commands.** `spokenEdits` stays off. The guide describes cleaning
  up what he said, not obeying it, and Murmur cannot tell a retraction from
  someone merely saying the words.

## The default, and the trade behind it

`Settings.cleanupLevel` defaults to **2 (Polished)**, which runs the model.

It defaulted to 1 (Cleaned, model-free) until the owner supplied the guide
and asked for the rewrite explicitly. That is a deliberate trade. The model
pass is the only way to compress a rambling dictation, and it is also the
path that once turned a dictation mentioning "caveman mode" into caveman
speech. The four defences above are what stand between those two facts.

To take the model out of the path entirely:

    defaults write local.murmur cleanupLevel -int 1
