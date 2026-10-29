import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Saved Project Zone and Scale Region outlines and calibration picks on the canvas (U-086).
///
/// Spec 13.2 source 4 makes zone and scale-region boundaries snap geometry, and 13.1 lists the
/// calibration point as a snap type. Until this file the snap index was fed those targets while
/// the canvas drew none of them — the panels' eye toggles flipped `isVisible` on an outline no
/// view stroked — so an old calibration pick or a zone edge could pull the cursor onto blank
/// paper: a candidate from invisible geometry, which `QUALITY_BAR` S16 forbids. The page view now
/// draws exactly ``PageBoundaryMark``s, the list the snap boundary layer is built from
/// (`TakeoffSession+SnapBoundaries.swift`), so a target is always something the person can see.
///
/// The kinds differ in shape and words, not only in colour: a Scale Region is a long dash with a
/// "Scale Region" label, a Project Zone a short dash with a "Zone" label, and a calibration pick
/// a ring with a cross, labelled "Calibration" once.
extension CanvasPageView {

    /// Draws the page's boundary marks and returns the identities it drew, in order.
    func drawBoundaryMarks(transform: PageDisplayTransform) -> [String] {
        guard !boundaryMarks.isEmpty else { return [] }
        var drawn: [String] = []
        drawn.reserveCapacity(boundaryMarks.count)
        for mark in boundaryMarks {
            let points = mark.points.map { transform.viewPoint(from: PDFPointValue(x: $0.x, y: $0.y)) }
            switch mark.kind {
            case .projectZone, .scaleRegion:
                guard points.count >= 3 else { continue }
                drawOutline(mark, points: points)
            case .calibration:
                guard !points.isEmpty else { continue }
                drawCalibrationPicks(points)
            }
            drawn.append(mark.id)
        }
        return drawn
    }

    /// The outline ink: the colour the panel set, never fainter than legible — the outline is a
    /// snap target, and a target drawn at a stored alpha of 0.05 would be one nobody can see.
    static func boundaryInk(_ color: ColorRGBA?) -> NSColor {
        guard let color else { return CanvasMarkupStyle.calibrationInk }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: max(color.alpha, 0.85))
    }

    private func drawOutline(_ mark: PageBoundaryMark, points: [CGPoint]) {
        let ink = Self.boundaryInk(mark.colorRGBA)
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        switch mark.kind {
        case .scaleRegion:
            path.lineWidth = ZPDFStroke.emphasis
            path.setLineDash([10, 4], count: 2, phase: 0)
        default:
            path.lineWidth = ZPDFStroke.emphasis
            path.setLineDash([3, 3], count: 2, phase: 0)
        }
        ink.setStroke()
        path.stroke()

        // The label, at the outline's top-left corner on screen (the view is flipped).
        let kindName = mark.kind == .scaleRegion
            ? NSLocalizedString("Scale Region", comment: "Canvas label on a saved Scale Region outline")
            : NSLocalizedString("Zone", comment: "Canvas label on a saved Project Zone outline")
        let name = mark.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = name.isEmpty ? kindName : String(
            format: NSLocalizedString("%1$@: %2$@", comment: "Canvas label on a saved outline: the kind (Scale Region or Zone), then its name"),
            kindName, name
        )
        let corner = points.min { ($0.y, $0.x) < ($1.y, $1.x) } ?? points[0]
        drawBoundaryLabel(text, ink: ink, at: CGPoint(x: corner.x + 4, y: corner.y - 4))
    }

    private func drawCalibrationPicks(_ points: [CGPoint]) {
        let ink = CanvasMarkupStyle.calibrationInk
        let radius: CGFloat = 4.5, arm: CGFloat = 7
        let path = NSBezierPath()
        for point in points {
            path.appendOval(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            path.move(to: CGPoint(x: point.x - arm, y: point.y))
            path.line(to: CGPoint(x: point.x + arm, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - arm))
            path.line(to: CGPoint(x: point.x, y: point.y + arm))
        }
        path.lineWidth = ZPDFStroke.regular
        ink.setStroke()
        path.stroke()
        if let first = points.first {
            drawBoundaryLabel(
                NSLocalizedString("Calibration", comment: "Canvas label beside the points a scale was calibrated from"),
                ink: ink, at: CGPoint(x: first.x + arm + 2, y: first.y - arm)
            )
        }
    }

    /// A small pill whose bottom-left corner is `origin`: the fence label's grammar.
    private func drawBoundaryLabel(_ text: String, ink: NSColor, at origin: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: ZPDFColor.nsColor(.textPrimary)
        ]
        let label = text as NSString
        let size = label.size(withAttributes: attributes)
        let box = CGRect(x: origin.x, y: origin.y - size.height - 2, width: size.width + 6, height: size.height + 2)
        let pill = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        ZPDFColor.nsColor(.elevated).withAlphaComponent(0.92).setFill()
        pill.fill()
        ink.setStroke()
        pill.lineWidth = ZPDFStroke.hairline
        pill.stroke()
        label.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attributes)
    }
}
