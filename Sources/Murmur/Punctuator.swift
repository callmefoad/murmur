import CryptoKit
import Foundation
import PunctuationRuntime
import os

/// Punctuates dictation by grammar instead of by pauses.
///
/// Apple's recognizer ends a sentence at every pause, so a speaker who stops
/// to think gets a period mid-thought. This runs a small punctuation model
/// (1-800-BAD-CODE/punctuation_fullstop_truecase_english, Apache 2.0) that
/// labels each word with the punctuation that follows it and whether it
/// starts with a capital. It is a token classifier, not a generator: it can
/// only label the words it was given, so it cannot reword, answer, or act on
/// anything that was said. The rebuild below also only ever touches trailing
/// punctuation and the first letter's case, and a final word-for-word check
/// falls back to the input on any mismatch.
///
/// About 20-40 ms per dictation on Apple silicon. English only.
final class Punctuator: @unchecked Sendable {
    static let shared = Punctuator()

    private let lock = NSLock()
    private var model: OpaquePointer?
    private var tokenizer: SentencePieceTokenizer?
    private var loadFailed = false
    private static let log = Logger(subsystem: "local.murmur", category: "punctuator")

    /// The model's post-punctuation labels, by output index.
    static let postLabels: [Character?] = [nil, nil, ".", ",", "?"]
    static let capWidth = 16
    /// 256 minus BOS and EOS.
    static let maxTokens = 254
    static let windowOverlap = 12

    deinit {
        if let model { punctuation_model_free(model) }
    }

    /// True when the model files are on disk and the model could be used.
    var isAvailable: Bool {
        PunctuationModelFiles.isInstalled && !loadFailed
    }

    /// Loads the model if it is installed. Safe to call from any thread;
    /// used at launch so the first dictation doesn't pay for loading.
    @discardableResult
    func warmUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> Bool {
        if model != nil, tokenizer != nil { return true }
        if loadFailed || !PunctuationModelFiles.isInstalled { return false }
        do {
            let data = try Data(contentsOf: PunctuationModelFiles.tokenizerURL)
            let tokenizer = try SentencePieceTokenizer(modelData: data)
            var error = [CChar](repeating: 0, count: 512)
            let path = PunctuationModelFiles.modelURL.path
            guard let loaded = punctuation_model_load(path, &error, Int32(error.count)) else {
                Self.log.error("model load failed: \(String(cString: error), privacy: .public)")
                loadFailed = true
                return false
            }
            self.tokenizer = tokenizer
            self.model = loaded
            return true
        } catch {
            Self.log.error("tokenizer load failed: \(error.localizedDescription, privacy: .public)")
            loadFailed = true
            return false
        }
    }

    /// Returns `text` re-punctuated by grammar, or `text` unchanged when the
    /// model isn't installed or anything goes wrong.
    func punctuate(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard loadLocked(), let model, let tokenizer else { return text }
        let result = Self.repunctuate(text) { words in
            Self.predict(words: words, model: model, tokenizer: tokenizer)
        }
        return result
    }

    // MARK: - Pure rebuild

    /// What the model decided about one model word.
    struct WordLabel: Equatable {
        var punctuation: Character?
        var capitalized: Bool
    }

    /// One whitespace-separated piece of the input line.
    struct Chunk {
        enum Kind { case word, abbreviation, other }
        let original: String
        /// The chunk without trailing punctuation (abbreviations keep their dots).
        let body: String
        /// Trailing punctuation the recognizer or formatter put there.
        let tail: String
        let kind: Kind
        /// Lowercased words fed to the model. Empty for "-", "&", emoji.
        let modelWords: [String]
    }

