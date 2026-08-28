import Foundation

/// How text reached the target app — determines the undo mechanics later.
enum InsertionMethod {
    /// Direct Accessibility write over the current selection (a bare caret
    /// being a zero-length selection).
    case ax
    /// Concealed clipboard write followed by a synthesized ⌘V.
    case paste
}

/// Everything needed to remove the most recent insertion again.
struct LastInsertion: Equatable {
    var text: String
    var method: InsertionMethod
    var date: Date
    /// Bundle id of the app the text went into.
    var bundleID: String?
    /// Non-empty selection the insertion overwrote, snapshotted before the
    /// write. nil for a plain caret insertion or when the selection could
    /// not be read. Lets an AX undo restore the prior content instead of
    /// merely deleting the new text.
    var replacedText: String?
}

/// Pure decision logic for whether a fresh hotkey press should undo the
/// last insertion or start a new recording. No AX or CGEvent dependencies,
/// so it can be unit-tested without Accessibility trust or a frontmost app.
enum InsertionTracker {

    enum Action: Equatable {
        case undo
        case record
    }

    /// Mechanics `TextInserter.undo` should apply, decided purely from the
    /// record so the branching can be unit-tested without Accessibility.
    enum UndoPlan: Equatable {
        /// One synthesized ⌘Z. The target app's own undo stack removes the
        /// paste AND restores whatever it replaced — nothing for us to do
        /// about a replaced selection, even when one was recorded.
        case nativeUndo
        /// Select the inserted span and write `replacedText` back into it,
        /// restoring the prior content; fall back to plain deletion if that
        /// write fails, so we never leave both texts in the field.
        case restoreOriginal
        /// Plain insertion: select-and-delete the inserted span, with a
        /// backspace fallback.
        case deleteInserted
    }

    /// Chooses undo mechanics from the insertion record alone.
    static func undoPlan(for insertion: LastInsertion) -> UndoPlan {
        switch insertion.method {
        case .paste:
            return .nativeUndo
        case .ax:
            return insertion.replacedText != nil ? .restoreOriginal : .deleteInserted
        }
    }

    /// Replacement mode iff a readable selection held at least one
    /// character — whitespace counts, since selecting spaces and dictating
    /// over them should replace them. An unreadable (nil) or empty
    /// selection is an ordinary caret insertion.
    static func isReplacement(selectedText: String?) -> Bool {
        guard let text = selectedText else { return false }
        return !text.isEmpty
    }

    /// Where the caret sits after an AX write of `replacementUTF16Length`
    /// UTF-16 units over a selection starting at `selectionLocation`.
    /// One formula covers both modes: replacing the span [loc, loc+len)
    /// with M units and inserting at a bare caret [loc, loc) both leave
    /// the caret at loc+M. This is the invariant TextInserter verifies
    /// after every direct AX write.
    static func postWriteCaretLocation(
        selectionLocation: Int, replacementUTF16Length: Int
    ) -> Int {
        selectionLocation + replacementUTF16Length
    }

    /// Seconds after an insertion during which a hotkey press undoes it.
    /// Reads UserDefaults each call so it is tunable on a running install:
    ///     defaults write local.murmur undoWindowSeconds -float 3
    static var windowSeconds: TimeInterval {
        UserDefaults.standard.object(forKey: "undoWindowSeconds") as? Double ?? 2.0
    }

    /// Undo wins only when an insertion is pending, it is still inside the
    /// window, and the frontmost app is still the one the text went into.
    static func action(
        now: Date, last: LastInsertion?, frontAppBundleID: String?,
        windowSeconds: TimeInterval
    ) -> Action {
        guard let last else { return .record }
        guard now.timeIntervalSince(last.date) < windowSeconds else { return .record }
        guard frontAppBundleID == last.bundleID else { return .record }
        return .undo
    }
}
