import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

/// The Tool Library as a non-modal panel beside the drawing (nl-ux, NL-UX-06).
///
/// It was a 720 × 520 **sheet** (`WorkflowSheet.presentToolLibrary`): while it was open the
/// window beneath it took no clicks, so a person could not arm a tool, draw with it and come
/// back for the next one, and the toolbar chip's "open" state could never be used to close it
/// because the sheet covered the chip. Now it is a utility panel attached to the project window
/// as a child: the canvas, the toolbar and the menus keep working while it is open, pressing
/// the Tool Library chip again closes it, and Escape or its close button close it too.
///
/// What did not change is everything the sheet was joined to: the same `ToolLibraryPanelView`,
/// the same `ToolLibraryEditingModel` with its change stream into the document, the
/// same artwork import and import-failure routes, and the same per-edit undo
/// registration, removed when the panel closes so no undo step outlives the model it reverts.
@MainActor
final class ToolChestPanel: NSObject, NSWindowDelegate {

    /// The panel window. Built on creation, ordered front only when a person can see it.
    let panel: NSPanel
    /// The working copy of the library the panel edits.
    let model: ToolLibraryEditingModel
    private weak var parent: NSWindow?
    private weak var undoManager: UndoManager?
    private var onEnd: (@MainActor () -> Void)?
    /// Whether ``show()`` ordered the panel in. Always `false` in a test process.
    private(set) var isOnScreen = false
    /// Whether the panel has been closed; closing is idempotent.
    private(set) var isClosed = false

    /// The panel's default size: narrow enough to sit beside the drawing.
    static let defaultSize = CGSize(width: 380, height: 560)

    init<Presenter: ToolLibraryPresenting>(
        parent: NSWindow,
        presenter: Presenter,
        selectedMarkup: MarkupSummary?,
        onPresetsChanged: (@MainActor ([ToolPresetSummary]) -> Void)?,
        onImportArtwork: ArtworkImportHandler?,
        onImportFailure: (@MainActor (ZPDFUserFacingError) -> Void)?,
        undoManager: UndoManager?,
        onEnd: @escaping @MainActor () -> Void
    ) {
        let model = ToolLibraryEditingModel(presets: presenter.presets)
        self.model = model
        self.parent = parent
        self.undoManager = undoManager
        self.onEnd = onEnd
        let panel = ToolChestWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = NSLocalizedString("Tool Library", comment: "Sheet title")
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 320, height: 360)
        panel.setAccessibilityLabel(NSLocalizedString("Tool Library", comment: "Sheet title"))
        self.panel = panel
        super.init()

        if let undoManager {
            model.onUndoableChange = { [weak model, weak undoManager] step in
                guard let model, let undoManager else { return }
                WorkflowSheet.registerToolLibraryUndo(step, model: model, undoManager: undoManager)
            }
        }
        model.onImportArtwork = onImportArtwork
        model.onImportFailure = onImportFailure
        if let onPresetsChanged {
            model.onChange = { [weak model] _ in
                guard let model else { return }
                onPresetsChanged(model.presets)
            }
        }
        let root = ToolLibraryPanelView(
            presenter: presenter,
            model: model,
            selectedMarkup: selectedMarkup,
            onClose: { [weak self] in self?.close() }
        )
        .background(ZPDFColor.color(.background))
        panel.contentViewController = NSHostingController(rootView: root)
        panel.setContentSize(Self.defaultSize)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Where the panel sits: inside the parent's right edge, below its top band, so it covers
    /// the Inspector column rather than the drawing.
    static func frame(besides parentFrame: NSRect, size: CGSize) -> NSRect {
        let inset: CGFloat = 12
        let topBand: CGFloat = 96
        let height = min(size.height, max(parentFrame.height - topBand - inset, 200))
        return NSRect(
            x: parentFrame.maxX - size.width - inset,
            y: parentFrame.maxY - topBand - height,
            width: size.width,
            height: height
        )
    }

    /// Orders the panel in beside its window — only in the shipping application, and only over
    /// a window a person can see. A test process never draws it (no test puts a window
    /// on screen).
    ///
    /// Through ``ZenitModalPresenter/presentPanel(_:identifier:)``, so the request is recorded
    /// like every other workflow surface (BH-923) and a test process draws nothing.
    func show() {
        guard !isClosed, let parent else { return }
        // In the app, never over a window nobody can see.
        if ZenitModalPresenter.canPresentModally, !parent.isVisible { return }
        panel.setFrame(Self.frame(besides: parent.frame, size: panel.frame.size), display: false)
        guard ZenitModalPresenter.presentPanel(panel, identifier: Self.modalIdentifier) else { return }
        parent.addChildWindow(panel, ordered: .above)
        isOnScreen = true
    }

    /// The presenter identifier, in the workflow family the sheet had.
    static let modalIdentifier = "workflow.Tool Library"

    /// Closes the panel, removes its undo steps and ends the mode. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if isOnScreen {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            isOnScreen = false
        }
        undoManager?.removeAllActions(withTarget: model)
        let end = onEnd
        onEnd = nil
        end?()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The title-bar close button: the window is already closing, so only the bookkeeping.
        isOnScreen = false
        close()
    }
}

/// The panel window: Escape closes it, as every Zenit surface must allow, and it never becomes the main window.
@MainActor
final class ToolChestWindow: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    override var canBecomeMain: Bool { false }
}

extension ToolChestPanel {
    /// The open panels, one per document at most, held here because the panel window's
    /// delegate reference is weak and nothing else owns the controller while it is open.
    static var open: [ObjectIdentifier: ToolChestPanel] = [:]
}
