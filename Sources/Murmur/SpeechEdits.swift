import Foundation

/// Pure decision logic for spoken edit commands embedded in — or standing
/// alone as — a finished dictation ("scratch that", "delete last sentence").
/// No AppKit, no Accessibility, no stored state: everything is a function of
/// the current transcript and the previous insertion's text, so every ruling
/// is unit-testable headlessly. `AppDelegate` merely applies the returned
/// plan.
enum SpeechEdits {

    // MARK: - Plan

    /// What should happen to one finished dictation.
    struct Plan: Equatable {
        enum Outcome: Equatable {
            /// The utterance was nothing but an edit command: insert nothing,
            /// and take the previous insertion back out (any age within the
            /// session; no-op when there is nothing to undo).
            case discardAll
            /// The utterance trailed an edit command: insert only the text
            /// that came before it.
            case replaceCurrent(cleanedRemainder: String)
            /// Ordinary dictation — no edit phrase detected.
            case none
        }

        var outcome: Outcome

        /// When set, the previous insertion is undone first and this text is
        /// typed in its place ("delete last sentence" shrinking the combined
        /// buffer). Takes precedence over `outcome`.
        var combinedReplacement: String?
    }

    /// Settings-gated entry point. `enabled` is the user's "Spoken edits"
    /// toggle (off by default): when it is false no phrase matching runs
    /// at all and the dictation is inserted exactly as transcribed. Kept
    /// here, beside the logic it guards, so the gating decision is as
    /// testable as the rulings themselves — `plan` below stays pure and
    /// unaware of Settings.
    static func gatedPlan(
        currentTranscript: String, previousText: String?, enabled: Bool
    ) -> Plan {
        guard enabled else { return Plan(outcome: .none) }
        return plan(currentTranscript: currentTranscript, previousText: previousText)
    }

    /// Decides what to do with a finished dictation. `currentTranscript`
    /// should already be formatted/snippet-expanded; `previousText` is the
    /// text of the last insertion, or nil when there is none.
    static func plan(currentTranscript: String, previousText: String?) -> Plan {
        let trimmed = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // An utterance with no words in it cannot be an edit command.
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
            return Plan(outcome: .none)
        }

        // "Delete last sentence" must end the utterance and rewrites the
        // combined buffer rather than the utterance alone.
        if let range = trailingRange(of: deleteLastSentencePhrase, in: trimmed) {
            return deleteLastSentencePlan(
                beforeSpoken: trimmed[..<range.lowerBound], previousText: previousText)
        }

        // Strip every trailing scratch-style command ("um scratch that
        // scratch that" collapses to a single withdrawal).
        var remainder = trimmed
        var strippedAny = false
        while let range = discardPhrases.lazy.compactMap({
            trailingRange(of: $0, in: remainder)
        }).first {
            remainder = String(remainder[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            strippedAny = true
        }
        guard strippedAny else { return Plan(outcome: .none) }

        // Nothing usable before the command: the whole utterance was the
        // command, so withdraw the previous insertion and insert nothing.
        guard remainder.contains(where: { $0.isLetter || $0.isNumber }) else {
            return Plan(outcome: .discardAll)
        }
        // Two-plus usable words ahead of the phrase are unmistakably a
        // retraction ("that looks great scratch that").
        if remainder.split(whereSeparator: \.isWhitespace).count >= 2 {
            return Plan(outcome: .replaceCurrent(cleanedRemainder: remainder))
        }
        // A lone filler before the command ("um scratch that") still means
        // the whole utterance was the command.
        if isFillerPrefix(remainder) {
            return Plan(outcome: .discardAll)
        }
        // Any other single word is far likelier real speech than a command
        // prefix ("Don't scratch that.") — stand down rather than nuke a
        // legitimate dictation.
        return Plan(outcome: .none)
    }

    // MARK: - Phrase tables

    /// Commands whose meaning is "take the last insertion back out". Matched
    /// only standing alone or closing the utterance.
    static let discardPhrases = [
        "scratch that", "scratch this", "scratch it", "never mind", "cancel that",
    ]
    /// Command that drops the final sentence of the combined buffer. Only
    /// recognized as the utterance's final words.
    static let deleteLastSentencePhrase = "delete last sentence"
    /// Characters allowed between a command phrase and the end of the
    /// utterance — punctuation and whitespace only.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", "\"", "'", ")", "]", "}", "”", "’",
    ]
    /// Characters that end a sentence for "delete last sentence" arithmetic.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    /// Lone words that mark what precedes a command as throat-clearing
    /// rather than dialogue, letting the one-word stand-down below pass.
    private static let fillerPrefixes: Set<String> = [
        "um", "uh", "er", "ah", "well", "so", "ok", "okay", "sorry", "oops",
    ]

