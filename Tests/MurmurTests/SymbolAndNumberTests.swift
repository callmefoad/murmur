import XCTest
@testable import Murmur

/// Focused coverage for the deliberate symbol/layout tokens, the escape
/// hatch, and the spoken-amount pass — including level gating (symbols and
/// layout at every stop; amounts only on cleaned stops) and boundary
/// safety for protected collocations.
final class SymbolAndNumberTests: XCTestCase {

    private let formatter = TextFormatter(dictionary: [:])

    /// This suite is about the symbol/amount conversions themselves, so it
    /// pins the "Spoken symbols" gate ON. The gate's own behavior — and the
    /// off-by-default it ships with — lives in `VoiceCommandGatingTests`.
    private func fmt(_ text: String, autoPeriod: Bool) -> String {
        formatter.format(text, autoPeriod: autoPeriod, spokenSymbols: true)
    }

    private func fmtVerbatim(_ text: String) -> String {
        formatter.formatVerbatim(text, spokenSymbols: true)
    }

    // MARK: - Symbol tokens

    func testCommaAndPeriodConvertWithTidiedSpacing() {
        XCTAssertEqual(
            fmt("apples comma oranges and pears period", autoPeriod: true),
            "Apples, oranges and pears.")
    }

    func testQuestionAndExclamationMarks() {
        XCTAssertEqual(
            fmt("are you there question mark wow exclamation mark", autoPeriod: false),
            "Are you there? Wow!")
        XCTAssertEqual(
            fmt("stop exclamation point now", autoPeriod: true),
            "Stop! Now.")
    }

    func testExplicitPunctuationAndRepeatedPeriodsStayClean() {
        XCTAssertEqual(
            fmt(
                "so cute period what does this week look like after 5 PM for you question mark I think I have... prayer tonight",
                autoPeriod: true),
            "So cute. What does this week look like after 5 PM for you? I think I have. Prayer tonight.")
        XCTAssertEqual(
            fmt("you question mark question mark", autoPeriod: false),
            "You?")
    }

    func testColonAndSemicolon() {
        XCTAssertEqual(
            fmt("two options colon red semicolon blue", autoPeriod: true),
            "Two options: red; blue.")
    }

    func testParenthesesHugTheirContent() {
        XCTAssertEqual(
            fmt(
                "see the appendix open paren page forty close paren for details",
                autoPeriod: true),
            "See the appendix (page forty) for details.")
    }

    func testBracketsHugTheirContent() {
        XCTAssertEqual(
            fmt("note open bracket draft close bracket done", autoPeriod: true),
            "Note [draft] done.")
    }

    func testSquareBracketAliases() {
        XCTAssertEqual(
            fmt(
                "open square bracket x close square bracket done", autoPeriod: false),
            "[X] done")
    }

    func testQuotesUseCurlyFormsAndCapitalizeInside() {
        // Mid-sentence quotes inherit the pending (lowercase) state.
        XCTAssertEqual(
            fmt(
                "he said open quote hello there close quote today", autoPeriod: true),
            "He said “hello there” today.")
        // A quote at a sentence start capitalizes through the glyph.
        XCTAssertEqual(
            fmt("open quote stop close quote he said", autoPeriod: true),
            "“Stop” he said.")
    }

    func testForwardSlashGluesNeighbours() {
        XCTAssertEqual(
            fmt("yes forward slash no maybe", autoPeriod: true),
            "Yes/no maybe.")
    }

    func testAtHashDollarSigns() {
        XCTAssertEqual(
            fmt("email me at sign home", autoPeriod: true),
            "Email me @ home.")
        XCTAssertEqual(
            fmt("issue hash sign 42 fixed", autoPeriod: true),
            "Issue #42 fixed.")
        XCTAssertEqual(
            fmt("dollar sign 42 charge", autoPeriod: true),
            "$42 charge.")
    }

    func testAmpersandAliases() {
        XCTAssertEqual(
            fmt("smith ampersand co filed", autoPeriod: true),
            "Smith & co filed.")
    }

