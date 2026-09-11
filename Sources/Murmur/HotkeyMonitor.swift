import AppKit
import Foundation

/// Watches the chosen modifier key globally.
/// - Hold = push-to-talk (release stops).
/// - Double-tap = arm the next held dictation for Polished cleanup.
/// Requires Accessibility permission for global key monitoring.
final class HotkeyMonitor {

    enum Hotkey: String, CaseIterable {
        case fn
        case rightOption

        var displayName: String {
            switch self {
            case .fn: return "fn (Globe)"
            case .rightOption: return "Right Option (⌥)"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .rightOption: return 61
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: return .function
            case .rightOption: return .option
            }
        }
    }

    var hotkey: Hotkey
    var onStart: (() -> Void)?
    /// Called when dictation should stop and be transcribed.
    var onStop: (() -> Void)?
    /// Called when a too-short press should be discarded.
    var onCancel: (() -> Void)?
    var onPolishedRequested: (() -> Void)?
    /// Called first on each key-down; return true to consume the press as an
    /// undo — it never enters the tap/hold machine (no onStart, and the
    /// matching key-up is ignored). Deliberate trade-off: a fast double-tap
    /// right after an insertion spends the first tap on the undo.
    var onUndoAttempt: (() -> Bool)?

    /// How the hotkey is currently being observed.
    enum Mode {
        /// A `CGEventTap` is installed; matching events are swallowed so the
        /// system's own Globe action does not also fire.
        case consuming
        /// Passive `NSEvent` monitors; the event still reaches other apps.
        case passive
        case off
    }

    private(set) var mode: Mode = .off
    /// Convenience for the UI: true when the tap is active.
    var isConsuming: Bool { mode == .consuming }

    private var eventTap: EventTap?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private var pressStartedAt: Date?
    private var lastTapEndedAt: Date?
    private var secondPressIsPolished = false

    /// Presses shorter than this count as taps, not push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.5

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    func startMonitoring() {
        stopMonitoring()

        // Preferred path: a session event tap, which can swallow the key.
        let tap = EventTap { [weak self] _, event in
            guard let self else { return event }
            let keyCode = UInt16(
                truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == self.hotkey.keyCode else { return event }

            // Decide fast, do the real work off the callback. The state
            // machine itself is cheap, but never run app logic inline in a
            // tap callback — that is what gets the tap disabled.
            let pressed = self.isHotkeyPressed(flags: event.flags)
            DispatchQueue.main.async { [weak self] in
                self?.apply(pressed: pressed)
            }

            // Swallowing is opt-in and off by default. Right-Option is never
            // swallowed — hiding its .flagsChanged would hide the Option
            // modifier from every app, breaking ⌥-click and friends. fn is
            // swallowed only when the user asks for it, because fn is itself a
            // live modifier: fn+arrows (Home/End/PageUp/PageDown), fn+Delete
            // for forward delete, and fn+F1-F12 all depend on apps seeing it.
            let swallow = self.hotkey == .fn && Settings.consumeHotkey
            return swallow ? nil : event
        }

        if tap.start(mask: .mask(for: .flagsChanged)) == nil {
            eventTap = tap
            mode = .consuming
            return
        }

        // Fallback: the passive monitors. They cannot consume, but a hotkey
        // that fires is far better than one that does not.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
            return event
        }
        mode = .passive
    }

    func stopMonitoring() {
        eventTap?.stop()
        eventTap = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        mode = .off
    }

    deinit {
        eventTap?.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    /// CGEvent flag test mirroring `NSEvent.modifierFlags.contains(hotkey.flag)`.
    private func isHotkeyPressed(flags: CGEventFlags) -> Bool {
        switch hotkey {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.contains(.maskAlternate)
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        apply(pressed: event.modifierFlags.contains(hotkey.flag))
    }

    /// Edge detection + tap/hold state machine. Unchanged behaviour; only the
    /// event source differs between the tap and the NSEvent fallback.
    func apply(pressed: Bool, now: Date = Date()) {
        if pressed, !keyIsDown {
            keyIsDown = true
            keyDown(at: now)
        } else if !pressed, keyIsDown {
            keyIsDown = false
            keyUp(at: now)
        }
    }

    private func keyDown(at now: Date) {
        // Make the natural gesture work: tap once, then hold the second
        // press and speak. Arm Polished before onStart so that second press
        // itself records in Polished mode; no third press is required.
        if let lastTap = lastTapEndedAt,
           now.timeIntervalSince(lastTap) <= doubleTapWindow {
            lastTapEndedAt = nil
            secondPressIsPolished = true
            pressStartedAt = now
            onPolishedRequested?()
            onStart?()
            return
        }

        secondPressIsPolished = false
        if onUndoAttempt?() == true {
            // The press undid the last insertion instead of dictating;
            // leave pressStartedAt nil so its key-up is a no-op.
            pressStartedAt = nil
            return
        }
        pressStartedAt = now
        onStart?()
    }

    private func keyUp(at now: Date) {
        guard let startedAt = pressStartedAt else { return }
        pressStartedAt = nil
        let holdDuration = now.timeIntervalSince(startedAt)

        if holdDuration >= tapThreshold {
            // Push-to-talk: release ends dictation.
            lastTapEndedAt = nil
            secondPressIsPolished = false
            onStop?()
            return
        }

        if secondPressIsPolished {
            // Two quick taps still work as the original "arm next hold"
            // gesture. The second recording is discarded, then Polished is
            // re-armed for the next hold.
            secondPressIsPolished = false
            onCancel?()
            onPolishedRequested?()
        } else {
            lastTapEndedAt = now
            onCancel?()
        }
    }
}
