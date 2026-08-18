import Foundation

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
    private let limit = 50
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
            // Persist any ids that were just minted for pre-migration entries.
            save()
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

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
            AppPaths.secure(fileURL)
        }
    }
}
