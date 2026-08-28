import XCTest
@testable import Murmur

/// Murmur transcribes; it does not obey. These cover the three switches that
/// decide whether the CONTENT of a dictation is allowed to change what gets
/// inserted, beyond neutral formatting.
final class VoiceCommandGatingTests: XCTestCase {

    // MARK: - Spoken edits gate

    /// Phrases that read as retractions to `SpeechEdits` but are ordinary
    /// speech to everyone else.
    private let hazardousTranscripts = [
        "Scratch that.",
        "Never mind.",
        "Sorry, never mind.",
        "That looks great, scratch that.",
        "Delete last sentence.",
        "Um, scratch that.",
    ]

    func testSpokenEditsOffLeavesEveryTranscriptUntouched() {
        for transcript in hazardousTranscripts {
            let plan = SpeechEdits.gatedPlan(
                currentTranscript: transcript,
                previousText: "The earlier insertion.",
                enabled: false)
            XCTAssertEqual(
                plan, SpeechEdits.Plan(outcome: .none),
                "gate leaked for \"\(transcript)\"")
            XCTAssertNil(plan.combinedReplacement)
        }
    }

    /// The gate is the only thing that changed: with it on, every ruling is
    /// byte-for-byte what `SpeechEdits.plan` decides on its own.
    func testSpokenEditsOnMatchesUngatedPlanExactly() {
        for transcript in hazardousTranscripts {
            let previous = "The earlier insertion."
            XCTAssertEqual(
                SpeechEdits.gatedPlan(
                    currentTranscript: transcript, previousText: previous,
                    enabled: true),
                SpeechEdits.plan(
                    currentTranscript: transcript, previousText: previous),
                "gated ruling diverged for \"\(transcript)\"")
        }
    }

    func testSpokenEditsOffDoesNotDiscardWholeDictation() {
        let plan = SpeechEdits.gatedPlan(
            currentTranscript: "Scratch that.", previousText: "Earlier text.",
            enabled: false)
        XCTAssertNotEqual(plan.outcome, .discardAll)
    }

    // MARK: - Spoken layout gate

    func testSpokenLayoutOffKeepsNewLineLiteral() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format(
                "I need to add a new line to the config",
                autoPeriod: true, spokenLayout: false),
            "I need to add a new line to the config.")
    }

    func testSpokenLayoutOffKeepsNewParagraphLiteral() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format(
                "start a new paragraph here",
                autoPeriod: true, spokenLayout: false),
            "Start a new paragraph here.")
    }

    func testSpokenLayoutOnStillBreaks() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format(
                "first line new line second line",
                autoPeriod: true, spokenLayout: true),
            "First line\nSecond line.")
        XCTAssertEqual(
            formatter.format(
                "intro new paragraph details here",
                autoPeriod: true, spokenLayout: true),
            "Intro\n\nDetails here.")
    }

    func testVerbatimHonorsSpokenLayoutBothWays() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.formatVerbatim(
                "um first line new line second line", spokenLayout: true),
            "um first line\nsecond line")
        XCTAssertEqual(
            formatter.formatVerbatim(
                "um first line new line second line", spokenLayout: false),
            "um first line new line second line")
    }

    // MARK: - Spoken symbols gate

    /// Ordinary sentences whose words collide with the symbol vocabulary.
    private let hazardousSymbolTranscripts = [
        "add a star there",
        "the dash between them",
        "at the end of the period",
        "a colon in the sentence",
    ]

    func testSpokenSymbolsOffKeepsHazardousWordsLiteral() {
        let formatter = TextFormatter(dictionary: [:])
        for transcript in hazardousSymbolTranscripts {
            let got = formatter.format(
                transcript, autoPeriod: false, spokenLayout: false,
                spokenSymbols: false)
            XCTAssertEqual(
                got, transcript.prefix(1).uppercased() + transcript.dropFirst(),
                "symbol gate leaked for \"\(transcript)\"")
        }
    }

    func testSpokenSymbolsOnConvertsTheSameTranscripts() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format(
                "add a star there", autoPeriod: false, spokenLayout: false,
                spokenSymbols: true),
            "Add a * there")
        XCTAssertEqual(
            formatter.format(
                "hello comma world period", autoPeriod: false,
                spokenLayout: false, spokenSymbols: true),
            "Hello, world.")
    }

    /// The escape hatch and the collocation shield are part of the gated
    /// pass; with the gate on they behave exactly as before.
    func testEscapeHatchAndProtectedPhrasesStillWorkWhenOn() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.format(
                "say literally comma now", autoPeriod: true,
                spokenLayout: false, spokenSymbols: true),
            "Say comma now.")
        XCTAssertEqual(
            formatter.format(
                "a classic period piece film", autoPeriod: true,
                spokenLayout: false, spokenSymbols: true),
            "A classic period piece film.")
        XCTAssertEqual(
            formatter.format(
                "a five star rating indeed period", autoPeriod: true,
                spokenLayout: false, spokenSymbols: true),
            "A five star rating indeed.")
    }

    func testVerbatimHonorsSpokenSymbolsBothWays() {
        let formatter = TextFormatter(dictionary: [:])
        XCTAssertEqual(
            formatter.formatVerbatim(
                "hello comma world period", spokenLayout: false,
                spokenSymbols: true),
            "hello, world.")
        XCTAssertEqual(
            formatter.formatVerbatim(
                "hello comma world period", spokenLayout: false,
                spokenSymbols: false),
            "hello comma world period")
        XCTAssertEqual(
            formatter.formatVerbatim(
                "add a star there", spokenLayout: false, spokenSymbols: false),
            "add a star there")
    }

    // MARK: - Defaults

    func testDefaultsAreOffForEditsAndSymbolsAndOnForLayout() {
        let defaults = UserDefaults.standard
        let savedEdits = defaults.object(forKey: "spokenEdits")
        let savedLayout = defaults.object(forKey: "spokenLayout")
        let savedSymbols = defaults.object(forKey: "spokenSymbols")
        defaults.removeObject(forKey: "spokenEdits")
        defaults.removeObject(forKey: "spokenLayout")
        defaults.removeObject(forKey: "spokenSymbols")
        defer {
            if let savedEdits { defaults.set(savedEdits, forKey: "spokenEdits") }
            if let savedLayout { defaults.set(savedLayout, forKey: "spokenLayout") }
            if let savedSymbols { defaults.set(savedSymbols, forKey: "spokenSymbols") }
        }

        XCTAssertFalse(Settings.spokenEdits)
        XCTAssertTrue(Settings.spokenLayout)
        XCTAssertFalse(Settings.spokenSymbols)
    }

    func testSettingsRoundTripAllThreeKeys() {
        let defaults = UserDefaults.standard
        let savedEdits = defaults.object(forKey: "spokenEdits")
        let savedLayout = defaults.object(forKey: "spokenLayout")
        let savedSymbols = defaults.object(forKey: "spokenSymbols")
        defer {
            defaults.removeObject(forKey: "spokenEdits")
            defaults.removeObject(forKey: "spokenLayout")
            defaults.removeObject(forKey: "spokenSymbols")
            if let savedEdits { defaults.set(savedEdits, forKey: "spokenEdits") }
            if let savedLayout { defaults.set(savedLayout, forKey: "spokenLayout") }
            if let savedSymbols { defaults.set(savedSymbols, forKey: "spokenSymbols") }
        }

        Settings.spokenEdits = true
        Settings.spokenLayout = false
        Settings.spokenSymbols = true
        XCTAssertTrue(Settings.spokenEdits)
        XCTAssertFalse(Settings.spokenLayout)
        XCTAssertTrue(Settings.spokenSymbols)
    }

}
