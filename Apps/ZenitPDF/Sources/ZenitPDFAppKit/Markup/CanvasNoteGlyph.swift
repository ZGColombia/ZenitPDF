import AppKit
import ZPDFDesignSystem

/// The sticky-note mark (NL-MARKUP-17): a page with a folded corner and three ruled lines,
/// drawn inside the note's frame in the markup's ink. Zenit's own glyph, drawn from geometry.
enum CanvasNoteGlyph {

    /// Draws the glyph inside the quadrilateral `corners` (view space, the note's four corners).
    @MainActor
    static func draw(corners: [CGPoint], ink: NSColor) {
        guard corners.count >= 4 else { return }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: 2, dy: 2)
        guard rect.width > 4, rect.height > 4 else { return }
        let fold = min(rect.width, rect.height) * 0.3
        // The view is flipped (y down): the fold sits at the top-right corner on screen.
        let page = NSBezierPath()
        page.move(to: CGPoint(x: rect.minX, y: rect.minY))
        page.line(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        page.line(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        page.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        page.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        page.close()
        CanvasMarkupStyle.paper.setFill()
        page.fill()
        ink.setStroke()
        page.lineWidth = 1
        page.stroke()
        let corner = NSBezierPath()
        corner.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        corner.line(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        corner.line(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        corner.lineWidth = 1
        corner.stroke()
        let lines = NSBezierPath()
        for step in 1...3 {
            let y = rect.minY + fold + (rect.height - fold) * CGFloat(step) / 4.5
            lines.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: y))
            lines.line(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: y))
        }
        lines.lineWidth = 0.8
        lines.stroke()
    }
}
