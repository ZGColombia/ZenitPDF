import AppKit
import Foundation
import ZPDFDesignSystem

/// The canvas column: the canvas bar, the canvas, the status strip, and room over the canvas
/// for a canvas view mode.
///
/// # Why the canvas is never removed
///
/// A view mode must give back *exactly* the view the person had:
/// same page, same zoom, same scroll offset, to the pixel. The obvious implementation — swap the
/// split item's view controller for the mode's, swap it back on exit — cannot promise that. An
/// `NSScrollView` taken out of a window and put back has had its clip view resized twice, and
/// `NSDocument`-scale drawings restore their content offset from a frame that no longer matches;
/// what comes back is *approximately* where you were.
///
/// So the canvas controller is never removed. It stays in the hierarchy, laid out, scrolled where
/// it was, and the mode is added *over* it, filling the pane and hiding it from accessibility.
/// Leaving is one `removeFromSuperview`, after which the canvas underneath is not restored — it
/// was never disturbed. That is a stronger guarantee than a restore routine can make, and it is
/// the guarantee ``ProjectWindowLayoutController/canvasViewportIsUndisturbed`` asserts.
@MainActor
public final class CanvasPaneContainerViewController: NSViewController {

    /// The document canvas. Owned for the life of the window and never removed.
    public let canvasController: NSViewController

    /// The mode currently covering the canvas, or `nil`.
    public private(set) var modeController: NSViewController?

    /// The canvas bar along the top of the column — page navigation, zoom, fit, undo and redo,
    /// the in-document search field — or `nil` for a bare canvas.
    public let topBarController: NSViewController?
    /// The slim status strip along the bottom of the column — the armed tool, scale, unit, the
    /// snap toggles, the pointer coordinate — or `nil` for a bare canvas.
    public let statusStripController: NSViewController?

    /// The height the top bar is laid out at.
    public let topBarHeight: CGFloat
    /// The height the status strip is laid out at.
    public let statusStripHeight: CGFloat

    /// The region a view mode covers: the canvas and the canvas bar above it, whose page and
    /// zoom controls would otherwise act on a canvas the person cannot see. The status strip
    /// stays uncovered, as the window's status bar always did during a mode.
    private let coverGuide = NSLayoutGuide()

    /// Creates the container around one canvas controller.
    ///
    /// - Parameters:
    ///   - canvasController: the document canvas, owned for the life of the window.
    ///   - topBar: the canvas bar, laid out `topBarHeight` tall above the canvas.
    ///   - statusStrip: the status strip, laid out `statusStripHeight` tall below it.
    public init(
        canvasController: NSViewController,
        topBar: NSViewController? = nil,
        topBarHeight: CGFloat = 0,
        statusStrip: NSViewController? = nil,
        statusStripHeight: CGFloat = 0
    ) {
        self.canvasController = canvasController
        self.topBarController = topBar
        self.topBarHeight = topBar == nil ? 0 : topBarHeight
        self.statusStripController = statusStrip
        self.statusStripHeight = statusStrip == nil ? 0 : statusStripHeight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        // The shell builds its window in code; there is no nib to decode from.
        return nil
    }

    public override func loadView() {
        let container = ZPDFPanelBackgroundView(token: .canvasBackdrop)
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        container.addLayoutGuide(coverGuide)

        // Top to bottom: canvas bar, canvas, status strip. With neither bar the canvas fills
        // the pane exactly as it always has.
        var above = container.topAnchor
        if let topBarController {
            addChild(topBarController)
            let barView = topBarController.view
            barView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(barView)
            NSLayoutConstraint.activate([
                barView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                barView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                barView.topAnchor.constraint(equalTo: container.topAnchor),
                barView.heightAnchor.constraint(equalToConstant: topBarHeight)
            ])
            above = barView.bottomAnchor
        }

        var below = container.bottomAnchor
        if let statusStripController {
            addChild(statusStripController)
            let stripView = statusStripController.view
            stripView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stripView)
            NSLayoutConstraint.activate([
                stripView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stripView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stripView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stripView.heightAnchor.constraint(equalToConstant: statusStripHeight)
            ])
            below = stripView.topAnchor
        }

        addChild(canvasController)
        let canvasView = canvasController.view
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: above),
            canvasView.bottomAnchor.constraint(equalTo: below),

            coverGuide.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            coverGuide.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            coverGuide.topAnchor.constraint(equalTo: container.topAnchor),
            coverGuide.bottomAnchor.constraint(equalTo: below)
        ])
    }

    /// Whether a view mode is covering the canvas.
    public var isShowingMode: Bool { modeController != nil }

    /// Puts a mode over the canvas. Replacing one mode with another swaps only the cover.
    public func present(mode: NSViewController) {
        if modeController != nil { dismissMode() }
        loadViewIfNeeded()
        addChild(mode)
        let modeView = mode.view
        modeView.translatesAutoresizingMaskIntoConstraints = false
        // Above everything in the pane, the canvas bar included, but inside the cover guide so
        // the status strip below stays readable.
        view.addSubview(modeView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            modeView.leadingAnchor.constraint(equalTo: coverGuide.leadingAnchor),
            modeView.trailingAnchor.constraint(equalTo: coverGuide.trailingAnchor),
            modeView.topAnchor.constraint(equalTo: coverGuide.topAnchor),
            modeView.bottomAnchor.constraint(equalTo: coverGuide.bottomAnchor)
        ])
        // The canvas underneath is still laid out and still scrolled where it was, but it is
        // not on screen: a screen reader that could still reach it would read a page the person
        // is not looking at.
        canvasController.view.setAccessibilityHidden(true)
        topBarController?.view.setAccessibilityHidden(true)
        modeController = mode
        view.window?.makeFirstResponder(modeView)
    }

    /// Takes the mode off the canvas. Safe to call when there is none.
    public func dismissMode() {
        guard let mode = modeController else { return }
        mode.view.removeFromSuperview()
        mode.removeFromParent()
        modeController = nil
        canvasController.view.setAccessibilityHidden(false)
        topBarController?.view.setAccessibilityHidden(false)
        // Focus goes back to the canvas rather than to the window: leaving a mode with the
        // window itself as first responder is how the next keystroke silently does nothing.
        view.window?.makeFirstResponder(canvasController.view)
    }
}
