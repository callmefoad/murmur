import XCTest
@testable import Murmur

/// The owner's voice guide is enforced in two places: a prompt, which is a
/// request, and `introducedBannedPhrasing`, which is a rule. These cover the
/// rule, since that is the half that has to hold when the model ignores the
/// other half.
final class VoiceGuideTests: XCTestCase {

    // MARK: - Corporate phrasing the model reached for

    func testIntroducedCorporateWordIsCaught() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "we should just use the cheaper one",
                rewritten: "We should utilize the more economical option."),
            ["utilize"])
    }

    func testIntroducedBoilerplateIsCaught() {
        XCTAssertFalse(
            RewriteEngine.introducedBannedPhrasing(
                original: "can you send me the file",
                rewritten: "I hope this message finds you well. Please send "
                    + "me the file.").isEmpty)
    }

    /// His own word is his own word. The guard exists to stop the model
    /// reaching for vocabulary he never used, not to police his.
    func testSpeakersOwnWordIsNotAViolation() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "I want to utilize the whole budget this quarter",
                rewritten: "I want to utilize the whole budget this quarter."),
            [])
    }

    func testOrdinaryRewritePasses() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "um so I think I think we should probably just "
                    + "ship it and see what happens",
                rewritten: "I think we should probably just ship it and see "
                    + "what happens."),
            [])
    }

    // MARK: - Punctuation he does not write

    func testIntroducedEmDashIsCaught() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "it works, mostly",
                rewritten: "It works \u{2014} mostly."),
            ["em dash"])
    }

    func testIntroducedSemicolonIsCaught() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "it works and I like it",
                rewritten: "It works; I like it."),
            ["semicolon"])
    }

    func testEmDashHeDictatedHimselfSurvives() {
        XCTAssertEqual(
            RewriteEngine.introducedBannedPhrasing(
                original: "it works \u{2014} mostly",
                rewritten: "It works \u{2014} mostly."),
            [])
    }

    // MARK: - The guard is wired into the accept path

    func testAcceptedRewriteRejectsCorporatePhrasing() {
        XCTAssertNil(
            RewriteEngine.acceptedRewrite(
                original: "we should just use the cheaper one and move on",
                rewritten: "We should utilize the cheaper option and proceed.",
                profile: .preserving, context: "test"))
    }

    func testAcceptedRewriteKeepsACleanRewrite() {
        let rewritten = "I think we should ship it and see what happens."
        XCTAssertEqual(
            RewriteEngine.acceptedRewrite(
                original: "um so I think we should ship it and uh see what "
                    + "happens",
                rewritten: rewritten,
                profile: .preserving, context: "test"),
            rewritten)
    }

    // MARK: - Prompt wiring

    func testPolishAndTightenShareTheVoiceCoreAndDiffer() {
        let polished = RewriteEngine.polishPrompt(level: .polished)
        let tightened = RewriteEngine.polishPrompt(level: .tightened)
        XCTAssertTrue(polished.contains("Return only the cleaned text"))
        XCTAssertTrue(tightened.contains("Return only the cleaned text"))
        XCTAssertNotEqual(polished, tightened)
        XCTAssertTrue(tightened.contains("Compress, do not summarize"))
    }

    func testModelFreeLevelsHaveNoPrompt() {
        XCTAssertEqual(RewriteEngine.polishPrompt(level: .verbatim), "")
        XCTAssertEqual(RewriteEngine.polishPrompt(level: .cleaned), "")
        XCTAssertNil(CleanupLevel.verbatim.polishInstructions)
        XCTAssertNil(CleanupLevel.cleaned.polishInstructions)
    }

    /// The prompt shares one small context window with the transcript and
    /// the output, so it has to stay affordable.
    func testPromptStaysWithinItsBudget() {
        XCTAssertLessThan(
            RewriteEngine.polishPrompt(level: .tightened).count, 3500)
    }

    /// Every rule stated in the prompt that is also mechanically checkable
    /// must actually be checked, or the prompt is making a promise the code
    /// does not keep.
    func testPromptBansAreBackedByTheGuard() {
        let prompt = RewriteEngine.polishPrompt(level: .polished).lowercased()
        for word in ["utilize", "leverage", "facilitate", "commence",
                     "subsequently", "delve", "robust", "seamless"] {
            XCTAssertTrue(
                prompt.contains(word), "prompt should name \(word)")
            XCTAssertTrue(
                RewriteEngine.bannedPhrases.contains(word),
                "guard should enforce \(word)")
        }
    }
}