    private static let trailingPunctuation: Set<Character> = [".", ",", "?", "!", ";", ":"]
    private static let firstPersonForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]
    /// The model sometimes capitalizes after "she said" as if a quote
    /// started. Mid-sentence, these words are never names, so a model capital
    /// on them is ignored. Names, days and brands still come through.
    static let neverMidSentenceCapital: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "if", "then", "because",
        "we", "you", "he", "she", "it", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these",
        "those", "there", "here", "what", "when", "where", "why", "how", "who",
        "which", "is", "are", "was", "were", "be", "been", "do", "does", "did",
        "have", "has", "had", "will", "would", "can", "could", "should", "just",
        "not", "no", "yes", "yeah", "okay", "ok", "well", "also", "now", "to",
        "of", "in", "on", "at", "for", "with", "from", "about", "like", "let's",
        "we're", "you're", "it's", "that's", "there's", "don't", "can't",
    ]

    /// Splits text into chunks, asks `predict` for a label per model word,
    /// and rebuilds. `predict` gets the model words of the whole text and
    /// returns one label per word, or nil to leave the text unchanged.
    static func repunctuate(
        _ text: String, predict: ([String]) -> [WordLabel]?
    ) -> String {
        let lines = text.components(separatedBy: "\n")
        let chunkedLines = lines.map { line in
            line.split(separator: " ", omittingEmptySubsequences: true)
                .map { chunk(String($0)) }
        }
        let words = chunkedLines.flatMap { $0.flatMap(\.modelWords) }
        guard !words.isEmpty, let labels = predict(words), labels.count == words.count
        else { return text }

        var cursor = 0
        var rebuiltLines: [String] = []
        for (index, (line, chunks)) in zip(lines, chunkedLines).enumerated() {
            guard !chunks.isEmpty else {
                rebuiltLines.append(line)
                continue
            }
            let leading = String(line.prefix { $0 == " " })
            let count = chunks.reduce(0) { $0 + $1.modelWords.count }
            let lineLabels = Array(labels[cursor..<cursor + count])
            cursor += count
            let isLastLine = !chunkedLines[(index + 1)...].contains { !$0.isEmpty }
            rebuiltLines.append(leading + render(chunks, labels: lineLabels, isLastLine: isLastLine))
        }
        let result = rebuiltLines.joined(separator: "\n")
        // The words must come back exactly as they went in. By construction
        // they do, but this is the line that guarantees it.
        guard wordSequence(result) == wordSequence(text) else { return text }
        return result
    }

    static func chunk(_ original: String) -> Chunk {
        // "p.m." and "U.S.," keep their dots; only what follows is a tail.
        if let match = original.firstMatch(of: #/^((?:[A-Za-z]\.){2,})([,.?!;:]?)$/#) {
            let body = String(match.output.1)
            return Chunk(
                original: original, body: body, tail: String(match.output.2),
                kind: .abbreviation, modelWords: [body.lowercased().filter(\.isLetter)])
        }
        var body = Substring(original)
        while let last = body.last, trailingPunctuation.contains(last), body.count > 1 {
            body = body.dropLast()
        }
        let tail = String(original[body.endIndex...])
        let bodyString = String(body)
        let isWord = bodyString.first?.isLetter == true
            && bodyString.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        return Chunk(
            original: original, body: bodyString, tail: tail,
            kind: isWord ? .word : .other, modelWords: modelWords(bodyString))
    }

    /// Lowercase runs of letters, digits and apostrophes. Hyphens and every
    /// other symbol split words, so the tokenizer never sees `<unk>` for them.
    static func modelWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if (character == "'" || character == "’"), !current.isEmpty {
                current.append("'")
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { word in
            var word = Substring(word)
            while word.last == "'" { word = word.dropLast() }
            return String(word)
        }.filter { !$0.isEmpty }
    }

    static func wordSequence(_ text: String) -> [String] {
        modelWords(text)
    }

    private static func render(_ chunks: [Chunk], labels: [WordLabel], isLastLine: Bool) -> String {
        var out: [String] = []
        var cursor = 0
        // Every line starts a sentence: layout newlines are deliberate.
        var sentenceStart = true
        var originalSentenceStart = true
        for (position, chunk) in chunks.enumerated() {
            let isLast = position == chunks.count - 1
            let originalEndsSentence = chunk.original.last.map { ".?!".contains($0) } ?? false
            defer { originalSentenceStart = originalEndsSentence }

            guard !chunk.modelWords.isEmpty else {
                // "-", "&", "…": nothing for the model to say about it.
                out.append(chunk.original)
                if originalEndsSentence { sentenceStart = true }
                continue
            }
            let first = labels[cursor]
            let last = labels[cursor + chunk.modelWords.count - 1]
            cursor += chunk.modelWords.count

            // Punctuation after the chunk.
            var punctuation: String
            let kept = chunk.tail.filter { "?!;:".contains($0) }
            if !kept.isEmpty {
                // A question mark or exclamation came from the recognizer
                // hearing the voice, keep it.
                punctuation = kept
            } else {
                punctuation = last.punctuation.map(String.init) ?? ""
                if isLast {
                    if punctuation.isEmpty, chunk.tail.contains(".") {
                        punctuation = "."
                    } else if isLastLine, chunk.tail.isEmpty, punctuation != "?" {
                        // No period at the very end means the user turned
                        // the automatic period off. Respect that.
                        punctuation = ""
                    }
                }
            }
            if chunk.kind == .abbreviation, punctuation == "." { punctuation = "" }
            if chunk.kind == .other, let end = chunk.body.last, ".?!".contains(end) {
                punctuation = ""
            }

            // Case of the first letter.
            var body = chunk.body
            if chunk.kind == .word {
                body = cased(
                    body, sentenceStart: sentenceStart, modelCapital: first.capitalized,
                    capitalFromPause: originalSentenceStart)
            }
            out.append(body + punctuation)

            let emitted = body + punctuation
            if let end = emitted.last, ".?!".contains(end) {
                sentenceStart = chunk.kind != .abbreviation || !punctuation.isEmpty
                    || last.punctuation == "."
            } else {
                sentenceStart = false
            }
        }
        return out.joined(separator: " ")
    }

    private static func cased(
        _ word: String, sentenceStart: Bool, modelCapital: Bool, capitalFromPause: Bool
    ) -> String {
        guard let first = word.first else { return word }
        // "iPhone", "McDonald", "NASA": the recognizer's casing is deliberate.
        if word.dropFirst().contains(where: \.isUppercase) { return word }
        if firstPersonForms.contains(word.lowercased().replacingOccurrences(of: "’", with: "'")) {
            return word
        }
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let modelCapital = modelCapital && !neverMidSentenceCapital.contains(lower)
        if sentenceStart || modelCapital {
            return first.uppercased() + word.dropFirst()
        }
        // The only capital the recognizer gave it came from a pause it read
        // as a sentence end, and the model says it's not a name. Lowercase.
        if first.isUppercase, capitalFromPause {
            return first.lowercased() + word.dropFirst()
        }
        return word
    }

    // MARK: - Inference

    private static func predict(
        words: [String], model: OpaquePointer, tokenizer: SentencePieceTokenizer
    ) -> [WordLabel]? {
        let tokenized = words.map { tokenizer.encode(word: $0) }
        var labels = [WordLabel?](repeating: nil, count: words.count)
        var start = 0
        while start < words.count {
            var end = start
            var tokens = 0
            while end < words.count, tokens + tokenized[end].count <= maxTokens {
                tokens += tokenized[end].count
                end += 1
            }
            if end == start { end = start + 1 } // one absurdly long word
            let windowWords = Array(start..<end)
            guard let windowLabels = run(
                windowWords.map { tokenized[$0] }, model: model, tokenizer: tokenizer)
            else { return nil }

            let atEnd = end == words.count
            let small = end - start <= windowOverlap
            let keepFrom = start == 0 ? start : start + windowOverlap / 2
            let keepTo = (atEnd || small) ? end : end - windowOverlap / 2
            for index in max(start, keepFrom)..<keepTo where labels[index] == nil {
                labels[index] = windowLabels[index - start]
            }
            if atEnd { break }
            start = small ? end : end - windowOverlap
        }
        let result = labels.compactMap { $0 }
        return result.count == words.count ? result : nil
    }

    private static func run(
        _ words: [[Int32]], model: OpaquePointer, tokenizer: SentencePieceTokenizer
    ) -> [WordLabel]? {
        var ids: [Int64] = [Int64(SentencePieceTokenizer.bosID)]
        var ranges: [Range<Int>] = []
        for tokens in words {
            let begin = ids.count
            let room = maxTokens + 1 - ids.count
            ids.append(contentsOf: tokens.prefix(max(room, 1)).map(Int64.init))
            ranges.append(begin..<ids.count)
        }
        ids.append(Int64(SentencePieceTokenizer.eosID))

        var post = [Int64](repeating: 0, count: ids.count)
        var caps = [UInt8](repeating: 0, count: ids.count * capWidth)
        var error = [CChar](repeating: 0, count: 512)
        let status = punctuation_model_run(
            model, ids, Int32(ids.count), &post, &caps, Int32(capWidth),
            &error, Int32(error.count))
        guard status == 0 else {
            log.error("inference failed: \(String(cString: error), privacy: .public)")
            return nil
        }

        return ranges.map { range in
            guard let lastToken = range.last else {
                return WordLabel(punctuation: nil, capitalized: false)
            }
            let label = Int(post[lastToken])
            let punctuation = label < postLabels.count ? postLabels[label] : nil
            // First letter: index 1 of a "▁word" piece (0 is the ▁ itself),
            // or index 0 of the next piece when "▁" stands alone.
            var capToken = range.lowerBound
            var capIndex = 0
            let piece = tokenizer.piece(Int32(ids[capToken]))
            if piece == "▁", range.count > 1 {
                capToken += 1
            } else if piece.hasPrefix("▁") {
                capIndex = 1
            }
            let capitalized = caps[capToken * capWidth + min(capIndex, capWidth - 1)] != 0
            return WordLabel(punctuation: punctuation, capitalized: capitalized)
        }
    }
}

