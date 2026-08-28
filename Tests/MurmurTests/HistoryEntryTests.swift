import XCTest
@testable import Murmur

final class HistoryEntryTests: XCTestCase {

    /// Legacy history files were written before `id` existed. Decoding
    /// JSON with no `id` key must mint a fresh UUID rather than fail.
    func testDecodingWithoutIdKeyMintsUUID() throws {
        let json = """
        {"text": "hello world", "date": 700000000.0}
        """
        let entry = try JSONDecoder().decode(
            HistoryEntry.self, from: Data(json.utf8))
        XCTAssertFalse(entry.id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: entry.id))
        XCTAssertEqual(entry.text, "hello world")
    }

    func testDecodingWithIdKeyPreservesItExactly() throws {
        let json = """
        {"id": "fixed-id-123", "text": "hello world", "date": 700000000.0}
        """
        let entry = try JSONDecoder().decode(
            HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.id, "fixed-id-123")
    }

    func testEncodeDecodeRoundTripIsIdStable() throws {
        let original = HistoryEntry(text: "round trip", date: Date())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded, original)
    }

    /// The old scheme derived ids from `text.hashValue`, which collided
    /// whenever two entries shared identical text and date. Each entry
    /// must now get its own independent UUID.
    func testIdenticalTextAndDateStillGetDifferentIds() {
        let date = Date()
        let first = HistoryEntry(text: "same text", date: date)
        let second = HistoryEntry(text: "same text", date: date)
        XCTAssertNotEqual(first.id, second.id)
    }
}

/// Coverage for `HistoryStore` exports plus the configurable history limit.
///
/// The store's persistence is redirected to a per-test temp directory via
/// `HistoryStore.fileOverride`. Snapshotting the real `history.json` is not
/// enough: the live app rewrites that file on every dictation, racing any
/// test that touches it. With the override, tests are hermetic and never
/// read or write real user data.
final class HistoryStoreExportTests: XCTestCase {

    private var tempDirectory: URL!
    private var originalLimit: Any?
    private var originalPaused: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Drain writes still queued by earlier tests before pointing the
        // store at a fresh directory, so a late async write can't land in
        // (or be read back from) this test's history.json.
        HistoryStore.flushPendingWrites()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        HistoryStore.fileOverride =
            tempDirectory.appendingPathComponent("history.json")

        // UserDefaults in the test process are separate from the running
        // app's, but snapshot/restore anyway so repeat runs stay clean.
        originalLimit = UserDefaults.standard.object(forKey: "historyLimit")
        originalPaused = UserDefaults.standard.object(forKey: "historyPaused")
        Settings.historyPaused = false
        Settings.historyRetentionDays = 0
        UserDefaults.standard.removeObject(forKey: "historyLimit")
    }

    override func tearDown() {
        // Drain this test's queued writes so none land after the directory
        // is removed (or into the next test's override target).
        HistoryStore.flushPendingWrites()
        HistoryStore.fileOverride = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        if let originalLimit {
            UserDefaults.standard.set(originalLimit, forKey: "historyLimit")
        } else {
            UserDefaults.standard.removeObject(forKey: "historyLimit")
        }
        if let originalPaused {
            UserDefaults.standard.set(originalPaused, forKey: "historyPaused")
        } else {
            UserDefaults.standard.removeObject(forKey: "historyPaused")
        }
        UserDefaults.standard.removeObject(forKey: "historyRetentionDays")
        super.tearDown()
    }

    private func makeStore() -> HistoryStore { HistoryStore() }

    // MARK: - Export

    /// The JSON export uses the same Codable shape as history.json, so it
    /// must decode back into exactly the stored entries.
    func testExportJSONRoundTripsEntriesExactly() throws {
        let store = makeStore()
        store.add("first dictation", duration: 1.5)
        store.add("second dictation", duration: 2.5)
        store.add("third dictation")

        let data = try store.exportJSONData()
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)

        XCTAssertEqual(decoded, store.entries)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.first?.text, "third dictation")
    }

    /// One bullet per transcript, header first, newlines inside a
    /// transcript flattened so each entry stays on one line.
    func testExportMarkdownListsEveryEntryOnOneBulletLine() throws {
        let store = makeStore()
        store.add("plain line")
        store.add("multi\nline\ntext")

        let markdown = store.exportMarkdown()
        let lines = markdown.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, "# Murmur History")
        let bullets = lines.filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 2)
        XCTAssertTrue(bullets.contains { $0.contains("multi line text") },
                      "newlines should be flattened: \(markdown)")
        XCTAssertFalse(markdown.contains("\nmulti"))
    }

    func testStaticMarkdownBuilderIsDeterministicForFixedDates() {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let entries = [
            HistoryEntry(text: "hello world", date: date, id: "id-1"),
        ]
        let output = HistoryStore.makeMarkdown(from: entries)
        // The timestamp renders in the local zone, so derive the expected
        // stamp with an identically-configured formatter and assert on the
        // surrounding structure (header, bullet, em dash, trailing newline).
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = stampFormatter.string(from: date)
        XCTAssertEqual(
            output,
            "# Murmur History\n\n- \(stamp) — hello world\n",
            "fixed-format output keeps the export stable across locales")
    }

    // MARK: - History limit

    /// Out-of-range values are clamped on write; unset falls back to 50.
    func testHistoryLimitClampsToTenThroughThousand() {
        Settings.historyLimit = 5
        XCTAssertEqual(Settings.historyLimit, 10)
        Settings.historyLimit = 5000
        XCTAssertEqual(Settings.historyLimit, 1000)
        UserDefaults.standard.removeObject(forKey: "historyLimit")
        XCTAssertEqual(Settings.historyLimit, 50)
    }

    /// Appends trim the oldest entries once the configured limit is hit,
    /// keeping the newest ones at the front.
    func testAppendTrimsToConfiguredLimit() {
        let store = makeStore()
        Settings.historyLimit = 10
        for index in 0..<15 {
            store.add("entry \(index)")
        }

        XCTAssertEqual(store.entries.count, 10)
        XCTAssertEqual(store.entries.first?.text, "entry 14")
        XCTAssertEqual(store.entries.last?.text, "entry 5")

        // Raising the limit never regrows dropped history.
        Settings.historyLimit = 20
        store.enforceLimit()
        XCTAssertEqual(store.entries.count, 10)

        // New appends respect the raised ceiling...
        for index in 15..<25 {
            store.add("entry \(index)")
        }
        XCTAssertEqual(store.entries.count, 20)

        // ...and lowering it applies immediately via enforceLimit().
        Settings.historyLimit = 15
        store.enforceLimit()
        XCTAssertEqual(store.entries.count, 15)
        XCTAssertEqual(store.entries.first?.text, "entry 24")
        XCTAssertEqual(store.entries.last?.text, "entry 10")
    }
}
