import AppKit
import Foundation
import ZPDFUIShell

/// Keeps the canvas bar's Undo and Redo buttons in step with one document's undo manager.
///
/// The shell draws the buttons but cannot see the undo stack — undo is serviced here, in the
/// app tier — so this feed writes ``CanvasUndoState`` every time the stack can have changed:
/// a group closing, an undo, a redo, and the checkpoints the undo manager posts around each.
/// Without it the buttons would stay permanently enabled and a press with nothing to undo would
/// do nothing at all, which is the dead end the no-dead-ends rule forbids.
final class CanvasUndoStateFeed {

    private var tokens: [NSObjectProtocol] = []

    /// Starts feeding `state` from `undoManager`, and writes the current answer at once.
    @MainActor
    init(undoManager: UndoManager?, state: CanvasUndoState) {
        guard let undoManager else { return }
        Self.write(undoManager, to: state)
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint,
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange
        ]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: undoManager,
                // Synchronously, on the posting thread: a document's undo manager is used on the
                // main thread, and the bar must be right the moment `undo()` returns, not one
                // run-loop turn later (with `.main` the update was queued, and a test — or a
                // second press in the same turn — read the stale state).
                queue: nil
            ) { [weak undoManager, weak state] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    guard let undoManager, let state else { return }
                    Self.write(undoManager, to: state)
                }
            }
        }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Copies what the undo manager can do into the shell's state, writing only what changed so
    /// an unchanged checkpoint does not invalidate the bar.
    @MainActor
    static func write(_ undoManager: UndoManager, to state: CanvasUndoState) {
        let canUndo = undoManager.canUndo
        let canRedo = undoManager.canRedo
        if state.canUndo != canUndo { state.canUndo = canUndo }
        if state.canRedo != canRedo { state.canRedo = canRedo }
        let undoName = canUndo ? undoManager.undoActionName : ""
        let redoName = canRedo ? undoManager.redoActionName : ""
        if state.undoActionName != undoName { state.undoActionName = undoName }
        if state.redoActionName != redoName { state.redoActionName = redoName }
    }
}
