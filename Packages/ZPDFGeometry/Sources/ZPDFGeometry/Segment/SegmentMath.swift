import Foundation
import ZPDFContracts

/// The nearest point on a segment to a query point.
public struct NearestPointOnSegment: Hashable, Sendable {
    /// The point itself, in PDF page space.
    public let point: PDFPoint
    /// Parameter along the segment, clamped to `0...1`. 0 is `start`, 1 is `end`.
    public let t: Double
    /// Distance from the query point, in PDF points.
    public let distance: Double
    /// True when the nearest point is one of the two endpoints, i.e. the perpendicular foot
    /// fell outside the segment. Endpoint snaps and edge snaps are different snap kinds
    /// (spec 13.1), so the caller has to be able to tell them apart.
    public let isEndpoint: Bool
}

/// The result of intersecting two segments.
public enum SegmentIntersection: Hashable, Sendable {
    /// They do not meet.
    case none
    /// They meet at one point. `tOnFirst` and `tOnSecond` are the parameters in `0...1`.
    case point(PDFPoint, tOnFirst: Double, tOnSecond: Double)
    /// They are collinear and share a span. The segment is the shared part; the ranges are its
    /// parameter extent on each input.
    case collinearOverlap(
        SegmentGeometry,
        tRangeOnFirst: ClosedRange<Double>,
        tRangeOnSecond: ClosedRange<Double>
    )
    /// They are parallel (or collinear) but do not touch.
    case parallelDisjoint
}

/// Segment, line and circle primitives.
///
/// Every predicate takes its tolerance from a ``GeometryEpsilon`` rather than hard-coding one,
/// and every failure is a typed throw. Nothing here rounds: results are `Double` page-space
/// values that the measurement engine later turns into `Decimal` quantities exactly once.
public enum SegmentMath {

    // MARK: - Nearest point

    /// Projects `point` onto the segment, clamping to the endpoints.
    ///
    /// A zero-length segment yields its own start with `t == 0`; that is the only sensible
    /// answer and it keeps snap candidate generation from having to special-case degenerate
    /// primitives that PDF content is full of.
    public static func nearestPoint(
        on segment: SegmentGeometry,
        to point: PDFPoint
    ) -> NearestPointOnSegment {
        let direction = PDFVector(from: segment.start, to: segment.end)
        let lengthSquared = direction.squaredMagnitude
        guard lengthSquared > 0 else {
            return NearestPointOnSegment(
                point: segment.start,
                t: 0,
                distance: segment.start.distance(to: point),
                isEndpoint: true
            )
        }
        let toPoint = PDFVector(from: segment.start, to: point)
        let rawT = toPoint.dot(direction) / lengthSquared
        let t = Swift.min(Swift.max(rawT, 0), 1)
        let projected = segment.start.offset(by: direction.scaled(by: t))
        return NearestPointOnSegment(
            point: projected,
            t: t,
            distance: projected.distance(to: point),
            isEndpoint: rawT <= 0 || rawT >= 1
        )
    }

    /// The perpendicular foot of `point` on the **infinite line** through `a` and `b`.
    ///
    /// Unclamped, unlike ``nearestPoint(on:to:)``. Perpendicular snapping (spec 13.1) needs the
    /// foot even when it lies beyond the drawn edge, because the wall the user is measuring to
    /// continues past the line the PDF happened to draw.
    ///
    /// - Throws: ``GeometryError/degenerateSegment`` when `a == b`.
    public static func perpendicularFoot(
        from point: PDFPoint,
        onLineThrough a: PDFPoint,
        and b: PDFPoint
    ) throws -> PDFPoint {
        let direction = PDFVector(from: a, to: b)
        let lengthSquared = direction.squaredMagnitude
        guard lengthSquared > 0, lengthSquared.isFinite else {
            throw GeometryError.degenerateSegment
        }
        let t = PDFVector(from: a, to: point).dot(direction) / lengthSquared
        return a.offset(by: direction.scaled(by: t))
    }

    /// Signed distance from `point` to the infinite line through `a` and `b`. Positive on the
    /// left of `a -> b`.
    ///
    /// - Throws: ``GeometryError/degenerateSegment`` when `a == b`.
    public static func signedDistance(
        from point: PDFPoint,
        toLineThrough a: PDFPoint,
        and b: PDFPoint
    ) throws -> Double {
        let direction = PDFVector(from: a, to: b)
        let length = direction.magnitude
        guard length > 0, length.isFinite else { throw GeometryError.degenerateSegment }
        return direction.cross(PDFVector(from: a, to: point)) / length
    }

