import AppKit

/// A utility panel that belongs to one drawing — the Takeoff Assistant Inbox, the Review List —
/// and never takes the Edit menu away from it (L-78).
///
/// With the Inbox in front, Undo, Redo and Copy in the Edit menu were disabled for the drawing
/// behind it. The panel had been made key, so the menu's actions went to the panel first: an
/// `NSWindow` answers `undo:` and `redo:` itself, from its own undo manager, which was empty, and
/// the hosting view answered `copy:` with nothing to copy. The responder chain stopped there and
/// never reached the drawing.
///
/// Two rules fix it at that root:
///
///   * **The panel becomes key only when it must** — when a text field in it is clicked — so
///     pressing Accept or picking a row leaves the project window key and the Edit menu acting
///     on the drawing. It is ordered front, never made key, when it opens.
///   * **Its undo manager is the drawing's.** When it is key (a field is being typed in), Undo
///     and Redo still act on the drawing's history, exactly as they do from the project window.
@MainActor
final class DocumentUtilityPanel: NSPanel {

    /// The drawing whose history Undo and Redo act on.
    weak var document: NSDocument?

    init(document: NSDocument, contentRect: NSRect, styleMask: NSWindow.StyleMask) {
        self.document = document
        super.init(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
    }

    override var undoManager: UndoManager? {
        document?.undoManager ?? super.undoManager
    }

    /// Brings the panel forward without taking the keyboard or the Edit menu from the project
    /// window — in the assembled application only; a test process never orders it on screen.
    func presentWithoutTakingKey() {
        guard ZenitModalPresenter.canPresentModally else { return }
        orderFront(nil)
    }
}
