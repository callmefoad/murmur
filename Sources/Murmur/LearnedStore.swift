import Foundation
import os

struct LearnedCorrection: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the recognizer heard.
    var heard: String
    /// What the user actually said.
    var intended: String
    var timesSeen: Int = 1
}

struct LearnedData: Codable {
    var corrections: [LearnedCorrection] = []
    /// Words/phrases the user has taught (used for recognition biasing
    /// even when no correction mapping is needed).
    var terms: [String] = []
}

/// Murmur's pronunciation memory. Populated by the Voice Training page and
/// by corrections the user makes to transcripts in History. Used two ways:
/// 1. `apply(in:)` fixes known mishearings in every transcript.
/// 2. `biasTerms()` feeds the user's vocabulary into the speech model
///    before recognition (AnalysisContext contextual strings).
enum LearnedStore {
    private static let logger = Logger(subsystem: "local.murmur", category: "learned")
    private static let cache = PersistentCache<LearnedData>()

    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("learned.json")
    }

    static func load() -> LearnedData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LearnedData()
        }
        do {
            return try cache.load(from: fileURL)
        } catch {
            logger.error(
                """
                Failed to load \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return LearnedData()
        }
    }

    static func save(_ learned: LearnedData) {
        do {
            let data = try JSONEncoder().encode(learned)
            try data.write(to: fileURL, options: .atomic)
            AppPaths.secure(fileURL)
            cache.store(learned, for: fileURL)
        } catch {
            logger.error(
                """
                Failed to save \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    static func clear() {
        save(LearnedData())
    }

    // MARK: - Recording new knowledge

    /// Adds one mapping (merging duplicates) and remembers the intended term.
    static func add(heard: String, intended: String) {
        let heardTrimmed = normalizePhrase(heard)
        let intendedTrimmed = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsefulMapping(heard: heardTrimmed, intended: intendedTrimmed) else {
            addTerm(intendedTrimmed)
            return
        }
        var learned = load()
        if let index = learned.corrections.firstIndex(where: {
            $0.heard.lowercased() == heardTrimmed.lowercased()
                && $0.intended == intendedTrimmed
        }) {
            learned.corrections[index].timesSeen += 1
        } else {
            learned.corrections.append(LearnedCorrection(
                heard: heardTrimmed, intended: intendedTrimmed))
        }
        if learned.corrections.count > 300 {
            learned.corrections.removeFirst(learned.corrections.count - 300)
        }
        appendTerm(intendedTrimmed, to: &learned)
        save(learned)
    }

    /// Remembers a term for recognition biasing without any mapping.
    static func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var learned = load()
        appendTerm(trimmed, to: &learned)
        save(learned)
    }

    private static func appendTerm(_ term: String, to learned: inout LearnedData) {
        guard !term.isEmpty,
              !learned.terms.contains(where: { $0.lowercased() == term.lowercased() })
        else { return }
        learned.terms.append(term)
        if learned.terms.count > 300 {
            learned.terms.removeFirst(learned.terms.count - 300)
        }
    }

    /// Learns from a user-corrected transcript: extracts word-level
    /// substitutions and stores each. Returns how many were learned.
    ///
    /// Nonisolated async, so callers on the main actor hop off it for the
    /// whole body — the O(n·m) LCS diff and the per-pair learned.json
    /// merge never run on main.
    @discardableResult
    static func learn(original: String, corrected: String) async -> Int {
        let pairs = extractCorrections(original: original, corrected: corrected)
        for pair in pairs {
            add(heard: pair.heard, intended: pair.intended)
        }
        return pairs.count
    }

    // MARK: - Using the knowledge

    /// Fixes known mishearings: case-insensitive whole phrases, longest
    /// first, in a single pass so one correction can never rewrite the
    /// text another correction just inserted. Terms with non-word edges
    /// ("see plus plus" -> "C++") match too, which the old `\b`-only
    /// pattern silently refused to do.
    static func apply(in text: String) -> String {
        let entries = load().corrections
            .map { (key: $0.heard, value: $0.intended) }
        return PhraseReplacer.replace(in: text, using: entries)
    }

    /// Vocabulary handed to the speech model before recognition:
    /// taught terms, learned spellings, dictionary spellings, snippet triggers.
    ///
    /// Nonisolated async: the body reads up to four JSON files
    /// (learned.json, dictionary.json, snippets.json), so awaiting this
    /// from the main actor keeps that disk I/O off it — notably on every
    /// hotkey key-down.
    static func biasTerms() async -> [String] {
        let learned = load()
        // Round-robin across the four sources instead of concatenating them.
        // Concatenating starved the last three: `learned.terms` is itself
        // capped at 300, so a user with a full taught vocabulary got zero
        // biasing for the Dictionary and Snippets the Settings UI promises
        // are "fed to the model". Dictionary values are sorted because
        // `Dictionary.values` order varies per process.
        let sources: [[String]] = [
            learned.terms,
            learned.corrections.map(\.intended),
            TextFormatter.loadDictionary().values.sorted(),
            SnippetStore.load().map(\.trigger),
        ]
        return interleave(sources, limit: 300)
    }

    /// Takes one item from each source in turn until every source is
    /// exhausted or `limit` items have been kept. Skips blanks and
    /// single-character terms, and de-duplicates case-insensitively.
    static func interleave(_ sources: [[String]], limit: Int) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        let longest = sources.map(\.count).max() ?? 0
        for index in 0..<longest {
            for source in sources where index < source.count {
                let trimmed = source[index]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let key = trimmed.lowercased()
                guard trimmed.count > 1, !seen.contains(key) else { continue }
                seen.insert(key)
                terms.append(trimmed)
                if terms.count >= limit { return terms }
            }
        }
        return terms
    }

    // MARK: - Diff extraction

    /// Word-level diff between the original transcript and the user's
    /// correction. Returns substituted runs (up to 4 words long) as
    /// heard → intended pairs.
    /// Word cap per side for `extractCorrections`, bounding the LCS table
    /// at roughly 32 MB.
    static let maxDiffTokens = 2000

    static func extractCorrections(
        original: String, corrected: String) -> [(heard: String, intended: String)] {
        let originalWords = tokenize(original)
        let correctedWords = tokenize(corrected)
        guard !originalWords.isEmpty, !correctedWords.isEmpty else { return [] }
        // The LCS table below is O(n*m) *Int*, and this runs from "Save &
        // Learn" (off the main actor via the async `learn`). Hands-free
        // dictation reaches thousands of words, where that table costs
        // hundreds of megabytes (12,000 words measured at ~1 GB). Long
        // transcripts are not where per-word pronunciation fixes come from,
        // so bail out instead.
        guard originalWords.count <= maxDiffTokens,
              correctedWords.count <= maxDiffTokens else { return [] }

        // Longest common subsequence over normalized tokens.
        let n = originalWords.count
        let m = correctedWords.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if originalWords[i].key == correctedWords[j].key {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var pairs: [(heard: String, intended: String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if originalWords[i].key == correctedWords[j].key {
                i += 1
                j += 1
                continue
            }
            // Collect one substituted run on each side.
            var removed: [String] = []
            var added: [String] = []
            while i < n, j < m, originalWords[i].key != correctedWords[j].key {
                if lcs[i + 1][j] >= lcs[i][j + 1] {
                    removed.append(originalWords[i].raw)
                    i += 1
                } else {
                    added.append(correctedWords[j].raw)
                    j += 1
                }
                // A pure insertion or deletion isn't a pronunciation fix.
                if i >= n || j >= m { break }
            }
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= 4, added.count <= 4 {
                let heard = normalizePhrase(removed.joined(separator: " "))
                let intended = added.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if isUsefulMapping(heard: heard, intended: intended) {
                    pairs.append((heard, intended))
                }
            }
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [(raw: String, key: String)] {
        text.split(whereSeparator: { $0.isWhitespace }).map { token in
            let raw = String(token)
            let key = raw.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            return (raw, key)
        }
    }

    private static func normalizePhrase(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    }

    private static func isUsefulMapping(heard: String, intended: String) -> Bool {
        guard heard.count >= 2, !intended.isEmpty,
              heard.lowercased() != intended.lowercased()
        else { return false }
        return true
    }

    // MARK: - Self test

    /// Smoke test for the shipped binary. Thin on purpose: `LearnedStoreTests`
    /// owns the diff's edge cases, the token cap and the interleave rules, and
    /// even calls this function. All this needs to prove is that both run at
    /// all inside a packaged build.
    static func runSelfTest() -> Bool {
        var passed = true

        let got = extractCorrections(
            original: "The base ten pipeline is fast.",
            corrected: "The Baseten pipeline is fast.")
        let diffed = got.count == 1
            && got[0].heard == "base ten" && got[0].intended == "Baseten"
        if !diffed { passed = false }
        print("\(diffed ? "PASS" : "FAIL"): diff = \(got)")

        let mixed = interleave([["a1", "a2", "a3"], ["b1"], [], ["d1", "d2"]], limit: 300)
        let interleaved = mixed == ["a1", "b1", "d1", "a2", "d2", "a3"]
        if !interleaved { passed = false }
        print("\(interleaved ? "PASS" : "FAIL"): interleave = \(mixed)")

        return passed
    }
}
