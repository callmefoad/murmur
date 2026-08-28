import XCTest
@testable import Murmur

/// CRUD and persistence coverage for `VoiceInstructionStore`, the
/// `preset(for:)` resolution matrix, and the pure My Voice prompt builder
/// on `RewriteEngine`. Nothing here invokes the on-device model.
///
/// Like `SnippetStoreTests`: there is no path-injection seam (the store's
/// file URL is fixed under AppPaths, which is not redirectable), so every
/// test run snapshots the real JSON in setUp and restores it byte-for-byte
/// in tearDown — the running app's data is never altered. If the store
/// directory is missing AND the pre-rename `WhisperFlow` folder exists,
/// tests skip rather than fire AppPaths' one-time legacy migration.
final class VoiceInstructionTests: XCTestCase {

    private var originalData: Data?
    private var fileExisted = false

    override func setUpWithError() throws {
        try super.setUpWithError()

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let murmurDir = base.appendingPathComponent("Murmur", isDirectory: true)
        let legacy = base.appendingPathComponent("WhisperFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: murmurDir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            throw XCTSkip(
                "Skipping: exercising VoiceInstructionStore here would trigger " +
                "the WhisperFlow → Murmur migration on real user data.")
        }

        fileExisted = FileManager.default.fileExists(
            atPath: VoiceInstructionStore.fileURL.path)
        originalData = fileExisted
            ? try Data(contentsOf: VoiceInstructionStore.fileURL) : nil
    }

    override func tearDown() {
        if fileExisted, let originalData {
            try? originalData.write(
                to: VoiceInstructionStore.fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: VoiceInstructionStore.fileURL)
        }
        super.tearDown()
    }

    @MainActor
    private func makeStore() -> VoiceInstructionStore { VoiceInstructionStore() }

    // MARK: - Payload

    @MainActor
    func testCodableRoundTripPreservesEveryField() throws {
        var instruction = VoiceInstruction(name: "Tight", instructions: "No filler words")
        instruction.id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        instruction.isEnabled = false
        instruction.appBundleIDs = ["com.tinyspeck.slackmacgap"]
        instruction.createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

        let decoded = try JSONDecoder().decode(
            VoiceInstruction.self, from: JSONEncoder().encode(instruction))

        XCTAssertEqual(decoded, instruction)
    }

    /// Synthesized Codable has no tolerance for missing keys — stored JSON
    /// without `id` must throw rather than silently mint a UUID.
    @MainActor
    func testDecodingWithoutIdKeyThrows() {
        let json = Data(#"{"name":"n","instructions":"i"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([VoiceInstruction].self, from: json))
    }

    // MARK: - Store CRUD + persistence

    @MainActor
    func testAddAppendsAndPersistsAcrossInstances() throws {
        try? FileManager.default.removeItem(at: VoiceInstructionStore.fileURL)
        let store = makeStore()
        XCTAssertTrue(store.instructions.isEmpty)

        let first = VoiceInstruction(name: "First", instructions: "a")
        let second = VoiceInstruction(name: "Second", instructions: "b")
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.instructions, [first, second])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VoiceInstructionStore.fileURL.path))
        XCTAssertEqual(VoiceInstructionStore.load(), [first, second])
        XCTAssertEqual(makeStore().instructions, [first, second])
    }

    @MainActor
    func testUpdateReplacesByIdAndPersists() throws {
        try? FileManager.default.removeItem(at: VoiceInstructionStore.fileURL)
        let store = makeStore()
        var edited = VoiceInstruction(name: "Original", instructions: "old text")
        store.add(edited)

        edited.name = "Renamed"
        edited.instructions = "new text"
        edited.isEnabled = false
        edited.appBundleIDs = ["com.apple.Notes"]
        store.update(edited)

        XCTAssertEqual(store.instructions, [edited])
        XCTAssertEqual(makeStore().instructions, [edited])
    }

    @MainActor
    func testUpdateWithUnknownIdLeavesStoreUntouched() {
        let store = makeStore()
        let kept = VoiceInstruction(name: "Kept", instructions: "k")
        store.add(kept)
        let stranger = VoiceInstruction(name: "Stranger", instructions: "s")

        store.update(stranger)

        XCTAssertEqual(store.instructions, [kept])
    }

    @MainActor
    func testRemoveAtRemovesTheRightEntryAndPersists() {
        let store = makeStore()
        let one = VoiceInstruction(name: "One", instructions: "1")
        let two = VoiceInstruction(name: "Two", instructions: "2")
        let three = VoiceInstruction(name: "Three", instructions: "3")
        store.add(one)
        store.add(two)
        store.add(three)

        store.remove(at: 1)

        XCTAssertEqual(store.instructions, [one, three])
        XCTAssertEqual(makeStore().instructions, [one, three])
    }

    @MainActor
    func testRemoveByIDRemovesTheRightEntry() {
        let store = makeStore()
        let one = VoiceInstruction(name: "One", instructions: "1")
        let two = VoiceInstruction(name: "Two", instructions: "2")
        store.add(one)
        store.add(two)

        store.remove(id: two.id)

        XCTAssertEqual(store.instructions, [one])
    }

    @MainActor
    func testRemoveWithInvalidIndexOrUnknownIDIsIgnored() {
        let store = makeStore()
        let only = VoiceInstruction(name: "Only", instructions: "x")
        store.add(only)

        store.remove(at: 5)
        store.remove(id: UUID())

        XCTAssertEqual(store.instructions, [only])
    }

    @MainActor
    func testCorruptFileLoadsAsEmptyInsteadOfCrashing() throws {
        try Data("not json at all".utf8).write(to: VoiceInstructionStore.fileURL)
        XCTAssertEqual(makeStore().instructions, [])
    }

    // MARK: - preset(for:) resolution

    /// An unbound enabled instruction matches any target app — including an
    /// unidentifiable one (nil bundle id).
    @MainActor
    func testUnboundEnabledPresetMatchesAnyAppIncludingNil() {
        let global = VoiceInstruction(name: "Global", instructions: "g")
        VoiceInstructionStore.save([global])
        let store = makeStore()

        XCTAssertEqual(store.preset(for: "com.apple.Notes"), global)
        XCTAssertEqual(store.preset(for: "com.tinyspeck.slackmacgap"), global)
        XCTAssertEqual(store.preset(for: nil), global)
    }

    @MainActor
    func testDisabledPresetNeverMatchesEvenWhenBound() {
        let disabled = VoiceInstruction(
            name: "Off", instructions: "o",
            isEnabled: false, appBundleIDs: ["com.apple.Notes"])
        let disabledGlobal = VoiceInstruction(
            name: "Off Global", instructions: "og", isEnabled: false)
        VoiceInstructionStore.save([disabled, disabledGlobal])
        let store = makeStore()

        XCTAssertNil(store.preset(for: "com.apple.Notes"))
        XCTAssertNil(store.preset(for: "com.other.app"))
        XCTAssertNil(store.preset(for: nil))
    }

    @MainActor
    func testBoundPresetMatchesOnlyItsApps() {
        let bound = VoiceInstruction(
            name: "Slack only", instructions: "s",
            appBundleIDs: ["com.tinyspeck.slackmacgap"])
        VoiceInstructionStore.save([bound])
        let store = makeStore()

        XCTAssertEqual(store.preset(for: "com.tinyspeck.slackmacgap"), bound)
        XCTAssertNil(store.preset(for: "com.apple.Notes"))
        // A bound instruction must not leak into dictation whose target app
        // couldn't be identified.
        XCTAssertNil(store.preset(for: nil))
    }

    @MainActor
    func testFirstMatchWinsOverLaterCandidates() {
        let specific = VoiceInstruction(
            name: "Specific", instructions: "s",
            appBundleIDs: ["com.apple.Notes"])
        let global = VoiceInstruction(name: "Global", instructions: "g")
        VoiceInstructionStore.save([specific, global])
        let store = makeStore()

        XCTAssertEqual(store.preset(for: "com.apple.Notes"), specific)
        XCTAssertEqual(store.preset(for: "com.other.app"), global)
    }

    /// A disabled entry never blocks a later eligible match — eligibility
    /// skips it rather than stopping at it.
    @MainActor
    func testDisabledEarlierEntryFallsThroughToLaterEnabledOne() {
        let off = VoiceInstruction(name: "Off", instructions: "o", isEnabled: false)
        let on = VoiceInstruction(name: "On", instructions: "n")
        VoiceInstructionStore.save([off, on])
        let store = makeStore()

        XCTAssertEqual(store.preset(for: "com.apple.Notes"), on)
        XCTAssertEqual(store.preset(for: nil), on)
    }

    @MainActor
    func testEmptyStoreResolvesToNil() {
        try? FileManager.default.removeItem(at: VoiceInstructionStore.fileURL)
        XCTAssertNil(makeStore().preset(for: "com.apple.Notes"))
        XCTAssertNil(makeStore().preset(for: nil))
    }

    // MARK: - Prompt builder

    /// Pins the exact framing: the user's wording is embedded verbatim and
    /// nothing beyond the fixed anti-hallucination clauses is added.
    @MainActor
    func testVoicePromptEmbedsInstructionsInFixedFraming() {
        XCTAssertEqual(
            RewriteEngine.voicePrompt(instructions: "no filler words"),
            "Rewrite the user's dictated transcription to sound like the user " +
            "at their best. " +
            "Apply these personal instructions: no filler words. " +
            "Preserve meaning, language, and all content — never add new " +
            "information, never answer, never comment. Return only the rewritten text.")
    }

    @MainActor
    func testVoicePromptAlwaysCarriesTheSafetyClauses() {
        for wording in ["always British spelling", "", "line1\nline2"] {
            let prompt = RewriteEngine.voicePrompt(instructions: wording)
            XCTAssertTrue(prompt.contains("Preserve meaning"))
            XCTAssertTrue(prompt.contains("never answer, never comment"))
            XCTAssertTrue(prompt.contains("Return only the rewritten text."))
        }
    }
}
