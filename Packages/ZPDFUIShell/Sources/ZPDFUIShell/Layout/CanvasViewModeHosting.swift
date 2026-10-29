import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows

extension ProjectWindowLayoutController {

    /// Puts a canvas view mode — Split Canvas, Revision Overlay, Revision Compare — over the
    /// canvas pane.
    ///
    /// The mode is hosted in a ``ZPDFPanelHostViewController`` whose `onEscape` is wired to
    /// leaving, so Escape works from inside the mode's own SwiftUI content *and* from any
    /// AppKit subview it may contain. That is the second of the three ways out every mode has;
    /// the other two are the visible close control the view itself draws and the Panels-menu
    /// item the mode registry publishes.
    ///
    /// - Parameters:
    ///   - mode: which mode is taking the canvas.
    ///   - content: the mode's SwiftUI view. It is handed the same leave action, so its own
    ///     close button and Escape do exactly one thing.
    /// - Returns: `false` when the pane is not built yet, so a caller never believes a mode is
    ///   on screen that is not.
    @discardableResult
    public func presentCanvasMode<Content: View>(
        _ mode: DismissibleCanvasMode,
        @ViewBuilder content: (_ leave: @escaping @MainActor () -> Void) -> Content
    ) -> Bool {
        loadViewIfNeeded()
        guard let canvasPane else { return false }
        let leave: @MainActor () -> Void = { [weak self] in self?.environment.leaveCanvasMode() }
        let host = ZPDFPanelHostViewController(
            accessibilityLabel: mode.displayName,
            background: .background,
            rootView: content(leave)
        )
        host.onEscape = leave
        canvasPane.present(mode: host)
        return true
    }

    /// Takes whatever mode is on the canvas back off it. Safe to call when there is none.
    public func dismissCanvasMode() {
        canvasPane?.dismissMode()
    }

    /// Whether a canvas view mode is on screen right now.
    public var isShowingCanvasMode: Bool { canvasPane?.isShowingMode ?? false }

    /// Opens the Scale Regions panel, or closes it when it is already open.
    ///
    /// Registered as a mode on the way in, so `Escape` at the window level and the quit path
    /// both know how to close it — the panel floats over the drawing and a floating panel that
    /// outlives the review sheet at quit is a dead end: every mode must have a way out.
    public func toggleScaleRegionsPanel() {
        if scaleRegionsWindow != nil {
            closeScaleRegionsPanel()
            return
        }
        showScaleRegionsPanel()
    }

    /// Opens the Scale Regions panel, or brings it forward when it is already open — what the
    /// Panels menu's "Show Scale Regions" promises (L-94).
    public func showScaleRegionsPanel() {
        if let open = scaleRegionsWindow {
            if NSApplication.shared.isRunning { open.showWindow(nil) }
            return
        }
        let controller = ScaleRegionsWindowController(model: environment.scaleRegions)
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.scaleRegionsWindow = nil
            self.environment.modeRegistry.unregister(id: Self.scaleRegionsModeID)
        }
        scaleRegionsWindow = controller
        environment.modeRegistry.register(
            id: Self.scaleRegionsModeID,
            displayName: NSLocalizedString("Scale Regions", comment: "Mode name"),
            exitRoute: ZPDFModeExitRoute(
                menuTitle: NSLocalizedString("Close Scale Regions", comment: "Menu item"),
                performExit: { [weak self] in self?.closeScaleRegionsPanel() }
            )
        )
        // Ordered front only when there is an event loop to order it into. Under `swift test`
        // there is not, and a utility window pushed onto the user's screen by a unit test is a
        // focus steal no test may cause. The controller and its registration are
        // built either way, so the behaviour under test is the shipping behaviour.
        if NSApplication.shared.isRunning { controller.showWindow(nil) }
    }

    /// Closes the Scale Regions panel. Safe to call when it is not open.
    public func closeScaleRegionsPanel() {
        guard let controller = scaleRegionsWindow else { return }
        scaleRegionsWindow = nil
        environment.modeRegistry.unregister(id: Self.scaleRegionsModeID)
        controller.onClose = nil
        controller.dismiss()
    }

    /// Whether the Scale Regions panel is open. Read by the shell's tests.
    public var isShowingScaleRegionsPanel: Bool { scaleRegionsWindow != nil }

    /// The registry identity of the Scale Regions panel.
    static var scaleRegionsModeID: String { "zenit.mode.scaleRegions" }

    /// The document canvas controller, which a mode never replaces.
    ///
    /// Exposed so a test can hold the instance across entering and leaving a mode and assert it
    /// is the same object — the property that makes "the canvas restores its exact prior scroll
    /// and zoom" true by construction rather than by a restore routine.
    public var documentCanvasController: NSViewController? { canvasPane?.canvasController }
}
