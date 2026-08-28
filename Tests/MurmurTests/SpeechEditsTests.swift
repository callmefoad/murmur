import XCTest
@testable import Murmur

final class SpeechEditsTests: XCTestCase {

    private func plan(
        _ transcript: String, previous: String? = nil
    ) -> SpeechEditPlan {
        SpeechEdits.plan(currentTranscript: transcript, previousText: previous)
    }

    // MARK: - Trigger phrase alone → discardAll

    func testEachDiscardPhraseAloneDiscardsAll() {
        for phrase in SpeechEdits.discardPhrases {
            XCTAssertEqual(
                plan(phrase), .init(outcome: .discardAll), "failed for \(phrase)")
        }
    }

    func testDiscardPhrasesWithTrailingPunctuationStillDiscard() {
        for utterance in [
            "Scratch that.", "NEVER MIND!", "cancel that?", "Never mind…",
            "SCRATCH IT.", "scratch this,", "Cancel that;",
        ] {
            XCTAssertEqual(
                plan(utterance), .init(outcome: .discardAll),
                "failed for \(utterance)")
        }
    }

    func testSurroundingWhitespaceDoesNotBlockDetection() {
        XCTAssertEqual(plan("  scratch that  "), .init(outcome: .discardAll))
    }

    func testRepeatedCommandCollapsesToSingleWithdrawal() {
        XCTAssertEqual(plan("scratch that scratch that"), .init(outcome: .discardAll))
        XCTAssertEqual(plan("um never mind, cancel that."), .init(outcome: .discardAll))
    }

    func testNilPreviousAndScratchAloneIsDiscardAllNothingToUndoVariant() {
        // AppDelegate reads the same discardAll as "undo if something is
        // pending, otherwise skip silently" — the plan itself is identical.
        let result = plan("never mind", previous: nil)
        XCTAssertEqual(result, .init(outcome: .discardAll))
        XCTAssertNil(result.combinedReplacement)
    }

    // MARK: - Trailing command after real content → replaceCurrent

    func testTrailingScratchKeepsPrecedingText() {
        XCTAssertEqual(
            plan("that looks great scratch that"),
            .init(outcome: .replaceCurrent(cleanedRemainder: "that looks great")))
    }

    func testTrailingCommandCaseInsensitiveKeepsInteriorPunctuation() {
        XCTAssertEqual(
            plan("First draft. Sounds good SCRATCH THAT."),
            .init(outcome: .replaceCurrent(cleanedRemainder: "First draft. Sounds good")))
    }

    func testTrailingNeverMindAfterCommaClause() {
        XCTAssertEqual(
            plan("Draft one, never mind"),
            .init(outcome: .replaceCurrent(cleanedRemainder: "Draft one,")))
    }

    // MARK: - Mid-sentence and embedded occurrences → none

    func testMidSentencePhrasesAreIgnored() {
        for utterance in [
            "he said never mind yesterday",
            "let us scratch that idea tomorrow",
            "I will cancel that meeting",
            "you can scratch it yourself later",
        ] {
            XCTAssertEqual(
                plan(utterance), .init(outcome: .none), "failed for \(utterance)")
        }
    }

    func testWordsMerelyContainingPhraseAreIgnored() {
        XCTAssertEqual(plan("scratched that"), .init(outcome: .none))
        XCTAssertEqual(plan("he never minded the wait"), .init(outcome: .none))
        XCTAssertEqual(plan("scratchpad"), .init(outcome: .none))
    }

    // MARK: - Guard rails

    func testSingleWordBeforePhraseStandsDownRatherThanNuking() {
        // "Don't scratch that." is likelier dialogue than a retraction.
        XCTAssertEqual(plan("Don't scratch that."), .init(outcome: .none))
        XCTAssertEqual(plan("Stop canceling that"), .init(outcome: .none))
    }

    func testPunctuationOnlyUtteranceIsIgnored() {
        XCTAssertEqual(plan("..."), .init(outcome: .none))
        XCTAssertEqual(plan("   "), .init(outcome: .none))
        XCTAssertEqual(plan(""), .init(outcome: .none))
    }

    func testLongDictationEndingInCommandKeepsEverythingBeforeIt() {
        let essay = String(repeating: "Word after word. ", count: 50)
        XCTAssertEqual(
            plan(essay + "scratch that"),
            .init(outcome: .replaceCurrent(cleanedRemainder: essay.trimmingCharacters(
                in: .whitespaces))))
    }

    // MARK: - Delete last sentence

    func testBareCommandShrinksMultiSentencePreviousInsertion() {
        XCTAssertEqual(
            plan("delete last sentence", previous: "First one. Second one."),
            .init(outcome: .none, combinedReplacement: "First one."))
    }

    func testQuestionEndingDropsOnlyQuestionSentence() {
        XCTAssertEqual(
            plan("delete last sentence", previous: "Is this on? Yes it is."),
            .init(outcome: .none, combinedReplacement: "Is this on?"))
    }

    func testExclamationEndingDropsOnlyExclaimSentence() {
        XCTAssertEqual(
            plan("Delete last sentence.", previous: "Wow! Really!"),
            .init(outcome: .none, combinedReplacement: "Wow!"))
    }

    func testCommandAfterNewContentDropsThatContent() {
        XCTAssertEqual(
            plan("Gamma delta delete last sentence", previous: "Alpha beta."),
            .init(outcome: .none, combinedReplacement: "Alpha beta."))
    }

    func testEllipsisCountsAsTerminator() {
        XCTAssertEqual(
            plan("delete last sentence", previous: "So… done"),
            .init(outcome: .none, combinedReplacement: "So…"))
    }

    func testUnterminatedFinalSentenceIsStillDropped() {
        XCTAssertEqual(
            plan("delete last sentence", previous: "Keep this. drop this"),
            .init(outcome: .none, combinedReplacement: "Keep this."))
    }

    func testSingleSentenceCombinedBufferDiscardsEntireInsertion() {
        XCTAssertEqual(
            plan("delete last sentence", previous: "hello world"),
            .init(outcome: .discardAll))
    }

    func testBareCommandWithNoPreviousDiscardsQuietly() {
        XCTAssertEqual(
            plan("delete last sentence", previous: nil),
            .init(outcome: .discardAll))
        XCTAssertEqual(
            plan("delete last sentence", previous: "  "),
            .init(outcome: .discardAll))
    }

    func testMidUtteranceDeleteCommandIsIgnored() {
        XCTAssertEqual(
            plan("please delete last sentence now"),
            .init(outcome: .none))
    }

    // MARK: - Plan shape

    func testReplaceCurrentCarriesNoCombinedReplacement() {
        let result = plan("looks good scratch that")
        XCTAssertEqual(result.combinedReplacement, nil)
    }

    func testPlainDictationYieldsNoneWithNoReplacement() {
        let result = plan("The quick brown fox jumps.")
        XCTAssertEqual(result, .init(outcome: .none))
        XCTAssertNil(result.combinedReplacement)
    }
}
