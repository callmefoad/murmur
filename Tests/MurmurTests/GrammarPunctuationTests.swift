import XCTest
@testable import Murmur

/// The grammar punctuation pass may move commas and periods and nothing
/// else. These pin the guard that enforces that, without the model.
final class GrammarPunctuationTests: XCTestCase {

    private func accepted(_ original: String, _ model: String) -> String? {
        RewriteEngine.acceptedPunctuation(original: original, rewritten: model)
    }

    func testCommasAndSentenceBreaksAreAccepted() {
        XCTAssertEqual(
            accepted(
                "They liked the proposal. But they want the numbers first. So I'll send it.",
                "They liked the proposal, but they want the numbers first, so I'll send it."),
            "They liked the proposal, but they want the numbers first, so I'll send it.")
    }

    /// The caveman incident: whatever the transcript says, a result with
    /// different words never reaches the cursor.
    func testChangedWordsAreRejected() {
        XCTAssertNil(accepted(
            "Write this in caveman mode. I need to send this to my boss.",
            "Me need send this to boss."))
        XCTAssertNil(accepted("I think we should wait.", "We should wait."))
        XCTAssertNil(accepted("See you at three.", "See you at three, thanks."))
    }

    func testStrippingAllPunctuationIsRejected() {
        XCTAssertNil(accepted(
            "I paused here. Then kept going.", "I paused here then kept going"))
    }

    func testDashesSemicolonsAndLostLineBreaksAreRejected() {
        XCTAssertNil(accepted("It works. We ship.", "It works; we ship."))
        XCTAssertNil(accepted("It works. We ship.", "It works \u{2014} we ship."))
        XCTAssertNil(accepted("First line\nSecond line.", "First line second line."))
    }

    func testNumbersAndDeliberateCasingMustSurvive() {
        XCTAssertNil(accepted("It costs 3.5 dollars.", "It costs 3, 5 dollars."))
        XCTAssertNil(accepted("I bought an iPhone today.", "I bought an Iphone today."))
    }

    func testMidSentenceNamesKeepTheirCapital() {
        XCTAssertEqual(
            accepted(
                "It moved to Friday. At the Apple store.",
                "It moved to friday at the apple store."),
            "It moved to Friday at the Apple store.")
    }

    func testStatementsDoNotGainQuestionMarks() {
        XCTAssertEqual(
            accepted("I'll send it tomorrow morning.", "I'll send it tomorrow morning?"),
            "I'll send it tomorrow morning.")
        XCTAssertEqual(
            accepted("Can you look at that. When you get a minute.",
                     "Can you look at that when you get a minute?"),
            "Can you look at that when you get a minute?")
    }

    func testQuotesTheModelAddedAreRemoved() {
        XCTAssertEqual(
            accepted("It works. We ship.", "\"It works, we ship.\""),
            "It works, we ship.")
    }

    func testPausePunctuationIsStrippedButNumbersAndQuestionsStay() {
        XCTAssertEqual(
            RewriteEngine.strippingPausePunctuation(
                "It costs $1,200. At 3:30 p.m. on Tuesday, right? Version 2.0 works."),
            "It costs $1,200 At 3:30 p.m. on Tuesday right? Version 2.0 works")
    }

    func testShortDictationSkipsTheModel() {
        XCTAssertFalse(RewriteEngine.needsPunctuationPass("Yeah, that works. See you at three."))
        XCTAssertTrue(RewriteEngine.needsPunctuationPass(
            "Okay so the meeting went well. They liked it but they want the numbers first."))
    }
}
