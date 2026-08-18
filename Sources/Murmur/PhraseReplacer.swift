import Foundation

/// One shared, single-pass phrase replacer used by every user-configurable
/// substitution list in Murmur: the personal dictionary, learned
/// pronunciation corrections, and voice snippets.
///
/// Why a single pass matters:
///
/// 1. **No cascading.** Looping `replacingOccurrences` once per entry lets a
///    later rule rewrite text an earlier rule just inserted — snippet
///    `email -> me@example.com` followed by `com -> Company` produced
///    `me@example.Company`. Here the scan happens exactly once over the
///    ORIGINAL text, so replacement output is never rescanned.
/// 2. **Deterministic longest-match.** Branches are ordered longest key
///    first (ICU alternation is leftmost-first among branches) with a
///    secondary comparison on the key itself, giving a TOTAL order that
///    cannot vary with `Dictionary`'s per-process hash seed or with
///    `sorted`'s instability.
/// 3. **Edge-aware boundaries.** `\b` requires a word character on that
///    side, so `"(?i)\b\(key)\b"` silently never matched `C++`, `.NET`,
///    `F#`, `/slash` or an emoji trigger. Each boundary is now chosen from
///    that key's own edge character.
/// 4. **Literal replacements.** The result is assembled from match ranges,
///    so the stored text is spliced in verbatim — there is no template
///    interpretation anywhere and `$1` is just two characters.
enum PhraseReplacer {

    /// Replaces every occurrence of any key with its value, matching
    /// case-insensitively and inserting the stored value exactly as saved.
    ///
    /// Keys that are empty or whitespace-only are ignored. If no usable
    /// keys remain — or the combined pattern fails to compile — the input
    /// is returned unchanged.
    static func replace(
        in text: String, using entries: [(key: String, value: String)]
    ) -> String {
        guard !text.isEmpty else { return text }

        // Total ordering: longest key first (so longer phrases win over the
        // shorter phrases nested inside them), then by key, then by value.
        // The last two comparisons exist purely so the order can never
        // differ between processes.
        let ordered = entries
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
                if $0.key != $1.key { return $0.key < $1.key }
                return $0.value < $1.value
            }
        guard !ordered.isEmpty else { return text }

        // Replacements are looked up by the LOWERCASED matched text, which
        // is what lets a spoken "iphone" pick up the stored "iPhone" casing.
        var replacements: [String: String] = [:]
        var branches: [String] = []
        for entry in ordered {
            let lowered = entry.key.lowercased()
            // First in the total order wins if two keys differ only by case.
            guard replacements[lowered] == nil else { continue }
            replacements[lowered] = entry.value
            branches.append(pattern(for: entry.key))
        }

        let combined = "(?i)(?:" + branches.joined(separator: "|") + ")"
        guard let regex = try? NSRegularExpression(pattern: combined) else {
            return text
        }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let matched = String(text[range])
            // Spliced in literally — no template/backreference interpretation.
            result += replacements[matched.lowercased()] ?? matched
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Convenience overload for the personal dictionary.
    static func replace(in text: String, using dictionary: [String: String]) -> String {
        replace(in: text, using: dictionary.map { (key: $0.key, value: $0.value) })
    }

    // MARK: - Pattern construction

    /// One alternation branch: the escaped key wrapped in boundaries chosen
    /// from its own edge characters. A key that starts or ends with a
    /// non-word character (`C++`, `.NET`, `@here`, an emoji) gets a
    /// "not preceded/followed by a word character" lookaround, because `\b`
    /// there would demand a word character that the key does not have.
    private static func pattern(for key: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let leading = key.first.map(isWordCharacter) == true ? "\\b" : "(?<!\\w)"
        let trailing = key.last.map(isWordCharacter) == true ? "\\b" : "(?!\\w)"
        return leading + escaped + trailing
    }

    /// Mirrors ICU's `\w` closely enough for edge detection.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