// MARK: - Model files

/// The two files the punctuator needs, pinned to one revision and verified
/// by SHA-256 before they are used. Downloaded once from Hugging Face into
/// Application Support. Nothing about dictations is ever sent anywhere.
enum PunctuationModelFiles {
    static let repository = "1-800-BAD-CODE/punctuation_fullstop_truecase_english"
    static let revision = "b26fd1c40e88678859048898218ea4edcc24c84a"

    struct File {
        let name: String
        let size: Int
        let sha256: String
    }

    static let model = File(
        name: "punct_cap_seg_en.onnx", size: 209_532_928,
        sha256: "dd922d459da618cd324280889740608b76fb3e9e61d3f402291be1251f91421b")
    static let tokenizer = File(
        name: "spe_32k_lc_en.model", size: 587_902,
        sha256: "9e86d0263de80b3b68327a21f5350c8cdf846e4c4400253c9baf05e3d44871c3")

    static var directory: URL {
        AppPaths.supportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("punctuation-\(revision.prefix(12))", isDirectory: true)
    }

    static var modelURL: URL { directory.appendingPathComponent(model.name) }
    static var tokenizerURL: URL { directory.appendingPathComponent(tokenizer.name) }

    static var isInstalled: Bool {
        [model, tokenizer].allSatisfy { file in
            let url = directory.appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
            return size == file.size
        }
    }

