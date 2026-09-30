import XCTest
@testable import Murmur

/// Cuts are decided from one VAD probability per 256 ms chunk. "S" is a
/// speech chunk (0.9), "." silence (0.05), "~" in-between (0.4).
final class SpeechSegmenterTests: XCTestCase {
    private func cuts(_ pattern: String, minSegment: Int = 0) -> [Range<Int>] {
        var segmenter = SpeechSegmenter()
        segmenter.padChunks = 1
        segmenter.minSegmentChunks = minSegment
        var result: [Range<Int>] = []
        for mark in pattern {
            let probability: Float = mark == "S" ? 0.9 : mark == "~" ? 0.4 : 0.05
            if let cut = segmenter.feed(probability) { result.append(cut) }
        }
        if let cut = segmenter.finish() { result.append(cut) }
        return result
    }

    func testOneUtteranceRunsToTheEnd() {
        XCTAssertEqual(cuts("..SSSS"), [1..<6])
    }

    func testPauseCutsAndDropsTheSilence() {
        // Speech 2-4, pause 5-10, speech 11-12. Silence past the padding
        // (chunks 6-9) is in neither segment.
        XCTAssertEqual(cuts("..SSS......SS"), [1..<6, 10..<13])
    }

    func testShortPauseDoesNotCut() {
        XCTAssertEqual(cuts("SSS..SSS"), [0..<8])
    }

    func testInBetweenProbabilityKeepsSpeechGoing() {
        XCTAssertEqual(cuts("SS~~~~SS"), [0..<8])
    }

    func testInBetweenProbabilityDoesNotStartSpeech() {
        XCTAssertEqual(cuts("~~~~"), [])
    }

    func testSilenceOnlyHasNoSegments() {
        XCTAssertEqual(cuts("........"), [])
    }

    func testSegmentsNeverOverlap() {
        // Second utterance starts right after the cut; its padding can't
        // reach back into the first segment.
        let result = cuts("SS...SS")
        XCTAssertEqual(result, [0..<3, 4..<7])
    }

    func testTrailingSilenceAfterCutIsIgnored() {
        XCTAssertEqual(cuts("SS......."), [0..<3])
    }

    func testShortSegmentWaitsForMoreSpeech() {
        // First phrase is 2 chunks, under the 3-chunk minimum: the pause
        // doesn't cut, and the phrase joins the next one.
        XCTAssertEqual(cuts("SS....SS....S", minSegment: 3), [0..<9, 11..<13])
    }

    func testShippedDefaultsKeepAShortDictationWhole() {
        var segmenter = SpeechSegmenter()
        var result: [Range<Int>] = []
        let pattern = String(repeating: "S", count: 12) + "....." + String(repeating: "S", count: 8)
        for mark in pattern {
            if let cut = segmenter.feed(mark == "S" ? 0.9 : 0.05) { result.append(cut) }
        }
        if let cut = segmenter.finish() { result.append(cut) }
        XCTAssertEqual(result, [0..<25])
    }

    func testSampleRangeClampsToRecording() {
        XCTAssertEqual(SpeechSegmenter.sampleRange(1..<2, totalSamples: 10_000), 4096..<8192)
        XCTAssertEqual(SpeechSegmenter.sampleRange(2..<4, totalSamples: 10_000), 8192..<10_000)
        XCTAssertEqual(SpeechSegmenter.sampleRange(5..<6, totalSamples: 10_000), 10_000..<10_000)
    }

    func testJoinSkipsEmptySegments() {
        XCTAssertEqual(SpeechSegmenter.join([" First part.", "", "Second part. "]),
                       "First part. Second part.")
    }
}
