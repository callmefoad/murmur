import XCTest
@testable import Murmur

/// The polish pass runs after the key is released, so every millisecond of
/// it is wait the user feels. These pin the rule that decides whether it is
/// worth paying for — and, just as importantly, that it errs toward paying.
final class PolishGateTests: XCTestCase {

    // MARK: - Skips: short, clean, nothing for a rewrite to do

    func testShortCleanSentenceSkipsTheModel() {
        XCTAssertFalse(RewriteEngine.needsPolish(
            "Yeah that works for me, I'll be there at three."))
    }

    func testShortQuestionSkipsTheModel() {
        XCTAssertFalse(RewriteEngine.needsPolish(
            "Can you send me the invoice when you get a chance?"))
    }

    func testSentenceOpeningWithAConjunctionStillSkips() {
        // His voice opens sentences with But/So/And on purpose. That is not
        // evidence of a ramble, so it must not force a model pass.
        XCTAssertFalse(RewriteEngine.needsPolish(
            "So I pushed the fix. But the tests still need a rerun."))
    }

    func testBareActuallyAndIMeanDoNotForceAPass() {
        // Both are ordinary openers for him. Flagging them would skip
        // nothing, which would make the whole gate pointless.
        XCTAssertFalse(RewriteEngine.needsPolish(
            "Actually that's better. I mean it reads cleaner."))
    }

    // MARK: - Runs: the cases a rewrite exists for

    func testLongDictationRunsTheModel() {
        let long = String(repeating: "word ", count: 40)
        XCTAssertTrue(RewriteEngine.needsPolish(long))
    }

    /// Distinct words, so this pins the word-limit boundary alone and does
    /// not accidentally trip the stutter check.
    private func distinctWords(_ count: Int) -> String {
        (0..<count).map { "w\($0)" }.joined(separator: " ")
    }

    func testExactlyAtTheWordLimitStillSkips() {
        // At the limit the sentence-length check must not fire either, so
        // this doubles as a guard that the two limits agree.
        XCTAssertFalse(RewriteEngine.needsPolish(
            distinctWords(RewriteEngine.polishSkipWordLimit) + "."))
    }

    func testOneWordOverTheLimitRuns() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            distinctWords(RewriteEngine.polishSkipWordLimit + 1) + "."))
    }

    func testSelfCorrectionRunsTheModel() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            "Move it to Tuesday. Sorry, I meant Wednesday."))
    }

    func testScaffoldingRunsTheModel() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            "What I'm trying to say is the price should go up."))
    }

    func testResidualFillerRunsTheModel() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            "It's basically done, um, mostly."))
    }

    func testStutterRunsTheModel() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            "Send me the the invoice today."))
    }

    func testShortButRunOnRunsTheModel() {
        // Under the word limit overall, but one breathless clause.
        let runOn = "I went to the store and then I saw him and he said the "
            + "thing about the invoice and I told him it was already sent so "
            + "he should check again"
        XCTAssertTrue(RewriteEngine.needsPolish(runOn))
    }

    func testParagraphBreakRunsTheModel() {
        XCTAssertTrue(RewriteEngine.needsPolish("First point.\n\nSecond point."))
    }

    // MARK: - Edges

    func testEmptyTextNeedsNoPolish() {
        XCTAssertFalse(RewriteEngine.needsPolish(""))
        XCTAssertFalse(RewriteEngine.needsPolish("   \n  "))
    }

    func testSingleWordNeedsNoPolish() {
        XCTAssertFalse(RewriteEngine.needsPolish("Yes."))
    }

    /// The gate's whole safety argument is that a wrong "skip" costs polish
    /// while a wrong "run" costs only time, so it must never skip a
    /// dictation long enough to have structure worth fixing.
    func testTheGateErrsTowardRunning() {
        XCTAssertTrue(RewriteEngine.needsPolish(
            String(repeating: "clean and tidy words here ", count: 10)))
    }
}

/// Streaming transcription moves recognition off the post-release critical
/// path. It is the default now, so the default is worth pinning.
final class StreamingDefaultTests: XCTestCase {

    func testStreamingTranscriptionIsOnByDefault() {
        UserDefaults.standard.removeObject(forKey: "streamingTranscription")
        XCTAssertTrue(Settings.streamingTranscription)
    }

    func testStreamingTranscriptionCanStillBeTurnedOff() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "streamingTranscription")
        XCTAssertFalse(Settings.streamingTranscription)
        defaults.removeObject(forKey: "streamingTranscription")
    }
}