    // MARK: - Matching

    /// Locates `phrase` when it closes the utterance: preceded by the start
    /// of the string or whitespace, and followed by nothing but punctuation
    /// and whitespace. Every occurrence is examined from the end backwards,
    /// so an earlier mid-sentence occurrence ("um never mind, cancel that")
    /// never masks a later closing one. Words merely containing the phrase
    /// ("scratched") never match.
    static func trailingRange(of phrase: String, in utterance: String) -> Range<String.Index>? {
        var searchUpper = utterance.endIndex
        while searchUpper > utterance.startIndex,
              let range = utterance.range(
                of: phrase, options: [.caseInsensitive, .backwards],
                range: utterance.startIndex..<searchUpper)
        {
            let precededByBoundary =
                range.lowerBound == utterance.startIndex
                || utterance[utterance.index(before: range.lowerBound)].isWhitespace
            let tailIsPunctuationOnly = utterance[range.upperBound...].allSatisfy {
                $0.isWhitespace || trailingPunctuation.contains($0)
            }
            if precededByBoundary && tailIsPunctuationOnly { return range }
            searchUpper = range.lowerBound
        }
        return nil
    }

    /// True when `remainder` is exactly one filler word ("um", "well", …),
    /// optionally still carrying its trailing punctuation.
    private static func isFillerPrefix(_ remainder: String) -> Bool {
        guard remainder.split(whereSeparator: \.isWhitespace).count == 1 else {
            return false
        }
        let word = remainder.filter { !trailingPunctuation.contains($0) }
        return fillerPrefixes.contains(word.lowercased())
    }

    // MARK: - Delete-last-sentence arithmetic

    private static func deleteLastSentencePlan(
        beforeSpoken spoken: Substring, previousText: String?
    ) -> Plan {
        let remainder = String(spoken).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [previousText?.trimmingCharacters(in: .whitespacesAndNewlines), remainder]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // Command with nothing on screen to shrink: a quiet no-op.
        guard !parts.isEmpty else { return Plan(outcome: .discardAll) }
        let combined = parts.joined(separator: " ")
        guard let head = droppingLastSentence(from: combined) else {
            // The whole combined buffer is a single sentence: deleting it
            // empties the insertion, which is a plain withdrawal.
            return Plan(outcome: .discardAll)
        }
        return Plan(outcome: .none, combinedReplacement: head)
    }

    /// Returns `text` without its final sentence, or nil when `text` is a
    /// single (possibly unterminated) sentence. Sentences end at `.`, `!`,
    /// `?` or `…`; trailing quotes and brackets stay attached to the
    /// sentence they close.
    static func droppingLastSentence(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let lastTerminator = trimmed.lastIndex(where: {
            sentenceTerminators.contains($0)
        }) else { return nil }

        // Does real content follow that terminator? Then the final sentence
        // runs unterminated to the end of the text ("Alpha beta. Gamma").
        var scan = trimmed.index(after: lastTerminator)
        while scan < trimmed.endIndex,
              trimmed[scan].isWhitespace || trailingPunctuation.contains(trimmed[scan]) {
            scan = trimmed.index(after: scan)
        }
        if scan < trimmed.endIndex {
            let head = String(trimmed[...lastTerminator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return head.isEmpty ? nil : head
        }

        // The terminator itself closes the final sentence; it starts after
        // the previous one, or at the beginning of the text.
        let contentStart: String.Index
        if let priorEnd = trimmed[..<lastTerminator]
            .lastIndex(where: { sentenceTerminators.contains($0) }) {
            var index = trimmed.index(after: priorEnd)
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            contentStart = index
        } else {
            contentStart = trimmed.startIndex
        }
        let head = String(trimmed[..<contentStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }
}

/// Spoken-edit decision produced for one finished dictation.
typealias SpeechEditPlan = SpeechEdits.Plan
