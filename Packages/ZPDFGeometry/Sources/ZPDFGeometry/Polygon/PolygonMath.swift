import Foundation
import ZPDFContracts

/// Where a point sits relative to a ring.
public enum PointContainment: String, Hashable, Sendable, CaseIterable {
    case inside
    case outside
    /// Within ``GeometryEpsilon/onSegment`` of an edge. Reported separately because a boundary
    /// hit is a snap candidate, not an area membership answer.
    case onBoundary
}

/// Area, perimeter and containment for rings in PDF page space.
///
/// Everything here is `Double` (spec 11.4: geometry is `Double`), compensated where the term
/// count can grow, and never rounded. Conversion into `Decimal` happens in the measurement
/// engine, once, at the point where a page-space number becomes a real-world quantity.
public enum PolygonMath {

    // MARK: - Area

    /// The signed shoelace area, in square PDF points. Positive for a counter-clockwise ring.
    ///
    /// Two things make this different from the textbook loop:
    ///
    /// 1. **Origin shift.** Every vertex is expressed relative to the ring's first vertex before
    ///    the cross products are formed. A 5 m x 5 m room drawn at page coordinate (10000, 8000)
    ///    otherwise forms terms near 8e7 whose difference is near 1e4 — losing four decimal
    ///    digits to cancellation before the sum even starts. Shifting is exact for the
    ///    subtraction and removes the cancellation entirely.
    /// 2. **Kahan-Babuska-Neumaier summation** over the terms (spec 11.4), so a 200 000-vertex
    ///    traced boundary does not accumulate drift.
    ///
    /// A ring with fewer than three vertices has zero area; that is a definition, not an error,
    /// so callers that need to reject it use ``requireSimplePolygon(_:epsilon:)`` or check
    /// ``PolygonRing/uniquePoints``.
    public static func signedArea(_ points: [PDFPoint]) -> Double {
        let count = points.count
        guard count >= 3 else { return 0 }
        let originX = points[0].x
        let originY = points[0].y
        var accumulator = KahanAccumulator()
        for index in 0..<count {
            let current = points[index]
            let next = points[index + 1 == count ? 0 : index + 1]
            let ax = current.x - originX
            let ay = current.y - originY
            let bx = next.x - originX
            let by = next.y - originY
            accumulator.add(ax * by - bx * ay)
        }
        return accumulator.total / 2
    }

    /// Absolute area in square PDF points.
    public static func area(_ points: [PDFPoint]) -> Double {
        Swift.abs(signedArea(points))
    }

    /// Signed area of a ring value.
    public static func signedArea(_ ring: PolygonRing) -> Double {
        signedArea(ring.points)
    }

    /// True when the interiors of two simple rings share area. Touching along an edge, along
    /// part of an edge or at a vertex is not overlap; identical rings, nested rings (with or
    /// without shared boundary) and properly crossing rings are.
    ///
    /// Exact for simple rings: if the interiors meet, the boundary of their intersection is
    /// made of boundary pieces of the two rings, and each such piece either lies strictly
    /// inside the other ring or runs along it with both interiors on the same side. Both are
    /// detected below, after the cheap vertex and crossing tests.
    static func interiorsOverlap(
        _ first: [PDFPoint],
        _ second: [PDFPoint],
        epsilon: GeometryEpsilon = .standard
    ) -> Bool {
        guard first.count >= 3, second.count >= 3 else { return false }
        if first.contains(where: { classify($0, in: second, epsilon: epsilon) == .inside }) { return true }
        if second.contains(where: { classify($0, in: first, epsilon: epsilon) == .inside }) { return true }
        if edgesCrossProperly(first, second, epsilon: epsilon) { return true }
        let forward = edgePiecePlacement(of: first, against: second, epsilon: epsilon)
        if forward.inside || forward.sharedSameSide { return true }
        let backward = edgePiecePlacement(of: second, against: first, epsilon: epsilon)
        return backward.inside || backward.sharedSameSide
    }

    /// Where the boundary of `ring` runs relative to `other`.
    struct EdgePiecePlacement: Equatable {
        /// Some piece of `ring`'s boundary lies strictly inside `other`.
        var inside = false
        /// Some piece lies strictly outside `other`.
        var outside = false
        /// Some piece runs along `other`'s boundary with both interiors on the same side.
        var sharedSameSide = false
        /// Some piece runs along `other`'s boundary with the interiors on opposite sides.
        var sharedOppositeSide = false
    }

