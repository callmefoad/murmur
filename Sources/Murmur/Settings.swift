import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// One-time import of preferences saved under the app's pre-rename
    /// bundle id (local.whisperflow). Call before anything reads Settings.
    static func migrateLegacyDefaults() {
        migrateTwoSpeedDefault()
        guard defaults.object(forKey: "hotkey") == nil,
              defaults.object(forKey: "locale") == nil,
              let legacy = UserDefaults(suiteName: "local.whisperflow")
        else { return }
        for key in ["hotkey", "locale", "styleDefault", "styleOverrides"] {
            if defaults.object(forKey: key) == nil,
               let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// The previous release defaulted ordinary holds to Polished. Move that
    /// default to Cleaned once; double-tap is now the explicit polished path.
    private static func migrateTwoSpeedDefault() {
        let marker = "didMigrateTwoSpeedDefault"
        guard !defaults.bool(forKey: marker) else { return }
        if defaults.object(forKey: "cleanupLevel") as? Int == 2 {
            defaults.set(1, forKey: "cleanupLevel")
        }
        defaults.set(true, forKey: marker)
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// Recognition engine: "apple" (instant), "parakeet" (fast,
    /// accurate) or "whisper" (precise).
    static var engine: String {
        get { defaults.string(forKey: "engine") ?? "apple" }
        set { defaults.set(newValue, forKey: "engine") }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    /// Live transcription: feed the microphone to SpeechAnalyzer while the
    /// user speaks instead of transcribing the finished file afterwards.
    /// Apple engine only (WhisperKit needs a finished file).
    ///
    /// On by default, because transcribing after release is pure added wait:
    /// measured at ~230 ms for 11 s of speech, plus the four-file vocabulary
    /// read that the file path performs after key-up and this path performs
    /// at key-down. The `.caf` is still written either way, so a streaming
    /// failure falls back to the file and costs only the time it saved.
    /// Turn it off with
    /// `defaults write local.murmur streamingTranscription -bool false`.
    static var streamingTranscription: Bool {
        get { defaults.object(forKey: "streamingTranscription") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "streamingTranscription") }
    }

    /// Whether recognized text gets a trailing period auto-appended.
    static var autoPeriod: Bool {
        get { defaults.object(forKey: "autoPeriod") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPeriod") }
    }

    /// Rejoins sentences the recognizer split at a breath rather than at a
    /// real boundary ("the primary blender. Motor." -> "the primary
    /// blender motor"). Punctuation repair only: the pass deletes a
    /// period and lowercases the letter behind it, never touching words,
    /// so it cannot reinterpret what was said. On by default.
    static var joinFragments: Bool {
        get { defaults.object(forKey: "joinFragments") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "joinFragments") }
    }

    /// Re-punctuate dictations by grammar with the on-device punctuation
    /// model, instead of keeping a period at every pause. ON by default.
    /// Only punctuation and first-letter case can change; see `Punctuator`.
    static var grammarPunctuation: Bool {
        get { defaults.object(forKey: "grammarPunctuation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "grammarPunctuation") }
    }

    /// The punctuation model is English only, and Verbatim means verbatim.
    static var usesGrammarPunctuation: Bool {
        grammarPunctuation
            && locale.language.languageCode == .english
            && CleanupLevel.resolve(cleanupLevel) != .verbatim
    }

    /// How aggressively dictations are cleaned up: 0 Verbatim,
    /// 1 Cleaned (default), 2 Polished, 3 Tightened.
    ///
    /// The unset default is Cleaned. Double-tapping the dictation key requests
    /// one Polished pass explicitly. The model path once turned a dictation
    /// mentioning "caveman mode" into caveman speech, so four
    /// independent defences stand between those facts, none of which is a
    /// prompt asking the model to behave:
    ///   1. the transcript is delimited as data, with lookalike tags
    ///      neutralized, so it is never the conversational turn;
    ///   2. `isPlausibleRewrite` discards output that diverges from the
    ///      input in length, content-word recall, or precision;
    ///   3. `introducedBannedPhrasing` discards output that reaches for
    ///      vocabulary or punctuation the speaker did not use;
    ///   4. every rejection degrades to the rules-only text, silently.
    /// Normal hold-to-talk never rewords unless changed here. Its only model
    /// is `Punctuator`, which labels words and cannot generate any.
    static var cleanupLevel: Int {
        get {
            let level = defaults.object(forKey: "cleanupLevel") as? Int ?? 1
            return min(max(level, 0), 3)
        }
        set { defaults.set(newValue, forKey: "cleanupLevel") }
    }

    /// Spoken edit commands ("scratch that", "never mind", "delete last
    /// sentence") acting on the finished dictation. OFF by default: those
    /// are ordinary English phrases, and Murmur cannot tell a retraction
    /// from someone simply saying the words, so an un-opted-in user must
    /// never have text silently eaten. When false, `SpeechEdits` never
    /// runs and the transcript passes through byte-for-byte.
    static var spokenEdits: Bool {
        get { defaults.object(forKey: "spokenEdits") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "spokenEdits") }
    }

    /// Spoken layout commands ("new line", "new paragraph") turning into
    /// real breaks. ON by default — standard dictation behavior and the
    /// only way to produce a paragraph by voice — but killable for anyone
    /// who dictates those words literally. Additive only: it can insert a
    /// break, never delete text.
    static var spokenLayout: Bool {
        get { defaults.object(forKey: "spokenLayout") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "spokenLayout") }
    }

    /// Spoken symbol tokens ("period" -> ".", "question mark" -> "?",
    /// "comma" -> ",") converting into glyphs. ON by default so explicit
    /// punctuation words are honored even when the recognizer leaves them
    /// literal. Turn it off when dictating ordinary words such as "star",
    /// "dash" or "period"; protected collocations remain shielded either way.
    static var spokenSymbols: Bool {
        get { defaults.object(forKey: "spokenSymbols") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "spokenSymbols") }
    }

    /// Floating microphone/waveform HUD shown while dictating.
    static var liveCaptions: Bool {
        get { defaults.object(forKey: "liveCaptions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "liveCaptions") }
    }

    /// Last-known dashboard window frame, encoded with `NSStringFromRect`.
    static var dashboardWindowFrame: String? {
        get { defaults.string(forKey: "dashboardWindowFrame") }
        set { defaults.set(newValue, forKey: "dashboardWindowFrame") }
    }

    /// When true, the dictation hotkey is swallowed via a session event tap
    /// so the frontmost app never sees it. On by default for fn: otherwise
    /// macOS may interpret a double-press as its own Dictation shortcut and
    /// show a competing microphone HUD. Turn it off if you rely on fn+arrows,
    /// fn+Delete, or fn+F-keys in other apps.
    static var consumeHotkey: Bool {
        get { defaults.object(forKey: "consumeHotkey") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "consumeHotkey") }
    }

    /// When true, dictations are not written to History.
    static var historyPaused: Bool {
        get { defaults.bool(forKey: "historyPaused") }
        set { defaults.set(newValue, forKey: "historyPaused") }
    }

    /// Days of History to retain; 0 means keep forever.
    static var historyRetentionDays: Int {
        get { defaults.integer(forKey: "historyRetentionDays") }
        set { defaults.set(newValue, forKey: "historyRetentionDays") }
    }

    /// Maximum number of transcripts kept in History. Values outside
    /// 10...1000 are clamped on both read and write; unset means 50.
    static var historyLimit: Int {
        get {
            let raw = defaults.object(forKey: "historyLimit") as? Int ?? 50
            return min(max(raw, 10), 1000)
        }
        set { defaults.set(min(max(newValue, 10), 1000), forKey: "historyLimit") }
    }

    /// UUID of the My Voice preset forced onto every dictation; nil means
    /// no forced preset (per-app bindings still resolve normally).
    static var selectedVoicePresetID: UUID? {
        get {
            guard let raw = defaults.string(forKey: "selectedVoicePresetID")
            else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: "selectedVoicePresetID")
            } else {
                defaults.removeObject(forKey: "selectedVoicePresetID")
            }
        }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}
