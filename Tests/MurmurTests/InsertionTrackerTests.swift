import XCTest
@testable import Murmur

final class InsertionTrackerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func insertion(
        _ secondsAgo: TimeInterval,
        method: InsertionMethod = .ax,
        bundleID: String? = "com.example.editor"
    ) -> LastInsertion {
        LastInsertion(
            text: "hello", method: method, date: now.addingTimeInterval(-secondsAgo),
            bundleID: bundleID)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "undoWindowSeconds")
        super.tearDown()
    }

    func testWithinWindowAndSameAppUndoes() {
        let action = InsertionTracker.action(
            now: now, last: insertion(1.0), frontAppBundleID: "com.example.editor",
            windowSeconds: 2.0)
        XCTAssertEqual(action, .undo)
    }

    func testOutsideWindowRecords() {
        let action = InsertionTracker.action(
            now: now, last: insertion(2.5), frontAppBundleID: "com.example.editor",
            windowSeconds: 2.0)
        XCTAssertEqual(action, .record)
    }

    func testExactlyAtWindowEdgeRecords() {
        let action = InsertionTracker.action(
            now: now, last: insertion(2.0), frontAppBundleID: "com.example.editor",
            windowSeconds: 2.0)
        XCTAssertEqual(action, .record)
    }

    func testDifferentFrontAppRecords() {
        let action = InsertionTracker.action(
            now: now, last: insertion(0.5), frontAppBundleID: "com.example.other",
            windowSeconds: 2.0)
        XCTAssertEqual(action, .record)
    }

    func testNoLastInsertionRecords() {
        let action = InsertionTracker.action(
            now: now, last: nil, frontAppBundleID: "com.example.editor", windowSeconds: 2.0)
        XCTAssertEqual(action, .record)
    }

    func testAfterUndoClearedRecords() {
        var last: LastInsertion? = insertion(0.5)
        // Mirrors AppDelegate.undoLastInsertionIfEligible(): clear on undo so
        // the next press records normally.
        last = nil
        let action = InsertionTracker.action(
            now: now, last: last, frontAppBundleID: "com.example.editor", windowSeconds: 2.0)
        XCTAssertEqual(action, .record)
    }

    func testCustomUserDefaultsWindowRespected() {
        UserDefaults.standard.set(10.0, forKey: "undoWindowSeconds")
        XCTAssertEqual(InsertionTracker.windowSeconds, 10.0)
        XCTAssertEqual(
            InsertionTracker.action(
                now: now, last: insertion(5.0), frontAppBundleID: "com.example.editor",
                windowSeconds: InsertionTracker.windowSeconds),
            .undo)

        UserDefaults.standard.set(1.0, forKey: "undoWindowSeconds")
        XCTAssertEqual(InsertionTracker.windowSeconds, 1.0)
        XCTAssertEqual(
            InsertionTracker.action(
                now: now, last: insertion(5.0), frontAppBundleID: "com.example.editor",
                windowSeconds: InsertionTracker.windowSeconds),
            .record)
    }

    // MARK: - Replacement-mode detection (pure, headless)

    func testUnreadableSelectionMeansCaretInsertion() {
        XCTAssertFalse(InsertionTracker.isReplacement(selectedText: nil))
    }

    func testEmptySelectionMeansCaretInsertion() {
        XCTAssertFalse(InsertionTracker.isReplacement(selectedText: ""))
    }

    func testAnyCharacterSelectionIsReplacement() {
        XCTAssertTrue(InsertionTracker.isReplacement(selectedText: "a"))
        XCTAssertTrue(InsertionTracker.isReplacement(selectedText: "hello world"))
    }

    func testWhitespaceOnlySelectionIsStillReplacement() {
        XCTAssertTrue(InsertionTracker.isReplacement(selectedText: " "))
        XCTAssertTrue(InsertionTracker.isReplacement(selectedText: " \n\t "))
    }

    // MARK: - Post-write caret invariant

    func testPostWriteCaretIsLocationPlusWrittenUnitsOnly() {
        // Inserting at a bare caret [10, 10) lands at 15…
        XCTAssertEqual(
            InsertionTracker.postWriteCaretLocation(
                selectionLocation: 10, replacementUTF16Length: 5), 15)
        // …and replacing a wide span with the same text lands in the same
        // place: the formula has NO replaced-length term, which is exactly
        // why one post-write verification covers both modes.
        let written = "hello"
        XCTAssertEqual(
            InsertionTracker.postWriteCaretLocation(
                selectionLocation: 10, replacementUTF16Length: (written as NSString).length),
            15)
    }

    func testPostWriteCaretCountsUTF16UnitsNotCharacters() {
        let emoji = "👍👍"  // 2 surrogate pairs = 4 UTF-16 units
        XCTAssertEqual((emoji as NSString).length, 4)
        XCTAssertEqual(
            InsertionTracker.postWriteCaretLocation(
                selectionLocation: 3, replacementUTF16Length: (emoji as NSString).length), 7)
    }

    // MARK: - Undo plans

    func testPasteAlwaysUsesNativeUndoEvenWhenItReplacedSomething() {
        let record = LastInsertion(
            text: "new", method: .paste, date: now, bundleID: "com.example.editor",
            replacedText: "old")
        // The target app's ⌘Z natively restores what its paste overwrote;
        // we never know the geometry, so replacedText is informational here.
        XCTAssertEqual(InsertionTracker.undoPlan(for: record), .nativeUndo)
        XCTAssertEqual(InsertionTracker.undoPlan(for: insertion(0.0, method: .paste)), .nativeUndo)
    }

    func testAXInsertionWithoutReplacedTextPlansDeletion() {
        XCTAssertEqual(InsertionTracker.undoPlan(for: insertion(0.0)), .deleteInserted)
        var empty = insertion(0.0)
        empty.replacedText = ""
        // Only non-nil counts as a replacement; "" is not produced by the
        // pipeline but would still restore-to-empty (= delete) if it were.
        XCTAssertEqual(InsertionTracker.undoPlan(for: empty), .restoreOriginal)
    }

    func testAXInsertionWithReplacedTextPlansRestore() {
        let record = LastInsertion(
            text: "dictated", method: .ax, date: now, bundleID: "com.example.editor",
            replacedText: "selected words")
        XCTAssertEqual(InsertionTracker.undoPlan(for: record), .restoreOriginal)
    }

    // MARK: - Record shape

    func testReplacedTextDefaultsToNilForPlainInsertions() {
        XCTAssertNil(insertion(0.5).replacedText)
    }

    func testEqualityDistinguishesReplacementFromDeletionUndo() {
        let plain = LastInsertion(
            text: "x", method: .ax, date: now, bundleID: nil)
        let replacing = LastInsertion(
            text: "x", method: .ax, date: now, bundleID: nil, replacedText: "y")
        XCTAssertNotEqual(plain, replacing)
        var sameAsReplacing = replacing
        sameAsReplacing.replacedText = "y"
        XCTAssertEqual(replacing, sameAsReplacing)
    }
}
