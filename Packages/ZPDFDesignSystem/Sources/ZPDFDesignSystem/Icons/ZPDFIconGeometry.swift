import CoreGraphics
import SwiftUI

/// Original vector geometry for the Zenit measurement glyphs.
///
/// All construction happens in a 24x24 design box with a top-left origin, matching SwiftUI's
/// coordinate space. `path(for:in:)` fits that box into any rect, so one definition serves the
/// SwiftUI `Shape`, the rendered `NSImage`, and any future PDF stamp.
public enum ZPDFIconGeometry {

    /// The edge length of the design box every glyph is authored in.
    public static let designSize: CGFloat = 24

    /// The glyph, scaled and centred inside `rect`.
    public static func path(for kind: ZPDFIconKind, in rect: CGRect) -> Path {
        let base = designPath(for: kind)
        let scale = min(rect.width, rect.height) / designSize
        guard scale > 0 else { return Path() }
        let transform = CGAffineTransform(
            translationX: rect.midX - designSize * scale / 2,
            y: rect.midY - designSize * scale / 2
        )
        .scaledBy(x: scale, y: scale)
        return base.applying(transform)
    }

    /// The stroke width that keeps a glyph's weight constant as it is scaled.
    public static func strokeWidth(for size: CGFloat) -> CGFloat {
        max(ZPDFStroke.icon * size / designSize, 0.75)
    }

