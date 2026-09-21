import Foundation

/// A command is only created when the speaker explicitly addresses Murmur by
/// name. Ordinary dictation never enters this type and therefore cannot cause
/// an app action by accident.
struct VoiceCommand: Equatable, Identifiable {
    enum Action: Equatable {
        case message(contact: String, draft: String)
    }

    let action: Action

    var id: String {
        switch action {
        case .message(let contact, let draft):
            return "message|\(contact.lowercased())|\(draft.lowercased())"
        }
    }

    var contactName: String {
        switch action {
        case .message(let contact, _): return contact
        }
    }

    var draft: String {
        switch action {
        case .message(_, let draft): return draft
        }
    }
}

/// Conservative first-pass parser for the explicit command surface. It is
/// intentionally grammar-based instead of model-based: command boundaries
/// stay deterministic, local, and testable, and a malformed command simply
/// falls through as ordinary dictation.
enum VoiceCommandParser {
    private static let messagePrefixes = [
        "open up my text messages with ",
        "open my text messages with ",
        "open up text messages with ",
        "open text messages with ",
        "open up my messages with ",
        "open my messages with ",
        "open up messages with ",
        "open messages with ",
        "open my imessages with ",
        "open imessages with ",
        "open my imessage with ",
        "open imessage with ",
    ]

    /// Parses commands such as:
    /// `Murmur, open up my text messages with Isaiah and ask him who ...`
    static func parse(_ text: String) -> VoiceCommand? {
        guard let body = addressedBody(from: text) else { return nil }
        var command = body
        for prefix in ["i need you to ", "please "] {
            if command.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                command.removeFirst(prefix.count)
                break
            }
        }

        guard let prefix = messagePrefixes.first(where: {
            command.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
        }) else { return nil }
        let remainder = String(command.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let marker = remainder.range(
            of: #"(?:\s+and\s+|[.!?]\s+)(?:ask|tell|send)\s+(?:him|her|them)\s+"#,
            options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let contact = remainder[..<marker.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",.!?")))
        let request = remainder[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty, let draft = normalizedDraft(request) else { return nil }

        return VoiceCommand(action: .message(contact: contact, draft: draft))
    }

    private static func addressedBody(from text: String) -> String? {
        var pieces = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, omittingEmptySubsequences: true,
                   whereSeparator: { $0.isWhitespace })
        guard let first = pieces.first?.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted),
              first.lowercased() == "murmur" else {
            return nil
        }
        guard pieces.count == 2 else { return nil }
        return pieces.removeLast()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",:;")))
    }

    private static func normalizedDraft(_ request: String) -> String? {
        var draft = request
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\"'")))
        while let last = draft.last, ".!?".contains(last) {
            draft.removeLast()
        }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return nil }

        draft = directQuestionForm(draft)

        if let first = draft.first {
            draft.replaceSubrange(draft.startIndex...draft.startIndex,
                                  with: first.uppercased())
        }
        let firstWord = draft.split(whereSeparator: { $0.isWhitespace })
            .first?.lowercased() ?? ""
        let questionStarters: Set<String> = [
            "who", "what", "when", "where", "why", "how", "is", "are",
            "am", "can", "could", "did", "do", "does", "will", "would",
            "should", "have", "has", "had",
        ]
        draft += questionStarters.contains(firstWord) ? "?" : "."
        return draft
    }

    /// Spoken requests often use an indirect-question order ("who the
    /// painter was"). A message preview reads naturally when that becomes
    /// "Who was the painter?"; this narrow rewrite never touches statements.
    private static func directQuestionForm(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.first?.lowercased() == "who", words.count > 2 else {
            return text
        }
        let copulas = Set(["is", "are", "was", "were"])
        guard let verbIndex = words.dropFirst().firstIndex(where: {
            copulas.contains($0.lowercased())
        }), verbIndex > 1 else {
            return text
        }
        let subject = words[1..<verbIndex]
        let tail = words[(verbIndex + 1)...]
        var reordered = ["Who", words[verbIndex]]
        reordered.append(contentsOf: subject)
        reordered.append(contentsOf: tail)
        return reordered.joined(separator: " ")
    }
}
