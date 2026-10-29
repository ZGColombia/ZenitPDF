import AppKit
import Foundation
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIShell
import ZPDFUIWorkflows

/// A Split Canvas pane on a window of its own — a second display (NL-DOCS-14). The pane keeps
/// its state in the same controller, so sync with the other panes still holds; closing the
/// window brings the pane back into the split.
extension ProjectWindowController {

    /// How a pane's window reaches the screen. A test replaces it; nothing is ordered front
    /// outside the assembled bundle.
    static var paneWindowPresenter: @MainActor (NSWindow) -> Void = { window in
        guard ZenitModalPresenter.canPresentModally else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// One pane's window: which Split Canvas it belongs to (each drawing's shell has its own),
    /// and the observer that brings the pane back when the window closes.
    private struct PaneWindowKey: Hashable {
        let split: ObjectIdentifier
        let pane: SplitCanvasPaneID
    }

    private struct PaneWindowEntry {
        let window: NSWindow
        let split: SplitCanvasController
        let observer: any NSObjectProtocol
    }

    /// The pane windows open per window controller, per Split Canvas and pane. Emptied by
    /// ``closePaneWindows(of:)`` when the window closes, a drawing leaves it, or Split Canvas
    /// ends (S-022: they used to outlive all three, saying "This pane is empty." over a split
    /// controller they kept alive).
    private static var paneWindows: [ObjectIdentifier: [PaneWindowKey: PaneWindowEntry]] = [:]

    /// The window a pane is on, if it is on one: a pane of `split`, or of the front drawing's
    /// Split Canvas when `split` is `nil`.
    func paneWindow(_ id: SplitCanvasPaneID, in split: SplitCanvasController? = nil) -> NSWindow? {
        guard let split = split ?? activeDocument.flatMap({ windowShell(for: $0) })?.splitCanvas else { return nil }
        return Self.paneWindows[ObjectIdentifier(self)]?[PaneWindowKey(split: ObjectIdentifier(split), pane: id)]?.window
    }

    /// How many pane windows this window has open. Test affordance.
    var openPaneWindowCount: Int { Self.paneWindows[ObjectIdentifier(self)]?.count ?? 0 }

    func wireSplitPaneDetach(shell: ProjectShellEnvironment) {
        shell.splitCanvas.onDetachPane = { [weak self, weak shell] id in
            guard let self, let shell else { return }
            self.detachSplitPane(id, shell: shell)
        }
    }

    /// Moves a pane to its own window; answers the window, or `nil` for an empty pane.
    @discardableResult
    func detachSplitPane(_ id: SplitCanvasPaneID, shell: ProjectShellEnvironment) -> NSWindow? {
        let controller = shell.splitCanvas
        if let open = paneWindow(id, in: controller) { Self.paneWindowPresenter(open); return open }
        let pane = controller.pane(id)
        guard !pane.isEmpty, splitPaneRenderSource(for: pane) != nil else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.title = [pane.documentTitle, pane.pageLabel].filter { !$0.isEmpty }.joined(separator: " — ")
        window.contentView = NSHostingView(rootView: DetachedSplitPaneView(controller: controller, paneID: id) { [weak self] pane in
            self?.splitPaneRenderSource(for: pane)
        })
        controller.setDetached(true, pane: id)
        let owner = ObjectIdentifier(self)
        let key = PaneWindowKey(split: ObjectIdentifier(controller), pane: id)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.releasePaneWindow(owner: owner, key: key) }
        }
        Self.paneWindows[owner, default: [:]][key] = PaneWindowEntry(window: window, split: controller, observer: observer)
        Self.paneWindowPresenter(window)
        return window
    }

    /// Closes this window's pane windows: every one, or only those of `split`. Each pane goes
    /// back into its split first, and the window's close observer is removed with it.
    func closePaneWindows(of split: SplitCanvasController? = nil) {
        let owner = ObjectIdentifier(self)
        for (key, entry) in Self.paneWindows[owner] ?? [:] where split.map({ key.split == ObjectIdentifier($0) }) ?? true {
            Self.releasePaneWindow(owner: owner, key: key)
            entry.window.close()
        }
    }

    /// The pane is back in its split and its window is forgotten: the window closed by itself,
    /// or ``closePaneWindows(of:)`` is closing it.
    private static func releasePaneWindow(owner: ObjectIdentifier, key: PaneWindowKey) {
        guard let entry = paneWindows[owner]?[key] else { return }
        NotificationCenter.default.removeObserver(entry.observer)
        entry.split.setDetached(false, pane: key.pane)
        paneWindows[owner]?[key] = nil
        if paneWindows[owner]?.isEmpty == true { paneWindows[owner] = nil }
    }
}

/// The detached pane's content, following the controller's live state for that pane.
struct DetachedSplitPaneView: View {
    let controller: SplitCanvasController
    let paneID: SplitCanvasPaneID
    let source: @MainActor (SplitCanvasPaneState) -> SplitPaneRenderSource?

    var body: some View {
        let pane = controller.pane(paneID)
        if let renderSource = source(pane) {
            SplitCanvasPaneLiveContent(pane: pane, renderSource: renderSource, controller: controller)
        } else {
            Text(NSLocalizedString("This pane is empty.", comment: "Detached Split Canvas pane with nothing to show"))
                .zpdfText(.body, .textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