    /// Cuts each edge of `ring` at the vertices of `other` that lie on it and classifies each
    /// piece by its midpoint. With proper crossings already excluded, a piece cannot change
    /// sides part-way, so its midpoint speaks for all of it.
    ///
    /// For a piece on `other`'s boundary, the interior of a ring lies to the left of an edge
    /// when the ring winds counter-clockwise and to the right when it winds clockwise, so with
    /// winding signs `s` and edge directions `d`, `e` the interiors are on the same side
    /// exactly when `s_ring * s_other * (d . e) > 0`.
    static func edgePiecePlacement(
        of ring: [PDFPoint],
        against other: [PDFPoint],
        epsilon: GeometryEpsilon
    ) -> EdgePiecePlacement {
        var placement = EdgePiecePlacement()
        guard ring.count >= 3, other.count >= 3 else { return placement }
        let ringSign = signedArea(ring).sign == .minus ? -1.0 : 1.0
        let otherSign = signedArea(other).sign == .minus ? -1.0 : 1.0
        for index in ring.indices {
            let start = ring[index]
            let end = ring[index + 1 == ring.count ? 0 : index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > epsilon.pointMerge * epsilon.pointMerge else { continue }
            let edge = SegmentGeometry(start: start, end: end)

            var cuts: [Double] = [0, 1]
            for vertex in other
            where SegmentMath.nearestPoint(on: edge, to: vertex).distance <= epsilon.onSegment {
                let t = ((vertex.x - start.x) * dx + (vertex.y - start.y) * dy) / lengthSquared
                if t > 0, t < 1 { cuts.append(t) }
            }
            cuts.sort()

            let length = lengthSquared.squareRoot()
            for cut in 1..<cuts.count {
                let t0 = cuts[cut - 1]
                let t1 = cuts[cut]
                guard (t1 - t0) * length > epsilon.pointMerge else { continue }
                let pieceStart = PDFPoint(x: start.x + dx * t0, y: start.y + dy * t0)
                let pieceEnd = PDFPoint(x: start.x + dx * t1, y: start.y + dy * t1)
                let middle = PDFPoint(x: (pieceStart.x + pieceEnd.x) / 2, y: (pieceStart.y + pieceEnd.y) / 2)
                switch classify(middle, in: other, epsilon: epsilon) {
                case .inside:
                    placement.inside = true
                case .outside:
                    placement.outside = true
                case .onBoundary:
                    let piece = SegmentGeometry(start: pieceStart, end: pieceEnd)
                    for otherIndex in other.indices {
                        let a = other[otherIndex]
                        let b = other[otherIndex + 1 == other.count ? 0 : otherIndex + 1]
                        let otherEdge = SegmentGeometry(start: a, end: b)
                        guard case .collinearOverlap = SegmentMath.intersect(piece, otherEdge, epsilon: epsilon) else {
                            continue
                        }
                        let dot = dx * (b.x - a.x) + dy * (b.y - a.y)
                        if ringSign * otherSign * dot > 0 {
                            placement.sharedSameSide = true
                        } else {
                            placement.sharedOppositeSide = true
                        }
                        break
                    }
                }
            }
        }
        return placement
    }

    /// True when an edge of `first` crosses an edge of `second` at a point interior to both.
    /// A touch at an endpoint and a shared collinear span are not crossings.
    private static func edgesCrossProperly(
        _ first: [PDFPoint],
        _ second: [PDFPoint],
        epsilon: GeometryEpsilon
    ) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }
        let touch = epsilon.onSegment
        for i in first.indices {
            let a = SegmentGeometry(start: first[i], end: first[i + 1 == first.count ? 0 : i + 1])
            for j in second.indices {
                let b = SegmentGeometry(start: second[j], end: second[j + 1 == second.count ? 0 : j + 1])
                guard case .point(let crossing, _, _) = SegmentMath.intersect(a, b, epsilon: epsilon) else {
                    continue
                }
                if crossing.distance(to: a.start) > touch, crossing.distance(to: a.end) > touch,
                   crossing.distance(to: b.start) > touch, crossing.distance(to: b.end) > touch {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Perimeter

    /// Total edge length in PDF points, compensated.
    ///
    /// `isClosed` controls whether the closing edge from the last vertex back to the first is
    /// counted, which is the difference between a polygon's perimeter and a polyline's length.
    public static func perimeter(_ points: [PDFPoint], isClosed: Bool = true) -> Double {
        let count = points.count
        guard count >= 2 else { return 0 }
        var accumulator = KahanAccumulator()
        for index in 0..<(count - 1) {
            accumulator.add(points[index].distance(to: points[index + 1]))
        }
        if isClosed {
            accumulator.add(points[count - 1].distance(to: points[0]))
        }
        return accumulator.total
    }

    public static func perimeter(_ ring: PolygonRing) -> Double {
        perimeter(ring.points, isClosed: ring.isClosed)
    }

    // MARK: - Containment

    /// The winding number of a ring around a point.
    ///
    /// Uses the crossing formulation (Sunday): it counts signed upward and downward crossings of
    /// the horizontal ray through `point` and never evaluates a trigonometric function, so it is
    /// both exact for integer-ish coordinates and immune to the angle-summation rounding that
    /// makes the naive winding algorithm report 0 for points near an edge.
    public static func windingNumber(of point: PDFPoint, in polygon: [PDFPoint]) -> Int {
        let count = polygon.count
        guard count >= 3 else { return 0 }
        var winding = 0
        for index in 0..<count {
            let start = polygon[index]
            let end = polygon[index + 1 == count ? 0 : index + 1]
            if start.y <= point.y {
                if end.y > point.y, isLeft(start, end, point) > 0 {
                    winding += 1
                }
            } else if end.y <= point.y, isLeft(start, end, point) < 0 {
                winding -= 1
            }
        }
        return winding
    }

    /// `> 0` when `point` is left of the directed line `start -> end`.
    @inline(__always)
    private static func isLeft(_ start: PDFPoint, _ end: PDFPoint, _ point: PDFPoint) -> Double {
        (end.x - start.x) * (point.y - start.y) - (point.x - start.x) * (end.y - start.y)
    }

    /// Containment under the non-zero winding rule (the PDF default, and the right rule for a
    /// ring with holes wound the opposite way), boundary excluded.
    public static func contains(_ point: PDFPoint, in polygon: [PDFPoint]) -> Bool {
        windingNumber(of: point, in: polygon) != 0
    }

    /// Containment with the boundary reported as its own answer.
    ///
    /// The boundary test runs first and costs a full pass over the edges. That is deliberate:
    /// a point exactly on an edge is the single most common case in a takeoff (the user snapped
    /// to it), and the winding rule gives an arbitrary answer there.
    public static func classify(
        _ point: PDFPoint,
        in polygon: [PDFPoint],
        epsilon: GeometryEpsilon = .standard
    ) -> PointContainment {
        let count = polygon.count
        guard count >= 3 else { return .outside }
        for index in 0..<count {
            let start = polygon[index]
            let end = polygon[index + 1 == count ? 0 : index + 1]
            let nearest = SegmentMath.nearestPoint(on: SegmentGeometry(start: start, end: end), to: point)
            if nearest.distance <= epsilon.onSegment { return .onBoundary }
        }
        return contains(point, in: polygon) ? .inside : .outside
    }

    /// Containment in a polygon with holes: inside the outer ring and inside no hole.
    public static func classify(
        _ point: PDFPoint,
        in polygon: PolygonGeometry,
        epsilon: GeometryEpsilon = .standard
    ) -> PointContainment {
        let outer = classify(point, in: polygon.outer.points, epsilon: epsilon)
        guard outer == .inside else { return outer }
        for hole in polygon.holes {
            switch classify(point, in: hole.points, epsilon: epsilon) {
            case .inside: return .outside
            case .onBoundary: return .onBoundary
            case .outside: continue
            }
        }
        return .inside
    }

    // MARK: - Validation

    /// Cleans, then requires at least three distinct vertices and no self-intersection.
    ///
    /// - Returns: the cleaned ring.
    /// - Throws: ``GeometryError/fewerThanThreeUniquePoints(count:)`` or
    ///   ``MeasurementError/selfIntersectingPolygon``.
    @discardableResult
    public static func requireSimplePolygon(
        _ points: [PDFPoint],
        epsilon: GeometryEpsilon = .standard
    ) throws -> [PDFPoint] {
        let cleaned = try PolygonCleanup.cleanup(
            points,
            options: PolygonCleanupOptions(epsilon: epsilon)
        ).points
        guard cleaned.count >= 3 else {
            throw GeometryError.fewerThanThreeUniquePoints(count: cleaned.count)
        }
        let intersections = try selfIntersections(cleaned, isClosed: true, epsilon: epsilon)
        guard intersections.isEmpty else { throw MeasurementError.selfIntersectingPolygon }
        return cleaned
    }
}
