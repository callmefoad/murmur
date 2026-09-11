import XCTest
@testable import Murmur

/// Full CRUD coverage for `SnippetStore` plus its `expand(in:)` delegation
/// to `PhraseReplacer`.
///
/// There is no path-injection seam: `SnippetStore.fileURL` is hardcoded to
/// `<App Support>/Murmur/snippets.json`. Rather than refactor production
/// code, every test snapshots the real file (or its absence) in setUp and
/// restores it byte-for-byte in tearDown, so the running app's data is
/// never altered. If the store directory is missing AND the pre-rename
/// `WhisperFlow` folder exists, tests skip — touching anything would fire
/// AppPaths' one-time legacy migration as a side effect.
final class SnippetStoreTests: XCTestCase {

    private var originalData: Data?
    private var fileExisted = false

    override func setUpWithError() throws {
        try super.setUpWithError()

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
    }

    override func tearDown() {
        if fileExisted, let originalData {
            try? originalData.write(to: SnippetStore.fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: SnippetStore.fileURL)
        }
        super.tearDown()
    }

    // MARK: - Snippet payload

    func testDecodingWithoutIdKeyMintsUUID() throws {
        let json = Data(#"{"trigger": "sig", "expansion": "Taylor"}"#.utf8)
        let decoded = try JSONDecoder().decode(Snippet.self, from: json)
        XCTAssertEqual(decoded.trigger, "sig")
        XCTAssertEqual(decoded.expansion, "Taylor")
    }

    func testCodableRoundTripPreservesIdAndFields() throws {
        var snippet = Snippet(trigger: "addr", expansion: "123 Main St")
        snippet.id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

        let data = try JSONEncoder().encode(snippet)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)

        XCTAssertEqual(decoded, snippet)
        XCTAssertEqual(decoded.id, snippet.id)
    }

    // MARK: - CRUD

    func testLoadWithNoFileReturnsEmptyArray() {
        try? FileManager.default.removeItem(at: SnippetStore.fileURL)
        XCTAssertEqual(SnippetStore.load(), [])
    }

    func testSaveThenLoadPreservesOrderAndContent() {
        let snippets = [
            Snippet(trigger: "sig", expansion: "Taylor Foad"),
            Snippet(trigger: "addr", expansion: "123 Main St"),
        ]
        SnippetStore.save(snippets)

        XCTAssertTrue(FileManager.default.fileExists(atPath: SnippetStore.fileURL.path))
        XCTAssertEqual(SnippetStore.load(), snippets)
    }

    func testSaveReplacesPreviousContents() {
        SnippetStore.save([Snippet(trigger: "old", expansion: "OLD")])
        let replacement = [Snippet(trigger: "new", expansion: "NEW")]
        SnippetStore.save(replacement)

        XCTAssertEqual(SnippetStore.load(), replacement)
    }

    func testDeletingTheFileEmptiesTheStore() {
        SnippetStore.save([Snippet(trigger: "gone", expansion: "x")])
        try? FileManager.default.removeItem(at: SnippetStore.fileURL)
        XCTAssertEqual(SnippetStore.load(), [])
    }

    func testCorruptFileLoadsAsEmptyInsteadOfCrashing() throws {
        try Data("not json at all".utf8).write(to: SnippetStore.fileURL)
        XCTAssertEqual(SnippetStore.load(), [])
    }

    func testOneDamagedEntryDoesNotHideValidSnippets() throws {
        let json = Data("""
        [
          {"trigger":"first","expansion":"ONE"},
          {"trigger":17,"expansion":"BROKEN"},
          {"trigger":"last","expansion":"THREE"}
        ]
        """.utf8)
        try json.write(to: SnippetStore.fileURL, options: .atomic)
        XCTAssertEqual(SnippetStore.load().map(\.trigger), ["first", "last"])
    }

    // MARK: - expand(in:)

    func testExpandReplacesTriggerWithSavedExpansion() {
        SnippetStore.save([Snippet(trigger: "sig", expansion: "Taylor Foad")])
        XCTAssertEqual(SnippetStore.expand(in: "best, sig"), "best, Taylor Foad")
    }

    func testExpandMatchesCaseInsensitivelyButKeepsSavedCasing() {
        SnippetStore.save([Snippet(trigger: "sig", expansion: "T. Foad")])
        XCTAssertEqual(SnippetStore.expand(in: "SIG and Sig"), "T. Foad and T. Foad")
    }

    func testExpansionIsNeverRescannedByOtherSnippets() {
        SnippetStore.save([
            Snippet(trigger: "email", expansion: "me@example.com"),
            Snippet(trigger: "com", expansion: "Company"),
        ])
        XCTAssertEqual(SnippetStore.expand(in: "email"), "me@example.com")
    }

    func testWhitespaceOnlyTriggersAreIgnored() {
        SnippetStore.save([
            Snippet(trigger: "   ", expansion: "junk"),
            Snippet(trigger: "ok", expansion: "fine"),
        ])
        // The blank entry does nothing and does not break the real one.
        let text = "blank stays, ok"
        XCTAssertEqual(SnippetStore.expand(in: text), "blank stays, fine")
    }

    func testExpandWithNoSnippetsReturnsTextUnchanged() {
        try? FileManager.default.removeItem(at: SnippetStore.fileURL)
        XCTAssertEqual(SnippetStore.expand(in: "untouched text"), "untouched text")
    }
}
