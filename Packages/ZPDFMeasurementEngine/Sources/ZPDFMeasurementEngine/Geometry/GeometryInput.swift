import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Reads the pieces a tool needs out of a ``MeasurementGeometry``.
///
/// ``MeasurementGeometry`` is a bag of parallel collections rather than an enum, so every tool
/// has to state which collections it consumes and in what order of preference. Putting that in
/// one place keeps "Length also measures the arcs you drew" from being decided twice.
enum GeometryInput {

    // MARK: - Linear input

    /// The open polyline a length-like tool measures: free points first, then independent
    /// segments, then arcs. Returns the chain of vertices and the loose segments separately,
    /// because a chain of `n` points has `n - 1` edges while `n` loose segments have `n`.
    struct Linear: Sendable {
        var polyline: [PDFPoint]
        var isClosed: Bool
        var segments: [SegmentGeometry]
        var arcs: [ArcGeometry]
        /// Arc segments of the chain (ADR-0030 §5): one bulge per polyline vertex, `nil` when
        /// every chain edge is straight.
        var polylineBulges: [Double]? = nil

        var isEmpty: Bool { polyline.count < 2 && segments.isEmpty && arcs.isEmpty }

        /// The chain's edges in order, each with its bulge (`0` straight).
        private var chainEdges: [(SegmentGeometry, Double)] {
            guard polyline.count >= 2 else { return [] }
            let upper = isClosed ? polyline.count : polyline.count - 1
            let bulges = polylineBulges.flatMap { $0.count == polyline.count ? $0 : nil }
            return (0..<upper).map { index in
                (SegmentGeometry(start: polyline[index], end: polyline[(index + 1) % polyline.count]), bulges?[index] ?? 0)
            }
        }

        /// One piece of the run: a straight edge, or an arc whose length is exact (QUALITY_BAR
        /// §2.2 rule 4), never its flattened chords.
        enum Piece: Sendable {
            case edge(SegmentGeometry)
            case arc(ArcGeometry)
        }

        /// Every piece of the run in the order it appears: the chain's edges in drawn order,
        /// each bulged edge as its arc where it is drawn, then the loose segments, then the
        /// loose arcs. This is the order "one rise/drop per segment, in the order the segments
        /// appear" (SlopeSpecification) pairs rises with. It used to be two lists, straight
        /// edges and then arcs, so a rise meant for an arc in the middle of a chain landed on
        /// the straight edge after it (S-110).
        var pieces: [Piece] {
            chainEdges.map { edge, bulge -> Piece in
                if bulge != 0, let arc = BulgeArc.arc(from: edge.start, to: edge.end, bulge: bulge) {
                    return .arc(arc)
                }
                return .edge(edge)
            } + segments.map(Piece.edge) + arcs.map(Piece.arc)
        }
    }

    static func linear(_ geometry: MeasurementGeometry) -> Linear {
        Linear(
            polyline: geometry.points,
            isClosed: false,
            segments: geometry.segments,
            arcs: geometry.arcs,
            polylineBulges: geometry.validPointBulges
        )
    }

    // MARK: - Areal input

    /// The polygons an area-like tool measures, plus whether they were assembled implicitly.
    struct Areal: Sendable {
        var polygons: [PolygonGeometry]
        /// True when a bare point list was closed into a ring to make an area at all.
        var closedImplicitly: Bool
    }

    static func areal(_ geometry: MeasurementGeometry) -> Areal {
        if !geometry.polygons.isEmpty {
            return Areal(polygons: geometry.polygons, closedImplicitly: false)
        }
        guard geometry.points.count >= 3 else {
            return Areal(polygons: [], closedImplicitly: false)
        }
        let ring = PolygonRing(points: geometry.points, isClosed: true)
        return Areal(polygons: [PolygonGeometry(outer: ring)], closedImplicitly: true)
    }

    // MARK: - Circular input

    /// A circle from the circle list, from a centre-and-rim point pair, or from a diameter pair.
    enum CircleInterpretation: Sendable {
        /// Two points are centre and a point on the rim.
        case centreAndRim
        /// Two points are opposite ends of a diameter.
        case diameterEndpoints
    }

    static func circle(
        _ geometry: MeasurementGeometry,
        interpretation: CircleInterpretation
    ) -> CircleGeometry? {
        if let circle = geometry.circles.first { return circle }
        let points: [PDFPoint]
        if geometry.points.count >= 2 {
            points = Array(geometry.points.prefix(2))
        } else if let segment = geometry.segments.first {
            points = [segment.start, segment.end]
        } else {
            return nil
        }
        switch interpretation {
        case .centreAndRim:
            return CircleGeometry(center: points[0], radius: points[0].distance(to: points[1]))
        case .diameterEndpoints:
            let centre = PDFPoint(
                x: (points[0].x + points[1].x) / 2,
                y: (points[0].y + points[1].y) / 2
            )
            return CircleGeometry(center: centre, radius: points[0].distance(to: points[1]) / 2)
        }
    }

    /// The rectangle a Rectangle Area tool is drawn as, as an explicit four-vertex ring in page
    /// space. Two points are read as opposite corners; four or more are read as the ring the
    /// user actually drew, so a rotated rectangle stays rotated.
    static func rectangleRing(_ geometry: MeasurementGeometry) -> [PDFPoint]? {
        if let polygon = geometry.polygons.first, polygon.outer.uniquePoints.count >= 3 {
            return polygon.outer.uniquePoints
        }
        if geometry.points.count >= 4 { return geometry.points }
        let corners: (PDFPoint, PDFPoint)?
        if geometry.points.count == 2 {
            corners = (geometry.points[0], geometry.points[1])
        } else if let segment = geometry.segments.first {
            corners = (segment.start, segment.end)
        } else {
            corners = nil
        }
        guard let (first, second) = corners else { return nil }
        return [
            PDFPoint(x: first.x, y: first.y),
            PDFPoint(x: second.x, y: first.y),
            PDFPoint(x: second.x, y: second.y),
            PDFPoint(x: first.x, y: second.y)
        ]
    }
}
