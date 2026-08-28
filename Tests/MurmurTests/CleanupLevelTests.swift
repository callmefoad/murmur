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

    /// The unset default must be the highest stop that runs no on-device
    /// model pass. A user who never opted in must never have their own
    /// spoken words fed to a model that could read them as instructions.
    func testSettingsDefaultsToCleanedWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "cleanupLevel")
        XCTAssertEqual(Settings.cleanupLevel, 1)
        XCTAssertEqual(CleanupLevel.resolve(Settings.cleanupLevel), .cleaned)
        XCTAssertNil(
            CleanupLevel.resolve(Settings.cleanupLevel).polishInstructions,
            "the default stop must not invoke the on-device model")
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

    func testPolishedPromptMentionsKeepingWordsAndTone() throws {
        let prompt = try XCTUnwrap(CleanupLevel.polished.polishInstructions)
        let lowered = prompt.lowercased()
        XCTAssertTrue(lowered.contains("words"))
        XCTAssertTrue(lowered.contains("tone"))
        XCTAssertTrue(lowered.contains("meaning"))
        XCTAssertTrue(lowered.contains("never add"))
        XCTAssertFalse(lowered.contains("tighten"),
                       "Polished must be the light pass, not the condensing one")
    }

    func testTightenedPromptMentionsTighteningAndRedundancy() throws {
        let prompt = try XCTUnwrap(CleanupLevel.tightened.polishInstructions)
        let lowered = prompt.lowercased()
        XCTAssertTrue(lowered.contains("tighten"))
        XCTAssertTrue(lowered.contains("redundancy"))
        XCTAssertTrue(lowered.contains("rambling"))
        XCTAssertTrue(lowered.contains("never add"))
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