    enum DownloadError: LocalizedError {
        case badResponse(Int)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "download failed (HTTP \(code))"
            case .checksumMismatch(let name): return "\(name) failed its checksum"
            }
        }
    }

    /// Downloads whatever is missing. Each file is verified before it is
    /// moved into place, so a partial or tampered download is never used.
    static func download() async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        AppPaths.secure(directory.deletingLastPathComponent())
        AppPaths.secure(directory)
        // Smallest first, so a failure shows up fast.
        for file in [tokenizer, model] {
            let destination = directory.appendingPathComponent(file.name)
            let size = (try? manager.attributesOfItem(atPath: destination.path)[.size]) as? Int
            if size == file.size { continue }
            let url = URL(string:
                "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? manager.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw DownloadError.badResponse(http.statusCode)
            }
            guard try sha256(of: temporary) == file.sha256 else {
                throw DownloadError.checksumMismatch(file.name)
            }
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: temporary, to: destination)
            AppPaths.secure(destination)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Tokenizer

/// Minimal SentencePiece unigram encoder: reads the `.model` protobuf and
/// runs Viterbi over one word at a time. Words never share a piece in this
/// model (pieces only carry ▁ at their start), so per-word encoding matches
/// encoding the whole text.
struct SentencePieceTokenizer {
    static let unknownID: Int32 = 0
    static let bosID: Int32 = 1
    static let eosID: Int32 = 2