    /// The glyph in its native 24x24 design box.
    public static func designPath(for kind: ZPDFIconKind) -> Path {
        var p = Path()
        switch kind {
        case .length:
            // A measured segment: the run plus a perpendicular witness tick at each end.
            line(&p, 5, 19, 19, 5)
            line(&p, 2.98, 16.98, 7.02, 21.02)
            line(&p, 16.98, 2.98, 21.02, 7.02)

        case .polylength:
            // Chained segments with a vertex node on every turn.
            polyline(&p, [(3, 18), (9, 9), (14, 14), (21, 5)])
            for v in [(3.0, 18.0), (9.0, 9.0), (14.0, 14.0), (21.0, 5.0)] {
                node(&p, v.0, v.1, 2.6)
            }

        case .perimeter:
            // A closed outline, nodes on the corners, nothing filling the inside.
            closedPolygon(&p, [(4, 8), (12, 3), (20, 8), (20, 18), (8, 21)])
            for v in [(4.0, 8.0), (12.0, 3.0), (20.0, 18.0)] {
                node(&p, v.0, v.1, 2.6)
            }

        case .area:
            // A free-form region, hatched to read as filled surface rather than outline.
            closedPolygon(&p, [(3, 9), (9, 4), (20, 7), (18, 19), (6, 20)])
            line(&p, 5.0, 15.5, 10.5, 6.4)
            line(&p, 9.0, 18.9, 16.6, 6.2)
            line(&p, 14.0, 19.2, 18.6, 11.6)

        case .rectangleArea:
            // A hatched rectangle carrying a dimension line, so it reads as a measured
            // rectangular region rather than as a table.
            rect(&p, 4, 3, 16, 12)
            line(&p, 5.5, 14.0, 14.5, 3.8)
            line(&p, 11.0, 14.4, 19.5, 4.6)
            line(&p, 4, 19, 20, 19)
            line(&p, 4, 16.8, 4, 21.2)
            line(&p, 20, 16.8, 20, 21.2)

        case .ellipseArea:
            // An elliptical region with horizontal hatching.
            p.addEllipse(in: CGRect(x: 3, y: 6, width: 18, height: 12))
            line(&p, 7.2, 9, 16.8, 9)
            line(&p, 4.2, 12, 19.8, 12)
            line(&p, 7.2, 15, 16.8, 15)

        case .cutout:
            // A parent region with an inner region struck out of it.
            rect(&p, 3, 5, 18, 14)
            rect(&p, 8, 9, 8, 6)
            line(&p, 8, 15, 16, 9)

        case .volume:
            // An extruded solid: hexagon silhouette with the three visible interior edges.
            closedPolygon(&p, [(12, 2), (20.66, 7), (20.66, 17), (12, 22), (3.34, 17), (3.34, 7)])
            line(&p, 12, 12, 12, 2)
            line(&p, 12, 12, 20.66, 17)
            line(&p, 12, 12, 3.34, 17)

        case .wallArea:
            // A wall face seen at an angle, with its height dimension called out.
            closedPolygon(&p, [(4, 7), (16, 4), (16, 18), (4, 21)])
            line(&p, 19, 5, 19, 19)
            polyline(&p, [(17.5, 6.6), (19, 5), (20.5, 6.6)])
            polyline(&p, [(17.5, 17.4), (19, 19), (20.5, 17.4)])

        case .count:
            // A scatter of tally markers.
            for c in [(6.0, 7.0), (12.0, 5.5), (18.0, 9.0), (7.0, 15.0), (14.0, 17.5), (20.0, 16.0)] {
                p.addEllipse(in: CGRect(x: c.0 - 1.5, y: c.1 - 1.5, width: 3.0, height: 3.0))
            }

        case .slope:
            // Rise over run, with the right angle marked so it cannot be read as a plain triangle.
            closedPolygon(&p, [(4, 20), (20, 20), (20, 6)])
            polyline(&p, [(16.6, 20), (16.6, 16.6), (20, 16.6)])

        case .radius:
            // Centre out to the edge.
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            line(&p, 12, 12, 18.01, 5.99)
            node(&p, 12, 12, 2.2)

        case .diameter:
            // Edge to edge through the centre, with a witness tick at each end.
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            line(&p, 3.5, 12, 20.5, 12)
            line(&p, 3.5, 9, 3.5, 15)
            line(&p, 20.5, 9, 20.5, 15)

        case .angle:
            // Two rays from a vertex with the swept angle drawn between them.
            line(&p, 4, 20, 21, 20)
            line(&p, 4, 20, 17, 5)
            p.move(to: CGPoint(x: 12, y: 20))
            p.addQuadCurve(to: CGPoint(x: 9.24, y: 13.95), control: CGPoint(x: 12.0, y: 16.34))

        case .arc:
            // A curved run with its chord, endpoints and midpoint called out.
            p.move(to: CGPoint(x: 4, y: 18))
            p.addQuadCurve(to: CGPoint(x: 20, y: 18), control: CGPoint(x: 12, y: 2))
            line(&p, 4, 18, 20, 18)
            node(&p, 4, 18, 2.4)
            node(&p, 20, 18, 2.4)
            node(&p, 12, 10, 2.0)

        case .calibrate:
            // A known distance being confirmed.
            line(&p, 3, 15, 21, 15)
            line(&p, 3, 11, 3, 19)
            line(&p, 21, 11, 21, 19)
            line(&p, 9, 12.5, 9, 15)
            line(&p, 15, 12.5, 15, 15)
            polyline(&p, [(8.5, 6.6), (11.2, 9.3), (16, 3.6)])

        case .vectorSnap:
            // Two page edges meeting, with the vertex captured.
            line(&p, 3, 19, 12, 7)
            line(&p, 12, 7, 21, 13)
            rect(&p, 9.4, 4.4, 5.2, 5.2)

        case .gridSnap:
            // A grid with the nearest intersection captured.
            for c in [(5.0, 5.0), (12.0, 5.0), (19.0, 5.0), (5.0, 12.0), (19.0, 12.0), (5.0, 19.0), (12.0, 19.0), (19.0, 19.0)] {
                p.addEllipse(in: CGRect(x: c.0 - 1.1, y: c.1 - 1.1, width: 2.2, height: 2.2))
            }
            line(&p, 12, 8.2, 12, 15.8)
            line(&p, 8.2, 12, 15.8, 12)
            p.addEllipse(in: CGRect(x: 9.4, y: 9.4, width: 5.2, height: 5.2))

        case .markupSnap:
            // Existing markup with one of its own vertices captured.
            polyline(&p, [(4, 16), (10, 9), (14.5, 13), (19, 7)])
            node(&p, 10, 9, 2.4)
            p.addEllipse(in: CGRect(x: 15.8, y: 3.8, width: 6.4, height: 6.4))
        }
        return p
    }

    // MARK: - Construction helpers

    private static func line(_ p: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
    }

    private static func polyline(_ p: inout Path, _ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        p.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() {
            p.addLine(to: CGPoint(x: point.0, y: point.1))
        }
    }

    private static func closedPolygon(_ p: inout Path, _ points: [(CGFloat, CGFloat)]) {
        polyline(&p, points)
        p.closeSubpath()
    }

    private static func rect(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        p.addRect(CGRect(x: x, y: y, width: w, height: h))
    }

    /// A small square vertex marker centred on a point.
    private static func node(_ p: inout Path, _ x: CGFloat, _ y: CGFloat, _ side: CGFloat) {
        p.addRect(CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
    }
}

/// A Zenit measurement glyph as a SwiftUI `Shape`.
///
/// The path is authored to be stroked, not filled — use `.stroke(style:)` or the ready-made
/// `ZPDFIconView`, which applies the correct weight, caps and joins for the rendered size.
public struct ZPDFIconShape: Shape, Sendable {
    public let kind: ZPDFIconKind

    public init(_ kind: ZPDFIconKind) {
        self.kind = kind
    }

    public func path(in rect: CGRect) -> Path {
        ZPDFIconGeometry.path(for: kind, in: rect)
    }
}