    // MARK: - Intersection

    /// Intersects two segments, handling parallel and collinear input explicitly.
    ///
    /// The parallel test is on `|r x s| / (|r| |s|)`, i.e. the sine of the angle between them,
    /// compared against ``GeometryEpsilon/parallel``. Testing the raw cross product instead —
    /// which is what most implementations do — makes the threshold depend on segment length, so
    /// two 3000-point-long edges 0.001 degrees apart would be called crossing while two
    /// 2-point-long edges 5 degrees apart would be called parallel.
    ///
    /// Degenerate (zero-length) inputs are treated as points and tested for lying on the other
    /// segment, so a snap index full of zero-length stubs does not need pre-filtering.
    public static func intersect(
        _ first: SegmentGeometry,
        _ second: SegmentGeometry,
        epsilon: GeometryEpsilon = .standard
    ) -> SegmentIntersection {
        let r = PDFVector(from: first.start, to: first.end)
        let s = PDFVector(from: second.start, to: second.end)
        let rLength = r.magnitude
        let sLength = s.magnitude

        // Degenerate inputs.
        if rLength <= epsilon.pointMerge && sLength <= epsilon.pointMerge {
            return first.start.distance(to: second.start) <= epsilon.onSegment
                ? .point(first.start, tOnFirst: 0, tOnSecond: 0)
                : .none
        }
        if rLength <= epsilon.pointMerge {
            let nearest = nearestPoint(on: second, to: first.start)
            return nearest.distance <= epsilon.onSegment
                ? .point(first.start, tOnFirst: 0, tOnSecond: nearest.t)
                : .none
        }
        if sLength <= epsilon.pointMerge {
            let nearest = nearestPoint(on: first, to: second.start)
            return nearest.distance <= epsilon.onSegment
                ? .point(second.start, tOnFirst: nearest.t, tOnSecond: 0)
                : .none
        }

        let denominator = r.cross(s)
        let qp = PDFVector(from: first.start, to: second.start)
        let isParallel = Swift.abs(denominator) <= epsilon.parallel * rLength * sLength

        if isParallel {
            // Collinear when the offset between the two lines is (near) zero.
            let offset = Swift.abs(qp.cross(r)) / rLength
            guard offset <= epsilon.onSegment else { return .parallelDisjoint }

            let rSquared = r.squaredMagnitude
            let t0 = qp.dot(r) / rSquared
            let t1 = PDFVector(from: first.start, to: second.end).dot(r) / rSquared
            let low = Swift.min(t0, t1)
            let high = Swift.max(t0, t1)
            let clampedLow = Swift.max(low, 0)
            let clampedHigh = Swift.min(high, 1)
            let parameterSlack = epsilon.onSegment / rLength

            if clampedLow > clampedHigh + parameterSlack { return .parallelDisjoint }
            if clampedHigh - clampedLow <= parameterSlack {
                let t = (clampedLow + clampedHigh) / 2
                let contact = first.start.offset(by: r.scaled(by: t))
                let u = nearestPoint(on: second, to: contact).t
                return .point(contact, tOnFirst: t, tOnSecond: u)
            }

            let startPoint = first.start.offset(by: r.scaled(by: clampedLow))
            let endPoint = first.start.offset(by: r.scaled(by: clampedHigh))
            let uLow = nearestPoint(on: second, to: startPoint).t
            let uHigh = nearestPoint(on: second, to: endPoint).t
            return .collinearOverlap(
                SegmentGeometry(start: startPoint, end: endPoint),
                tRangeOnFirst: clampedLow...clampedHigh,
                tRangeOnSecond: Swift.min(uLow, uHigh)...Swift.max(uLow, uHigh)
            )
        }

        let t = qp.cross(s) / denominator
        let u = qp.cross(r) / denominator
        let tSlack = epsilon.onSegment / rLength
        let uSlack = epsilon.onSegment / sLength
        guard t >= -tSlack, t <= 1 + tSlack, u >= -uSlack, u <= 1 + uSlack else { return .none }
        let clampedT = Swift.min(Swift.max(t, 0), 1)
        let clampedU = Swift.min(Swift.max(u, 0), 1)
        return .point(
            first.start.offset(by: r.scaled(by: clampedT)),
            tOnFirst: clampedT,
            tOnSecond: clampedU
        )
    }

    // MARK: - Circles and arcs

