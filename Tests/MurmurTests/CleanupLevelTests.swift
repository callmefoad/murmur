import XCTest
@testable import Murmur

final class CleanupLevelTests: XCTestCase {

    override func tearDown() {
        // Mirror InsertionTrackerTests' custom-window approach: poke the
        // real UserDefaults key directly, then remove it so no state leaks
        // into other tests (and never into the live app's defaults domain
        // beyond this key, which the app re-reads per insertion anyway).
        UserDefaults.standard.removeObject(forKey: "cleanupLevel")
        super.tearDown()
    }

    // MARK: Labels and blurbs

    func testRawValuesMatchPersistedStops() {
        XCTAssertEqual(CleanupLevel.verbatim.rawValue, 0)
        XCTAssertEqual(CleanupLevel.cleaned.rawValue, 1)
        XCTAssertEqual(CleanupLevel.polished.rawValue, 2)
        XCTAssertEqual(CleanupLevel.tightened.rawValue, 3)
    }

    func testLabelsAreNonEmptyAndDistinct() {
        let labels = CleanupLevel.allCases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, CleanupLevel.allCases.count)
    }

    func testBlurbsStartWithTheirLabelAndAreDistinct() {
        for level in CleanupLevel.allCases {
            XCTAssertTrue(
                level.blurb.hasPrefix(level.label),
                "\(level.label)'s blurb must start with its label")
        }
        XCTAssertEqual(
            Set(CleanupLevel.allCases.map(\.blurb)).count,
            CleanupLevel.allCases.count)
    }

    func testResolveClampsGarbageToValidStops() {
        XCTAssertEqual(CleanupLevel.resolve(-1), .verbatim)
        XCTAssertEqual(CleanupLevel.resolve(0), .verbatim)
        XCTAssertEqual(CleanupLevel.resolve(2), .polished)
        XCTAssertEqual(CleanupLevel.resolve(3), .tightened)
        XCTAssertEqual(CleanupLevel.resolve(99), .tightened)
    }

    // MARK: Settings clamp behaviour (UserDefaults, InsertionTracker-style)

    /// Normal hold-to-talk stays model-free. Double-tap is the explicit
    /// request for one Polished model pass.
    func testSettingsDefaultsToCleanedWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "cleanupLevel")
        XCTAssertEqual(Settings.cleanupLevel, 1)
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .cleaned)
        XCTAssertNil(CleanupLevel.resolve(Settings.cleanupLevel).polishInstructions)
    }

    /// Level 1 stays available as the way out of the model path entirely.
    func testCleanedRemainsModelFree() {
        UserDefaults.standard.set(1, forKey: "cleanupLevel")
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .cleaned)
        XCTAssertNil(
            CleanupLevel.resolve(Settings.cleanupLevel).polishInstructions,
            "Cleaned must never invoke the on-device model")
        UserDefaults.standard.removeObject(forKey: "cleanupLevel")
    }

    /// An explicit choice survives the default move.
    func testExplicitlyChosenLevelSurvivesTheDefaultChange() {
        UserDefaults.standard.set(2, forKey: "cleanupLevel")
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .polished)
        UserDefaults.standard.removeObject(forKey: "cleanupLevel")
    }

    func testSettingsClampsOutOfRangeStoredValuesOnRead() {
        UserDefaults.standard.set(-5, forKey: "cleanupLevel")
        XCTAssertEqual(Settings.cleanupLevel, 0)
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .verbatim)

        UserDefaults.standard.set(99, forKey: "cleanupLevel")
        XCTAssertEqual(Settings.cleanupLevel, 3)
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .tightened)
    }

    func testSettingsRoundTripsValidLevels() {
        Settings.cleanupLevel = CleanupLevel.tightened.rawValue
        XCTAssertEqual(Settings.cleanupLevel, 3)
        Settings.cleanupLevel = CleanupLevel.cleaned.rawValue
        XCTAssertEqual(Settings.cleanupLevel, 1)
    }

    // MARK: Polish prompts

    func testOnlyModelStopsHavePolishPrompts() {
        XCTAssertNil(CleanupLevel.verbatim.polishInstructions)
        XCTAssertNil(CleanupLevel.cleaned.polishInstructions)
        XCTAssertNotNil(CleanupLevel.polished.polishInstructions)
        XCTAssertNotNil(CleanupLevel.tightened.polishInstructions)
    }

    func testPolishedPromptPreservesVoiceAndForbidsAdditions() throws {
        let prompt = try XCTUnwrap(CleanupLevel.polished.polishInstructions)
        let lowered = prompt.lowercased()
        XCTAssertTrue(lowered.contains("same personality"))
        XCTAssertTrue(lowered.contains("keep contractions"))
        XCTAssertTrue(lowered.contains("add content of any kind"))
        XCTAssertTrue(lowered.contains("change his certainty"))
        XCTAssertFalse(
            lowered.contains("compress, do not summarize"),
            "Polished must be the light pass, not the condensing one")
    }

    func testTightenedPromptReconstructsWithoutSummarizing() throws {
        let prompt = try XCTUnwrap(CleanupLevel.tightened.polishInstructions)
        let lowered = prompt.lowercased()
        XCTAssertTrue(lowered.contains("compress, do not summarize"))
        XCTAssertTrue(lowered.contains("repeated ideas"))
        XCTAssertTrue(lowered.contains("constraint, number and qualifier"))
        XCTAssertTrue(lowered.contains("add content of any kind"))
    }

    func testPolishPromptsAreDistinct() {
        let polished = CleanupLevel.polished.polishInstructions
        let tightened = CleanupLevel.tightened.polishInstructions
        XCTAssertNotEqual(polished, tightened)
        // The enum delegates to the engine's pure builders.
        XCTAssertEqual(polished, RewriteEngine.polishPrompt(level: .polished))
        XCTAssertEqual(tightened, RewriteEngine.polishPrompt(level: .tightened))
        XCTAssertEqual(RewriteEngine.polishPrompt(level: .cleaned), "")
    }

    // MARK: Verbatim formatter variant

    private var verbatimFormatter: TextFormatter {
        TextFormatter(dictionary: [
            "jira": "Jira",
            "period": ".",
            "gonna": "going to",
        ])
    }

    func testVerbatimRetainsFillers() {
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("um hello world"), "um hello world")
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("this is, uh, a test"),
            "this is, uh, a test")
    }

    func testVerbatimAddsNoTrailingPeriod() {
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("hello world"), "hello world")
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("is this thing on"), "is this thing on")
    }

    func testVerbatimKeepsOriginalCasing() {
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("this is great"), "this is great")
        // A dictionary value that lands mid-sentence keeps its own case,
        // but nothing downstream capitalizes sentence starts.
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("i love jira honestly"),
            "i love Jira honestly")
    }

    func testVerbatimStillAppliesDictionarySubstitutions() {
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("file a ticket in jira today"),
            "file a ticket in Jira today")
    }

    func testVerbatimStillBreaksLinesOnSpokenCommands() {
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("first line new line second line"),
            "first line\nsecond line")
        XCTAssertEqual(
            verbatimFormatter.formatVerbatim("intro new paragraph details here"),
            "intro\n\ndetails here")
    }

    func testVerbatimTidiesDictionaryPunctuationWithoutAddingAny() {
        // The user SAID "period" — that's a substitution, not auto-period.
        XCTAssertEqual(verbatimFormatter.formatVerbatim("hello period"), "hello.")
        // But a plain sentence still ends bare, and casing stays as spoken.
        XCTAssertEqual(
            TextFormatter(dictionary: [:]).formatVerbatim("running a bit late"),
            "running a bit late")
    }

    func testVerbatimEmptyInputStaysEmpty() {
        XCTAssertEqual(TextFormatter().formatVerbatim(""), "")
        XCTAssertEqual(TextFormatter().formatVerbatim("   "), "")
    }
}
