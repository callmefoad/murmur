import XCTest
@testable import Murmur

/// `PhraseReplacer` is the one substitution engine behind the personal
/// dictionary, learned corrections, and snippets. It is exercised directly
/// here because `LearnedStore.apply` and `SnippetStore.expand` read the
/// user's real files on disk.
final class PhraseReplacerTests: XCTestCase {

    // MARK: - No cascading (single pass)

    /// The snippet case from the bug report: looping per entry over the
    /// accumulating result let "com" rewrite the inside of the address
    /// "email" had just expanded to, yielding "me@example.Company".
    func testReplacementOutputIsNeverRescanned() {
        let result = PhraseReplacer.replace(
            in: "email",
            using: [("email", "me@example.com"), ("com", "Company")])
        XCTAssertEqual(result, "me@example.com")
    }

    /// The dictionary case from the bug report: "ticket" must not rewrite
    /// the word "ticket" that the "jira ticket" entry just inserted.
    func testLongerEntryOutputIsNotRewrittenByShorterEntry() {
        let result = PhraseReplacer.replace(
            in: "File a jira ticket today",
            using: [("jira ticket", "Jira ticket"), ("ticket", "TICKET")])
        XCTAssertEqual(result, "File a Jira ticket today")
    }

    func testUntouchedTextIsPreservedAroundMatches() {
        let result = PhraseReplacer.replace(
            in: "  keep   this, jira ok?  ", using: [("jira", "Jira")])
        XCTAssertEqual(result, "  keep   this, Jira ok?  ")
    }

    // MARK: - Deterministic ordering

    func testLongestKeyWinsOverNestedShorterKey() {
        let result = PhraseReplacer.replace(
            in: "we use the stripe api daily",
            using: [("stripe", "Stripe Inc"), ("stripe api", "our internal wrapper")])
        XCTAssertEqual(result, "we use the our internal wrapper daily")
    }

    /// Two keys of EQUAL length used to flip between process launches:
    /// `sorted` is not stable and `Dictionary` iteration order is seeded
    /// per process. The tie-break on the key itself makes the ordering
    /// total. (The cross-process proof is a shell loop over the release
    /// binary's `--selftest`; this only pins the expected winner.)
    func testEqualLengthKeysResolveToTheSameWinner() {
        for _ in 0..<200 {
            let dictionary = ["big apple": "NYC", "apple pie": "dessert"]
            XCTAssertEqual(
                PhraseReplacer.replace(in: "big apple pie", using: dictionary),
                "NYC pie")
        }
    }

    /// Keys differing only by case collapse to one lowercased lookup, so
    /// which value wins must not depend on dictionary iteration order.
    func testKeysDifferingOnlyByCaseResolveDeterministically() {
        for _ in 0..<200 {
            XCTAssertEqual(
                PhraseReplacer.replace(in: "the foo thing",
                                       using: ["Foo": "UPPER", "foo": "lower"]),
                "the UPPER thing")
        }
    }

    // MARK: - Edge-aware boundaries

    /// `\b` demands a word character on that side, so "(?i)\bC\+\+\b" could
    /// never match "C++" and the entry silently did nothing.
    func testTrailingNonWordCharacterTermsMatch() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "I write C++ daily", using: ["C++": "C plus plus"]),
            "I write C plus plus daily")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "F# is fine", using: ["F#": "FSharp"]),
            "FSharp is fine")
    }

    func testLeadingNonWordCharacterTermsMatch() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "the .NET runtime", using: [".NET": "dotnet"]),
            "the dotnet runtime")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "ping @here now", using: ["@here": "everyone"]),
            "ping everyone now")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "type /slash here", using: ["/slash": "SLASH"]),
            "type SLASH here")
    }

    func testEmojiTriggerMatches() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "ship it 🚀 now", using: ["🚀": "rocket"]),
            "ship it rocket now")
    }

    /// Whole-word behaviour must survive for ordinary terms: "cat" may not
    /// match inside "concatenate".
    func testOrdinaryTermsKeepWholeWordBoundaries() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "concatenate the cat", using: ["cat": "dog"]),
            "concatenate the dog")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "C++x stays", using: ["C++": "C plus plus"]),
            "C++x stays")
    }

    // MARK: - Casing and literal replacement

    func testMatchIsCaseInsensitiveAndInsertsStoredCasing() {
        for spoken in ["iphone", "IPHONE", "iPhone", "IpHoNe"] {
            XCTAssertEqual(
                PhraseReplacer.replace(in: "my \(spoken) here", using: ["iphone": "iPhone"]),
                "my iPhone here")
        }
    }

    /// The result is assembled from match ranges, so a replacement is
    /// spliced in verbatim — "$1" is two literal characters, not a
    /// backreference to a capture group.
    func testReplacementIsInsertedLiterally() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "the five dollars total",
                                   using: ["five dollars": "cost is $5"]),
            "the cost is $5 total")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "say group", using: ["group": "$1 and $0"]),
            "say $1 and $0")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "say backslash", using: ["backslash": #"a\b"#]),
            #"say a\b"#)
    }

    /// Regex metacharacters in a KEY are literal too.
    func testKeyMetacharactersAreEscaped() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "a (b) c", using: ["(b)": "B"]), "a B c")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "a.b matches", using: ["a.b": "AB"]), "AB matches")
        XCTAssertEqual(
            PhraseReplacer.replace(in: "axb ignored", using: ["a.b": "AB"]), "axb ignored")
    }

    // MARK: - Degenerate input

    func testEmptyEntryListReturnsInputUnchanged() {
        XCTAssertEqual(PhraseReplacer.replace(in: "unchanged", using: [:]), "unchanged")
    }

    func testBlankAndWhitespaceOnlyKeysAreSkipped() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "unchanged", using: ["": "x", "   ": "y"]),
            "unchanged")
        // A blank key alongside a real one must not break the real one.
        XCTAssertEqual(
            PhraseReplacer.replace(in: "a jira b", using: ["": "x", "jira": "Jira"]),
            "a Jira b")
    }

    func testEmptyTextReturnsEmptyText() {
        XCTAssertEqual(PhraseReplacer.replace(in: "", using: ["jira": "Jira"]), "")
    }

    func testEmptyReplacementDeletesTheMatch() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "drop this word", using: ["this": ""]),
            "drop  word")
    }

    func testMultipleOccurrencesAreAllReplaced() {
        XCTAssertEqual(
            PhraseReplacer.replace(in: "jira and jira and JIRA", using: ["jira": "Jira"]),
            "Jira and Jira and Jira")
    }
}