    /// The unique circle through three points.
    ///
    /// Collinearity is rejected on the **normalised** measure `|cross| / maxEdge^2`, which is
    /// twice the triangle's area divided by the square of its longest edge — a dimensionless
    /// number equal to `sin(angle) * shortEdge / longEdge`. An absolute area threshold would
    /// accept three points 1 metre apart deviating by a micrometre (a circle of radius 1e8 m,
    /// numerically garbage) while rejecting three points 1 millimetre apart forming a perfectly
    /// good small circle.
    ///
    /// - Parameter collinearityThreshold: default `1e-9`, i.e. roughly 5.7e-8 degrees of bend on
    ///   an equilateral triple.
    /// - Throws: ``GeometryError/nearlyCollinearPoints(measure:)``.
    public static func circumcircle(
        _ a: PDFPoint,
        _ b: PDFPoint,
        _ c: PDFPoint,
        collinearityThreshold: Double = 1e-9
    ) throws -> CircleGeometry {
        guard a.isFinite, b.isFinite, c.isFinite else { throw GeometryError.nonFiniteCoordinate }

        // Shift to c so the determinant is formed from small differences, not from page
        // coordinates that can be four digits before the decimal point.
        let ax = a.x - c.x
        let ay = a.y - c.y
        let bx = b.x - c.x
        let by = b.y - c.y

        let cross = ax * by - ay * bx
        let maxEdge = Swift.max(
            a.distance(to: b),
            Swift.max(b.distance(to: c), c.distance(to: a))
        )
        guard maxEdge > 0 else { throw GeometryError.nearlyCollinearPoints(measure: 0) }
        let measure = Swift.abs(cross) / (maxEdge * maxEdge)
        guard measure > collinearityThreshold else {
            throw GeometryError.nearlyCollinearPoints(measure: measure)
        }

        let aSquared = ax * ax + ay * ay
        let bSquared = bx * bx + by * by
        let denominator = 2 * cross
        let ux = (aSquared * by - bSquared * ay) / denominator
        let uy = (bSquared * ax - aSquared * bx) / denominator
        let radius = (ux * ux + uy * uy).squareRoot()
        return CircleGeometry(center: PDFPoint(x: ux + c.x, y: uy + c.y), radius: radius)
    }

    /// The arc through three points, `a` to `c` passing through `b`.
    ///
    /// The sweep direction is chosen so the arc actually contains `b`, which is the whole point
    /// of three-point arc entry: the user clicks a start, a point on the curve and an end.
    public static func arc(
        through a: PDFPoint,
        _ b: PDFPoint,
        _ c: PDFPoint,
        collinearityThreshold: Double = 1e-9
    ) throws -> ArcGeometry {
        let circle = try circumcircle(a, b, c, collinearityThreshold: collinearityThreshold)
        let startAngle = PDFVector(from: circle.center, to: a).angle
        let middleAngle = PDFVector(from: circle.center, to: b).angle
        let endAngle = PDFVector(from: circle.center, to: c).angle

        // Counter-clockwise sweeps from start to end and to the middle point, both normalised
        // into [0, 2pi). If the middle is not reached before the end, the arc must go the other
        // way round.
        let twoPi = 2 * Double.pi
        func normalised(_ value: Double) -> Double {
            let wrapped = value.truncatingRemainder(dividingBy: twoPi)
            return wrapped < 0 ? wrapped + twoPi : wrapped
        }
        let toEnd = normalised(endAngle - startAngle)
        let toMiddle = normalised(middleAngle - startAngle)
        let sweep = toMiddle <= toEnd ? toEnd : toEnd - twoPi
        return ArcGeometry(
            center: circle.center,
            radius: circle.radius,
            startAngle: startAngle,
            sweepAngle: sweep
        )
    }

    /// Total length of a polyline, compensated (spec 11.4).
    public static func polylineLength(_ points: [PDFPoint], isClosed: Bool = false) -> Double {
        PolygonMath.perimeter(points, isClosed: isClosed)
    }

    /// The point at parameter `t` along a segment. `t` is not clamped, so this doubles as the
    /// parametric form of the infinite line.
    public static func point(on segment: SegmentGeometry, at t: Double) -> PDFPoint {
        segment.start.offset(by: PDFVector(from: segment.start, to: segment.end).scaled(by: t))
    }

    /// The midpoint of a segment, the most requested snap of all (spec 13.1).
    public static func midpoint(of segment: SegmentGeometry) -> PDFPoint {
        PDFPoint(
            x: (segment.start.x + segment.end.x) / 2,
            y: (segment.start.y + segment.end.y) / 2
        )
    }
}
