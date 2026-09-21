import XCTest
@testable import Murmur

final class TextFormatterTests: XCTestCase {

    func testFillerRemoval() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format("this is, uh, a test", autoPeriod: true)
        XCTAssertEqual(result, "This is, a test.")
    }

    func testRecognizerCapitalizationAfterCommaIsNormalized() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format("so, Here's a test", autoPeriod: true),
            "So, here's a test.")
    }

    func testSpokenNewLine() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format(
            "first line new line second line", autoPeriod: true)
        XCTAssertEqual(result, "First line\nSecond line.")
    }

    func testSpokenNewParagraph() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format(
            "intro new paragraph details here", autoPeriod: true)
        XCTAssertEqual(result, "Intro\n\nDetails here.")
    }

    /// A dictionary replacement containing a literal "$" must survive
    /// verbatim, proving `applyDictionary` uses `escapedTemplate` rather
    /// than treating the replacement as a regex template (where "$5"
    /// would be read as a backreference). The key deliberately avoids
    /// "<number> dollars", which the amount pass claims first.
    func testDictionaryReplacementWithLiteralDollarSign() {
        let formatter = TextFormatter(dictionary: ["five bucks": "cost is $5"])
        let result = formatter.format("the five bucks total", autoPeriod: true)
        XCTAssertEqual(result, "The cost is $5 total.")
    }

    /// A deliberately camelCased dictionary value ("iphone" -> "iPhone")
    /// must keep its casing at a sentence start. The dictionary runs BEFORE
    /// capitalization; capitalizeSentences protects the token because it
    /// carries an uppercase letter after its first character.
    func testCamelCasedDictionaryValueSurvivesSentenceStart() {
        let formatter = TextFormatter(dictionary: ["iphone": "iPhone"])
        let result = formatter.format("iphone is great", autoPeriod: true)
        XCTAssertEqual(result, "iPhone is great.")
    }

    /// The same protection is a general rule, not dictionary knowledge, so
    /// it also covers learned corrections and snippet expansions, which are
    /// applied later in the pipeline than the formatter.
    func testDeliberatelyCasedTokensAreNeverCapitalized() {
        let formatter = TextFormatter(dictionary: [:])
        for token in ["iPhone", "eBay", "iOS", "macOS", "gRPC", "iPad"] {
            XCTAssertEqual(
                formatter.format("\(token) rocks", autoPeriod: true),
                "\(token) rocks.")
        }
        // ... while ordinary tokens still get capitalized.
        XCTAssertEqual(formatter.format("ipad rocks", autoPeriod: true), "Ipad rocks.")
        XCTAssertEqual(
            formatter.format("hello world. iOS is fine", autoPeriod: true),
            "Hello world. iOS is fine.")
    }

    /// A normalization-style entry ("gonna" -> "going to", "cuz" ->
    /// "because") lands at a sentence start with a lowercase first letter
    /// and must still be capitalized — i.e. the dictionary must run BEFORE
    /// capitalizeSentences.
    func testNormalizationValueIsCapitalizedAtSentenceStart() {
        let formatter = TextFormatter(dictionary: [
            "gonna": "going to", "cuz": "because", "wanna": "want to",
            "thx": "thanks",
        ])
        XCTAssertEqual(
            formatter.format("gonna be late", autoPeriod: true), "Going to be late.")
        XCTAssertEqual(
            formatter.format("cuz he said so", autoPeriod: true), "Because he said so.")
        XCTAssertEqual(
            formatter.format("wanna go. thx", autoPeriod: true), "Want to go. Thanks.")
    }

    /// A punctuation-only value must flow through tidying, which strips the
    /// space the spoken form left behind — i.e. the dictionary must run
    /// BEFORE tidyWhitespaceAndPunctuation.
    func testPunctuationOnlyValueLeavesNoStraySpace() {
        let formatter = TextFormatter(dictionary: ["period": "."])
        XCTAssertEqual(formatter.format("hello period", autoPeriod: true), "Hello.")
        XCTAssertEqual(
            formatter.format("one period two period", autoPeriod: true),
            "One. Two.")
    }

    /// A later entry must not rewrite text an earlier entry just inserted.
    func testDictionaryEntriesDoNotCascadeIntoEachOther() {
        let formatter = TextFormatter(dictionary: [
            "jira ticket": "Jira ticket", "ticket": "TICKET",
        ])
        XCTAssertEqual(
            formatter.format("File a jira ticket today", autoPeriod: true),
            "File a Jira ticket today.")
    }

    /// Equal-length keys must pick the same winner in every process; the
    /// cross-process proof is a shell loop over `Murmur --selftest`.
    func testEqualLengthDictionaryKeysAreDeterministic() {
        for _ in 0..<100 {
            let formatter = TextFormatter(dictionary: [
                "big apple": "NYC", "apple pie": "dessert",
            ])
            XCTAssertEqual(formatter.format("big apple pie", autoPeriod: true), "NYC pie.")
        }
    }

    /// `\b` requires a word character on that side, so a term with a
    /// non-word edge used to be silently ignored.
    func testTermsWithNonWordEdgesActuallyApply() {
        let formatter = TextFormatter(dictionary: ["see plus plus": "C++"])
        XCTAssertEqual(formatter.format("i love see plus plus", autoPeriod: true),
                       "I love C++")
    }

    /// Overlapping dictionary keys must resolve deterministically by
    /// matching the longest key first, regardless of Swift's unordered
    /// dictionary storage. If the shorter key "stripe" won first, it
    /// would consume the "stripe" inside "stripe api" and replace it
    /// before the "stripe api" entry ever got a chance to match the
    /// literal text, producing a different (wrong) result.
    func testLongestDictionaryKeyWinsOverOverlappingShorterKey() {
        let formatter = TextFormatter(dictionary: [
            "stripe": "Stripe Inc",
            "stripe api": "our internal wrapper",
        ])
        let result = formatter.format("we use the stripe api daily", autoPeriod: true)
        XCTAssertEqual(result, "We use the our internal wrapper daily.")
    }

    func testAutoPeriodFalseDoesNotAppendPeriod() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format("hello world", autoPeriod: false)
        XCTAssertEqual(result, "Hello world")
    }

    func testAutoPeriodTrueAppendsPeriod() {
        let formatter = TextFormatter(dictionary: [:])
        let result = formatter.format("hello world", autoPeriod: true)
        XCTAssertEqual(result, "Hello world.")
    }

    func testEmptyStringInput() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(formatter.format("", autoPeriod: true), "")
        XCTAssertEqual(formatter.format("", autoPeriod: false), "")
    }

    func testBuiltInSelfTestStillPasses() {
        XCTAssertTrue(TextFormatter.runSelfTest())
    }

    // MARK: - Language rules

    /// Spanish filler removal ("eh", "este", "o sea", "mmm").
    func testSpanishFillerRemoval() {
        let formatter = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "es-ES"))
        XCTAssertEqual(formatter.format("hola eh mundo", autoPeriod: true), "Hola mundo.")
        XCTAssertEqual(
            formatter.format("este es un test", autoPeriod: true), "Es un test.")
        XCTAssertEqual(
            formatter.format("bueno, mmm, o sea bien", autoPeriod: true), "Bueno, bien.")
    }

    /// Spanish spoken layout commands: "nueva línea" / "nuevo párrafo".
    func testSpanishSpokenLayoutCommands() {
        let formatter = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "es-ES"))
        XCTAssertEqual(
            formatter.format("primera línea nueva línea segunda línea", autoPeriod: true),
            "Primera línea\nSegunda línea.")
        XCTAssertEqual(
            formatter.format("intro nuevo párrafo detalles aquí", autoPeriod: true),
            "Intro\n\nDetalles aquí.")
    }

    /// German filler removal ("ähm", "äh", "also").
    func testGermanFillerRemoval() {
        let formatter = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "de-DE"))
        XCTAssertEqual(
            formatter.format("also ich denke ähm ja", autoPeriod: true), "Ich denke ja.")
        XCTAssertEqual(
            formatter.format("äh hallo welt", autoPeriod: true), "Hallo welt.")
    }

    /// German spoken layout commands: "neue Zeile" / "neuer Absatz".
    func testGermanSpokenLayoutCommands() {
        let formatter = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "de-DE"))
        XCTAssertEqual(
            formatter.format("erste Zeile neue Zeile zweite Zeile", autoPeriod: true),
            "Erste Zeile\nZweite Zeile.")
        XCTAssertEqual(
            formatter.format("einleitung neuer Absatz details hier", autoPeriod: true),
            "Einleitung\n\nDetails hier.")
    }

    /// The remaining Romance languages resolve their own filler and
    /// command sets (spot check one phrase each).
    func testFrenchItalianPortugueseRulesResolve() {
        XCTAssertEqual(
            TextFormatter(dictionary: [:], locale: Locale(identifier: "fr-FR"))
                .format("euh bonjour le monde", autoPeriod: false),
            "Bonjour le monde")
        XCTAssertEqual(
            TextFormatter(dictionary: [:], locale: Locale(identifier: "it-IT"))
                .format("ehm ciao a tutti", autoPeriod: false),
            "Ciao a tutti")
        XCTAssertEqual(
            TextFormatter(dictionary: [:], locale: Locale(identifier: "pt-BR"))
                .format("tipo isso né", autoPeriod: false),
            "Isso")
    }

    /// Unknown or unsupported language codes fall back to the English
    /// rule set — English fillers still apply, foreign ones don't.
    func testUnknownLanguageFallsBackToEnglish() {
        let unknownCode = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "xx-YY"))
        let unsupportedRegion = TextFormatter(
            dictionary: [:], locale: Locale(identifier: "en_US_POSIX"))
        let noLocale = TextFormatter(dictionary: [:])
        for formatter in [unknownCode, unsupportedRegion, noLocale] {
            XCTAssertEqual(
                formatter.format("this is, uh, a test", autoPeriod: true),
                "This is, a test.")
            XCTAssertEqual(
                formatter.format("first new line second", autoPeriod: true),
                "First\nSecond.")
        }
        // German fillers must NOT be stripped under the English fallback.
        XCTAssertEqual(
            unknownCode.format("also ich denke ähm ja", autoPeriod: false),
            "Also ich denke ähm ja")
    }
}
