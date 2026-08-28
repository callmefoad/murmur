import AppKit
import Foundation
import os

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say during dictation.
    var trigger: String
    /// What gets inserted instead (exact casing preserved).
    var expansion: String
}

/// Voice shortcuts: saying a trigger phrase mid-dictation inserts the saved
/// text block — like Wispr Flow's Snippets.
/// Dynamic values usable inside snippet expansions, written as
/// `{{name}}` double-brace tokens:
///
/// | Token          | Expands to                                   |
/// |----------------|----------------------------------------------|
/// | `{{clipboard}}`| Current clipboard string, or "" if none      |
/// | `{{date}}`     | Long local date, e.g. "August 25, 2026"      |
/// | `{{time}}`     | Short local time, e.g. "3:42 PM"             |
/// | `{{datetime}}` | Both of the above, locale-joined             |
///
/// The grammar is strict: a token is exactly `{{`, optional whitespace,
/// ASCII letters, optional whitespace, `}}`. Anything else — one brace
/// missing, digits, internal spaces, unknown names — passes through
/// verbatim, so user text that merely looks like a template is never
/// mangled. Matching is case-insensitive (`{{Date}}` works) but the
/// passthrough always preserves what was typed.
enum SnippetVariables {

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z]+)\s*\}\}"#)

    /// Pure token expander: every input it needs arrives as a parameter,
    /// so this never touches the pasteboard or the clock and is fully
    /// deterministic in tests.
    ///
    /// - Parameters:
    ///   - clipboard: The clipboard text to substitute for `{{clipboard}}`.
    ///     Nil (image-only or empty clipboard) expands to an empty string —
    ///     leaving raw tokens in inserted text would be worse than silence.
    ///   - now: The instant `{{date}}`/`{{time}}`/`{{datetime}}` render.
    static func expand(
        in text: String,
        clipboard: String?,
        now: Date = Date()
    ) -> String {
        guard !text.isEmpty else { return text }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let matches = tokenPattern.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }

        // Assembled from match ranges like PhraseReplacer, so untouched
        // regions (including non-matching braces) survive byte-for-byte.
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            result += nsText.substring(
                with: NSRange(location: cursor, length: range.location - cursor))
            switch nsText.substring(with: match.range(at: 1)).lowercased() {
            case "clipboard":
                result += clipboard ?? ""
            case "date":
                result += formatted(now, dateStyle: .long, timeStyle: .none)
            case "time":
                result += formatted(now, dateStyle: .none, timeStyle: .short)
            case "datetime":
                result += formatted(now, dateStyle: .long, timeStyle: .short)
            default:
                // Not one of ours: emit the whole {{...}} exactly as typed.
                result += nsText.substring(with: range)
            }
            cursor = range.location + range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// Renders `instant` with a fresh DateFormatter built from the current
    /// locale and timezone. Built per call rather than cached so a locale
    /// or timezone change is picked up on the very next snippet.
    private static func formatted(
        _ instant: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: instant)
    }
}

enum SnippetStore {
    private static let logger = Logger(subsystem: "local.murmur", category: "snippets")

    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("snippets.json")
    }

    static func load() -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            logger.error(
                """
                Failed to load \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return []
        }
    }

    static func save(_ snippets: [Snippet]) {
        do {
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: fileURL, options: .atomic)
            AppPaths.secure(fileURL)
        } catch {
            logger.error(
                """
                Failed to save \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Where `{{clipboard}}` gets its text. Defaults to a synchronous
    /// NSPasteboard read on the calling thread (snippet expansion runs on
    /// the main thread); tests inject a stub here instead of writing to the
    /// real pasteboard. Confined to the main thread by convention.
    nonisolated(unsafe) static var clipboardProvider: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }

    /// Replaces spoken trigger phrases with their expansions.
    /// Case-insensitive whole-phrase match; the expansion keeps its saved
    /// casing and is inserted literally. One pass over the original text,
    /// so an expansion can never be rewritten by another snippet: with
    /// "email" -> "me@example.com" and "com" -> "Company", "email" expands
    /// to "me@example.com" and stops there.
    ///
    /// Afterwards any `{{...}}` tokens inside the result are expanded once —
    /// tokens in dictated text work too, since this runs over the whole
    /// transcript. The pasteboard is only consulted when at least one token
    /// candidate (`{{`) is actually present.
    static func expand(in text: String) -> String {
        let entries = load()
            .map { (key: $0.trigger.trimmingCharacters(in: .whitespaces),
                    value: $0.expansion) }
            .filter { !$0.key.isEmpty }
        let replaced = PhraseReplacer.replace(in: text, using: entries)
        guard replaced.contains("{{") else { return replaced }
        return SnippetVariables.expand(in: replaced, clipboard: clipboardProvider())
    }
}
