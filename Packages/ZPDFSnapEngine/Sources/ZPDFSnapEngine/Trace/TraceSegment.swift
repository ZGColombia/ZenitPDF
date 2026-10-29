import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFVectorExtraction

/// One straight piece of drawn linework, as the tracer sees it.
///
/// The tracer works on segments only. Curves reach it through
/// ``ZPDFVectorExtraction/VectorFlattener``, which is the same convenience the snap index uses
/// for hit testing: the stored `VectorCubic` is never replaced, a throwaway polyline stands in
/// for it while the arrangement is built, and its error is bounded by
/// ``TraceOptions/curveFlatness``.
struct TraceSegment: Sendable, Hashable {
    let start: PDFPoint
    let end: PDFPoint
    /// Identifier of the primitive this piece came from, kept only so the ordering of segments
    /// is a function of the input rather than of the order a dictionary handed them back.
    let sourceID: UInt64
    /// Position of this piece inside its primitive.
    let pieceIndex: Int

    var minX: Double { Swift.min(start.x, end.x) }
    var maxX: Double { Swift.max(start.x, end.x) }
    var minY: Double { Swift.min(start.y, end.y) }
    var maxY: Double { Swift.max(start.y, end.y) }

    var bounds: PDFRect { PDFRect(corner: start, opposite: end) }
    var length: Double { start.distance(to: end) }
}

/// Turns the page's primitives into the segment soup the arrangement is built from.
enum TraceSegmentCollector {

    enum Outcome {
        case collected([TraceSegment])
        /// A cap in ``TraceOptions`` was passed. `count` is the measured quantity.
        case overflow(count: Int)
    }

    /// - Note: no primitive is filtered on paint role, layer or confidence. The tracer follows
    ///   what is on the page; deciding that a dashed line or a fill boundary is not a wall is a
    ///   judgement this engine is not entitled to make, and a boundary silently dropped here
    ///   would come back as a bridged gap somewhere else.
    static func collect(
        primitives: [VectorPrimitive],
        options: TraceOptions
    ) -> Outcome {
        guard primitives.count <= options.maximumPrimitives else {
            return .overflow(count: primitives.count)
        }

        let flattener = VectorFlattener(flatness: options.curveFlatness)
        var segments: [TraceSegment] = []
        segments.reserveCapacity(Swift.min(primitives.count * 2, options.maximumSegments))

        // Two endpoints closer than this are the same point, so the piece between them is not a
        // segment at all. A tenth of the join tolerance: anything the arrangement would merge
        // into one node anyway.
        let degenerate = options.joinTolerance * 0.1

        // The extractor emits a closed subpath twice: as a parent `.rectangle` or `.ring`, and
        // as its child segments with `parentID` set. Both describe the same outline, and
        // collecting both put every edge of every rectangle into the arrangement twice as a
        // coincident pair (IM-010). A parent that has children is skipped; a shape that arrived
        // on its own — a synthetic fixture, or a producer that emits no children — is kept.
        // Only ever asked `contains`, so `Set` order cannot reach the segment order.
        var parents = Set<UInt64>()
        for primitive in primitives {
            if let parent = primitive.parentID { parents.insert(parent) }
        }

        for primitive in primitives {
            // A ring that contains curves records its on-curve vertices only; the polygon
            // through them is chords, not outline, and tracing it made a Bézier circle its
            // inscribed square — area 2r² for πr² (CR-36). The outline is the ring's child
            // cubics and lines, which are primitives of their own and are collected below.
            if case .ring(let ring) = primitive.geometry, ring.containsCurves { continue }
            switch primitive.geometry {
            case .rectangle, .ring:
                if parents.contains(primitive.id) { continue }
            case .line, .cubic:
                break
            }
            let points = flattener.flatten(primitive)
            guard points.count >= 2 else { continue }

            var piece = 0
            var previous: PDFPoint?
            for raw in points {
                guard raw.x.isFinite, raw.y.isFinite else {
                    previous = nil
                    continue
                }
                let point = PDFPoint(x: Double(raw.x), y: Double(raw.y))
                guard let start = previous else {
                    previous = point
                    continue
                }
                // A step under the degenerate length is not advanced past: the run of tiny
                // steps a hard-subdivided curve produces is accumulated into one segment
                // rather than dropped one at a time, which would drift the polyline.
                guard start.distance(to: point) > degenerate else { continue }

                if segments.count >= options.maximumSegments {
                    return .overflow(count: segments.count + 1)
                }
                segments.append(
                    TraceSegment(
                        start: start,
                        end: point,
                        sourceID: primitive.id,
                        pieceIndex: piece
                    )
                )
                piece += 1
                previous = point
            }
        }

        // A total order that does not depend on the order primitives arrived in, so the node
        // numbering below — and therefore the ring the walk produces — is a function of the
        // segment set alone.
        segments.sort(by: Self.stableOrder)
        return .collected(segments)
    }

    static func stableOrder(_ a: TraceSegment, _ b: TraceSegment) -> Bool {
        if a.start.x != b.start.x { return a.start.x < b.start.x }
        if a.start.y != b.start.y { return a.start.y < b.start.y }
        if a.end.x != b.end.x { return a.end.x < b.end.x }
        if a.end.y != b.end.y { return a.end.y < b.end.y }
        if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
        return a.pieceIndex < b.pieceIndex
    }
}
