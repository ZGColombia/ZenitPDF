import Foundation
import ZPDFContracts

/// One place where a ring crosses or touches itself.
public struct PolygonSelfIntersection: Hashable, Sendable {
    /// What kind of contact it is.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The two edges properly cross.
        case crossing
        /// They meet at a single point without crossing (a vertex lying on a far edge).
        case touching
        /// They are collinear and share more than a point.
        case collinearOverlap
    }

    /// Index of the first edge, where edge `i` runs from vertex `i` to vertex `i + 1`.
    public let firstEdgeIndex: Int
    /// Index of the second edge, always greater than ``firstEdgeIndex``.
    public let secondEdgeIndex: Int
    /// The intersection point, or `nil` for a collinear overlap (which is a span, not a point).
    public let point: PDFPoint?
    public let kind: Kind

    public init(firstEdgeIndex: Int, secondEdgeIndex: Int, point: PDFPoint?, kind: Kind) {
        self.firstEdgeIndex = firstEdgeIndex
        self.secondEdgeIndex = secondEdgeIndex
        self.point = point
        self.kind = kind
    }
}

/// Cost and safety limits for the self-intersection check.
public struct SelfIntersectionOptions: Hashable, Sendable {
    /// Stop after this many intersections. `nil` reports all of them.
    ///
    /// A validity check only needs to know whether the count is zero, and a badly traced ring
    /// can produce tens of thousands, so the default stops at the first one.
    public var maximumReported: Int?

    /// Refuse rings above this vertex count rather than running for minutes.
    ///
    /// # Why 50 000
    ///
    /// The algorithm below is an **x-interval sweep over an exhaustive pairwise test**: edges are
    /// sorted by their minimum x, and each edge is compared only against later edges whose
    /// minimum x has not yet passed its own maximum x. For the geometry this product actually
    /// sees — traced room boundaries, hatched areas, region outlines — the active set stays in
    /// the tens, so the real cost is `O(n log n)` and 50 000 vertices measure in tens of
    /// milliseconds.
    ///
    /// The worst case is still `O(n^2)`: a ring of 50 000 near-vertical edges all spanning the
    /// same x range degenerates to 1.25e9 segment tests, roughly a minute. That shape does not
    /// occur in a takeoff, but it is reachable from a malformed import, so the limit is a hard
    /// throw rather than a comment. Bentley-Ottmann would bound the worst case at
    /// `O((n + k) log n)`; it is not here because its degenerate-case handling (vertical edges,
    /// three edges through one point, collinear overlaps — all of which a traced polygon
    /// produces routinely) is where that algorithm's real bugs live, and a wrong "this ring is
    /// simple" answer is worse than a slow one.
    ///
    /// Rings above the limit are still measurable: ``PolygonMath/signedArea(_:)`` and
    /// ``PolygonMath/perimeter(_:isClosed:)`` do not need simplicity.
    public var vertexLimit: Int

    public init(maximumReported: Int? = 1, vertexLimit: Int = 50_000) {
        self.maximumReported = maximumReported
        self.vertexLimit = vertexLimit
    }

    /// Report every intersection, for a repair or highlight UI.
    public static let exhaustive = SelfIntersectionOptions(maximumReported: nil)
}

extension PolygonMath {

    /// Finds where a ring or polyline intersects itself.
    ///
    /// Adjacent edges share an endpoint by construction; that shared endpoint is not an
    /// intersection and is filtered out. Adjacent edges that fold back onto each other
    /// (a spike: `A -> B -> A`) *are* reported, as ``PolygonSelfIntersection/Kind/collinearOverlap``,
    /// because that is a real defect in a boundary.
    ///
    /// - Throws: ``GeometryError/ringTooLargeForIntersectionCheck(vertexCount:limit:)`` above
    ///   ``SelfIntersectionOptions/vertexLimit``, or ``GeometryError/nonFiniteCoordinate``.
    public static func selfIntersections(
        _ points: [PDFPoint],
        isClosed: Bool = true,
        epsilon: GeometryEpsilon = .standard,
        options: SelfIntersectionOptions = SelfIntersectionOptions()
    ) throws -> [PolygonSelfIntersection] {
        try epsilon.validate()
        guard points.count <= options.vertexLimit else {
            throw GeometryError.ringTooLargeForIntersectionCheck(
                vertexCount: points.count,
                limit: options.vertexLimit
            )
        }
        for point in points where !point.isFinite { throw GeometryError.nonFiniteCoordinate }

        let vertexCount = points.count
        let edgeCount = isClosed ? vertexCount : vertexCount - 1
        // Two edges can already fold back onto each other in an open polyline (A -> B -> A);
        // a closed ring needs three edges before it is a ring at all (BH-550).
        guard edgeCount >= (isClosed ? 3 : 2) else { return [] }

        var edges: [SegmentGeometry] = []
        edges.reserveCapacity(edgeCount)
        for index in 0..<edgeCount {
            let next = index + 1 == vertexCount ? 0 : index + 1
            edges.append(SegmentGeometry(start: points[index], end: points[next]))
        }

        // The sweep: edge order by minimum x, plus each edge's maximum x, so the inner loop can
        // stop as soon as a candidate starts to the right of the current edge's end.
        let order = (0..<edgeCount).sorted { lhs, rhs in
            let a = Swift.min(edges[lhs].start.x, edges[lhs].end.x)
            let b = Swift.min(edges[rhs].start.x, edges[rhs].end.x)
            return a == b ? lhs < rhs : a < b
        }
        let minXs = edges.map { Swift.min($0.start.x, $0.end.x) }
        let maxXs = edges.map { Swift.max($0.start.x, $0.end.x) }
        let minYs = edges.map { Swift.min($0.start.y, $0.end.y) }
        let maxYs = edges.map { Swift.max($0.start.y, $0.end.y) }

        var found: [PolygonSelfIntersection] = []
        let slack = epsilon.onSegment

        outer: for position in 0..<order.count {
            let i = order[position]
            for otherPosition in (position + 1)..<order.count {
                let j = order[otherPosition]
                if minXs[j] > maxXs[i] + slack { break }
                if minYs[j] > maxYs[i] + slack || minYs[i] > maxYs[j] + slack { continue }

                let low = Swift.min(i, j)
                let high = Swift.max(i, j)
                let isAdjacent = (high == low + 1) || (isClosed && low == 0 && high == edgeCount - 1)

                let result = SegmentMath.intersect(edges[low], edges[high], epsilon: epsilon)
                switch result {
                case .none, .parallelDisjoint:
                    continue
                case .collinearOverlap:
                    found.append(
                        PolygonSelfIntersection(
                            firstEdgeIndex: low,
                            secondEdgeIndex: high,
                            point: nil,
                            kind: .collinearOverlap
                        )
                    )
                case .point(let point, let t, let u):
                    if isAdjacent {
                        // The shared vertex is expected; anything else on adjacent edges is not.
                        let atSharedEnd = (t <= slack || t >= 1 - slack)
                            && (u <= slack || u >= 1 - slack)
                        if atSharedEnd { continue }
                    }
                    let isEndpointContact = t <= slack || t >= 1 - slack
                        || u <= slack || u >= 1 - slack
                    found.append(
                        PolygonSelfIntersection(
                            firstEdgeIndex: low,
                            secondEdgeIndex: high,
                            point: point,
                            kind: isEndpointContact ? .touching : .crossing
                        )
                    )
                }
                if let limit = options.maximumReported, found.count >= limit { break outer }
            }
        }
        return found
    }
}
