import XCTest
@testable import Murmur

final class LearnedStoreTests: XCTestCase {

    func testSingleWordSubstitution() {
        let pairs = LearnedStore.extractCorrections(
            original: "Send it to Soren today.",
            corrected: "Send it to Søren today.")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "Soren")
        XCTAssertEqual(pairs.first?.intended, "Søren")
    }

    func testMultiWordRun() {
        let pairs = LearnedStore.extractCorrections(
            original: "The base ten pipeline is fast.",
            corrected: "The Baseten pipeline is fast.")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.heard, "base ten")
        XCTAssertEqual(pairs.first?.intended, "Baseten")
    }

    func testIdenticalStringsYieldNoCorrections() {
        let pairs = LearnedStore.extractCorrections(
            original: "Hello world.", corrected: "Hello world.")
        XCTAssertTrue(pairs.isEmpty)
    }

    /// The LCS table is O(n*m) Ints and `learn` runs synchronously on the
    /// main actor, so a 12,000-word hands-free transcript used to allocate
    /// about a gigabyte. Past the cap, extraction bails out instead.
    func testOverlongTranscriptsBailOutInsteadOfAllocating() {
        let long = Array(repeating: "word", count: LearnedStore.maxDiffTokens + 1)
            .joined(separator: " ")
        XCTAssertTrue(
            LearnedStore.extractCorrections(original: long, corrected: long + " Søren")
                .isEmpty)
        XCTAssertTrue(
            LearnedStore.extractCorrections(original: "Send it to Soren today.",
                                            corrected: long).isEmpty)
    }

    func testAtTheCapExtractionStillRuns() {
        let words = Array(repeating: "word", count: LearnedStore.maxDiffTokens - 2)
        let original = (words + ["Soren", "tail"]).joined(separator: " ")
        let corrected = (words + ["Søren", "tail"]).joined(separator: " ")
        let pairs = LearnedStore.extractCorrections(
            original: original, corrected: corrected)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.intended, "Søren")
    }

    /// Bias terms used to be concatenated, so a user whose taught
    /// vocabulary already filled the 300-term cap got ZERO biasing for
    /// their dictionary and snippets. Sources are now interleaved.
    func testInterleaveRepresentsEverySource() {
        let result = LearnedStore.interleave(
            [["a1", "a2", "a3"], ["b1"], [], ["d1", "d2"]], limit: 300)
        XCTAssertEqual(result, ["a1", "b1", "d1", "a2", "d2", "a3"])
    }

    func testInterleaveGivesLaterSourcesRoomUnderTheCap() {
        let first = (1...300).map { "term\($0)" }
        let result = LearnedStore.interleave([first, ["snippet"]], limit: 300)
        XCTAssertEqual(result.count, 300)
        XCTAssertTrue(result.contains("snippet"))
    }

    func testInterleaveDedupesCaseInsensitivelyAndDropsShortTerms() {
        let result = LearnedStore.interleave(
            [["Jira", "x", " "], ["jira", "Baseten"]], limit: 300)
        XCTAssertEqual(result, ["Jira", "Baseten"])
    }

    func testBuiltInSelfTestStillPasses() {
        XCTAssertTrue(LearnedStore.runSelfTest())
    }
}
