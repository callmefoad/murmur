import Foundation
import os

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let date: Date
    /// Length of the recording, if known. Used for words-per-minute stats.
    var duration: TimeInterval?

    init(text: String, date: Date, duration: TimeInterval? = nil,
         id: String = UUID().uuidString) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, date, duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        // Entries written before ids were persisted get one assigned on first load.
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Persists the most recent transcripts, like Wispr Flow's history panel.
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    /// How many entries to keep, from the user-adjustable setting
    /// (clamped to 10...1000 there). Read live so a lowered limit
    /// takes effect on the next append or explicit trim.
    private var limit: Int { Settings.historyLimit }
    private let logger = Logger(subsystem: "local.murmur", category: "history")
    /// Injection seam for tests: when set, all reads/writes go to this file
    /// instead of the real support directory — which both the running app
    /// and in-flight writer-queue jobs may rewrite concurrently.
    /// `nonisolated(unsafe)`: tests set this once in setUp before any store
    /// instance exists; production code never touches it.
    nonisolated(unsafe) static var fileOverride: URL?
    /// Serial FIFO queue for disk writes, shared by every instance.
    /// Mutations stay on the main actor and enqueue an immutable snapshot
    /// each time, so rapid dictations persist history.json in insertion
    /// order even though `add` returns before the write lands — and the
    /// encode+write never runs on main.
    private static let writer = DispatchQueue(
        label: "local.murmur.history", qos: .utility)

    /// Blocks until every snapshot enqueued so far has hit disk. Tests
    /// share the real on-disk file and need a quiesced state across
    /// setUp/tearDown boundaries.
    static func flushPendingWrites() {
        writer.sync(flags: .barrier) {}
    }
    private var fileURL: URL {
        Self.fileOverride ?? AppPaths.supportDirectory.appendingPathComponent(
            "history.json")
    }

    init() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
                // Persist any ids that were just minted for pre-migration entries.
                save()
            } catch {
                logger.error(
                    """
                    Failed to load \(self.fileURL.path, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        prune()
    }

    func add(_ text: String, duration: TimeInterval? = nil) {
        guard !Settings.historyPaused else { return }
        entries.insert(HistoryEntry(text: text, date: Date(), duration: duration), at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
        prune()
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func update(id: String, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = HistoryEntry(
            text: text, date: entries[index].date, duration: entries[index].duration,
            id: entries[index].id)
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Drops entries older than the configured retention window, if any.
    func prune() {
        guard Settings.historyRetentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(
            -Double(Settings.historyRetentionDays) * 24 * 60 * 60)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        if entries.count != before {
            save()
        }
    }

    /// Trims the oldest entries so the store fits the configured limit.
    /// Called when the user lowers the limit, so the change applies
    /// immediately instead of waiting for the next dictation.
    func enforceLimit() {
        guard entries.count > limit else { return }
        entries.removeLast(entries.count - limit)
        save()
    }

    // MARK: Export

    func exportJSONData() throws -> Data {
        try Self.makeJSON(from: entries)
    }

    func exportMarkdown() -> String {
        Self.makeMarkdown(from: entries)
    }

    /// Pretty-printed JSON of `entries` using the same Codable shape as
    /// history.json, so an export decodes back to identical entries.
    static func makeJSON(from entries: [HistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    /// One bullet per transcript: `- yyyy-MM-dd HH:mm — text`. Newlines
    /// inside a transcript are flattened so each entry stays one line.
    static func makeMarkdown(from entries: [HistoryEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["# Murmur History", ""]
        lines.append(contentsOf: entries.map { entry in
            let text = entry.text.replacingOccurrences(of: "\n", with: " ")
            return "- \(formatter.string(from: entry.date)) — \(text)"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private func save() {
        // Snapshot the value-type array now: the writer encodes an immutable
        // copy, so a later mutation on the main thread can't tear it, and
        // serial FIFO submission keeps write order == mutation order.
        let snapshot = entries
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
