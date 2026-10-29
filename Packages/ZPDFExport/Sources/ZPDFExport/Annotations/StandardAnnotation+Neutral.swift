import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFPDFKitBridge

extension StandardAnnotation {

    /// The same markup for the PDFKit writer — the fallback for a drawing the incremental writer
    /// refuses (an encrypted one), which PDFKit can rewrite once it is unlocked.
    ///
    /// Still one annotation per markup, with its name, ownership, author, subject, dates and
    /// translucent colours. What PDFKit cannot carry is lost and the caller says so: `/CA`, the
    /// review-state reply, the appearance stream (PDFKit draws its own from the keys), and a
    /// stamp's or count's artwork — those become a plain outline of their extent rather than
    /// PDFKit's default stamp, which would print a word nobody wrote.
    public func neutralAnnotation(pageIndex: Int) -> NeutralAnnotation {
        func cg(_ point: PDFPoint) -> CGPoint { CGPoint(x: point.x, y: point.y) }
        func colour(_ value: RGBAColor?) -> AnnotationColor? {
            value.map {
                let c = $0.clampedToUnitRange()
                let opacity = opacity.isFinite ? Swift.min(1, Swift.max(0, opacity)) : 1
                return AnnotationColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha * opacity)
            }
        }
        let rect = StandardAnnotationWriter.pageRect(of: self) ?? .zero
        var neutral = NeutralAnnotation(
            pageIndex: pageIndex,
            kind: .stamp,
            bounds: rect,
            contents: contents,
            subject: subject,
            author: author,
            color: colour(stroke),
            interiorColor: nil,
            borderWidth: lineWidth.isFinite ? lineWidth : 1,
            modificationDate: modificationDate,
            creationDate: creationDate,
            name: name,
            isZenitOwned: true
        )
        switch geometry {
        case let .polygon(points):
            neutral.kind = .polygon
            neutral.points = points.map(cg)
            neutral.interiorColor = colour(fill)
        case let .polyLine(points):
            neutral.kind = .polyLine
            neutral.points = points.map(cg)
        case let .line(start, end):
            // A two-vertex PolyLine: the bridge reads a Line's end points relative to its bounds
            // and displaced them (BH-381); `/Vertices` are page space by definition.
            neutral.kind = .polyLine
            neutral.points = [cg(start), cg(end)]
        case let .ink(paths):
            neutral.kind = .ink
            neutral.inkPaths = paths.map { $0.map(cg) }
        case let .square(shape):
            neutral.kind = .square
            neutral.bounds = CGRect(x: shape.minX, y: shape.minY, width: shape.width, height: shape.height)
            neutral.interiorColor = colour(fill)
        case let .circle(shape):
            neutral.kind = .circle
            neutral.bounds = CGRect(x: shape.minX, y: shape.minY, width: shape.width, height: shape.height)
            neutral.interiorColor = colour(fill)
        case let .freeText(box, _):
            neutral.kind = .freeText
            neutral.bounds = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        case let .note(point):
            neutral.kind = .text
            neutral.bounds = CGRect(x: point.x, y: point.y - 20, width: 20, height: 20)
        case .stamp:
            neutral.kind = .square
        case let .link(box, uri):
            neutral.kind = .link
            neutral.bounds = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
            neutral.action = .uri(uri)
        case let .pageLink(box, target):
            neutral.kind = .link
            neutral.bounds = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
            neutral.action = .goToPage(pageIndex: target)
        case let .textMarkup(kind, rects):
            switch kind {
            case .highlight: neutral.kind = .highlight
            case .underline: neutral.kind = .underline
            case .strikeOut: neutral.kind = .strikeOut
            }
            neutral.quadPoints = rects.flatMap {
                [CGPoint(x: $0.minX, y: $0.maxY), CGPoint(x: $0.maxX, y: $0.maxY),
                 CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.minY)]
            }
        }
        return neutral
    }
}
