import Foundation

/// Rule-based cleanup of raw transcripts: filler removal, spoken layout
/// commands, spacing/capitalization fixes, and personal-dictionary
/// substitutions. Mirrors Wispr Flow's "AI edits" with local rules.
struct TextFormatter {
    private static let dictionaryCache = PersistentCache<[String: String]>()

    /// Filler words removed when they appear as standalone tokens
    /// (English; see `languageRules` for other languages).
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ehm", "mhm", "hmm",
    ]

    /// Per-language cleanup rules: filler tokens removed as standalone
    /// words, plus regex sources for the spoken layout commands.
    private struct LanguageRules {
        var fillers: Set<String>
        var newLineCommand: String
        var newParagraphCommand: String
    }

    /// English keeps its optional-space "newline" spelling, hence the
    /// regex fragment rather than a plain phrase.
    private static let languageRules: [String: LanguageRules] = [
        "en": LanguageRules(
            fillers: fillers,
            newLineCommand: "new ?line",
            newParagraphCommand: "new paragraph"),
        "es": LanguageRules(
            fillers: ["eh", "este", "o sea", "mmm"],
            newLineCommand: "nueva línea",
            newParagraphCommand: "nuevo párrafo"),
        "fr": LanguageRules(
            fillers: ["euh", "ben", "quoi"],
            newLineCommand: "nouvelle ligne",
            newParagraphCommand: "nouveau paragraphe"),
        "de": LanguageRules(
            fillers: ["ähm", "äh", "also"],
            newLineCommand: "neue Zeile",
            newParagraphCommand: "neuer Absatz"),
        "it": LanguageRules(
            fillers: ["ehm", "insomma"],
            newLineCommand: "nuova riga",
            newParagraphCommand: "nuovo paragrafo"),
        "pt": LanguageRules(
            fillers: ["éh", "tipo", "né"],
            newLineCommand: "nova linha",
            newParagraphCommand: "novo parágrafo"),
    ]

    /// Resolves a locale to a supported language key, falling back to
    /// English rules for nil or unsupported language codes.
    private static func rules(for locale: Locale?) -> LanguageRules {
        guard let code = locale?.language.languageCode?.identifier,
              let rules = languageRules[code.lowercased()]
        else { return languageRules["en"]! }
        return rules
    }

    // MARK: - Deliberate symbol & layout tokens

    /// Spoken forms mapped to the glyph they produce. Matching builds a
    /// longest-first alternation (see `escapedAlternation`), so list order
    /// here is only for readability — "open parenthesis" always wins over
    /// any shorter overlapping form.
    private static let symbolTokens: [(spoken: String, symbol: String)] = [
        ("open parenthesis", "("), ("close parenthesis", ")"),
        ("open square bracket", "["), ("close square bracket", "]"),
        ("exclamation mark", "!"), ("exclamation point", "!"),
        ("open paren", "("), ("close paren", ")"),
        ("open bracket", "["), ("close bracket", "]"),
        ("open quote", "\u{201C}"), ("close quote", "\u{201D}"),
        ("forward slash", "/"), ("full stop", "."),
        ("question mark", "?"), ("ampersand", "&"), ("and sign", "&"),
        ("at sign", "@"), ("hash sign", "#"), ("pound sign", "#"),
        ("plus sign", "+"), ("equals sign", "="), ("equal sign", "="),
        ("dollar sign", "$"),
        ("colon", ":"), ("semicolon", ";"), ("comma", ","),
        ("period", "."), ("percent", "%"), ("asterisk", "*"),
        ("star", "*"), ("underscore", "_"), ("hyphen", "-"),
        ("dash", "-"),
    ]

    private static let symbolLookup: [String: String] = Dictionary(
        symbolTokens.map { ($0.spoken.lowercased(), $0.symbol) },
        uniquingKeysWith: { first, _ in first })

    /// Common collocations where a token word is meant literally. Shielded
    /// during the symbol pass so "period piece" survives while a lone
    /// "period" still converts. Kept short on purpose: an over-eager list
    /// silently disables real commands. Extend as field data warrants.
    private static let protectedPhrases = [
        "cooling off period", "grace period", "trial period",
        "time period", "waiting period", "period piece",
        "movie star", "rock star", "rising star", "guest star",
        "all star", "one star", "two star", "three star", "four star",
        "five star", "dash board",
    ]

    private static let protectedPhraseRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(?i)\\b(\(escapedAlternation(protectedPhrases)))\\b")
    }()

    /// Words the "literally <token>" escape hatch protects from conversion:
    /// every spoken symbol form plus the layout words themselves.
    private static var escapeHatchVocabulary: [String] {
        symbolTokens.map(\.spoken) + ["bullet point", "bullet", "tab key", "tab"]
    }

    /// One combined scan for symbols, bullets, tabs and the escape hatch.
    /// A single pass matters: replacements are never rescanned, so the
    /// word "comma" emitted by "literally comma" cannot be re-converted
    /// by its own rule later in the same scan.
    private static let symbolLayoutRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern:
                "(?i)\\bliterally\\s+(?<lit>\(escapedAlternation(escapeHatchVocabulary)))\\b" +
                // A bullet opens an item only at the start of the utterance
                // or right after a line break; elsewhere it stays a word.
                "|(?<pre>^|\\n)[ \t]*(?<bul>bullet point|bullet)\\b" +
                "|[ \t]*\\b(?<tab>tab key|tab)\\b[ \t]*" +
                "|\\b(?<sym>\(escapedAlternation(symbolTokens.map(\.spoken))))\\b")
    }()

    /// Sorts spoken forms longest-first and joins them into one regex
    /// alternation, so multi-word forms win against shorter overlaps.
    private static func escapedAlternation(_ forms: [String]) -> String {
        forms
            .sorted { a, b in
                let wa = a.split(separator: " ").count
                let wb = b.split(separator: " ").count
                if wa != wb { return wa > wb }
                if a.count != b.count { return a.count > b.count }
                return a < b
            }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression,
        transform: (_ match: NSTextCheckingResult, _ source: String) -> String?
    ) -> String {
        let matches = regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[cursor..<range.lowerBound]
            out += transform(match, text) ?? String(text[range])
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    private static func group(
        _ name: String, of match: NSTextCheckingResult, in source: String
    ) -> Substring? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let r = Range(range, in: source)
        else { return nil }
        return source[r]
    }

    /// Replaces every protected collocation with an opaque placeholder.
    /// The placeholder removes the words entirely — unlike merely wrapping
    /// them, which would still expose inner words to any `\b`-anchored
    /// matcher (the personal dictionary included). Returns the masked text
    /// plus the original spans for `unmaskProtectedPhrases`.
    private static func maskProtectedPhrases(
        in text: String
    ) -> (masked: String, store: [String]) {
        var store: [String] = []
        let masked = replaceMatches(in: text, regex: protectedPhraseRegex) { match, source in
            guard let r = Range(match.range, in: source) else { return nil }
            let placeholder = "\u{E000}\(store.count)\u{E001}"
            store.append(String(source[r]))
            return placeholder
        }
        return (masked, store)
    }

    private static func unmaskProtectedPhrases(
        from text: String, store: [String]
    ) -> String {
        guard !store.isEmpty else { return text }
        return replaceMatches(
            in: text,
            regex: try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
        ) { match, source in
            guard let r = Range(match.range(at: 1), in: source),
                  let index = Int(source[r]),
                  index < store.count else { return nil }
            return store[index]
        }
    }

    /// Converts spoken punctuation and layout tokens in one left-to-right
    /// scan. Every branch below is a spoken-command conversion — there is
    /// no neutral formatting mixed in (spacing is left to
    /// `tidyWhitespaceAndPunctuation`), so callers gate the whole call on
    /// the "Spoken symbols" setting rather than gating it piecemeal:
    ///
    /// - symbol tokens ("comma" → ",", "open paren" → "(" …);
    /// - "bullet"/"bullet point" opens a "- " item at the start of the
    ///   utterance or right after a line break;
    /// - "tab key"/"tab" inserts a literal tab (trailing spaces consumed);
    /// - "literally <token>" emits the word form with no conversion;
    /// - `protectedPhrases` collocations are shielded from conversion.
    ///
    /// Spacing is deliberately left to `tidyWhitespaceAndPunctuation`
    /// (no space before closing glyphs, none after opening ones).
    func applySymbolsAndLayout(to text: String) -> String {
        let (masked, maskStore) = Self.maskProtectedPhrases(in: text)
        let converted = Self.replaceMatches(
            in: masked, regex: Self.symbolLayoutRegex
        ) { match, source in
            if let literal = Self.group("lit", of: match, in: source) {
                return String(literal)
            }
            if Self.group("bul", of: match, in: source) != nil {
                let prefix = Self.group("pre", of: match, in: source) ?? ""
                return prefix + "- "
            }
            if Self.group("tab", of: match, in: source) != nil {
                return "\t"
            }
            if let spoken = Self.group("sym", of: match, in: source),
               let glyph = Self.symbolLookup[spoken.lowercased()] {
                return glyph
            }
            return nil
        }
        return Self.unmaskProtectedPhrases(from: converted, store: maskStore)
    }

    // MARK: - Spoken amounts

    /// Number words understood by the amount parser, including scale words.
    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
        "ninety": 90, "hundred": 100, "thousand": 1_000,
        "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// A contiguous amount: EITHER bare digits ("75", "1,250") OR a run of
    /// number words (optional leading "a"/"an", hyphenated compounds,
    /// British "and"). The two shapes deliberately never mix — letting a
    /// digit-led run continue into words would make "<n> dollars" swallow
    /// a following "<m> cents" spoken without "and". Group names are
    /// injected by callers because ICU forbids duplicate capture names.
    private static func amount(named name: String) -> String {
        let word = escapedAlternation(Array(numberWords.keys))
        return "(?<\(name)>[0-9][0-9,]*" +
            "|(?:(?:a|an)[ \t-]+)?(?:\(word))(?:[ \t-]+(?:and[ \t-]+)?(?:\(word)))*)"
    }

    private static let percentRegex = try! NSRegularExpression(
        pattern: "(?i)\\b\(amount(named: "amt"))[ \t]+percent\\b")

    private static let dollarsRegex = try! NSRegularExpression(
        pattern: "(?i)\\b\(amount(named: "amt"))[ \t]+dollars?" +
            "(?:[ \t]+and[ \t]+\(amount(named: "cents"))[ \t]+cents?)?\\b")

    private static let centsRegex = try! NSRegularExpression(
        pattern: "(?i)\\b\(amount(named: "amt"))[ \t]+cents?\\b")

    private static let eurosRegex = try! NSRegularExpression(
        pattern: "(?i)\\b\(amount(named: "amt"))[ \t]+euros?\\b")

    private static let storageRegex = try! NSRegularExpression(
        pattern: "(?i)\\b\(amount(named: "amt"))[ \t]+" +
            "(?<unit>terabytes?|gigabytes?|gigs?|megabytes?|megs?|kilobytes?)\\b")

    /// Parses a spoken amount ("twenty five", "one hundred and five",
    /// "1,250", "hundred") into an integer; nil when nothing numeric
    /// remains after tokenizing.
    static func parseAmount(_ text: some StringProtocol) -> Int? {
        let flattened = String(text).replacingOccurrences(of: ",", with: "")
        var total = 0
        var current = 0
        var sawAny = false
        for raw in flattened.split(whereSeparator: { [" ", "\t", "-"].contains($0) }) {
            let word = raw.lowercased()
            if word == "and" { continue }
            if let digits = Int(word) {
                current = digits
                sawAny = true
                continue
            }
            guard let value = numberWords[word] else { return nil }
            sawAny = true
            switch value {
            case 100:
                current = max(current, 1) * 100
            case 1_000, 1_000_000, 1_000_000_000:
                total += max(current, 1) * value
                current = 0
            default:
                current += value
            }
        }
        return sawAny ? total + current : nil
    }

    private static func money(_ dollars: Int, _ cents: Int) -> String {
        let whole = dollars + cents / 100
        let fraction = cents % 100
        return fraction == 0
            ? "$\(whole)"
            : "$\(whole)." + String(format: "%02d", fraction)
    }

    /// Converts spoken money/percentage/storage amounts into symbolic form:
    /// "fifty dollars [and twenty-five cents]" → "$50[.25]",
    /// "seventy five cents" alone → "$0.75", "twenty euros" → "€20",
    /// "fifty percent" → "50%", "two gigs" → "2 GB".
    ///
    /// Runs on the cleaned stops ONLY — at Verbatim numbers stay words
    /// (percent still lands as "%" via the symbol pass + tidy glue).
    /// "Pounds" is deliberately not converted: weight vs currency is
    /// undecidable from audio alone.
    func applyNumbersAndCurrency(to text: String) -> String {
        var result = text
        // Percent first so "<n> percent" never leaks a bare "%" conversion.
        result = Self.replaceMatches(in: result, regex: Self.percentRegex) { m, src in
            guard let amt = Self.group("amt", of: m, in: src),
                  let value = Self.parseAmount(amt) else { return nil }
            return "\(value)%"
        }
        result = Self.replaceMatches(in: result, regex: Self.dollarsRegex) { m, src in
            guard let amt = Self.group("amt", of: m, in: src),
                  let dollars = Self.parseAmount(amt) else { return nil }
            let cents = Self.group("cents", of: m, in: src)
                .flatMap { Self.parseAmount($0) } ?? 0
            return Self.money(dollars, cents)
        }
        result = Self.replaceMatches(in: result, regex: Self.centsRegex) { m, src in
            guard let amt = Self.group("amt", of: m, in: src),
                  let cents = Self.parseAmount(amt) else { return nil }
            return Self.money(0, cents)
        }
        result = Self.replaceMatches(in: result, regex: Self.eurosRegex) { m, src in
            guard let amt = Self.group("amt", of: m, in: src),
                  let value = Self.parseAmount(amt) else { return nil }
            return "€\(value)"
        }
        result = Self.replaceMatches(in: result, regex: Self.storageRegex) { m, src in
            guard let amt = Self.group("amt", of: m, in: src),
                  let value = Self.parseAmount(amt),
                  let unit = Self.group("unit", of: m, in: src) else { return nil }
            switch unit.lowercased() {
            case "terabyte", "terabytes": return "\(value) TB"
            case "gigabyte", "gigabytes", "gig", "gigs": return "\(value) GB"
            case "megabyte", "megabytes", "meg", "megs": return "\(value) MB"
            default: return "\(value) KB"
            }
        }
        return result
    }

    var dictionary: [String: String]

    private let rules: LanguageRules

    init(
        dictionary: [String: String] = TextFormatter.loadDictionary(),
        locale: Locale? = nil
    ) {
        self.dictionary = dictionary
        self.rules = Self.rules(for: locale)
    }

    static var dictionaryURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("dictionary.json")
    }

    static func loadDictionary() -> [String: String] {
        (try? dictionaryCache.load(from: dictionaryURL)) ?? [:]
    }

    /// - Parameters:
    ///   - autoPeriod: append a terminal period when none was spoken.
    ///   - spokenLayout: honor "new line"/"new paragraph" as real breaks.
    ///   - spokenSymbols: honor spoken punctuation/symbol tokens
    ///     ("comma" → ",", "star" → "*"). Off by default.
    ///     All three are threaded in explicitly rather than read from
    ///     Settings inside, so the function stays pure and deterministic
    ///     in tests.
    func format(
        _ raw: String,
        autoPeriod: Bool = Settings.autoPeriod,
        spokenLayout: Bool = Settings.spokenLayout,
        spokenSymbols: Bool = Settings.spokenSymbols,
        joinFragments: Bool = Settings.joinFragments
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        text = removeFillers(from: text)
        // Deliberately this early: every period in the text is still one the
        // recognizer produced. Run any later and the pass could delete
        // punctuation the user dictated on purpose — a spoken "period", or a
        // dictionary entry whose value is one — which would be exactly the
        // kind of second-guessing this app must never do.
        if joinFragments {
            text = joinPauseFragments(in: text)
        }
        if spokenLayout {
            text = applySpokenCommands(to: text)
        }
        // Amounts resolve BEFORE symbol tokens so the "percent" inside
        // "fifty percent" is consumed as part of the amount; a bare
        // "percent" elsewhere still falls through to the "%" glyph.
        text = applyNumbersAndCurrency(to: text)
        if spokenSymbols {
            text = applySymbolsAndLayout(to: text)
        }
        // Protected collocations stay shielded through the dictionary pass
        // too: a personal entry like "period" -> "." must not eat the
        // words a protection just saved.
        let (dictionaryMasked, dictionaryMask) = Self.maskProtectedPhrases(in: text)
        text = applyDictionary(to: dictionaryMasked)
        text = Self.unmaskProtectedPhrases(from: text, store: dictionaryMask)
        // Dictionary output has to flow through the remaining passes: tidying
        // fixes the spacing left by punctuation-only values ("period" -> "."),
        // and capitalization fixes normalization values that land at a
        // sentence start ("gonna" -> "going to"). Deliberately-cased values
        // like "iPhone" are protected inside capitalizeSentences itself.
        text = tidyWhitespaceAndPunctuation(in: text)
        text = capitalizeSentences(in: text)
        if autoPeriod {
            text = ensureTerminalPunctuation(in: text)
        }
        return text
    }

    /// Cleanup stop `.verbatim`: exactly what was spoken except deliberate
    /// user intents stay active — personal dictionary substitutions apply,
    /// and spoken layout commands ("new line"/"new paragraph") apply while
    /// `spokenLayout` is on (the "Spoken layout" setting, on by default).
    /// Spoken *symbol* tokens ("comma" → ",") are a separate opt-in and
    /// are off at every stop unless the user turns them on.
    /// Filler words are retained, and neither auto-capitalization nor a
    /// terminal period is ever added. Snippet triggers run separately in
    /// the dictation pipeline, so they remain active by construction.
    func formatVerbatim(
        _ raw: String,
        spokenLayout: Bool = Settings.spokenLayout,
        spokenSymbols: Bool = Settings.spokenSymbols
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        if spokenLayout {
            text = applySpokenCommands(to: text)
        }
        // Symbol/layout tokens stay active even verbatim while the user
        // has opted in; spoken amounts intentionally never do — numbers
        // stay words at this stop.
        if spokenSymbols {
            text = applySymbolsAndLayout(to: text)
        }
        let (dictionaryMasked, dictionaryMask) = Self.maskProtectedPhrases(in: text)
        text = applyDictionary(to: dictionaryMasked)
        text = Self.unmaskProtectedPhrases(from: text, store: dictionaryMask)
        // Dictionary output flows through the whitespace/punctuation tidy
        // exactly as in format(): punctuation-only values ("period" -> ".")
        // must not leave stray spaces behind. That pass never alters words,
        // casing, or terminal punctuation, so the transcript stays verbatim.
        text = tidyWhitespaceAndPunctuation(in: text)
        return text
    }

    // MARK: - Passes

    private func removeFillers(from text: String) -> String {
        var result = text
        for filler in rules.fillers {
            // Filler optionally followed by a comma, as its own word.
            let token = NSRegularExpression.escapedPattern(for: filler)
            let pattern = "(?i)(^|\\s)\(token)[,.]?(?=\\s|$)"
            result = result.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    private func applySpokenCommands(to text: String) -> String {
        var result = text
        let commands: [(pattern: String, replacement: String)] = [
            ("(?i)[,.]?\\s*\\b\(rules.newParagraphCommand)[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\b\(rules.newLineCommand)[,.]?\\s*", "\n"),
        ]
        for command in commands {
            result = result.replacingOccurrences(
                of: command.pattern, with: command.replacement,
                options: .regularExpression)
        }
        return result
    }

    private func applyDictionary(to text: String) -> String {
        // One pass over the original text: no entry can rewrite what another
        // entry just inserted, longest spoken form wins deterministically,
        // and terms with non-word edges (C++, .NET) actually match.
        PhraseReplacer.replace(in: text, using: dictionary)
    }

    private func tidyWhitespaceAndPunctuation(in text: String) -> String {
        var result = text
        // Collapse runs of spaces. Tabs survive: they are deliberate
        // layout output from "tab", including leading indentation.
        result = result.replacingOccurrences(
            of: " +", with: " ", options: .regularExpression)
        // Glue a hyphen between alphanumeric neighbours ("twenty - five"
        // -> "twenty-five"); a dash at a line edge is left alone.
        result = result.replacingOccurrences(
            of: "(?<=[0-9A-Za-z])[ \t]*-[ \t]*(?=[0-9A-Za-z])",
            with: "-", options: .regularExpression)
        // Slash and currency glue ("yes / no" -> "yes/no",
        // "$ 42" -> "$42", "# 42" -> "#42").
        result = result.replacingOccurrences(
            of: "(?<=/)[ \t]+|[ \t]+(?=/)", with: "",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(?<=[$#€])[ \t]+(?=[0-9A-Za-z(])", with: "",
            options: .regularExpression)
        // No space before closing punctuation — now including brackets,
        // curly closing quotes, percent and underscore.
        result = result.replacingOccurrences(
            of: " +([,.;:!?%)\\]}”’_])", with: "$1",
            options: .regularExpression)
        // No space after opening brackets/quotes/underscore.
        result = result.replacingOccurrences(
            of: "([(\\[{“‘_]) +", with: "$1", options: .regularExpression)
        // Speech recognition sometimes emits an ellipsis or repeats a
        // spoken period that it already inserted. Murmur uses explicit
        // sentence punctuation instead of dot runs, so keep one period.
        result = result.replacingOccurrences(
            of: "\\.{2,}", with: ".", options: .regularExpression)
        // Collapse duplicate punctuation like ",," or "??" left by the
        // recognizer when a spoken token lands beside its own punctuation.
        result = result.replacingOccurrences(
            of: "([,;:!?])\\1+", with: "$1", options: .regularExpression)
        // Trim each line — spaces only, so a leading tab keeps its indent.
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
            .joined(separator: "\n")
        // At most one blank line in a row.
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        // Overall trim, preserving deliberate leading/trailing tabs.
        return result.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
                .subtracting(CharacterSet(charactersIn: "\t")))
    }

    // MARK: - Pause-fragment joining

    /// Apple's transcriber punctuates from prosody, so an ordinary breath
    /// mid-sentence comes back as a sentence break: "Now it's the primary
    /// blender. Motor. For the whole kitchen." Three sentences, one
    /// of them a bare noun and one a bare prepositional phrase.
    ///
    /// This pass repairs those breaks and nothing else. It only ever
    /// deletes a period and lowercases the letter that followed it — no
    /// word is added, removed, reordered or reworded — so it cannot act on
    /// what was said, only on how it was punctuated.
    ///
    /// Line structure is preserved: a deliberate "new line"/"new paragraph"
    /// is a boundary no join crosses.
    private func joinPauseFragments(in text: String) -> String {
        text.components(separatedBy: "\n")
            .map { Self.joinFragments(inLine: $0) }
            .joined(separator: "\n")
    }

    /// Clause openers that almost always continue the thought before them in
    /// speech. A breath before one is not enough evidence for a new sentence;
    /// the whole clause is more useful than the recognizer's early guess.
    private static let continuationOpeners: Set<String> = [
        "and", "but", "or", "nor", "so", "yet", "plus", "because", "if",
        "when", "while", "although", "though", "unless", "until", "before",
        "after", "since", "as",
    ]

    /// Utterances that stand alone as a whole sentence, so a short verbless
    /// one is deliberate rather than a stray fragment.
    private static let standaloneUtterances: Set<String> = [
        "yes", "no", "yeah", "yep", "nope", "okay", "ok", "sure", "right",
        "exactly", "correct", "agreed", "true", "false", "maybe", "perhaps",
        "thanks", "thank", "please", "sorry", "hi", "hello", "hey", "bye",
        "nice", "great", "cool", "wow", "absolutely", "definitely", "done",
        "congrats", "congratulations", "good", "bad", "same", "either",
        "neither", "both", "anyway", "regardless", "understood", "noted",
    ]

    /// Words that routinely carry a sentence-ending period of their own, so
    /// the break after them is an abbreviation, not a sentence boundary.
    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "etc",
        "eg", "ie", "inc", "ltd", "co", "corp", "dept", "est", "approx",
        "min", "max", "no", "vol", "fig", "al", "am", "pm", "us", "uk",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
        "oct", "nov", "dec", "mon", "tue", "tues", "wed", "thu", "thur",
        "thurs", "fri", "sat", "sun",
    ]

    /// Finite verbs common enough in speech to settle the question cheaply.
    /// The list only has to answer "does this clause have a verb at all",
    /// and a miss is safe: an unrecognised verb means no join, which leaves
    /// the text exactly as dictated.
    private static let verbTokens: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being", "aint",
        "do", "does", "did", "done", "have", "has", "had", "having",
        "can", "cant", "could", "will", "wont", "would", "shall", "should",
        "may", "might", "must", "isnt", "arent", "wasnt", "werent",
        "dont", "doesnt", "didnt", "hasnt", "havent", "hadnt", "couldnt",
        "wouldnt", "shouldnt", "get", "gets", "got", "go", "goes", "went",
        "make", "makes", "made", "say", "says", "said", "think", "thinks",
        "know", "knows", "knew", "want", "wants", "need", "needs",
        "like", "likes", "see", "sees", "saw", "take", "takes", "took",
        "come", "comes", "came", "put", "puts", "let", "lets", "feel",
        "feels", "felt", "look", "looks", "work", "works", "use", "uses",
        "find", "finds", "found", "give", "gives", "gave", "tell", "tells",
        "told", "ask", "asks", "try", "tries", "call", "calls", "keep",
        "keeps", "kept", "start", "starts", "help", "helps", "seem",
        "seems", "run", "runs", "ran", "move", "moves", "live", "lives",
        "hope", "hopes", "love", "loves", "mean", "means", "meant",
        "pay", "pays", "paid", "send", "sends", "sent", "read", "reads",
        "write", "writes", "wrote", "buy", "buys", "bought", "sell",
        "sells", "sold", "hit", "set", "sets", "leave", "leaves", "left",
        "bring", "brings", "brought", "meet", "meets", "met", "wait",
        "waits", "sign", "signs", "cover", "covers", "handle", "handles",
        "run", "manage", "manages", "owe", "owes", "cost", "costs",
        "review", "reviews", "reviewed",
    ]

    /// Openers that leave a phrase stranded on the wrong side of a period.
    private static let prepositionOpeners: Set<String> = [
        "for", "with", "of", "at", "in", "on", "from", "by", "into", "onto",
        "about", "over", "under", "through", "during", "between", "among",
        "against", "toward", "towards", "across", "around", "per", "via",
        "up", "down", "out", "off", "near", "to", "without", "within",
        "upon", "besides", "beyond", "despite", "regarding", "than",
    ]

    /// A subject of its own makes a clause, and a clause can stand alone.
    private static let subjectPronouns: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it",
    ]

    /// Short discourse adverbs that are commonly stranded by a breath after
    /// a conjunction: "and. Really. Work on…". They are only eligible when
    /// the sentence before them is already visibly unfinished, so a deliberate
    /// standalone "Really." still survives.
    private static let continuationAdverbs: Set<String> = [
        "actually", "also", "basically", "especially", "even", "finally",
        "just", "literally", "maybe", "now", "probably", "really", "still",
        "then",
    ]

    /// A sentence-fragment opener that is usually an appositive or trailing
    /// time phrase when it follows a complete clause. This is intentionally
    /// narrower than all determiners: joining every "The …" fragment would
    /// erase deliberate noun-phrase sentences.
    private static let trailingNounPhraseOpeners: Set<String> = ["a", "an"]

    /// Stems whose "'s" is the verb "is", not a possessive.
    private static let contractiblePronouns: Set<String> = [
        "it", "that", "this", "there", "here", "he", "she", "what", "who",
        "where", "when", "how", "why", "one", "everyone", "someone",
        "something", "everything", "nothing", "nobody", "let", "he", "she",
    ]

    /// A clause with no finite verb is a fragment, so this is the test that
    /// decides whether a sentence can stand on its own.
    private static func isVerbLike(_ word: String) -> Bool {
        let lower = word.lowercased()
        if verbTokens.contains(lower) { return true }
        if let mark = lower.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) {
            let stem = String(lower[lower.startIndex..<mark])
            let suffix = String(lower[lower.index(after: mark)...])
            // "'m", "'re", "'ve", "'ll", "'d" are only ever a verb.
            if ["m", "re", "ve", "ll", "d"].contains(suffix) { return true }
            // "'s" is a verb after a pronoun ("it's") and a possessive
            // after a noun ("Sarah's").
            if suffix == "s", contractiblePronouns.contains(stem) { return true }
        }
        // Participles and past tenses, length-guarded so short nouns that
        // merely end in those letters ("bed", "ted", "ring") don't count.
        if lower.count >= 5, lower.hasSuffix("ing") || lower.hasSuffix("ed") {
            return true
        }
        return false
    }

    /// Participles and infinitives do not make a preposition-initial fragment
    /// an independent clause: "For the templates to be built" is still a
    /// continuation, while "On Monday we review it again" is not.
    private static func hasFiniteVerb(_ words: [String]) -> Bool {
        for (index, word) in words.enumerated() {
            guard isVerbLike(word) else { continue }
            let lower = word.lowercased()
            if lower == "be", index > 0, words[index - 1] == "to" {
                continue
            }
            if lower.hasSuffix("ing") || lower.hasSuffix("ed") {
                continue
            }
            return true
        }
        return false
    }

    /// Returns true when the preceding fragment visibly ends in an unfinished
    /// coordinator, or in a coordinator followed by a discourse adverb. This
    /// lets the repair pass follow a chain of breaths instead of stopping
    /// after the first repaired fragment.
    private static func hasOpenContinuationTail(_ words: [String]) -> Bool {
        guard let last = words.last else { return false }
        if continuationOpeners.contains(last) { return true }
        guard continuationAdverbs.contains(last), words.count > 1 else {
            return false
        }
        return continuationOpeners.contains(words[words.count - 2])
    }

    /// Time tails such as "an unmeasurable amount of time later" are noun
    /// phrases, not new thoughts. They are a safe continuation signal because
    /// the phrase itself contains no finite verb.
    private static func isTrailingTimePhrase(_ words: [String]) -> Bool {
        guard let last = words.last else { return false }
        return ["later", "today", "tomorrow", "yesterday", "tonight"].contains(last)
    }

    /// A prepositional opener can contain a coordinated clause of its own:
    /// "For the templates to be built, but it will save us." The first
    /// phrase is still attached to the sentence before it, so the period
    /// before "For" is the recognizer's false boundary.
    private static func hasPrefixedPrepositionalClause(_ text: String) -> Bool {
        guard let comma = text.firstIndex(of: ",") else { return false }
        let prefix = String(text[..<comma])
        let prefixWords = wordTokens(prefix)
        guard prefixWords.count <= 8,
              let opener = prefixWords.first,
              prepositionOpeners.contains(opener),
              !hasFiniteVerb(prefixWords) else { return false }
        let remainder = text[text.index(after: comma)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return continuationOpeners.contains {
            remainder == $0 || remainder.hasPrefix("\($0) ")
        }
    }

    /// Lowercased words of a sentence, stripped of edge punctuation.
    private static func wordTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet.alphanumerics.union(
                        CharacterSet(charactersIn: "'\u{2019}-")).inverted)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    /// Splits a line after every sentence mark that is followed by whitespace,
    /// keeping each mark with the text before it and each run of
    /// whitespace as that piece's trailing separator, so a line that is
    /// left unjoined is reassembled byte for byte.
    private static func sentencePieces(_ line: String) -> [(text: String, separator: String)] {
        let text = line as NSString
        guard let regex = try? NSRegularExpression(pattern: "[.!?][ \\t]+") else {
            return [(line, "")]
        }
        var pieces: [(text: String, separator: String)] = []
        var start = 0
        for match in regex.matches(
            in: line, range: NSRange(location: 0, length: text.length)) {
            let markEnd = match.range.location + 1
            pieces.append((
                text: text.substring(with: NSRange(
                    location: start, length: markEnd - start)),
                separator: text.substring(with: NSRange(
                    location: markEnd,
                    length: match.range.location + match.range.length - markEnd))))
            start = match.range.location + match.range.length
        }
        pieces.append((text: text.substring(from: start), separator: ""))
        return pieces
    }

    /// Whether the sentence mark between `previous` and `next` is a pause the
    /// recognizer punctuated rather than a real sentence boundary. Speech
    /// recognition can emit `?` for a rising intonation before a speaker
    /// finishes the same question ("What should we fix? On the website?").
    static func shouldJoin(previous: String, next: String) -> Bool {
        guard let terminator = previous.last,
              ".!?".contains(terminator), !next.isEmpty else { return false }
        let stem = previous.dropLast()
        // An ellipsis is deliberate; a decimal or an initial is not a
        // sentence end at all. Abbreviation checks only apply to periods —
        // a question/exclamation mark cannot be part of "Dr." or "etc.".
        if terminator == "." {
            guard let tail = stem.last, tail != "." else { return false }
        }
        guard let lastWord = Self.wordTokens(String(stem)).last else { return false }
        guard lastWord.count > 1 else { return false }
        if terminator == ".", Self.abbreviations.contains(lastWord) {
            return false
        }
        // A recognizer that inserts a period capitalizes the word after it,
        // so a lowercase opener means this break did not come from the
        // recognizer's own punctuation and is none of our business.
        guard let firstLetter = next.first(where: { $0.isLetter }),
              firstLetter.isUppercase
        else { return false }
        let words = Self.wordTokens(next)
        guard let opener = words.first else { return false }
        guard !Self.standaloneUtterances.contains(opener) else { return false }
        if Self.continuationOpeners.contains(opener) { return true }

        // A breath can split a continuation more than once. Once a prior
        // fragment ends in "and" or "and really", keep following a short
        // adverb/verb fragment so "and. Really. Work on…" becomes one thought.
        if Self.hasOpenContinuationTail(Self.wordTokens(String(stem))) {
            if Self.continuationAdverbs.contains(opener)
                || Self.isVerbLike(opener)
                || Self.prepositionOpeners.contains(opener) {
                return true
            }
        }
        if Self.prepositionOpeners.contains(opener) {
            // A stranded phrase: "For the whole kitchen." It cannot be a
            // sentence, so join it — but only while it is short enough to be
            // one breath's worth, which keeps real preposition-initial
            // sentences ("On Monday we review the numbers again.") intact.
            // Participles/infinitives do not make the fragment independent:
            // "For the templates to be built" is still a continuation.
            if words.count <= 8, !Self.hasFiniteVerb(words) {
                return !words.contains(where: Self.subjectPronouns.contains)
            }
            return Self.hasPrefixedPrepositionalClause(next)
        }
        // Otherwise the fragment has to have no finite verb and no subject
        // of its own: both are marks of a clause that can stand alone, and
        // "Best purchase this year." is a real sentence even though it has
        // neither a verb nor a subject — which is why shape and length
        // decide the rest.
        guard !words.contains(where: Self.isVerbLike) else { return false }
        guard !words.contains(where: Self.subjectPronouns.contains) else {
            return false
        }
        if Self.isTrailingTimePhrase(words),
           Self.trailingNounPhraseOpeners.contains(opener) {
            return terminator == "."
        }
        // A bare noun with nothing hanging off it: "Manager.",
        // "The manager." Anything longer reads as a deliberate
        // noun-phrase sentence and is left alone.
        // Do not apply this permissive period rule after a question or
        // exclamation: "Who runs it? Manager." is a real two-part exchange,
        // while a question's continuation is handled by a clause/preposition
        // opener above.
        return terminator == "." && words.count <= 2
    }

    /// Joins `next` onto `previous`, dropping the period between them and
    /// lowercasing the letter it had capitalized.
    static func joined(previous: String, next: String) -> String {
        var opener = next
        if let first = opener.first, first.isUppercase,
           !Self.isIFamily(next), !Self.hasInteriorUppercase(next) {
            opener.replaceSubrange(
                opener.startIndex...opener.startIndex, with: first.lowercased())
        }
        return String(previous.dropLast()) + " " + opener
    }

    /// "I" and its contractions keep their capital wherever they land.
    private static func isIFamily(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        else { return false }
        let letters = word.lowercased().prefix { $0.isLetter }
        guard letters == "i" else { return false }
        let rest = word.dropFirst(letters.count)
        return rest.isEmpty || rest.first == "'" || rest.first == "\u{2019}"
            || !rest.first!.isLetter
    }

    /// A token cased on purpose — iPhone, eBay, macOS — keeps its casing,
    /// mirroring the protection in `capitalizeSentences`.
    private static func hasInteriorUppercase(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
        else { return false }
        return word.dropFirst().contains { $0.isUppercase }
    }

    static func joinFragments(inLine line: String) -> String {
        let pieces = sentencePieces(line)
        guard pieces.count > 1 else { return line }
        var result = pieces[0].text
        var separator = pieces[0].separator
        for piece in pieces.dropFirst() {
            if shouldJoin(previous: result, next: piece.text) {
                result = joined(previous: result, next: piece.text)
            } else {
                result += separator + piece.text
            }
            separator = piece.separator
        }
        return result + separator
    }

    private func capitalizeSentences(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var characters = Array(text)
        var capitalizeNext = true
        for index in characters.indices {
            let character = characters[index]
            if capitalizeNext, character.isLetter {
                // A token carrying an uppercase letter anywhere after its
                // first character is deliberately cased -- iPhone, eBay,
                // iOS, macOS, gRPC -- so leave it exactly as written. This
                // needs no dictionary knowledge, so it also protects
                // learned corrections and snippet expansions, which are
                // applied later in the pipeline.
                if !Self.isDeliberatelyCasedToken(in: characters, startingAt: index) {
                    characters[index] = Character(character.uppercased())
                }
                capitalizeNext = false
            } else if ".!?\n".contains(character) {
                capitalizeNext = true
            } else if !character.isWhitespace,
                      !Self.capitalizationTransparent.contains(character) {
                capitalizeNext = false
            }
        }
        return String(characters)
    }

    /// Glyphs that neither trigger nor cancel pending capitalization:
    /// symbol-token output (dash, star, currency…), brackets and quotes —
    /// so "- item" bullets, "(aside)" asides and “quoted” speech inherit
    /// natural sentence casing across the glyph.
    private static let capitalizationTransparent =
        "-*/_[](){}“”‘’\"'$%&+=@#€"

    /// Looks ahead at the whole alphanumeric token beginning at `start` and
    /// reports whether it contains an uppercase letter after its first
    /// character.
    private static func isDeliberatelyCasedToken(
        in characters: [Character], startingAt start: Int) -> Bool {
        var index = characters.index(after: start)
        while index < characters.endIndex {
            let character = characters[index]
            guard character.isLetter || character.isNumber else { break }
            if character.isUppercase { return true }
            index += 1
        }
        return false
    }

    private func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber {
            return text + "."
        }
        return text
    }

    // MARK: - Self test

    /// Smoke test for the shipped binary, reachable as `Murmur --selftest`.
    ///
    /// Deliberately thin. The XCTest suite owns this formatter's edge cases
    /// and runs against the test bundle; the only thing it cannot check is
    /// that the pipeline inside a packaged, signed build still runs end to
    /// end. So this is one case per pass, not a second copy of the suite.
    /// When a case here fails, the unit tests are where to look.
    static func runSelfTest() -> Bool {
        var passed = true

        func check(_ formatter: TextFormatter, _ input: String, _ expected: String) {
            let got = formatter.format(
                input, autoPeriod: true, spokenLayout: true,
                spokenSymbols: true, joinFragments: true)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \"\(input)\" -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(expected)\")"))
        }

        // "see plus plus" also proves the replacer matches terms whose edges
        // are not word characters, which a hardcoded \b never would.
        let formatter = TextFormatter(dictionary: [
            "jira": "Jira", "see plus plus": "C++",
        ])
        let cases: [(input: String, expected: String)] = [
            ("um hello world", "Hello world."),
            ("first line new line second line", "First line\nSecond line."),
            ("file a ticket in jira today", "File a ticket in Jira today."),
            ("i love see plus plus", "I love C++"),
            ("hello comma world period", "Hello, world."),
            ("it costs fifty dollars", "It costs $50."),
            ("  spaced   out   words ", "Spaced out words."),
            ("", ""),
        ]
        for testCase in cases {
            check(formatter, testCase.input, testCase.expected)
        }
        return passed
    }
}
