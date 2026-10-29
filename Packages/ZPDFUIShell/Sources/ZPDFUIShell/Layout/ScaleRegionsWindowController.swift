import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIMeasurement

/// The window the Scale Regions panel lives in.
///
/// # Why a utility window and not a pane or a sheet
///
/// The panel's whole job is to be open *while the person draws a boundary on the sheet*. A sheet
/// would cover the drawing and block the click. A fourth pane would contradict the layout,
/// which fixes the Navigator to four pages and the window to three panes plus the docked
/// ledger. A floating utility panel over the drawing is the arrangement
/// the workflow actually needs, and the detached Quantity Ledger already established the
/// pattern in this shell.
///
/// The window is closable, Escape-dismissible and non-modal, so it satisfies the no-dead-ends
/// rule three times over.
@MainActor
public final class ScaleRegionsWindowController: NSWindowController, NSWindowDelegate {

    /// AppKit's frame autosave key for this window.
    public static let autosaveName = "Zenit.ScaleRegionsWindow.Frame"

    /// Raised when the window closes by any route, so the owner can drop its reference and
    /// unregister the mode.
    public var onClose: (@MainActor () -> Void)?

    private var isDismissingProgrammatically = false

    /// Creates the window around a Scale Regions controller.
    public init(model: ScaleRegionsPanelModel) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Scale Regions", comment: "Scale Regions window title")
        window.minSize = NSSize(width: 340, height: 260)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Floats over the drawing so the boundary can be drawn without the panel disappearing
        // behind the project window on the first click.
        window.level = .floating
        window.hidesOnDeactivate = true
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        let host = ZPDFPanelHostViewController(
            accessibilityLabel: NSLocalizedString("Scale Regions", comment: "Accessibility: Scale Regions panel"),
            background: .surface,
            rootView: ScaleRegionsPanelHost(model: model, onClose: { [weak self] in self?.dismiss() })
        )
        host.onEscape = { [weak self] in self?.dismiss() }
        window.contentViewController = host
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        // Built in code only; there is no nib for this window.
        return nil
    }

    /// Closes the window and reports it once.
    public func dismiss() {
        guard !isDismissingProgrammatically else { return }
        isDismissingProgrammatically = true
        close()
        isDismissingProgrammatically = false
        onClose?()
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isDismissingProgrammatically else { return }
        onClose?()
    }
}
