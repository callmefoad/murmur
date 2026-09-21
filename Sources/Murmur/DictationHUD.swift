import AppKit
import SwiftUI

/// Model driving the dictation HUD's SwiftUI content.
private final class HUDModel: ObservableObject {
    @Published var level: Float = 0
    /// True on notched displays: the HUD renders as a solid-black strip
    /// fused to the notch bezel instead of a floating capsule.
    @Published var notchMode = false
    /// Top safe-area inset of the current screen; used to pad content below
    /// the camera housing so nothing draws inside the cut-out zone.
    @Published var notchInset: CGFloat = 0
}

/// Caps-lock-style floating indicator shown while dictating: a live input
/// meter without a transcript preview.
///
/// Lifecycle: `show()` on dictation start, `update(level:)` while running,
/// `hide()` on stop, cancel, or failure.
/// The panel floats above everything (including full-screen spaces), never
/// takes key focus, and ignores all mouse events. It sits top-centre on the
/// pointer's screen: tucked just below the camera housing ("notch") on
/// notched displays, otherwise just below the menu bar.
@MainActor
final class DictationHUD {
    static let shared = DictationHUD()

    private let model = HUDModel()
    private var panel: NSPanel?

    private init() {}

    // MARK: - Lifecycle

    /// Shows the HUD on the screen the pointer is currently on (falling back
    /// to the main screen), top-centred per `DictationHUDLayout`.
    func show() {
        model.level = 0
        let screen = currentScreen()
        let inset = screen?.safeAreaInsets.top ?? 0
        model.notchMode = DictationHUDLayout.isNotched(topSafeInset: inset)
        model.notchInset = model.notchMode ? inset : 0
        let hud = makePanelIfNeeded()
        guard let final = frame(for: hud, on: screen) else { return }
        // Bump the token so a still-running hide's completion handler can't
        // orderOut the panel we are about to re-show.
        appearanceToken += 1
        hud.alphaValue = 0
        hud.setFrame(final.offsetBy(dx: 0, dy: Self.slideDistance), display: false)
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hud.animator().setFrame(final, display: true)
            hud.animator().alphaValue = 1
        }
    }

    /// Feeds the input meter. Takes the raw microphone RMS and scales it so
    /// normal speech sits around mid-scale, with a fast attack and slower
    /// decay so the bars feel responsive without flickering.
    func update(level rms: Float) {
        let scaled = min(1, max(0, rms * 8))
        model.level = max(scaled, model.level * 0.72)
    }

    /// Fades the HUD out, retreating a few points back up toward the notch /
    /// menu bar. Safe to call when it isn't shown.
    func hide() {
        guard let hud = panel, hud.isVisible else { return }
        appearanceToken += 1
        let token = appearanceToken
        let retreat = hud.frame.offsetBy(dx: 0, dy: Self.slideDistance)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            hud.animator().setFrame(retreat, display: true)
            hud.animator().alphaValue = 0
        }, completionHandler: { [hud] in
            Task { @MainActor in
                guard token == self.appearanceToken else { return }
                hud.orderOut(nil)
            }
        })
    }

    // MARK: - Panel plumbing

    /// Vertical travel (points) of the enter/exit slide.
    private static let slideDistance: CGFloat = 10
    private var appearanceToken = 0

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            // Match the physical notch rather than stretching a wide HUD
            // across the menu bar; the indicator remains centered inside.
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: a drop shadow would betray the seam between the HUD and
        // the notch bezel it's supposed to be fused with.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DictationHUDContent(model: model))
        self.panel = panel
        return panel
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
    }

    private func frame(for panel: NSPanel, on screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }
        let inset = screen.safeAreaInsets.top
        var size = panel.frame.size
        if DictationHUDLayout.isNotched(topSafeInset: inset) {
            // Match the actual notch width for the current display mode and
            // cover exactly the notch depth plus the 39-point menu bar row.
            size.width = DictationHUDLayout.notchWidth(
                screen: screen, fallback: panel.frame.width)
            size.height = inset + Self.notchHangHeight
        }
        let origin = DictationHUDLayout.hudOrigin(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            topSafeInset: inset,
            hudSize: size,
            flushToScreenTop: DictationHUDLayout.isNotched(topSafeInset: inset))
        return CGRect(origin: origin, size: size)
    }

    /// The 16-inch MacBook Pro menu-bar row is 39 points tall.
    private static let notchHangHeight: CGFloat = 39
}