    private var pieces: [String: (id: Int32, score: Float)] = [:]
    private var idToPiece: [String] = []
    private var maxPieceLength = 1
    private var unknownScore: Float = -10

    enum ParseError: Error { case malformed }

    init(modelData data: Data) throws {
        let bytes = [UInt8](data)
        var reader = ProtoReader(bytes: bytes[...])
        var minScore: Float = 0
        while let (field, wire) = try reader.nextKey() {
            guard field == 1, wire == 2 else {
                try reader.skip(wire: wire)
                continue
            }
            var piece = ProtoReader(bytes: try reader.lengthDelimited())
            var text = ""
            var score: Float = 0
            var type: UInt64 = 1
            while let (pieceField, pieceWire) = try piece.nextKey() {
                switch (pieceField, pieceWire) {
                case (1, 2):
                    text = String(decoding: try piece.lengthDelimited(), as: UTF8.self)
                case (2, 5):
                    score = Float(bitPattern: try piece.fixed32())
                case (3, 0):
                    type = try piece.varint()
                default:
                    try piece.skip(wire: pieceWire)
                }
            }
            let id = Int32(idToPiece.count)
            idToPiece.append(text)
            // 1 normal, 4 user defined. Control and unknown pieces never match text.
            if type == 1 || type == 4 {
                pieces[text] = (id, score)
                maxPieceLength = max(maxPieceLength, text.unicodeScalars.count)
                minScore = min(minScore, score)
            }
        }
        guard !idToPiece.isEmpty else { throw ParseError.malformed }
        unknownScore = minScore - 10
    }

    func piece(_ id: Int32) -> String {
        Int(id) < idToPiece.count ? idToPiece[Int(id)] : ""
    }

    func encode(word: String) -> [Int32] {
        let scalars = Array(("▁" + word).unicodeScalars)
        let count = scalars.count
        var best = [Float](repeating: -.infinity, count: count + 1)
        var back = [(start: Int, id: Int32)](repeating: (0, 0), count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            var matchedSingle = false
            for length in 1...min(maxPieceLength, count - start) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[start..<(start + length)])
                guard let match = pieces[String(view)] else { continue }
                if length == 1 { matchedSingle = true }
                let score = best[start] + match.score
                if score > best[start + length] {
                    best[start + length] = score
                    back[start + length] = (start, match.id)
                }
            }
            if !matchedSingle {
                let score = best[start] + unknownScore
                if score > best[start + 1] {
                    best[start + 1] = score
                    back[start + 1] = (start, Self.unknownID)
                }
            }
        }
        var ids: [Int32] = []
        var position = count
        while position > 0 {
            let step = back[position]
            ids.append(step.id)
            position = step.start
        }
        ids.reverse()
        // Consecutive unknowns collapse into one, as SentencePiece does.
        var merged: [Int32] = []
        for id in ids where !(id == Self.unknownID && merged.last == Self.unknownID) {
            merged.append(id)
        }
        return merged
    }
}

private struct ProtoReader {
    var bytes: ArraySlice<UInt8>

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.first {
            bytes = bytes.dropFirst()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw SentencePieceTokenizer.ParseError.malformed
    }

    mutating func nextKey() throws -> (Int, Int)? {
        guard !bytes.isEmpty else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
        let length = Int(try varint())
        guard length >= 0, length <= bytes.count else {
            throw SentencePieceTokenizer.ParseError.malformed
        }
        let slice = bytes.prefix(length)
        bytes = bytes.dropFirst(length)
        return slice
    }

    mutating func fixed32() throws -> UInt32 {
        guard bytes.count >= 4 else { throw SentencePieceTokenizer.ParseError.malformed }
        var value: UInt32 = 0
        for (offset, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * UInt32(offset))
        }
        bytes = bytes.dropFirst(4)
        return value
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1:
            guard bytes.count >= 8 else { throw SentencePieceTokenizer.ParseError.malformed }
            bytes = bytes.dropFirst(8)
        case 2: _ = try lengthDelimited()
        case 5: _ = try fixed32()
        default: throw SentencePieceTokenizer.ParseError.malformed
        }
    }
}
