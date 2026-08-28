import XCTest
@testable import Murmur

/// Geometry-only coverage for DictationHUD placement. The HUD itself is a
/// live NSPanel and can't be screenshot-tested here; these tests pin the
/// pure notch/fallback math in `DictationHUDLayout` so visual QA on a real
/// Mac only has to confirm what's already proven numerically.
final class DictationHUDTests: XCTestCase {

    // MARK: Notch detection

    func testNotchDetectionThreshold() {
        XCTAssertFalse(DictationHUDLayout.isNotched(topSafeInset: 0))
        XCTAssertFalse(DictationHUDLayout.isNotched(topSafeInset: 0.25),
                       "rounding noise is not a notch")
        XCTAssertTrue(DictationHUDLayout.isNotched(topSafeInset: 0.6))
        XCTAssertTrue(DictationHUDLayout.isNotched(topSafeInset: 32))
    }

    // MARK: Notched placement

    /// 1512×982 = MacBook Pro 14" points; 32pt top inset ≈ camera housing.
    func testNotchedPlacementTucksBelowNotchCenteredOnFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 958)
        let hud = CGSize(width: 380, height: 64)

        let p = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: visible,
            topSafeInset: 32, hudSize: hud)

        XCTAssertEqual(p.x, 1512 / 2 - 190, accuracy: 0.5,
                       "centred on full frame midline")
        // y + height must land exactly `gap` below the notch bottom.
        XCTAssertEqual(p.y + 64, frame.maxY - 32 - 6, accuracy: 0.5)
        XCTAssertEqual(p.y, 880, accuracy: 0.5)
    }

    /// Full-screen space: menu bar hides (visibleFrame == frame), but the
    /// hardware cut-out stays — anchor must still come from the inset.
    func testFullscreenNotchedStillClearsHardwareNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let hud = CGSize(width: 380, height: 64)

        let p = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: frame,
            topSafeInset: 32, hudSize: hud)

        XCTAssertEqual(p.y + 64, frame.maxY - 32 - 6, accuracy: 0.5,
                       "anchored to notch bottom, not hidden menu bar")
        XCTAssertLessThanOrEqual(p.y + 64, frame.maxY - 32,
                                 "panel never overlaps the housing")
    }

    /// A menu bar taller than the inset must not push the HUD lower —
    /// on notched screens the notch wins.
    func testNotchAnchorBeatsTallerMenuBar() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 982 - 37)

        let p = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: visible,
            topSafeInset: 32, hudSize: CGSize(width: 380, height: 64))

        XCTAssertEqual(p.y, 880, accuracy: 0.5)
    }

    // MARK: Fallback placement

    /// No notch → anchored below the menu bar (visibleFrame.maxY), still
    /// centred on the display.
    func testFallbackAnchorsBelowMenuBarWhenNoNotch() {
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let visible = CGRect(x: 0, y: 25, width: 2560, height: 1415)

        let p = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: visible,
            topSafeInset: 0, hudSize: CGSize(width: 380, height: 64))

        XCTAssertEqual(p.x, 1090, accuracy: 0.5)
        XCTAssertEqual(p.y, visible.maxY - 6 - 64, accuracy: 0.5)
    }

    /// Left-docked Dock shrinks visibleFrame horizontally; centering must
    /// ignore it (regression for using screenFrame.midX over visibleFrame).
    func testSideDockDoesNotShiftHorizontalCentering() {
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let visible = CGRect(x: 156, y: 25, width: 2356, height: 1330)

        let dockedLeft = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: visible,
            topSafeInset: 0, hudSize: CGSize(width: 380, height: 64))
        let noDock = DictationHUDLayout.hudOrigin(
            screenFrame: frame,
            visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1330),
            topSafeInset: 0, hudSize: CGSize(width: 380, height: 64))

        XCTAssertEqual(dockedLeft.x, noDock.x, accuracy: 0.5,
                       "Dock position must not move the HUD sideways")
        XCTAssertEqual(dockedLeft.x, 1280 - 190, accuracy: 0.5)
    }

    // MARK: Degenerate clamp

    /// If anchor − gap − height would fall under the work area bottom
    /// (absurdly small screens / huge gap), it clamps to visibleFrame.minY.
    func testNeverDropsBelowVisibleBottom() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 70)
        let visible = CGRect(x: 0, y: 0, width: 300, height: 70)

        let p = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: visible,
            topSafeInset: 0, hudSize: CGSize(width: 290, height: 64),
            gap: 40)

        XCTAssertEqual(p.y, 0, accuracy: 0.5)
    }

    func testGapParameterIsHonored() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let hud = CGSize(width: 380, height: 64)

        let tight = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: frame,
            topSafeInset: 32, hudSize: hud, gap: 4)
        let loose = DictationHUDLayout.hudOrigin(
            screenFrame: frame, visibleFrame: frame,
            topSafeInset: 32, hudSize: hud, gap: 12)

        XCTAssertEqual(tight.y - loose.y, 8, accuracy: 0.5)
    }
}
