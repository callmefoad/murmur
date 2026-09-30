import Foundation

/// Decides where to cut a live recording into speech segments, from one
/// voice-activity probability per fixed-size chunk of 16 kHz audio.
///
/// Parakeet transcribes each finished segment while the user keeps talking,
/// so on release only the last segment is left to do. Cuts only happen at
/// a real pause, never mid-word, and silence longer than a pause is left
/// out of every segment, so dead air is never transcribed.
///
/// Pure value type: the VAD model supplies the probabilities, this only
/// does the bookkeeping, so it is testable without any model.
struct SpeechSegmenter {
    /// Samples per VAD chunk at 16 kHz (Silero's 256 ms window).
    static let chunkSamples = 4096

    /// Probability that starts a segment.
    var speechThreshold: Float = 0.5
    /// Once in speech, anything at or above this still counts as speech
    /// (hysteresis, so a soft syllable doesn't open a gap).
    var silenceThreshold: Float = 0.35
    /// Silent chunks in a row that end a segment: 3 × 256 ms ≈ 0.77 s.
    var silenceChunksToCut = 3
    /// Chunks of context kept on each side of the speech. Two, because a
    /// soft first syllable often scores below the threshold.
    var padChunks = 2
    /// A pause only cuts once the segment holds this much speech: 31 × 256 ms
    /// ≈ 8 s. Parakeet needs the context; a short phrase transcribed on its
    /// own loses words ("thanks" came back "serious"). Most dictations are
    /// shorter than this and stay one segment, exactly like the file path.
    var minSegmentChunks = 31

    private var chunkIndex = 0
    private var speechStart: Int?
    private var lastSpeech: Int?
    /// No segment may start before this chunk (the end of the last cut).
    private var cutFloor = 0

    /// Feeds the next chunk's probability. Returns a finished segment's
    /// chunk range when this chunk completes a pause.
    mutating func feed(_ probability: Float) -> Range<Int>? {
        let index = chunkIndex
        chunkIndex += 1

        guard let start = speechStart, let last = lastSpeech else {
            if probability >= speechThreshold {
                speechStart = index
                lastSpeech = index
            }
            return nil
        }
        if probability >= silenceThreshold {
            lastSpeech = index
            return nil
        }
        guard index - last >= silenceChunksToCut,
              last + 1 - start >= minSegmentChunks else { return nil }
        let range = max(cutFloor, start - padChunks)..<min(index + 1, last + 1 + padChunks)
        cutFloor = range.upperBound
        speechStart = nil
        lastSpeech = nil
        return range
    }

    /// The recording ended. Returns the segment still in progress, running
    /// to the very end: a word cut off at release is worse than a little
    /// trailing silence.
    mutating func finish() -> Range<Int>? {
        defer {
            speechStart = nil
            lastSpeech = nil
            cutFloor = chunkIndex
        }
        guard let start = speechStart else { return nil }
        return max(cutFloor, start - padChunks)..<chunkIndex
    }

    /// Sample range for a chunk range, clamped to what was recorded.
    static func sampleRange(_ chunks: Range<Int>, totalSamples: Int) -> Range<Int> {
        let lower = min(chunks.lowerBound * chunkSamples, totalSamples)
        let upper = min(chunks.upperBound * chunkSamples, totalSamples)
        return lower..<max(lower, upper)
    }

    /// Joins segment transcripts in order, dropping empty ones.
    static func join(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
