import AppKit
import ZPDFUIShell

/// Feeds the canvas undo toast (NL-UX-12) from one document's undo manager: after an undo the
/// step just taken back is the manager's redo name, after a redo it is its undo name.
///
/// One feed per window's shell (C-07): a second window on a document shares its undo manager but
/// has a toast of its own, and the toast shows in the window the ⌘Z came from — the one the
/// document's ``ZenitPDFProjectDocument/shell`` answers for — not only in the first window.
final class UndoToastFeed {

    /// One feed per window shell, with the shell it serves held weakly: a shell allocated later
    /// at a freed shell's address gets a feed of its own instead of finding a stale one.
    @MainActor private static var feeds: [ObjectIdentifier: (shell: WeakShell, feed: UndoToastFeed)] = [:]

    struct WeakShell {
        weak var shell: ProjectShellEnvironment?
    }

    private var tokens: [NSObjectProtocol] = []

    /// - Parameter isFocused: whether the toast of this feed's window should speak for a step —
    ///   the window is the one the person is working in. Every feed of a document hears every undo.
    @MainActor
    init(undoManager: UndoManager, toast: UndoToastModel, isFocused: @escaping @MainActor @Sendable () -> Bool = { true }) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .NSUndoManagerDidUndoChange, object: undoManager, queue: nil) { [weak undoManager, weak toast] _ in
            MainActor.assumeIsolated {
                guard isFocused(), let undoManager, let toast,
                      let text = UndoToastModel.text(undid: undoManager.redoActionName, isRedo: false) else { return }
                toast.show(text)
            }
        })
        tokens.append(center.addObserver(forName: .NSUndoManagerDidRedoChange, object: undoManager, queue: nil) { [weak undoManager, weak toast] _ in
            MainActor.assumeIsolated {
                guard isFocused(), let undoManager, let toast,
                      let text = UndoToastModel.text(undid: undoManager.undoActionName, isRedo: true) else { return }
                toast.show(text)
            }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Starts (or keeps) the feed for one window's shell on a document.
    @MainActor
    static func attach(document: ZenitPDFProjectDocument, shell: ProjectShellEnvironment) {
        guard let undoManager = document.undoManager else { return }
        feeds = feeds.filter { $0.value.shell.shell != nil }
        let key = ObjectIdentifier(shell)
        guard feeds[key]?.shell.shell !== shell else { return }
        let feed = UndoToastFeed(undoManager: undoManager, toast: shell.undoToast) { [weak document, weak shell] in
            guard let document, let shell else { return false }
            return document.shell === shell
        }
        feeds[key] = (WeakShell(shell: shell), feed)
    }

    /// Stops the feed of a window that closed.
    @MainActor
    static func detach(shell: ProjectShellEnvironment) {
        feeds[ObjectIdentifier(shell)] = nil
    }

    /// Whether a window's shell has a feed. Test affordance.
    @MainActor
    static func hasFeed(for shell: ProjectShellEnvironment) -> Bool {
        feeds[ObjectIdentifier(shell)]?.shell.shell === shell
    }
}
