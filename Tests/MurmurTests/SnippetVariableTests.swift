import AppKit
import XCTest
@testable import Murmur

/// Coverage for snippet variables (`{{clipboard}}`, `{{date}}`, `{{time}}`,
/// `{{datetime}}`).
///
/// The pure expander `SnippetVariables.expand(in:clipboard:now:)` is tested
/// directly with an injected clipboard string and pinned clock — it never
/// touches NSPasteboard. The one integration case goes through the real
/// `SnippetStore.expand(in:)` path by swapping `clipboardProvider`, so no
/// test ever reads or writes the real pasteboard.
final class SnippetVariableTests: XCTestCase {

    // MARK: - Expected-value helpers

    /// Builds a formatter identical to the production one (fresh instance,
    /// current locale + timezone, given styles) so expectations stay correct
    /// on any machine without hardcoding localized strings.
    private func referenceFormatter(
        dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    /// A fixed instant so date assertions are deterministic.
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Every token

    func testClipboardTokenInsertsProvidedText() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "paste: {{clipboard}}", clipboard: "hello"),
            "paste: hello")
    }

    func testClipboardTokenWithSurroundingWhitespaceStillWorks() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "{{ clipboard }}", clipboard: "x"),
            "x")
    }

    func testDateTokenUsesCurrentLocaleLongFormat() {
        let expected = referenceFormatter(dateStyle: .long, timeStyle: .none)
            .string(from: now)
        XCTAssertEqual(SnippetVariables.expand(in: "{{date}}", clipboard: nil, now: now), expected)
    }

    func testTimeTokenUsesCurrentLocaleShortFormat() {
        let expected = referenceFormatter(dateStyle: .none, timeStyle: .short)
            .string(from: now)
        XCTAssertEqual(SnippetVariables.expand(in: "{{time}}", clipboard: nil, now: now), expected)
    }

    func testDateTimeTokenCombinesBothStyles() {
        let expected = referenceFormatter(dateStyle: .long, timeStyle: .short)
            .string(from: now)
        XCTAssertEqual(
            SnippetVariables.expand(in: "{{datetime}}", clipboard: nil, now: now),
            expected)
    }

    func testTokensAreCaseInsensitive() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "{{CLIPBOARD}} {{Date}}", clipboard: "c", now: now),
            "c \(referenceFormatter(dateStyle: .long, timeStyle: .none).string(from: now))")
    }

    // MARK: - Clipboard fallback

    func testNilClipboardExpandsToEmptyString() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "a{{clipboard}}b", clipboard: nil),
            "ab")
    }

    func testEmptyClipboardStringExpandsToEmptyString() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "a{{clipboard}}b", clipboard: ""),
            "ab")
    }

    // MARK: - Unknown tokens & malformed braces pass through verbatim

    func testUnknownTokenPassesThroughVerbatim() {
        let text = "{{first_name}} {{NoPe}}"
        XCTAssertEqual(SnippetVariables.expand(in: text, clipboard: "x"), text)
    }

    func testMissingClosingBraceStaysLiteral() {
        XCTAssertEqual(SnippetVariables.expand(in: "{{clipboard", clipboard: "x"), "{{clipboard")
    }

    func testMissingOpeningBraceStaysLiteral() {
        XCTAssertEqual(SnippetVariables.expand(in: "clipboard}}", clipboard: "x"), "clipboard}}")
    }

    func testTripleBracesExpandOnlyTheInnerToken() {
        XCTAssertEqual(SnippetVariables.expand(in: "{{{clipboard}}}", clipboard: "x"), "{x}")
    }

    func testTrailingExtraBraceRemainsLiteral() {
        XCTAssertEqual(SnippetVariables.expand(in: "{{clipboard}}}", clipboard: "x"), "x}")
    }

    func testEmptyNameStaysLiteral() {
        XCTAssertEqual(SnippetVariables.expand(in: "{{}} and {{ }}", clipboard: "x"), "{{}} and {{ }}")
    }

    func testSpaceInsideNameStaysLiteral() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "{{clip board}}", clipboard: "x"),
            "{{clip board}}")
    }

    func testDigitsInNameStayLiteral() {
        XCTAssertEqual(SnippetVariables.expand(in: "{{v2}}", clipboard: "x"), "{{v2}}")
    }

    // MARK: - Combinations

    func testMultipleTokensInOneBlockAllExpand() {
        let date = referenceFormatter(dateStyle: .long, timeStyle: .none).string(from: now)
        let time = referenceFormatter(dateStyle: .none, timeStyle: .short).string(from: now)
        let datetime = referenceFormatter(dateStyle: .long, timeStyle: .short).string(from: now)

        XCTAssertEqual(
            SnippetVariables.expand(
                in: "on {{date}} at {{time}}, full {{datetime}}, clip {{clipboard}}, keep {{unknown}}",
                clipboard: "PAYLOAD",
                now: now),
            "on \(date) at \(time), full \(datetime), clip PAYLOAD, keep {{unknown}}")
    }

    func testAdjacentTokensWithoutSeparatorsExpand() {
        XCTAssertEqual(
            SnippetVariables.expand(in: "{{clipboard}}{{clipboard}}", clipboard: "-"),
            "--")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(SnippetVariables.expand(in: "", clipboard: "x"), "")
    }

    func testTextWithoutAnyBracesIsReturnedUnchanged() {
        let text = "plain dictated words, 123 — no templates here"
        XCTAssertEqual(SnippetVariables.expand(in: text, clipboard: "x"), text)
    }

    // MARK: - Integration through SnippetStore.expand(in:)

    private var originalData: Data?
    private var fileExisted = false
    private var originalProvider: (() -> String?)?

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Same guard as SnippetStoreTests: don't fire the legacy
        // WhisperFlow → Murmur migration on real user data.
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let murmurDir = base.appendingPathComponent("Murmur", isDirectory: true)
        let legacy = base.appendingPathComponent("WhisperFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: murmurDir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            throw XCTSkip(
                "Skipping: exercising SnippetStore here would trigger the " +
                "WhisperFlow → Murmur migration on real user data.")
        }

        fileExisted = FileManager.default.fileExists(atPath: SnippetStore.fileURL.path)
        originalData = fileExisted ? try Data(contentsOf: SnippetStore.fileURL) : nil
        originalProvider = SnippetStore.clipboardProvider
    }

    override func tearDown() {
        if fileExisted, let originalData {
            try? originalData.write(to: SnippetStore.fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: SnippetStore.fileURL)
        }
        SnippetStore.clipboardProvider = originalProvider ?? {
            NSPasteboard.general.string(forType: .string)
        }
        super.tearDown()
    }

    /// Full path: spoken trigger → saved expansion containing tokens →
    /// clipboard injected through the provider seam (real pasteboard is
    /// never touched).
    func testRealExpandPathInjectsClipboardAndLeavesUnknownTokensAlone() throws {
        SnippetStore.save([
            Snippet(trigger: "fwd", expansion: "FYI {{clipboard}} — {{unknown}}"),
        ])
        var providerCalls = 0
        SnippetStore.clipboardProvider = {
            providerCalls += 1
            return "the memo"
        }

        XCTAssertEqual(
            SnippetStore.expand(in: "please fwd this"),
            "please FYI the memo — {{unknown}} this")
        XCTAssertEqual(providerCalls, 1)
    }

    /// The pasteboard must not be read when nothing looks like a token.
    func testClipboardProviderIsNotConsultedWithoutTokens() {
        SnippetStore.save([Snippet(trigger: "sig", expansion: "Taylor")])
        SnippetStore.clipboardProvider = { XCTFail("pasteboard should not be read"); return nil }

        XCTAssertEqual(SnippetStore.expand(in: "best, sig"), "best, Taylor")
    }
}
