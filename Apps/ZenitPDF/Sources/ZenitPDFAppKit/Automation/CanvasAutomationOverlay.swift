import AppKit
import Foundation
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFSnapEngine
import ZPDFUIPresentation

/// What automation shows on the sheet while it waits for a person to decide: a proposed
/// region, the closing lines it would need, and the places a symbol search looked at.
///
/// Proposals are drawn and never committed from here. The overlay is cleared the moment the
/// person accepts, cancels or moves on.
struct CanvasAutomationOverlay: Equatable {
    /// One closing line across an opening, page space.
    struct Segment: Equatable {
        var start: PDFPointValue
        var end: PDFPointValue
    }

    /// Proposed regions, page space, outer rings.
    var rings: [[PDFPointValue]] = []
    /// Proposed closing lines, drawn dashed so they never read as drawing linework.
    var closures: [Segment] = []
    /// Places to look at: confirmed hits in accent, near misses in warning.
    var hits: [PDFRectValue] = []
    var nearMisses: [PDFRectValue] = []

    var isEmpty: Bool { rings.isEmpty && closures.isEmpty && hits.isEmpty && nearMisses.isEmpty }

    /// The overlay for an opening proposal.
    init(proposal: OpeningProposal) {
        rings = [proposal.region.ring.map { PDFPointValue(x: $0.x, y: $0.y) }]
        closures = proposal.closures.map {
            Segment(start: PDFPointValue(x: $0.start.x, y: $0.start.y), end: PDFPointValue(x: $0.end.x, y: $0.end.y))
        }
    }

    init(rings: [[PDFPointValue]] = [], closures: [Segment] = [], hits: [PDFRectValue] = [], nearMisses: [PDFRectValue] = []) {
        self.rings = rings
        self.closures = closures
        self.hits = hits
        self.nearMisses = nearMisses
    }
}

extension CanvasPageView {

    /// Draws ``automationOverlay`` above the committed ink. Colour is never the only signal:
    /// closures are dashed, near misses are dashed boxes, hits are solid boxes.
    func drawAutomationOverlay(transform: PageDisplayTransform) {
        guard let overlay = automationOverlay, !overlay.isEmpty else { return }
        let accent = CanvasMarkupStyle.onPaper(.accentBlue)
        let warning = CanvasMarkupStyle.onPaper(.warning)

        if !overlay.rings.isEmpty {
            let path = NSBezierPath()
            for ring in overlay.rings where ring.count >= 3 {
                path.move(to: transform.viewPoint(from: ring[0]))
                for point in ring.dropFirst() { path.line(to: transform.viewPoint(from: point)) }
                path.close()
            }
            accent.withAlphaComponent(0.14).setFill()
            path.fill()
            accent.withAlphaComponent(0.7).setStroke()
            path.lineWidth = ZPDFStroke.regular
            path.stroke()
        }

        for closure in overlay.closures {
            let path = NSBezierPath()
            path.move(to: transform.viewPoint(from: closure.start))
            path.line(to: transform.viewPoint(from: closure.end))
            path.lineWidth = ZPDFStroke.regular * 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            accent.setStroke()
            path.stroke()
        }

        func box(_ rect: PDFRectValue, dashed: Bool, color: NSColor) {
            let a = transform.viewPoint(from: PDFPointValue(x: rect.minX, y: rect.minY))
            let b = transform.viewPoint(from: PDFPointValue(x: rect.maxX, y: rect.maxY))
            let frame = CGRect(
                x: min(a.x, b.x) - 3, y: min(a.y, b.y) - 3,
                width: abs(a.x - b.x) + 6, height: abs(a.y - b.y) + 6
            )
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            path.lineWidth = ZPDFStroke.regular
            if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
            color.setStroke()
            path.stroke()
        }
        for rect in overlay.hits { box(rect, dashed: false, color: accent) }
        for rect in overlay.nearMisses { box(rect, dashed: true, color: warning) }
    }
}
