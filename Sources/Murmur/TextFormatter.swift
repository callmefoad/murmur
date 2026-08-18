import Foundation

/// Rule-based cleanup of raw transcripts: filler removal, spoken layout
/// commands, spacing/capitalization fixes, and personal-dictionary
/// substitutions. Mirrors Wispr Flow's "AI edits" with local rules.
struct TextFormatter {

    /// Filler words removed when they appear as standalone tokens.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ehm", "mhm", "hmm",
    ]

    var dictionary: [String: String]

    init(dictionary: [String: String] = TextFormatter.loadDictionary()) {
        self.dictionary = dictionary
    }

    static var dictionaryURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("dictionary.json")
    }

    static func loadDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: dictionaryURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    func format(_ raw: String, autoPeriod: Bool = Settings.autoPeriod) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        text = removeFillers(from: text)
        text = applySpokenCommands(to: text)
        text = applyDictionary(to: text)
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

    // MARK: - Passes

    private func removeFillers(from text: String) -> String {
        var result = text
        for filler in Self.fillers {
            // Filler optionally followed by a comma, as its own word.
            let pattern = "(?i)(^|\\s)\(filler)[,.]?(?=\\s|$)"
            result = result.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    private func applySpokenCommands(to text: String) -> String {
        var result = text
        let commands: [(pattern: String, replacement: String)] = [
            ("(?i)[,.]?\\s*\\bnew paragraph[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\bnew ?line[,.]?\\s*", "\n"),
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
        // Collapse runs of spaces/tabs (not newlines).
        result = result.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        result = result.replacingOccurrences(
            of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        // Collapse duplicate punctuation like ",." or ".." left by edits.
        result = result.replacingOccurrences(
            of: "([,.;:!?])[,.]", with: "$1", options: .regularExpression)
        // Trim each line.
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // At most one blank line in a row.
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            } else if !character.isWhitespace, !"\"'([{".contains(character) {
                capitalizeNext = false
            }
        }
        return String(characters)
    }

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

    static func runSelfTest() -> Bool {
        var passed = true

        func check(_ formatter: TextFormatter, _ input: String, _ expected: String) {
            let got = formatter.format(input, autoPeriod: true)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \"\(input)\" -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(expected)\")"))
        }

        func checkReplacer(
            _ entries: [(key: String, value: String)],
            _ input: String, _ expected: String) {
            let got = PhraseReplacer.replace(in: input, using: entries)
            let ok = got == expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): replace(\"\(input)\") -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(expected)\")"))
        }

        let formatter = TextFormatter(dictionary: [
            "jira": "Jira",
            "claude code": "Claude Code",
            // Literal "$" in the replacement: proves the replacement is
            // spliced in verbatim and never read as a regex template.
            "five dollars": "cost is $5",
            // Deliberately camelCased value: proves capitalizeSentences
            // leaves an already-cased token alone at a sentence start.
            "iphone": "iPhone",
            // Normalization-style value: proves the dictionary still runs
            // BEFORE capitalization, so a sentence start gets capitalized.
            "gonna": "going to",
            // Punctuation-only value: proves the dictionary still runs
            // BEFORE tidying, so no stray space is left behind.
            "period": ".",
            // Non-word edges: \b would never have matched these.
            "see plus plus": "C++",
        ])
        let cases: [(input: String, expected: String)] = [
            ("um hello world", "Hello world."),
            ("this is, uh, a test", "This is, a test."),
            ("first line new line second line", "First line\nSecond line."),
            ("intro new paragraph details here", "Intro\n\nDetails here."),
            ("file a ticket in jira today", "File a ticket in Jira today."),
            ("i use claude code daily", "I use Claude Code daily."),
            ("hello world. this is fine", "Hello world. This is fine."),
            ("  spaced   out   words ", "Spaced out words."),
            ("already punctuated!", "Already punctuated!"),
            ("", ""),
            ("the five dollars total", "The cost is $5 total."),
            ("iphone is great", "iPhone is great."),
            ("gonna be late", "Going to be late."),
            ("hello period", "Hello."),
            ("i love see plus plus", "I love C++"),
        ]
        for testCase in cases {
            check(formatter, testCase.input, testCase.expected)
        }

        // A later entry must never rewrite what an earlier entry inserted.
        check(
            TextFormatter(dictionary: [
                "jira ticket": "Jira ticket", "ticket": "TICKET",
            ]),
            "File a jira ticket today", "File a Jira ticket today.")

        // Equal-length keys: the total ordering must give the same answer
        // in every process, whatever the dictionary's hash seed happens
        // to be. Run the binary repeatedly to confirm.
        check(
            TextFormatter(dictionary: [
                "big apple": "NYC", "apple pie": "dessert",
            ]),
            "big apple pie", "NYC pie.")

        // Terms with non-word edges must actually match.
        checkReplacer(
            [("see plus plus", "C++"), ("dot net", ".NET"), ("f sharp", "F#")],
            "see plus plus and dot net and f sharp",
            "C++ and .NET and F#")
        checkReplacer([("C++", "C plus plus")], "I write C++ daily", "I write C plus plus daily")
        checkReplacer([(".NET", "dotnet")], "the .NET runtime", "the dotnet runtime")
        // Whole-word behaviour is preserved for ordinary terms.
        checkReplacer([("cat", "dog")], "concatenate the cat", "concatenate the dog")
        // Degenerate input.
        checkReplacer([], "unchanged", "unchanged")
        checkReplacer([("   ", "x")], "unchanged", "unchanged")

        return passed
    }
}