    func testPlusEqualsUnderscore() {
        XCTAssertEqual(
            fmt("one plus sign one equals sign two", autoPeriod: true),
            "One + one = two.")
        XCTAssertEqual(
            fmt("user underscore name field", autoPeriod: true),
            "User_name field.")
    }

    func testAsteriskHyphenDash() {
        XCTAssertEqual(
            fmt("put an asterisk there", autoPeriod: true),
            "Put an * there.")
        XCTAssertEqual(
            fmt("twenty hyphen five agreed", autoPeriod: true),
            "Twenty-five agreed.")
    }

    /// Word-boundary safety: token words inside larger words never fire.
    func testTokenWordsInsideLargerWordsStayUntouched() {
        XCTAssertEqual(
            fmt("periodic updates matter", autoPeriod: true),
            "Periodic updates matter.")
        XCTAssertEqual(
            fmt("the dashboard shows progress", autoPeriod: true),
            "The dashboard shows progress.")
    }

    /// Protected collocations keep their words while a lone token still
    /// converts in the same sentence.
    func testProtectedCollocationsSurvive() {
        XCTAssertEqual(
            fmt("a classic period piece film", autoPeriod: true),
            "A classic period piece film.")
        XCTAssertEqual(
            fmt("the grace period ends tomorrow", autoPeriod: true),
            "The grace period ends tomorrow.")
        XCTAssertEqual(
            fmt("a five star rating indeed period", autoPeriod: true),
            "A five star rating indeed.")
    }

    // MARK: - Escape hatch

    func testLiterallyEmitsWordForm() {
        // The hatch blocks CONVERSION, not sentence casing.
        XCTAssertEqual(fmt("literally period", autoPeriod: false), "Period")
        XCTAssertEqual(
            fmt("say literally comma now", autoPeriod: true),
            "Say comma now.")
    }

    func testLiterallyHandlesMultiWordTokens() {
        XCTAssertEqual(
            fmt("type literally open paren here", autoPeriod: false),
            "Type open paren here")
    }

    // MARK: - Bullet & tab

    func testBulletOpensItemAtUtteranceStart() {
        XCTAssertEqual(
            fmt("bullet buy milk", autoPeriod: true),
            "- Buy milk.")
    }

    func testBulletPointAlias() {
        XCTAssertEqual(
            fmt("bullet point buy eggs", autoPeriod: true),
            "- Buy eggs.")
    }

    func testBulletAfterNewLineOpensItem() {
        XCTAssertEqual(
            fmt(
                "groceries new line bullet eggs new line bullet milk", autoPeriod: true),
            "Groceries\n- Eggs\n- Milk.")
    }

    func testMidUtteranceBulletStaysAWord() {
        XCTAssertEqual(
            fmt("the bullet missed the target", autoPeriod: true),
            "The bullet missed the target.")
    }

    func testTabInsertsLiteralTabAnywhere() {
        XCTAssertEqual(
            fmt("tab key indented stuff", autoPeriod: true),
            "\tIndented stuff.")
        XCTAssertEqual(
            fmt("column one tab column two", autoPeriod: true),
            "Column one\tcolumn two.")
    }

    // MARK: - Amounts (cleaned stops)

    func testDollarsAlone() {
        XCTAssertEqual(
            fmt("it costs fifty dollars", autoPeriod: true),
            "It costs $50.")
    }

    func testDollarsAndCentsWithOptionalAnd() {
        XCTAssertEqual(
            fmt("fifty dollars and twenty five cents due", autoPeriod: true),
            "$50.25 due.")
        // Without "and" the cents stand alone as their own amount.
        XCTAssertEqual(
            fmt("ninety nine dollars nine cents total", autoPeriod: true),
            "$99 $0.09 total.")
    }

    func testMixedWordAndDigitCents() {
        XCTAssertEqual(
            fmt("fifty dollars and 25 cents due", autoPeriod: true),
            "$50.25 due.")
    }

    func testBritishInternalAndInAmount() {
        XCTAssertEqual(
            fmt("one hundred and five dollars please", autoPeriod: true),
            "$105 please.")
    }

