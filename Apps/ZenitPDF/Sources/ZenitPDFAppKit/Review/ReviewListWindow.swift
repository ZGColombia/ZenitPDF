import AppKit
import SwiftUI
import ZPDFUIShell

/// View ▸ Review List (NL-COLLAB-04): the Review List in a utility panel beside the drawing, so
/// the canvas stays usable while a reviewer works down the list.
///
/// One panel per drawing per window, reused (S-010: it used to be one per window, bound to the
/// first drawing it was opened for, so the list of tab B showed tab A's markups under A's name).
/// The panel is ordered front only in the assembled application
/// (``ZenitModalPresenter/canPresentModally``); a test builds it and never shows it.
@MainActor
enum ReviewListWindow {

    private static var panels = DocumentPanelRegistry()

    /// The panel for a window controller's document, made on first use.
    @discardableResult
    static func present(for controller: ProjectWindowController, document: ZenitPDFProjectDocument) -> NSPanel? {
        guard let shell = controller.windowShell(for: document) ?? document.shell else { return nil }
        let panel = panels.panel(for: controller, document: document)
            ?? makePanel(shell: shell, document: document)
        panels.store(panel, for: controller, document: document)
        // Ordered front, never made key: the Edit menu keeps acting on the drawing (L-78).
        (panel as? DocumentUtilityPanel)?.presentWithoutTakingKey()
        return panel
    }

    /// The panel for `document`. Like the Takeoff Assistant Inbox it is a
    /// ``DocumentUtilityPanel``: it takes the keyboard only for its fields, and its Undo and Redo
    /// are the drawing's, so opening it never disables the Edit menu for the drawing behind it.
    static func makePanel(shell: ProjectShellEnvironment, document: NSDocument) -> NSPanel {
        let panel = DocumentUtilityPanel(
            document: document,
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow]
        )
        panel.title = String(
            format: NSLocalizedString("Review List — %@", comment: "Review List window title; the document name"),
            document.displayName
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        // L-83: the hosting controller sized the panel to the pane's ideal size, about
        // 520 × 45 pt — the filter bar and no list. The panel keeps its own size now, never
        // smaller than the pane's minimum.
        let hosting = NSHostingController(rootView: ReviewListPane(environment: shell))
        hosting.sizingOptions = [.minSize]
        panel.contentViewController = hosting
        panel.contentMinSize = ReviewListPane.minimumSize
        panel.setContentSize(Self.initialContentSize)
        panel.setAccessibilityLabel(NSLocalizedString("Review List", comment: "Accessibility label of the Review List"))
        return panel
    }

    /// The panel's size when it first opens: room for the bar and a dozen rows.
    static let initialContentSize = NSSize(width: 960, height: 460)

    /// Closes and forgets the panels of a window that is closing, or of one drawing leaving it.
    static func forget(_ controller: ProjectWindowController, document: ZenitPDFProjectDocument? = nil) {
        panels.forget(controller, document: document)
    }

    /// The panel open for a window's drawing, if any. Test affordance.
    static func openPanel(for controller: ProjectWindowController, document: ZenitPDFProjectDocument) -> NSPanel? {
        panels.panel(for: controller, document: document)
    }
}

/// Utility panels that belong to one drawing in one window (S-010): the Review List and the
/// Takeoff Assistant Inbox. Keyed by both, so a panel always acts on the drawing it was made for,
/// and emptied when the window closes or the drawing leaves it, so a closed window's panel no
/// longer keeps its shell alive through the hosting controller.
@MainActor
struct DocumentPanelRegistry {
    private struct Key: Hashable {
        let controller: ObjectIdentifier
        let document: UUID
    }

    private var panels: [Key: NSPanel] = [:]

    func panel(for controller: ProjectWindowController, document: ZenitPDFProjectDocument) -> NSPanel? {
        panels[Key(controller: ObjectIdentifier(controller), document: document.documentIdentity)]
    }

    mutating func store(_ panel: NSPanel, for controller: ProjectWindowController, document: ZenitPDFProjectDocument) {
        panels[Key(controller: ObjectIdentifier(controller), document: document.documentIdentity)] = panel
    }

    /// Closes and drops the window's panels: all of them, or only `document`'s.
    mutating func forget(_ controller: ProjectWindowController, document: ZenitPDFProjectDocument? = nil) {
        let window = ObjectIdentifier(controller)
        for (key, panel) in panels where key.controller == window && (document == nil || key.document == document?.documentIdentity) {
            panel.close()
            panels[key] = nil
        }
    }

    /// How many panels are held. Test affordance.
    var count: Int { panels.count }
}
