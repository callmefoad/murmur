import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Inserts text at the cursor of the frontmost app. Tries direct
/// Accessibility (AX) insertion first — no clipboard involved — and falls
/// back to the clipboard+⌘V path when AX insertion isn't viable.
enum TextInserter {

    /// Escape hatch: flip to `false` in one place if AX insertion misbehaves
    /// in the field. No UserDefaults key or UI — this is a code-level knob.
    /// Whether to try the accessibility path before the clipboard round-trip.
    /// Defaults to true. Reads UserDefaults each time so it can be turned off
    /// on a running install without a rebuild:
    ///     defaults write local.murmur directInsertion -bool false
    static var preferDirectInsertion: Bool {
        UserDefaults.standard.object(forKey: "directInsertion") as? Bool ?? true
    }

    typealias SavedClipboard = [[String: Data]]

    /// A captured clipboard, plus whether the capture is known-complete.
    struct ClipboardSnapshot {
        var items: SavedClipboard
        /// True when the live pasteboard held content this snapshot could
        /// NOT fully capture — e.g. a Finder file promise, Photos, or any
        /// app that registers a pasteboard type without materializing its
        /// data. `NSPasteboardItem.data(forType:)` returns nil for those,
        /// which is indistinguishable from "no data" unless we track it
        /// explicitly. A snapshot with `isUnsnapshotable == true` must
        /// never be written back verbatim — `items` may be missing content
        /// entirely, and restoring it would destroy the original.
        var isUnsnapshotable: Bool

        static let empty = ClipboardSnapshot(items: [], isUnsnapshotable: false)
    }

    /// Writes text to the pasteboard marked so clipboard managers skip it.
    /// Returns the resulting changeCount, for use as a restore guard.
    @discardableResult
    static func place(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    static func insert(_ text: String) {
        if insertViaAccessibility(text) {
            return
        }
        let stamp = writeConcealed(text)
        sendKeystroke(kVK_ANSI_V, flags: .maskCommand)
        // Restore only if nothing else claimed the pasteboard meanwhile;
        // this does not detect that the paste itself was consumed, since
        // reading the pasteboard does not change its changeCount.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            attemptRestore(expectedStamp: stamp)
        }
    }

    // MARK: - Direct Accessibility insertion

