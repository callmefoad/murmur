import XCTest
@testable import Murmur

/// Covers `VoiceProfile` (the Codable persona payload) and the pure refresh
/// heuristics of `VoiceProfileStore`. `generate(from:engine:)` drives real
/// on-device inference and parses the reply inline, so it is out of scope
/// here.
///
/// `VoiceProfileStore` persists through `UserDefaults.standard` with no
/// injection seam. Following the repo's UserDefaults-test convention, every
/// test snapshots its key up front and restores it exactly in tearDown, so
/// a live profile on this machine survives the run untouched.
final class VoiceProfileTests: XCTestCase {

    private let key = "voiceProfile"

    private var savedValue: Data?
    private var hadValue = false

    override func setUp() {
        super.setUp()
        hadValue = UserDefaults.standard.object(forKey: key) != nil
        savedValue = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if hadValue, let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Payload

    func testCodableRoundTripPreservesAllFields() throws {
        var profile = VoiceProfile(
            title: "Pipeline Poet", summary: "Speaks in terse imperatives.",
            wordCountAtGeneration: 4_321)
        profile.title = "Deadline Whisperer"

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.wordCountAtGeneration, 4_321)
    }

    // MARK: - Refresh heuristic thresholds

    /// These two constants are the documented contract between the store and
    /// the UI copy ("enough material", "stale enough to refresh").
    func testThresholdConstantsAreOrderedAsDocumented() {
        XCTAssertEqual(VoiceProfileStore.minimumWords, 80)
        XCTAssertEqual(VoiceProfileStore.refreshThreshold, 250)
        XCTAssertLessThan(
            VoiceProfileStore.minimumWords, VoiceProfileStore.refreshThreshold)
    }

    func testBelowMinimumWordsNeverRefreshes() {
        // Even with a very stale profile on file, tiny totals stay put…
        VoiceProfileStore.save(
            VoiceProfile(title: "Old", summary: "s", wordCountAtGeneration: 0))
        XCTAssertFalse(VoiceProfileStore.shouldRefresh(totalWords: 79))
        // …and with no profile at all the minimum still applies.
        XCTAssertFalse(VoiceProfileStore.shouldRefresh(totalWords: 0))
    }

    func testFirstProfileTriggersOnceMinimumIsReached() {
        XCTAssertTrue(VoiceProfileStore.shouldRefresh(totalWords: 80))
        XCTAssertTrue(VoiceProfileStore.shouldRefresh(totalWords: 5_000))
    }

    func testFreshEnoughProfileSuppressesRefresh() {
        VoiceProfileStore.save(
            VoiceProfile(title: "Recent", summary: "s", wordCountAtGeneration: 100))
        XCTAssertFalse(VoiceProfileStore.shouldRefresh(totalWords: 349))
        XCTAssertFalse(VoiceProfileStore.shouldRefresh(totalWords: 100))
    }

    func testRefreshFiresExactlyAtTheThresholdDelta() {
        VoiceProfileStore.save(
            VoiceProfile(title: "Stale", summary: "s", wordCountAtGeneration: 100))
        XCTAssertTrue(VoiceProfileStore.shouldRefresh(totalWords: 350))
        XCTAssertTrue(VoiceProfileStore.shouldRefresh(totalWords: 1_000))
    }

    // MARK: - Store round trip

    func testSaveThenLoadRoundTripsThroughDefaults() throws {
        let profile = VoiceProfile(
            title: "Design Inspector",
            summary: "Names colors nobody has heard of.",
            wordCountAtGeneration: 512)
        VoiceProfileStore.save(profile)

        XCTAssertEqual(try XCTUnwrap(VoiceProfileStore.load()), profile)
    }

    func testLoadWithNothingStoredReturnsNil() {
        XCTAssertNil(VoiceProfileStore.load())
    }
}
