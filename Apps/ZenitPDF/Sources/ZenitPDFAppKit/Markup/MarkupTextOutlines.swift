import AppKit
import CoreText
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation

/// A markup's words as filled outlines in page space, for exports of a **turned** text box
/// (NL-MARKUP-18, r2-markup).
///
/// The renderer draws text labels screen-upright by design (`RenderTextLabel`), which is right
/// for a caption pill and wrong for a text box a person turned 30°. So a turned box's words go
/// out as glyph outlines — one polygon per glyph, its counters as holes, filled even-odd — turned
/// about the same centre the canvas turns them about. Bold, italic and the family come from the
/// same font the canvas draws with.
enum MarkupTextOutlines {

    /// The glyph polygons for `text`, set from the top-left of `box` in lines of 1.2 × size,
    /// turned `degrees` counter-clockwise about `centre`. Curves are sampled at 8 steps.
    static func polygons(
        text: String,
        box: PDFRectValue,
        fontName: String?,
        fontSize: Double,
        bold: Bool,
        italic: Bool,
        degrees: Double,
        centre: PDFPointValue
    ) -> [RenderPolygon] {
        guard fontSize.isFinite, fontSize > 0 else { return [] }
        let font = CanvasMarkupFont.font(named: fontName, size: CGFloat(fontSize), weight: .regular, bold: bold, italic: italic)
        var result: [RenderPolygon] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let attributed = NSAttributedString(string: String(line), attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            // Baseline of line n, measured down from the box top (page space is y-up).
            let baseline = box.maxY - fontSize * (Double(index) + 0.9) * 1.2
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for (glyph, position) in zip(glyphs, positions) {
                    guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                    let contours = Self.contours(of: path).map { contour in
                        contour.map { point -> PDFPoint in
                            let placed = PDFPointValue(
                                x: box.minX + 2 + Double(position.x) + Double(point.x),
                                y: baseline + Double(point.y)
                            )
                            let turned = CanvasSceneBuilder.turn(placed, about: centre, degrees: degrees)
                            return PDFPoint(x: turned.x, y: turned.y)
                        }
                    }.filter { $0.count >= 3 }
                    guard let outer = contours.first else { continue }
                    result.append(RenderPolygon(outer: outer, holes: Array(contours.dropFirst())))
                }
            }
        }
        return result
    }

    /// A path's closed subpaths as point lists, curves sampled.
    static func contours(of path: CGPath) -> [[CGPoint]] {
        var contours: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            let last = current.last ?? .zero
            switch e.type {
            case .moveToPoint:
                if current.count >= 3 { contours.append(current) }
                current = [e.points[0]]
            case .addLineToPoint:
                current.append(e.points[0])
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let u = 1 - t
                    current.append(CGPoint(
                        x: u * u * last.x + 2 * u * t * c.x + t * t * end.x,
                        y: u * u * last.y + 2 * u * t * c.y + t * t * end.y
                    ))
                }
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let u = 1 - t
                    current.append(CGPoint(
                        x: u * u * u * last.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                        y: u * u * u * last.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                    ))
                }
            case .closeSubpath:
                if current.count >= 3 { contours.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count >= 3 { contours.append(current) }
        return contours
    }
}