    /// Roles this app will attempt direct AX insertion into. `AXWebArea`
    /// covers the (rare) case where a web engine exposes the focused text
    /// node's settable value directly on the web-area element itself; the
    /// settability check below is what actually gates safety, this set just
    /// narrows to text-bearing roles.
    private static let axInsertableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXWebArea",
    ]

    /// Attempts to insert `text` at the caret of the focused element via
    /// the Accessibility API, replacing only the current selection (which
    /// is empty at a plain caret) rather than the field's whole value.
    /// Returns false — leaving the clipboard completely untouched — for
    /// every condition that isn't a clean, verified success, so the caller
    /// can fall back to the clipboard+⌘V path.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard preferDirectInsertion, AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return false
        }
        let element = focusedRef as! AXUIElement

        // Bail if the field isn't settable at all — read-only, disabled, or
        // an element that doesn't really support text entry.
        var settable: DarwinBoolean = false
        guard
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                == .success, settable.boolValue
        else {
            return false
        }

        var roleRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                == .success,
            let role = roleRef as? String, axInsertableRoles.contains(role)
        else {
            return false
        }

        // Only insert via the selected-text attribute: setting it replaces
        // the current selection (or inserts at the caret when the
        // selection is empty), which is exactly paste semantics and can
        // never clobber content outside the selection. If this attribute
        // isn't settable, bail to the clipboard path rather than attempt a
        // value-splice we can't safely verify here.
        var selectedTextSettable: DarwinBoolean = false
        guard
            AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &selectedTextSettable) == .success,
            selectedTextSettable.boolValue
        else {
            return false
        }

        let originalRange = selectedRange(of: element)

        guard
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else {
            return false
        }

        // Verify the write took effect where we can: after inserting,
        // the caret should have moved to just past the inserted text with
        // nothing selected. If we couldn't read a range before or after,
        // we still trust the successful AXError from the set call above.
        if let originalRange, let newRange = selectedRange(of: element) {
            let expectedLocation = originalRange.location + (text as NSString).length
            return newRange.length == 0 && newRange.location == expectedLocation
        }
        return true
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Copies the current selection in the frontmost app by synthesizing ⌘C.
    /// Returns the selected text, or nil if nothing was copied in time.
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        sendKeystroke(kVK_ANSI_C, flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != changeCount {
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }

    /// Captures the live pasteboard for later restoration. Distinguishes a
    /// genuinely empty clipboard (safe to restore to empty) from content
    /// this process could not fully snapshot — such as a Finder file
    /// promise or other lazily-provided data — by tracking whether any
    /// pasteboard item produced no data for any of its advertised types.
    static func saveClipboard() -> ClipboardSnapshot {
        let pasteboardItems = NSPasteboard.general.pasteboardItems ?? []
        var saved: SavedClipboard = []
        var unsnapshotable = false
        for item in pasteboardItems {
            var copy: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type.rawValue] = data
                }
            }
            if copy.isEmpty {
                // This item advertised one or more types but produced no
                // data for any of them — promised/lazy content we can't
                // reproduce synchronously (data(forType:) returns nil for
                // it), not an item that is genuinely empty.
                unsnapshotable = true
            } else {
                saved.append(copy)
            }
        }
        return ClipboardSnapshot(items: saved, isUnsnapshotable: unsnapshotable)
    }

    /// Restores a previously captured snapshot. If the snapshot is marked
    /// unsnapshotable, this intentionally does nothing: leaving Murmur's
    /// own concealed/transient text on the clipboard is strictly better
    /// than destroying content we couldn't capture in the first place (and
    /// the Transient marker means clipboard managers ignore it anyway). A
    /// genuinely empty original clipboard is still restored to empty.
    static func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        guard !snapshot.isUnsnapshotable else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    static func sendKeystroke(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Shared restore owner

    /// Ensures a pending restore is established without writing anything —
    /// for flows (like a transform's ⌘C-then-rewrite dance) that need a
    /// guaranteed-restorable original clipboard before doing work that may
    /// fail before any concealed text is ever placed. If a restore from
    /// another concurrent write is already pending, its original snapshot
    /// is reused rather than re-captured.
    static func beginClipboardHold() {
        restoreOwner.beginHold()
    }

    /// Writes `text` to the pasteboard as Murmur's own concealed content,
    /// coalescing with any restore already pending: an in-flight pending
    /// snapshot's ORIGINAL contents are carried forward rather than
    /// re-captured (which would otherwise capture Murmur's own transcript
    /// off the live pasteboard), and the pending restore is re-armed
    /// against this write's new stamp. Returns the resulting changeCount.
    @discardableResult
    static func writeConcealed(_ text: String) -> Int {
        restoreOwner.write(text)
    }

    /// Restores the held snapshot right now and clears the pending
    /// restore, unconditionally superseding any timer-based restore still
    /// in flight for an earlier write (that timer will see a cleared or
    /// stamp-mismatched pending and no-op harmlessly when it fires). Used
    /// by failure paths that give up before ever scheduling a delayed
    /// restore.
    static func restoreHeldClipboard() {
        restoreOwner.restoreAndClear()
    }

    /// Restores the held snapshot only if `expectedStamp` is still the
    /// most recently armed stamp (otherwise a later write has taken over
    /// the obligation to restore, and this call is a no-op) and the live
    /// pasteboard still carries exactly that stamp (otherwise the user —
    /// or some other app — claimed the pasteboard themselves in the
    /// interim, and their content is left alone rather than overwritten).
    static func attemptRestore(expectedStamp: Int) {
        restoreOwner.attemptRestore(expectedStamp: expectedStamp)
    }

    private static let restoreOwner = RestoreOwner()

    /// Owns the single pending "restore the user's real clipboard" record,
    /// shared by every path that conceals Murmur's own text on the
    /// pasteboard (`insert`, and `TransformManager.run`). Overlapping
    /// writes must not each snapshot the live pasteboard independently —
    /// doing so lets a second write capture the first write's own
    /// transcript as "the original", which then gets restored permanently
    /// once the dust settles. Instead, once a restore is pending, a later
    /// write reuses that same ORIGINAL snapshot and re-arms the timer
    /// against its own new stamp, so whichever write's guard fires last is
    /// the one that puts back the user's real clipboard.
    ///
    /// Lock-guarded rather than actor-isolated because `insert(_:)` is a
    /// synchronous, non-async entry point called from arbitrary threads
    /// (e.g. background `Task`s in AppDelegate) and must not force callers
    /// onto the main actor just to conceal-and-restore a paste.
    private final class RestoreOwner: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Pending?

        private struct Pending {
            var snapshot: ClipboardSnapshot
            /// The changeCount stamp of the most recent write that still
            /// owes a restore. A restore attempt only acts if it matches
            /// this exact stamp — an earlier write's attempt sees a stale
            /// stamp and no-ops, because a later write has taken over.
            var stamp: Int
        }

        func beginHold() {
            lock.lock()
            defer { lock.unlock() }
            if pending == nil {
                pending = Pending(snapshot: saveClipboard(), stamp: 0)
            }
        }

        func write(_ text: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = pending?.snapshot ?? saveClipboard()
            let stamp = place(text)
            pending = Pending(snapshot: snapshot, stamp: stamp)
            return stamp
        }

        func restoreAndClear() {
            lock.lock()
            let snapshot = pending?.snapshot ?? saveClipboard()
            pending = nil
            lock.unlock()
            restoreClipboard(snapshot)
        }

        func attemptRestore(expectedStamp: Int) {
            lock.lock()
            guard let current = pending, current.stamp == expectedStamp else {
                // Either already resolved, or a later write has taken over
                // the obligation to restore — that write's own check will
                // handle it.
                lock.unlock()
                return
            }
            let liveChangeCount = NSPasteboard.general.changeCount
            pending = nil
            lock.unlock()
            guard liveChangeCount == expectedStamp else { return }
            restoreClipboard(current.snapshot)
        }
    }
}
