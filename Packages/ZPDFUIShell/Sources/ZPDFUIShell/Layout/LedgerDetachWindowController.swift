import AppKit
import Foundation

/// The window the Quantity Ledger lives in when it is detached from the project window.
///
/// Detaching reparents the *same* view controller rather than building a second one, so the
/// ledger's scroll position, grouping, filter and selection survive the move in both
/// directions. Nothing is rebuilt, so nothing is lost.
@MainActor
public final class LedgerDetachWindowController: NSWindowController, NSWindowDelegate {

    /// Raised when the user closes the window, so the owner can dock the ledger again.
    public var onCloseRequested: (@MainActor () -> Void)?

    private var isDismissingProgrammatically = false

    /// The content size a first detach opens at: the header, a table of a dozen rows and a side
    /// panel with room for its fields.
    public static let defaultContentSize = CGSize(width: 900, height: 420)

    /// The smallest content the window allows: the header's controls side by side (the pane
    /// needs 560 pt for them once the summary chips have given way) and a side panel tall enough
    /// to show its fields (L-84, L-85).
    public static let minimumContentSize = CGSize(width: 560, height: 320)

    /// Creates the window around an already-built ledger view controller.
    ///
    /// - Parameters:
    ///   - contentViewController: the docked ledger controller, reparented into this window.
    ///   - initialFrame: the last frame the window had, when there is one.
    ///   - autosaveName: AppKit's frame autosave key.
    ///   - parentFrame: the project window's frame, so a first detach opens beside it rather
    ///     than centred over its canvas.
    ///   - screenFrame: the visible frame of the screen the project window is on.
    public init(
        contentViewController: NSViewController,
        initialFrame: ZPDFWindowFrame?,
        autosaveName: String = ZPDFShellAutosaveName.detachedLedgerWindow,
        parentFrame: CGRect? = nil,
        screenFrame: CGRect? = nil
    ) {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Quantity Ledger", comment: "Detached ledger window title")
        // Installing the controller sizes the window to the controller's view as it was docked —
        // 56 pt tall when the ledger was folded to its bar — which is how the window opened about
        // 200 pt tall over the canvas, with the side panel's fields squeezed out of reach (L-84).
        // The frame is set again below, after the controller is in.
        window.contentViewController = contentViewController
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName(autosaveName)
        let minimumFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.minimumContentSize)).size
        let defaultFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.defaultContentSize)).size
        let frame = initialFrame.map { Self.enlarged($0.cgRect, toAtLeast: minimumFrame) }
            ?? Self.firstFrame(size: defaultFrame, parent: parentFrame, screen: screenFrame ?? window.screen?.visibleFrame)
        window.setFrame(frame, display: false)
        if initialFrame == nil, parentFrame == nil { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    /// A remembered frame grown, from its top-left corner, to the window's minimum — a frame saved
    /// while the window could still open 200 pt tall must not bring that size back.
    static func enlarged(_ frame: CGRect, toAtLeast minimum: CGSize) -> CGRect {
        let width = max(frame.width, minimum.width)
        let height = max(frame.height, minimum.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }

    /// Where a first detach opens: under the project window when the screen has room for it
    /// there, else along the project window's bottom edge — where the docked ledger was — never
    /// centred over the canvas. As wide as the project window, within the screen.
    static func firstFrame(size: CGSize, parent: CGRect?, screen: CGRect?) -> CGRect {
        guard let parent else { return CGRect(origin: .zero, size: size) }
        var width = max(size.width, min(parent.width, 1_400))
        if let screen { width = min(width, screen.width) }
        var x = parent.minX
        if let screen { x = min(max(x, screen.minX), screen.maxX - width) }
        let below = parent.minY - size.height
        if let screen, below >= screen.minY {
            return CGRect(x: x, y: below, width: width, height: size.height)
        }
        let bottom = max(parent.minY, screen?.minY ?? parent.minY)
        return CGRect(x: x, y: bottom, width: width, height: size.height)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        // Built in code only; there is no nib for this window.
        return nil
    }

    /// The window's current frame, for the layout state.
    public var currentFrame: ZPDFWindowFrame? {
        guard let window else { return nil }
        return ZPDFWindowFrame(window.frame)
    }

    /// Closes the window without asking the owner to re-dock, used while re-docking.
    public func dismissForReattach() {
        isDismissingProgrammatically = true
        window?.contentViewController = nil
        close()
        isDismissingProgrammatically = false
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isDismissingProgrammatically else { return }
        onCloseRequested?()
    }
}
