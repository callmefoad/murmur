import Foundation

/// How aggressively a dictation is cleaned up before insertion.
/// Persisted as the raw Int under the Settings key "cleanupLevel".
///
/// - verbatim: exactly what was spoken, except deliberate user intents
///   stay active — personal dictionary substitutions, snippet triggers,
///   and spoken layout commands ("new line"/"new paragraph") while the
///   "Spoken layout" setting is on (its default). No filler removal, no
///   auto-capitalization, no terminal period. Spoken *edit* commands
///   ("scratch that") and spoken *symbol* tokens ("comma" -> ",") are
///   each a separate opt-in and are off at every stop unless the user
///   turns them on.
/// - cleaned (default): the rule-based pass only (fillers out, caps,
///   punctuation). No model runs, so nothing the user says can ever be
///   read as an instruction — this is why it, and not `polished`, is the
///   stop an un-opted-in user lands on.
/// - polished: rules, then a light on-device model pass that fixes
///   grammar and flow without touching the speaker's words.
/// - tightened: rules, then a stronger on-device pass that condenses.
///
/// Levels 2 and 3 send the transcript to the on-device model. Their output
/// is checked by `RewriteEngine.isPlausibleRewrite` before it is inserted;
/// a rewrite that diverges implausibly is discarded in favor of the
/// rules-only text.
enum CleanupLevel: Int, CaseIterable, Identifiable {
    case verbatim = 0
    case cleaned = 1
    case polished = 2
    case tightened = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .cleaned: return "Cleaned"
        case .polished: return "Polished"
        case .tightened: return "Tightened"
        }
    }

    var blurb: String {
        switch self {
        case .verbatim:
            return "Verbatim — the raw transcript, exactly as recognized."
        case .cleaned:
            return "Cleaned — filler words and spoken commands removed."
        case .polished:
            return "Polished — cleaned up, punctuated, and capitalized."
        case .tightened:
            return "Tightened — polished, then condensed to the essentials."
        }
    }

    /// On-device model framing for levels 2 and 3; nil means rules-only.
    /// Pure for tests via RewriteEngine.polishPrompt(level:).
    var polishInstructions: String? {
        switch self {
        case .verbatim, .cleaned:
            return nil
        case .polished:
            return RewriteEngine.polishPrompt(level: .polished)
        case .tightened:
            return RewriteEngine.polishPrompt(level: .tightened)
        }
    }

    /// Clamps any persisted Int into a valid stop, so garbage or legacy
    /// UserDefaults values degrade to a sane level instead of crashing.
    static func resolve(_ raw: Int) -> CleanupLevel {
        CleanupLevel(rawValue: min(max(raw, 0), 3)) ?? .cleaned
    }
}
