import AppKit
import Foundation
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The double-count guard's hatch (NL-MEASURE-13): where two areas of one subject cover the same
/// ground, the shared region is hatched and labelled "Counted twice" on the sheet. Hatch and words
/// together, never colour alone; the warning tray names both areas and the shared amount.
extension CanvasPageView {

    /// Page-space distance between hatch lines, in view points (constant on screen at any zoom).
    static let doubleCountHatchSpacing: CGFloat = 6

    /// The text drawn in each hatched region.
    static var doubleCountHatchLabel: String {
        NSLocalizedString("Counted twice", comment: "Canvas label on a region two same-subject areas both cover")
    }

    func drawDoubleCountHatch(transform: PageDisplayTransform) {
        let rings = doubleCountHatch.filter { $0.count >= 3 }
        guard !rings.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        for ring in rings {
            path.move(to: transform.viewPoint(from: ring[0]))
            for point in ring.dropFirst() { path.line(to: transform.viewPoint(from: point)) }
            path.close()
        }
        let colour = CanvasMarkupStyle.onPaper(.warning)
        context.saveGState()
        path.addClip()
        let bounds = path.bounds
        let hatch = NSBezierPath()
        let spacing = Self.doubleCountHatchSpacing
        var offset = -bounds.height
        while offset < bounds.width {
            hatch.move(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
            hatch.line(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
            offset += spacing
        }
        hatch.lineWidth = 1
        colour.withAlphaComponent(0.75).setStroke()
        hatch.stroke()
        context.restoreGState()
        colour.setStroke()
        path.lineWidth = ZPDFStroke.regular
        path.stroke()

        // One label per region, at its box centre, only where it fits.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: ZPDFColor.nsColor(.textPrimary)
        ]
        let text = Self.doubleCountHatchLabel as NSString
        let size = text.size(withAttributes: attributes)
        let boxes = rings.map { ring -> CGRect in
            let xs = ring.map(\.x), ys = ring.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        for (index, ring) in rings.enumerated() {
            // A hole's ring sits inside its outer ring's box: the outer ring carries the label.
            let isHole = boxes.indices.contains { $0 != index && boxes[$0].contains(boxes[index]) && boxes[$0] != boxes[index] }
            guard !isHole else { continue }
            let points = ring.map { transform.viewPoint(from: $0) }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { continue }
            let box = CGRect(x: (minX + maxX) / 2 - size.width / 2 - 4, y: (minY + maxY) / 2 - size.height / 2 - 2,
                             width: size.width + 8, height: size.height + 4)
            let pill = NSBezierPath(roundedRect: box, xRadius: CanvasMarkupStyle.pillCornerRadius, yRadius: CanvasMarkupStyle.pillCornerRadius)
            ZPDFColor.nsColor(.elevated).withAlphaComponent(0.94).setFill()
            pill.fill()
            colour.setStroke()
            pill.lineWidth = 1
            pill.stroke()
            text.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attributes)
        }
    }
}

extension PDFCanvasViewController {

    /// The rings the hatch fills: every overlap's outer ring and its holes, even-odd.
    static func doubleCountHatch(_ regions: [PolygonGeometry]) -> [[PDFPointValue]] {
        regions.flatMap { polygon in
            ([polygon.outer] + polygon.holes).map { ring in
                ring.uniquePoints.map { PDFPointValue(x: $0.x, y: $0.y) }
            }
        }
    }
}
