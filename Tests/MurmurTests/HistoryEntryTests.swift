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
