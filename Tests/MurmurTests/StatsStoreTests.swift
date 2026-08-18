import XCTest
@testable import Murmur

/// `StatsStore.init()` reads `~/Library/Application Support/Murmur/stats.json`
/// on disk, so it must never be instantiated in tests — that would touch
/// the user's real data. Only `LifetimeStats`, a plain in-memory `Codable`
/// struct, is exercised here. The day-streak and WPM logic live on
/// `StatsStore` itself and are disk-backed, so they are skipped.
final class StatsStoreTests: XCTestCase {

    /// Mirrors `StatsStore`'s private day-key formatter so day-key format
    /// assumptions can be verified without instantiating `StatsStore`.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func testLifetimeStatsCodableRoundTrip() throws {
        var stats = LifetimeStats()
        stats.dictations = 12
        stats.words = 340
        stats.timedWords = 300
        stats.timedSeconds = 120.5
        stats.dailyWords = ["2026-08-15": 100, "2026-08-16": 140, "2026-08-17": 100]
        stats.seeded = true

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: data)

        XCTAssertEqual(decoded.dictations, stats.dictations)
        XCTAssertEqual(decoded.words, stats.words)
        XCTAssertEqual(decoded.timedWords, stats.timedWords)
        XCTAssertEqual(decoded.timedSeconds, stats.timedSeconds)
        XCTAssertEqual(decoded.dailyWords, stats.dailyWords)
        XCTAssertEqual(decoded.seeded, stats.seeded)
        // activeDays is derived from dailyWords — verify it stays in sync.
        XCTAssertEqual(decoded.activeDays, Set(stats.dailyWords.keys))
    }

    func testLifetimeStatsDefaultsAreEmpty() {
        let stats = LifetimeStats()
        XCTAssertEqual(stats.dictations, 0)
        XCTAssertEqual(stats.words, 0)
        XCTAssertEqual(stats.timedWords, 0)
        XCTAssertEqual(stats.timedSeconds, 0.0)
        XCTAssertTrue(stats.dailyWords.isEmpty)
        XCTAssertTrue(stats.activeDays.isEmpty)
        XCTAssertFalse(stats.seeded)
    }

    /// Old `stats.json` files (before per-day word counts existed) only
    /// have `activeDays`, no `dailyWords`. This is exactly the user's live
    /// file shape reported in the task:
    /// {"seeded": true, "dictations": 52, "words": 3724, "timedWords": 3724,
    ///  "timedSeconds": 1378.09, "activeDays": [13 days]}
    /// Decoding it must not throw, must preserve every existing count
    /// exactly, and must seed `dailyWords` with those day keys at 0 words
    /// (not fabricate a count) so the day streak keeps working.
    func testDecodingOldPayloadWithoutDailyWordsSeedsDayKeysAtZero() throws {
        let activeDays = [
            "2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09",
            "2026-08-10", "2026-08-11", "2026-08-12", "2026-08-13",
            "2026-08-14", "2026-08-15", "2026-08-16", "2026-08-17", "2026-08-18"
        ]
        let json = """
        {
            "seeded": true,
            "dictations": 52,
            "words": 3724,
            "timedWords": 3724,
            "timedSeconds": 1378.09,
            "activeDays": \(try jsonArrayString(activeDays))
        }
        """
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.seeded, true)
        XCTAssertEqual(decoded.dictations, 52)
        XCTAssertEqual(decoded.words, 3724)
        XCTAssertEqual(decoded.timedWords, 3724)
        XCTAssertEqual(decoded.timedSeconds, 1378.09)
        XCTAssertEqual(decoded.activeDays, Set(activeDays))
        // Migration must not fabricate word counts for days it doesn't know.
        for day in activeDays {
            XCTAssertEqual(decoded.dailyWords[day], 0)
        }
        XCTAssertEqual(decoded.dailyWords.count, activeDays.count)
    }

    /// A payload missing several fields entirely (not just `dailyWords`)
    /// must still decode via the `decodeIfPresent(...) ?? default` pattern
    /// rather than throwing `keyNotFound`.
    func testDecodingPayloadMissingManyFieldsFallsBackToDefaults() throws {
        let json = """
        { "words": 500 }
        """
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.words, 500)
        XCTAssertEqual(decoded.dictations, 0)
        XCTAssertEqual(decoded.timedWords, 0)
        XCTAssertEqual(decoded.timedSeconds, 0.0)
        XCTAssertTrue(decoded.dailyWords.isEmpty)
        XCTAssertFalse(decoded.seeded)
    }

    /// Decoding empty JSON `{}` must not throw either — the most extreme
    /// case of the decodeIfPresent tolerance.
    func testDecodingEmptyPayloadDoesNotThrow() throws {
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.dictations, 0)
        XCTAssertTrue(decoded.dailyWords.isEmpty)
        XCTAssertFalse(decoded.seeded)
    }

    func testDailyWordsRoundTrip() throws {
        var stats = LifetimeStats()
        stats.dailyWords = ["2026-01-01": 12, "2026-01-02": 0, "2026-12-31": 999]

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: data)

        XCTAssertEqual(decoded.dailyWords, stats.dailyWords)
    }

    /// Day keys must stay a fixed "yyyy-MM-dd" format independent of the
    /// system locale/calendar — this is what makes them safely comparable
    /// and sortable as plain strings (e.g. for pruning).
    func testDayKeyFormatIsFixedAndLocaleStable() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 5
        components.hour = 12
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let key = Self.dayKeyFormatter.string(from: date)
        XCTAssertEqual(key, "2026-03-05")
        XCTAssertEqual(key.count, 10)
        XCTAssertTrue(key.allSatisfy { $0.isNumber || $0 == "-" })

        // Re-parsing with the same fixed formatter must round-trip exactly,
        // regardless of what the user's system locale/calendar is set to.
        let reparsed = Self.dayKeyFormatter.date(from: key)
        XCTAssertNotNil(reparsed)
        XCTAssertEqual(Self.dayKeyFormatter.string(from: reparsed!), key)
    }

    /// `pruneOldDays` bounds `dailyWords` to `LifetimeStats.maxTrackedDays`,
    /// dropping the oldest (lexicographically smallest, since keys are
    /// fixed-width "yyyy-MM-dd") entries first.
    func testPruneOldDaysDropsOldestFirst() {
        var stats = LifetimeStats()
        let calendar = Calendar(identifier: .gregorian)
        let startDate = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!

        let totalDays = LifetimeStats.maxTrackedDays + 50
        var keys: [String] = []
        for offset in 0..<totalDays {
            let date = calendar.date(byAdding: .day, value: offset, to: startDate)!
            let key = Self.dayKeyFormatter.string(from: date)
            keys.append(key)
            stats.dailyWords[key] = offset
        }
        XCTAssertEqual(stats.dailyWords.count, totalDays)

        stats.pruneOldDays()

        XCTAssertEqual(stats.dailyWords.count, LifetimeStats.maxTrackedDays)
        let sortedKeys = keys.sorted()
        let expectedDropped = sortedKeys.prefix(50)
        let expectedKept = sortedKeys.suffix(LifetimeStats.maxTrackedDays)
        for key in expectedDropped {
            XCTAssertNil(stats.dailyWords[key], "expected oldest day \(key) to be pruned")
        }
        for key in expectedKept {
            XCTAssertNotNil(stats.dailyWords[key], "expected recent day \(key) to survive pruning")
        }
    }

    func testPruneOldDaysIsNoOpUnderCap() {
        var stats = LifetimeStats()
        stats.dailyWords = ["2026-01-01": 5, "2026-01-02": 10]
        stats.pruneOldDays()
        XCTAssertEqual(stats.dailyWords.count, 2)
    }

    private func jsonArrayString(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        return String(data: data, encoding: .utf8)!
    }
}
