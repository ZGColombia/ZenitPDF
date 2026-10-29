import AppKit
import ZPDFDesignSystem
import ZPDFUIPresentation

/// NL-UX-09 (r2-layers): hovering a Quantity Ledger row outlines its markup on the sheet, so a row
/// and the drawing it came from can be matched without a click. Drawn on the live overlay only —
/// the page and its raster are never repainted for it.
extension CanvasPageView {

    /// A solid emphasis outline and a faint wash round the hovered row's markup — shape, not colour
    /// alone — distinct from the Select tool's dashed hover.
    func drawLedgerHover(transform: PageDisplayTransform) {
        guard let id = ledgerHoverMarkupID, let shape = shapes.first(where: { $0.id == id }) else { return }
        let box = shape.drawnBox   // framed as drawn, turned or not (T-002)
        let rect = transform.viewRect(from: box).insetBy(dx: -5, dy: -5)
        let path = NSBezierPath(roundedRect: rect, xRadius: ZPDFRadius.small, yRadius: ZPDFRadius.small)
        CanvasMarkupStyle.selectionInk.withAlphaComponent(0.08).setFill()
        path.fill()
        path.lineWidth = ZPDFStroke.emphasis
        CanvasMarkupStyle.selectionInk.setStroke()
        path.stroke()
    }

    /// Whether the ledger hover outline is showing, for tests.
    var ledgerHoverIsDrawnForTesting: Bool {
        guard let id = ledgerHoverMarkupID else { return false }
        return shapes.contains { $0.id == id }
    }
}

extension PDFCanvasViewController {

    /// Outlines the markup whose ledger row the pointer is over, or clears the outline (NL-UX-09).
    func showLedgerHover(_ markupID: UUID?) {
        pageView.ledgerHoverMarkupID = markupID
    }
}
