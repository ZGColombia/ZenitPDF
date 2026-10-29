import AppKit
import ZPDFDesignSystem

// The Quantity Ledger table's look, in the dark navy chrome of the 2026-09-23 main-window
// mockup: rows on the panel surface with a faint hairline under each, a selection drawn as a
// rounded accent fill rather than the system's saturated bar, group headings on a raised band,
// and a header row in the chrome's secondary text over a crisp one-pixel rule.
//
// Every colour is a ZPDFDesignSystem token resolved at draw time, so the table follows light
// appearance and Increase Contrast without being rebuilt.

/// One row of the ledger table or outline.
public final class LedgerTableRowView: NSTableRowView {

    /// Whether this row is a group heading (the outline's collapsible subtotal rows).
    public var isGroupHeading = false {
        didSet { if isGroupHeading != oldValue { needsDisplay = true } }
    }

    /// Selection inset from the row's edges, so the rounded fill reads as a pill rather than
    /// a bar that runs into the scroller.
    static let selectionInset = NSSize(width: 4, height: 1)

    public nonisolated override var isOpaque: Bool { false }

    public override func drawBackground(in dirtyRect: NSRect) {
        if isGroupHeading {
            ZPDFColor.nsColor(.elevated).setFill()
            bounds.fill(using: .sourceOver)
        }
        // A one-device-pixel rule under every row: the grid the table itself does not draw
        // (its grid style mask is empty so the pinned and scrolling halves never misalign).
        let scale = window?.backingScaleFactor ?? 2
        let rule = NSRect(x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale)
        LedgerTableRowView.fill(rule, token: .border, opacity: isGroupHeading ? 1 : 0.5)
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: Self.selectionInset.width, dy: Self.selectionInset.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: ZPDFRadius.medium, yRadius: ZPDFRadius.medium)
        // The selected fill — the same one a selected tab or card uses — which keeps the
        // primary text readable on it in both appearances (the opaque accent would not in
        // light). Emphasised (the table has focus) at full strength; otherwise quieter, so
        // the selection stays visible while the canvas has the keyboard.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(isEmphasized ? 1 : 0.6)
        ZPDFColor.nsColor(.selectedFill).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fills a rect with a token at a fraction of the token's own opacity. Multiplies rather
    /// than replaces the alpha, so a token that is itself translucent stays translucent.
    static func fill(_ rect: NSRect, token: ZPDFColorToken, opacity: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        ZPDFColor.nsColor(token).setFill()
        rect.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Text on a selected row stays the primary reading colour: the selection is the
    /// selected fill, not the system's saturated bar that needs white text.
    public override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// The ledger's column header cell: chrome ground, secondary text, a one-pixel rule under it
/// and a hairline between columns.
public final class LedgerTableHeaderCell: NSTableHeaderCell {

    public override init(textCell string: String) {
        super.init(textCell: string)
        font = ZPDFTypography.nsFont(.sectionHeader)
        textColor = ZPDFColor.nsColor(.textSecondary)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        font = ZPDFTypography.nsFont(.sectionHeader)
        textColor = ZPDFColor.nsColor(.textSecondary)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        LedgerTableHeaderView.fillGround(cellFrame)
        let scale = controlView.window?.backingScaleFactor ?? 2
        // Column separator, inset top and bottom like the mockup's control-group dividers.
        LedgerTableRowView.fill(NSRect(
            x: cellFrame.maxX - 1 / scale,
            y: cellFrame.minY + 5,
            width: 1 / scale,
            height: max(0, cellFrame.height - 10)
        ), token: .border, opacity: 0.7)
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // The token colours are dynamic, but a cell caches what it was handed: re-apply them
        // at draw time so an appearance flip repaints the header in the new ground's text.
        font = ZPDFTypography.nsFont(.sectionHeader)
        textColor = ZPDFColor.nsColor(.textSecondary)
        // Super draws the title and the sort indicator; the inset keeps the title off the
        // column separator like the cells under it.
        super.drawInterior(withFrame: cellFrame.insetBy(dx: ZPDFSpacing.xs, dy: 0), in: controlView)
    }
}

/// The header strip behind the cells: fills the area past the last column in the same
/// ground, so the header reads as one band, and draws the rule under it.
public final class LedgerTableHeaderView: NSTableHeaderView {

    public override func draw(_ dirtyRect: NSRect) {
        Self.fillGround(bounds)
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? 2
        LedgerTableRowView.fill(
            NSRect(x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale),
            token: .border, opacity: 1
        )
    }

    /// The header ground: the panel surface, one step under the chrome.
    static func fillGround(_ rect: NSRect) {
        ZPDFColor.nsColor(.surface).setFill()
        rect.fill(using: .sourceOver)
    }
}
