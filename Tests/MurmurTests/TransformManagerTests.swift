import Carbon.HIToolbox
import XCTest
@testable import Murmur

/// Covers the pure surface of `TransformManager`: the static transform
/// catalog and the chord matcher used by the event tap. `run(_:)` and
/// `startMonitoring()` touch the clipboard, system sounds and global event
/// taps, so they are deliberately not exercised here.
@MainActor
final class TransformManagerTests: XCTestCase {

    // MARK: - Catalog integrity

    func testExactlyTwoTransformsExist() {
        XCTAssertEqual(Transform.all.count, 2)
        XCTAssertEqual(Set(Transform.all.map(\.id)).count, 2)
    }

    /// The keyCodes are what the event tap matches against — if these drift,
    /// ⌃⌥1/⌃⌥2 silently stop working everywhere.
    func testKeyCodesMatchTheAdvertisedChords() throws {
        let polish = try XCTUnwrap(Transform.all.first { $0.id == "polish" })
        let promptEngineer = try XCTUnwrap(
            Transform.all.first { $0.id == "promptEngineer" })

        XCTAssertEqual(polish.keyCode, UInt16(kVK_ANSI_1))
        XCTAssertEqual(promptEngineer.keyCode, UInt16(kVK_ANSI_2))
        XCTAssertEqual(polish.keyLabel, "⌃⌥1")
        XCTAssertEqual(promptEngineer.keyLabel, "⌃⌥2")
    }

    func testEveryTransformCarriesPromptAndDescription() {
        for transform in Transform.all {
            XCTAssertFalse(transform.instructions.isEmpty, transform.id)
            XCTAssertFalse(transform.description.isEmpty, transform.id)
            XCTAssertFalse(transform.name.isEmpty, transform.id)
        }
    }

    func testTransformInstructionsAreDistinct() {
        XCTAssertEqual(
            Set(Transform.all.map(\.instructions)).count, Transform.all.count)
    }

    // MARK: - Chord matching

    /// Builds a synthetic key-down like the ones the CGEventTap delivers.
    private func keyEvent(
        _ keyCode: UInt16, _ modifiers: CGEventFlags
    ) -> NSEvent {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
        event.flags = modifiers
        return NSEvent(cgEvent: event)!
    }

    func testControlOptionDigitsMapToTheirTransforms() {
        XCTAssertEqual(
            TransformManager.matchingTransform(
                for: keyEvent(UInt16(kVK_ANSI_1), [.maskControl, .maskAlternate]))?.id,
            "polish")
        XCTAssertEqual(
            TransformManager.matchingTransform(
                for: keyEvent(UInt16(kVK_ANSI_2), [.maskControl, .maskAlternate]))?.id,
            "promptEngineer")
    }

    func testExactModifierMatchIsRequired() {
        // Adding command to the chord must NOT fire a transform…
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_ANSI_1), [.maskControl, .maskAlternate, .maskCommand])))
        // …and neither may any other substitution.
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_ANSI_1), [.maskControl, .maskShift])))
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_ANSI_1), [.maskCommand, .maskAlternate])))
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_ANSI_1), [])))
    }

    func testUnmappedKeysReturnNilEvenWithTheRightChord() {
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_ANSI_3), [.maskControl, .maskAlternate])))
        XCTAssertNil(TransformManager.matchingTransform(
            for: keyEvent(UInt16(kVK_Return), [.maskControl, .maskAlternate])))
    }

    // MARK: - Initial state

    func testFreshManagerStartsOff() {
        let manager = TransformManager(engine: RewriteEngine())
        XCTAssertEqual(manager.mode, .off)
        XCTAssertFalse(manager.isConsuming)
    }

    // MARK: - Length guard through the public apply path

    /// `apply(_:to:)` delegates to `RewriteEngine.rewrite`, so the same
    /// 8000-character guard applies to the Transforms page.
    func testApplyRejectsOverlongTextBeforeAnyModelCall() async {
        let manager = TransformManager(engine: RewriteEngine())
        let polish = Transform.all.first { $0.id == "polish" }!
        let oversized = String(repeating: "x", count: RewriteEngine.maxInputCharacters + 1)

        do {
            _ = try await manager.apply(polish, to: oversized)
            XCTFail("expected the over-length apply to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "Murmur")
            XCTAssertEqual(error.code, 20)
        }
    }
}
