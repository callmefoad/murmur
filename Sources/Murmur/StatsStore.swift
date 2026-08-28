import Foundation
import os

struct LifetimeStats: Codable {
    var dictations = 0
    var words = 0
    /// Words and seconds from entries that had a known duration, for WPM.
    var timedWords = 0
    var timedSeconds = 0.0
    /// "yyyy-MM-dd" -> words dictated that day. Source of truth for both
    /// the day streak (key presence) and the last-7-days chart (values).
    var dailyWords: [String: Int] = [:]
    var seeded = false

    /// Days with at least one dictation. Derived from `dailyWords` so there's
    /// a single source of truth — a day is "active" purely by having a key
    /// in `dailyWords`, regardless of its word count (a migrated day from an
    /// old `activeDays`-only payload has a key with value 0; see
    /// `init(from:)`).
    var activeDays: Set<String> { Set(dailyWords.keys) }

    /// Cap on distinct days kept in `dailyWords`, pruned oldest-first on
    /// every write. One entry per active day is tiny (~365/year), but this
    /// bounds unbounded growth for a long-lived install; ~400 days gives a
    /// little over a year of headroom past the streak/chart's actual needs.
    static let maxTrackedDays = 400

    init() {}

    private enum CodingKeys: String, CodingKey {
        case dictations, words, timedWords, timedSeconds, dailyWords, seeded
    }

    /// Old payloads (before per-day word counts existed) only have this key.
    private enum LegacyCodingKeys: String, CodingKey {
        case activeDays
    }

    /// Custom decoding so a future added field with a missing key falls back
    /// to its default instead of throwing `keyNotFound` and failing the
    /// whole decode. The synthesized `Decodable` has no such tolerance — a
    /// single missing key would make `StatsStore.init()` swallow the error
    /// via `try?`, fall back to a zero-value `LifetimeStats` with
    /// `seeded == false`, and silently re-seed lifetime totals from the
    /// 50-entry-capped history, discarding everything beyond it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dictations = try container.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
        timedWords = try container.decodeIfPresent(Int.self, forKey: .timedWords) ?? 0
        timedSeconds = try container.decodeIfPresent(Double.self, forKey: .timedSeconds) ?? 0.0
        if let decoded = try container.decodeIfPresent([String: Int].self, forKey: .dailyWords) {
            dailyWords = decoded
        } else {
            // Migrating an old payload that only recorded which days were
            // active, not per-day word counts. Seed those day keys at 0
            // words so the day streak keeps working uninterrupted — do NOT
            // fabricate a word count for history we don't have; the chart
            // renders these as "activity, unknown amount" rather than a
            // bare zero (see MainView's InsightsPage).
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let oldActiveDays = try legacyContainer.decodeIfPresent(
                Set<String>.self, forKey: .activeDays) ?? []
            dailyWords = Dictionary(uniqueKeysWithValues: oldActiveDays.map { ($0, 0) })
        }
        seeded = try container.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        pruneOldDays()
    }

    /// Keeps `dailyWords` bounded to the most recent `maxTrackedDays` days,
    /// dropping the oldest first. Day keys are fixed-width "yyyy-MM-dd"
    /// strings, so lexicographic order is chronological order.
    mutating func pruneOldDays() {
        guard dailyWords.count > Self.maxTrackedDays else { return }
        let excess = dailyWords.count - Self.maxTrackedDays
        for key in dailyWords.keys.sorted().prefix(excess) {
            dailyWords.removeValue(forKey: key)
        }
    }
}

/// Append-only lifetime stats, independent of HistoryStore's 50-entry cap.
/// The History panel is a recent-transcripts view; this is the source of
/// truth for totals like word count, WPM, and day streak so they don't
/// regress once dictation count exceeds the history limit.
final class StatsStore {
    private(set) var stats = LifetimeStats()
    private let logger = Logger(subsystem: "local.murmur", category: "stats")
    /// Serial FIFO queue for disk writes, shared by every instance.
    /// `record` mutates on the main actor and enqueues an immutable
    /// snapshot, so rapid dictations persist stats.json in recording order
    /// and the encode+write never runs on main.
    private static let writer = DispatchQueue(
        label: "local.murmur.stats", qos: .utility)

    /// Blocks until every snapshot enqueued so far has hit disk. Tests
    /// share the real on-disk file and need a quiesced state across
    /// setUp/tearDown boundaries.
    static func flushPendingWrites() {
        writer.sync(flags: .barrier) {}
    }
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("stats.json")
    }

    /// Fixed-format day key, independent of the system locale.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    init() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                stats = try JSONDecoder().decode(LifetimeStats.self, from: data)
            } catch {
                logger.error(
                    """
                    Failed to load \(self.fileURL.path, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
    }

    /// Records one dictation into the lifetime totals.
    func record(_ entry: HistoryEntry) {
        stats.dictations += 1
        stats.words += entry.wordCount
        if (entry.duration ?? 0) > 1 {
            stats.timedWords += entry.wordCount
            stats.timedSeconds += entry.duration ?? 0
        }
        stats.dailyWords[Self.dayKey(for: entry.date), default: 0] += entry.wordCount
        stats.pruneOldDays()
        save()
    }

    /// One-time backfill from existing history so lifetime stats aren't
    /// empty on first launch after this store was introduced. Runs over the
    /// (already retention-pruned) surviving history entries, so it can
    /// compute real per-day word counts for them.
    func seed(from entries: [HistoryEntry]) {
        guard !stats.seeded else { return }
        for entry in entries {
            stats.dictations += 1
            stats.words += entry.wordCount
            if (entry.duration ?? 0) > 1 {
                stats.timedWords += entry.wordCount
                stats.timedSeconds += entry.duration ?? 0
            }
            stats.dailyWords[Self.dayKey(for: entry.date), default: 0] += entry.wordCount
        }
        stats.pruneOldDays()
        stats.seeded = true
        save()
    }

    /// Consecutive days (through today, or yesterday if today has no
    /// entry yet) with at least one dictation.
    var dayStreak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if !stats.activeDays.contains(Self.dayKey(for: day)) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while stats.activeDays.contains(Self.dayKey(for: day)) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Lifetime words-per-minute across all timed dictations, if any.
    var wordsPerMinute: Int? {
        guard stats.timedSeconds > 0 else { return nil }
        return Int(Double(stats.timedWords) / (stats.timedSeconds / 60))
    }

    private func save() {
        // Snapshot the value-type struct now: the writer encodes an
        // immutable copy, so a later mutation on the main thread can't tear
        // it, and serial FIFO submission keeps write order == record order.
        let snapshot = stats
        let url = fileURL
        Self.writer.async { [logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                AppPaths.secure(url)
            } catch {
                logger.error(
                    """
                    Failed to save \(url.path, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
    }
}
