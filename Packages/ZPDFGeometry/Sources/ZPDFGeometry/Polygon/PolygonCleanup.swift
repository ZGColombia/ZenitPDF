import Foundation
import ZPDFContracts

/// How aggressively a ring is normalised before it is measured.
public struct PolygonCleanupOptions: Hashable, Sendable {
    /// The tolerance policy. ``GeometryEpsilon/pointMerge`` decides duplicate vertices.
    public var epsilon: GeometryEpsilon

    /// Treat the point list as a closed ring: the last vertex is also compared against the
    /// first, so an explicitly repeated closing vertex is dropped.
    public var isClosedRing: Bool

    /// Also drop vertices that lie on the straight line between their neighbours.
    ///
    /// Off by default. A traced boundary's collinear vertices are usually meaningful — they are
    /// where the user clicked, they carry segment-level annotations, and deleting them silently
    /// changes a per-segment ledger breakdown. Turn it on for derived geometry (region
    /// boundaries, simplified outlines) where only the shape matters.
    public var removesCollinearVertices: Bool

    /// Maximum perpendicular deviation, in PDF points, for a vertex to count as collinear.
    ///
    /// This is a *height*, not an area or an angle, so the threshold means the same thing on a
    /// 2-point edge and a 2000-point edge. An angle threshold would delete a real corner on a
    /// long edge and keep a meaningless one on a short edge.
    public var collinearHeightTolerance: Double

    public init(
        epsilon: GeometryEpsilon = .standard,
        isClosedRing: Bool = true,
        removesCollinearVertices: Bool = false,
        collinearHeightTolerance: Double = 1e-6
    ) {
        self.epsilon = epsilon
        self.isClosedRing = isClosedRing
        self.removesCollinearVertices = removesCollinearVertices
        self.collinearHeightTolerance = collinearHeightTolerance
    }
}

/// What cleanup did, so the caller can tell the user rather than silently changing their drawing.
public struct PolygonCleanupResult: Hashable, Sendable {
    public let points: [PDFPoint]
    /// Vertices dropped for being within ``GeometryEpsilon/pointMerge`` of their predecessor.
    public let removedDuplicates: Int
    /// Vertices dropped for lying on the line between their neighbours.
    public let removedCollinear: Int
}

/// Duplicate and collinear vertex removal with an explicit, configurable epsilon policy.
public enum PolygonCleanup {

    /// - Throws: ``GeometryError/nonFiniteCoordinate`` for NaN/infinite input, or
    ///   ``GeometryError/invalidEpsilon(name:value:)`` for an unusable policy.
    public static func cleanup(
        _ points: [PDFPoint],
        options: PolygonCleanupOptions = PolygonCleanupOptions()
    ) throws -> PolygonCleanupResult {
        try options.epsilon.validate()
        guard options.collinearHeightTolerance.isFinite, options.collinearHeightTolerance > 0 else {
            throw GeometryError.invalidEpsilon(
                name: "collinearHeightTolerance",
                value: options.collinearHeightTolerance
            )
        }
        for point in points where !point.isFinite { throw GeometryError.nonFiniteCoordinate }
        guard !points.isEmpty else {
            return PolygonCleanupResult(points: [], removedDuplicates: 0, removedCollinear: 0)
        }

        // Squared comparison keeps the whole pass free of square roots; the epsilon is squared
        // once rather than a root taken per vertex.
        let mergeSquared = options.epsilon.pointMerge * options.epsilon.pointMerge
        var deduplicated: [PDFPoint] = []
        deduplicated.reserveCapacity(points.count)
        var removedDuplicates = 0
        for point in points {
            if let last = deduplicated.last, last.squaredDistance(to: point) <= mergeSquared {
                removedDuplicates += 1
                continue
            }
            deduplicated.append(point)
        }
        // The wrap-around check repeats: after the last vertex merges into the first, the new
        // last vertex may be within pointMerge of the first as well. A single check once left
        // it behind as a zero-area sliver vertex (BH-549).
        if options.isClosedRing, let first = deduplicated.first {
            while deduplicated.count >= 2,
                  let last = deduplicated.last,
                  first.squaredDistance(to: last) <= mergeSquared {
                deduplicated.removeLast()
                removedDuplicates += 1
            }
        }

        guard options.removesCollinearVertices, deduplicated.count >= 3 else {
            return PolygonCleanupResult(
                points: deduplicated,
                removedDuplicates: removedDuplicates,
                removedCollinear: 0
            )
        }

        var kept = deduplicated
        var removedCollinear = 0
        var changed = true
        // Repeat to a fixed point: removing B from A-B-C can make A-C-D collinear.
        while changed, kept.count >= 3 {
            changed = false
            var index = 0
            while index < kept.count, kept.count >= 3 {
                let count = kept.count
                let previous = kept[(index + count - 1) % count]
                let current = kept[index]
                let next = kept[(index + 1) % count]
                if !options.isClosedRing, index == 0 || index == count - 1 {
                    index += 1
                    continue
                }
                if perpendicularHeight(of: current, between: previous, and: next)
                    <= options.collinearHeightTolerance {
                    kept.remove(at: index)
                    removedCollinear += 1
                    changed = true
                } else {
                    index += 1
                }
            }
        }

        return PolygonCleanupResult(
            points: kept,
            removedDuplicates: removedDuplicates,
            removedCollinear: removedCollinear
        )
    }

    /// Convenience returning only the cleaned points.
    public static func cleaned(
        _ points: [PDFPoint],
        options: PolygonCleanupOptions = PolygonCleanupOptions()
    ) throws -> [PDFPoint] {
        try cleanup(points, options: options).points
    }

    /// Distance from `point` to the infinite line through `a` and `b`. When `a == b` this is the
    /// plain distance to that coincident point, which is the behaviour collinear removal wants.
    private static func perpendicularHeight(
        of point: PDFPoint,
        between a: PDFPoint,
        and b: PDFPoint
    ) -> Double {
        let base = PDFVector(from: a, to: b)
        let length = base.magnitude
        guard length > 0 else { return a.distance(to: point) }
        let cross = base.cross(PDFVector(from: a, to: point))
        return Swift.abs(cross) / length
    }
}