    func testScaleAmounts() {
        // Note: money output does not re-insert thousands separators.
        XCTAssertEqual(
            fmt("two thousand fifty dollars owed", autoPeriod: true),
            "$2050 owed.")
        XCTAssertEqual(
            fmt("twenty-five dollars copay", autoPeriod: true),
            "$25 copay.")
    }

    func testCentsAloneBecomesFractionalDollars() {
        XCTAssertEqual(
            fmt("seventy five cents each", autoPeriod: true),
            "$0.75 each.")
        XCTAssertEqual(
            fmt("75 cents flat", autoPeriod: true),
            "$0.75 flat.")
    }

    func testCentOverflowCarriesIntoDollars() {
        XCTAssertEqual(
            fmt("one hundred fifty cents refunded", autoPeriod: true),
            "$1.50 refunded.")
    }

    func testEurosConvert() {
        XCTAssertEqual(
            fmt("that costs twenty euros today", autoPeriod: true),
            "That costs €20 today.")
    }

    /// Deliberate: "pounds" is ambiguous (weight vs currency) and stays a word.
    func testPoundsStayWords() {
        XCTAssertEqual(
            fmt("ten pounds of flour", autoPeriod: true),
            "Ten pounds of flour.")
    }

    func testPercentAttachesToNumberWords() {
        XCTAssertEqual(
            fmt("fifty percent of users", autoPeriod: true),
            "50% of users.")
    }

    func testPercentAttachesToDigits() {
        XCTAssertEqual(
            fmt("50 percent off everything", autoPeriod: true),
            "50% off everything.")
    }

    func testStorageUnitsConvert() {
        XCTAssertEqual(
            fmt("two hundred fifty gigabytes free", autoPeriod: true),
            "250 GB free.")
        XCTAssertEqual(
            fmt("five gigs left", autoPeriod: true),
            "5 GB left.")
        XCTAssertEqual(
            fmt("five hundred twelve megabytes used", autoPeriod: true),
            "512 MB used.")
        XCTAssertEqual(
            fmt("two terabytes backed up", autoPeriod: true),
            "2 TB backed up.")
        XCTAssertEqual(
            fmt("sixty four kilobytes cached", autoPeriod: true),
            "64 KB cached.")
    }

    /// Numbers without an amount unit stay words.
    func testNumbersWithoutUnitsStayWords() {
        XCTAssertEqual(
            fmt("i have three cats", autoPeriod: true),
            "I have three cats.")
    }

    // MARK: - Verbatim gating

    func testVerbatimKeepsAmountsAsWords() {
        XCTAssertEqual(
            fmtVerbatim("it costs fifty dollars"), "it costs fifty dollars")
        XCTAssertEqual(
            fmtVerbatim("seventy five cents each"), "seventy five cents each")
        XCTAssertEqual(
            fmtVerbatim("two gigs free"), "two gigs free")
    }

    /// Symbols DO convert at verbatim; tidy glues "%" to the number word.
    func testVerbatimStillConvertsSymbols() {
        XCTAssertEqual(
            fmtVerbatim("hello comma world period"),
            "hello, world.")
        XCTAssertEqual(
            fmtVerbatim("fifty percent"), "fifty%")
    }

    func testVerbatimLayoutTokensActive() {
        XCTAssertEqual(
            fmtVerbatim("bullet remember this"), "- remember this")
        XCTAssertEqual(
            fmtVerbatim("tab key indented"), "\tindented")
        XCTAssertEqual(
            fmtVerbatim("literally period"), "period")
    }

    // MARK: - Interaction with line commands & tidying

    func testSymbolsInteractWithNewLineCommands() {
        XCTAssertEqual(
            fmt(
                "first line period new line second line comma really", autoPeriod: true),
            "First line.\nSecond line, really.")
    }

    func testTabsSurviveTidyingAtLineEdges() {
        XCTAssertEqual(
            fmt("tab key deeply tab nested", autoPeriod: false),
            "\tDeeply\tnested")
    }
}
