import XCTest
@testable import Murmur

final class WhisperEngineTests: XCTestCase {

    @MainActor
    func testWhisperLanguageMapping() {
        // (localeID, expected whisper token)
        let table: [(locale: String, expected: String)] = [
            // Common cases — must match the old naive prefix behavior.
            ("en", "en"),
            ("en-US", "en"),
            ("fr-FR", "fr"),
            ("de-DE", "de"),
            ("ja-JP", "ja"),
            ("es-MX", "es"),
            ("pt-BR", "pt"),

            // Chinese variants all map to "zh"; only explicit yue-* gets "yue".
            ("zh-Hans-CN", "zh"),
            ("zh-Hant-TW", "zh"),
            ("zh-HK", "zh"),
            ("cmn-Hant-TW", "zh"),
            ("yue", "yue"),
            ("yue-Hant-HK", "yue"),

            // Norwegian family.
            ("no-NO", "no"),
            ("nb-NO", "no"),
            ("nn-NO", "nn"),

            // Legacy ISO 639 codes macOS APIs still emit.
            ("iw-IL", "he"),
            ("he-IL", "he"),
            ("in-ID", "id"),
            ("ji", "yi"),

            // Javanese: ISO 639-1 vs Whisper token.
            ("jv-ID", "jw"),

            // Case-insensitive primary subtag.
            ("EN-us", "en"),
            ("SV-se", "sv"),

            // Unknown or malformed input falls back to English.
            ("xx-Klingon", "en"),
            ("", "en"),
            ("---US", "en"),
        ]

        for (locale, expected) in table {
            XCTAssertEqual(
                WhisperEngine.whisperLanguage(for: locale), expected,
                "locale \(locale) should map to \(expected)")
        }
    }

    @MainActor
    func testEveryOverrideTargetIsValidToken() {
        for target in WhisperEngine.languageOverrides.values {
            XCTAssertTrue(
                WhisperEngine.whisperTokens.contains(target),
                "override target \(target) is not a valid Whisper token")
        }
    }
}
