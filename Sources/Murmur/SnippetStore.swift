import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say during dictation.
    var trigger: String
    /// What gets inserted instead (exact casing preserved).
    var expansion: String
}

/// Voice shortcuts: saying a trigger phrase mid-dictation inserts the saved
/// text block — like Wispr Flow's Snippets.
enum SnippetStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("snippets.json")
    }

    static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: fileURL),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return [] }
        return snippets
    }

    static func save(_ snippets: [Snippet]) {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
            AppPaths.secure(fileURL)
        }
    }

    /// Replaces spoken trigger phrases with their expansions.
    /// Case-insensitive whole-phrase match; the expansion keeps its saved
    /// casing and is inserted literally. One pass over the original text,
    /// so an expansion can never be rewritten by another snippet: with
    /// "email" -> "me@example.com" and "com" -> "Company", "email" expands
    /// to "me@example.com" and stops there.
    static func expand(in text: String) -> String {
        let entries = load()
            .map { (key: $0.trigger.trimmingCharacters(in: .whitespaces),
                    value: $0.expansion) }
            .filter { !$0.key.isEmpty }
        return PhraseReplacer.replace(in: text, using: entries)
    }
}
