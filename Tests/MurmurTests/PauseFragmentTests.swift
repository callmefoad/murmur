import XCTest
@testable import Murmur

/// Apple's transcriber punctuates from prosody, so a breath mid-sentence
/// comes back as a sentence break. These cover the repair pass and, just as
/// importantly, the sentences it must leave alone.
final class PauseFragmentTests: XCTestCase {

    private func formatted(_ input: String, joinFragments: Bool = true) -> String {
        TextFormatter(dictionary: [:]).format(
            input, autoPeriod: true, spokenLayout: true, spokenSymbols: false,
            joinFragments: joinFragments)
    }

    // MARK: - The reported case

    /// The shape of the dictation that prompted this pass, with neutral
    /// content: a bare noun and a prepositional phrase each stranded behind
    /// a pause period, plus a coordinator opening the last sentence. All
    /// three joins fire here exactly as they did on the original, which was
    /// personal enough not to keep in a repository.
    func testReportedDictationReadsAsThreeSentences() {
        XCTAssertEqual(
            formatted(
                "We tested the new unit. Now it's the primary blender. "
                + "Motor. For the whole kitchen. It's not exactly what we "
                + "specified, but it's 40% quieter. And we're keeping the "
                + "old one on the shelf."),
            "We tested the new unit. Now it's the primary blender motor for "
            + "the whole kitchen. It's not exactly what we specified, but "
            + "it's 40% quieter and we're keeping the old one on the shelf.")
    }

    /// A rising intonation can make SpeechAnalyzer emit a question mark at a
    /// breath before the final prepositional tail. Keep the question intact.
    func testQuestionPauseBeforeTailStaysOneQuestion() {
        XCTAssertEqual(
            formatted(
                "You're awesome. That works, and I think they're taking a look "
                + "at it right now. What else do we need to fix? On the website?"),
            "You're awesome. That works, and I think they're taking a look at "
                + "it right now. What else do we need to fix on the website?")
    }

    /// Subordinate clauses belong to the thought before them even when the
    /// speaker takes a breath after the main clause.
    func testSubordinateClauseAfterPauseStaysConnected() {
        XCTAssertEqual(
            formatted("I would appreciate it. If I make a pause, keep listening."),
            "I would appreciate it if I make a pause, keep listening.")
    }

    /// A real dictation can accumulate several prosodic breaks in one
    /// sentence. The repair must keep following the chain instead of fixing
    /// only the first one: "and. Really. Work…", then a long prepositional
    /// tail, then a trailing time phrase and subordinate clause.
    func testChainedPauseFragmentsStayInOneThought() {
        XCTAssertEqual(
            formatted(
                "I also hope that you're saving every single part of this. "
                + "I'm glad that you and I are taking the time to go through, and. "
                + "Really. Work on this entire thing. I know that it takes hours and hours. "
                + "For the templates to be built, but it will save us. "
                + "An unmeasurable amount of time later. If we can handle all the hard work now."),
            "I also hope that you're saving every single part of this. "
                + "I'm glad that you and I are taking the time to go through, and really "
                + "work on this entire thing. I know that it takes hours and hours for "
                + "the templates to be built, but it will save us an unmeasurable amount "
                + "of time later if we can handle all the hard work now.")
    }

    func testSettingOffLeavesTheBreaksAlone() {
        let input = "Now it's the primary blender. Motor."
        XCTAssertEqual(formatted(input, joinFragments: false), input)
    }

    // MARK: - Joins

    func testBareNounJoins() {
        XCTAssertEqual(
            formatted("I run the whole desk. Operations."),
            "I run the whole desk operations.")
    }

    func testStrandedPrepositionalPhraseJoins() {
        XCTAssertEqual(
            formatted("I sent the invoice. To the wrong address."),
            "I sent the invoice to the wrong address.")
    }

    func testCoordinatorJoinsEvenWithItsOwnVerb() {
        XCTAssertEqual(
            formatted("It pays well. And I keep the side work."),
            "It pays well and I keep the side work.")
    }

    func testJoinKeepsCapitalI() {
        XCTAssertEqual(
            formatted("The offer landed. And I took it."),
            "The offer landed and I took it.")
    }

    func testJoinPreservesDeliberateCasing() {
        XCTAssertEqual(
            formatted("I finally replaced it. With an iPhone."),
            "I finally replaced it with an iPhone.")
    }

    // MARK: - Must not join

    /// A verbless noun phrase long enough to read as a deliberate sentence.
    func testDeliberateNounPhraseSentenceSurvives() {
        let input = "I love my new phone. Best purchase this year."
        XCTAssertEqual(formatted(input), input)
    }

    /// Preposition-initial but a real clause: it has a subject and a verb.
    func testPrepositionInitialSentenceSurvives() {
        let input = "The total was flat. On Monday we review it again."
        XCTAssertEqual(formatted(input), input)
    }

    func testStandaloneReplySurvives() {
        let input = "Did the transfer land. No. I never saw it."
        XCTAssertEqual(formatted(input), input)
    }

    func testAbbreviationIsNotASentenceEnd() {
        let input = "I talked to Dr. Smith today."
        XCTAssertEqual(formatted(input), input)
    }

    /// An ellipsis is deliberate, so nothing joins across it. Asserted on
    /// the decision function rather than through `format`, which collapses
    /// runs of punctuation for unrelated reasons.
    func testEllipsisIsNotASentenceEnd() {
        XCTAssertFalse(
            TextFormatter.shouldJoin(
                previous: "I was going to say...", next: "Never mind."))
    }

    /// A period the user dictated is deliberate and must survive, which is
    /// why the pass runs before anything that inserts punctuation.
    func testDictatedPeriodIsNeverUndone() {
        let formatter = TextFormatter(dictionary: ["period": "."])
        XCTAssertEqual(
            formatter.format(
                "one period two period", autoPeriod: true, spokenLayout: true,
                spokenSymbols: false, joinFragments: true),
            "One. Two.")
    }

    /// A spoken "new line" is a deliberate boundary, so nothing joins
    /// across it even when the next line is a bare fragment.
    func testJoinNeverCrossesALineBreak() {
        XCTAssertEqual(
            formatted("primary blender new line motor"),
            "Primary blender\nMotor.")
    }

    /// Only breaks the recognizer itself punctuated are candidates, and it
    /// always capitalizes the word after a period it inserts. A lowercase
    /// opener therefore came from somewhere else and is left alone.
    func testLowercaseOpenerIsLeftAlone() {
        XCTAssertFalse(
            TextFormatter.shouldJoin(previous: "the desk.", next: "operations."))
    }

    // MARK: - Pure decision logic

    func testQuestionWithStandaloneFollowupStaysSeparate() {
        XCTAssertFalse(
            TextFormatter.shouldJoin(previous: "Who runs it?", next: "Manager."))
    }

    func testJoinedDropsThePeriodAndLowercases() {
        XCTAssertEqual(
            TextFormatter.joined(previous: "the desk.", next: "Operations."),
            "the desk operations.")
    }

    /// Reassembly is byte-for-byte when nothing joins, including the
    /// original spacing between sentences.
    func testUnjoinedLineIsReassembledExactly() {
        let line = "He signed it.  She approved it. They filed it."
        XCTAssertEqual(TextFormatter.joinFragments(inLine: line), line)
    }
}