// MARK: - Placement geometry

/// Pure placement math for the HUD — internal so tests can verify the
/// notch vs fallback decision without instantiating windows or screens.
enum DictationHUDLayout {
    /// Notched displays (MacBook Pro/Air camera housings) report a nonzero
    /// top safe-area inset; every other screen reports zero. The small
    /// epsilon guards against rounding noise.
    static func isNotched(topSafeInset: CGFloat) -> Bool {
        topSafeInset > 0.5
    }

    /// Derives the current notch width from AppKit's auxiliary top areas.
    /// Display scaling changes the point width, so a fixed constant is only
    /// correct in one resolution mode.
    static func notchWidth(screen: NSScreen, fallback: CGFloat) -> CGFloat {
        let width = screen.frame.width
            - (screen.auxiliaryTopLeftArea?.width ?? 0)
            - (screen.auxiliaryTopRightArea?.width ?? 0)
        return width > 0 ? width : fallback
    }

    /// Top-centre origin for a panel of `hudSize`, in AppKit coordinates:
    ///
    /// - **Notched** (`isNotched`): centred on the *full* frame's midline and
    ///   anchored `gap` below the notch's bottom edge
    ///   (`screenFrame.maxY - topSafeInset`). Anchoring to the notch rather
    ///   than visibleFrame keeps clearance from the hardware cut-out even in
    ///   full-screen spaces where the menu bar hides and
    ///   `visibleFrame.maxY == screenFrame.maxY`.
    /// - **Fallback**: centred on the full frame and anchored `gap` below the
    ///   menu bar (`visibleFrame.maxY`), clamped so the panel never drops
    ///   below `visibleFrame.minY`.
    ///
    /// Horizontal centering deliberately uses `screenFrame.midX`, not
    /// `visibleFrame.midX`: a left/right-docked Dock shrinks visibleFrame
    /// asymmetrically, which would pull the HUD off the display's true
    /// centreline.
    static func hudOrigin(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        topSafeInset: CGFloat,
        hudSize: CGSize,
        gap: CGFloat = 6,
        flushToScreenTop: Bool = false
    ) -> NSPoint {
        let anchorY: CGFloat
        if flushToScreenTop {
            // Fused-to-notch mode: the panel's top edge sits at the very top
            // of the display so the black strip covers the cut-out itself.
            anchorY = screenFrame.maxY
        } else if isNotched(topSafeInset: topSafeInset) {
            anchorY = screenFrame.maxY - topSafeInset
        } else {
            anchorY = min(visibleFrame.maxY, screenFrame.maxY)
        }
        let x = screenFrame.midX - hudSize.width / 2
        let offset = flushToScreenTop ? hudSize.height : gap + hudSize.height
        let y = max(visibleFrame.minY, anchorY - offset)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Content

private struct DictationHUDContent: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.accent)
            WaveformBars(level: model.level)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
        // Notch mode pads down past the camera housing; fallback keeps the
        // old capsule proportions.
        .padding(.top, model.notchMode ? model.notchInset : 14)
        .padding(.bottom, model.notchMode ? 13 : 14)
        .background {
            if model.notchMode {
                // Pure black with square top corners so the strip is visually
                // continuous with the notch bezel above it.
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 14,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
            } else {
                Capsule().fill(Color.black.opacity(0.78))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
        }
    }

}

private struct WaveformBars: View {
    let level: Float

    /// Per-bar sensitivity so the meter looks organic even on steady input.
    private let weights: [Float] = [0.55, 0.85, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 4, height: barHeight(weights[index]))
            }
        }
        .animation(.linear(duration: 0.09), value: level)
    }

    private func barHeight(_ weight: Float) -> CGFloat {
        let normalized = max(0.05, min(1, level * weight))
        return 6 + CGFloat(normalized) * 22
    }
}
