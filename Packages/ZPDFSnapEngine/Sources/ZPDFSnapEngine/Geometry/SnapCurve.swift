import Foundation
import ZPDFContracts
import ZPDFGeometry

/// One elementary curve a primitive decomposes into for hit testing and intersection.
///
/// A `PrimitiveGeometry` can be a whole 5 000-vertex ring; an intersection solver that took
/// rings as operands would be quadratic in the ring. Decomposition happens **inside the query
/// radius only**, and only for the edges whose bounding box is within the radius, so a huge
/// polyline contributes the two or three edges the cursor is actually near.
public enum SnapCurve: Sendable, Hashable {
    case line(SegmentGeometry)
    case cubic(p0: PDFPoint, p1: PDFPoint, p2: PDFPoint, p3: PDFPoint)
    case circle(CircleGeometry)
    case arc(ArcGeometry)
    /// A quarter of a markup ellipse, read exactly (U-089, ``SnapEllipseArc``).
    case ellipseArc(SnapEllipseArc)

    public var bounds: PDFRect? {
        switch self {
        case .line(let s): s.bounds
        case .cubic(let a, let b, let c, let d): PDFRect.boundingBox(of: [a, b, c, d])
        case .circle(let c): c.bounds
        // The arc's own box, not its circle's (W-087): a shallow markup arc's circle covers the
        // sheet, so every query near it decomposed it and solved its pairs for nothing.
        case .arc(let a): a.bounds
        case .ellipseArc(let e): e.bounds
        }
    }

    /// The point on the curve nearest to `q`, with its parameter and distance.
    public func nearestPoint(to q: PDFPoint) -> (point: PDFPoint, parameter: Double, distance: Double)? {
        switch self {
        case .line(let s):
            let nearest = SegmentMath.nearestPoint(on: s, to: q)
            return (nearest.point, nearest.t, nearest.distance)

        case .cubic(let p0, let p1, let p2, let p3):
            let t = SnapCurveMath.nearestParameterOnCubic(p0, p1, p2, p3, to: q)
            let point = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t)
            return (point, t, point.distance(to: q))

        case .circle(let c):
            let v = PDFVector(from: c.center, to: q)
            let magnitude = v.magnitude
            guard magnitude > 1e-300 else { return nil }
            let point = PDFPoint(
                x: c.center.x + v.dx / magnitude * c.radius,
                y: c.center.y + v.dy / magnitude * c.radius
            )
            return (point, SnapCurveMath.normalizedAngle(v.angle), point.distance(to: q))

        case .arc(let a):
            let v = PDFVector(from: a.center, to: q)
            let magnitude = v.magnitude
            guard magnitude > 1e-300 else { return nil }
            let angle = v.angle
            if SnapCurveMath.arcContains(a, angle: angle) {
                let point = PDFPoint(
                    x: a.center.x + v.dx / magnitude * a.radius,
                    y: a.center.y + v.dy / magnitude * a.radius
                )
                return (point, SnapCurveMath.normalizedAngle(angle), point.distance(to: q))
            }
            // Outside the sweep the nearest point on the arc is whichever endpoint is closer.
            let start = a.startPoint
            let end = a.endPoint
            return start.distance(to: q) <= end.distance(to: q)
                ? (start, SnapCurveMath.normalizedAngle(a.startAngle), start.distance(to: q))
                : (end, SnapCurveMath.normalizedAngle(a.startAngle + a.sweepAngle), end.distance(to: q))

        case .ellipseArc(let e):
            return e.nearest(to: q)
        }
    }

    /// The unit tangent at a parameter returned by ``nearestPoint(to:)``, used for the
    /// crossing-angle test of `QUALITY_BAR` S5.
    public func tangent(at parameter: Double) -> PDFVector? {
        switch self {
        case .line(let s):
            let v = PDFVector(from: s.start, to: s.end)
            return try? v.normalized()
        case .cubic(let p0, let p1, let p2, let p3):
            let d = SnapCurveMath.cubicDerivative(p0, p1, p2, p3, at: parameter)
            return try? d.normalized()
        case .circle, .arc:
            return PDFVector(dx: -Foundation.sin(parameter), dy: Foundation.cos(parameter))
        case .ellipseArc(let e):
            return try? e.derivative(at: parameter).normalized()
        }
    }

    /// `true` when `point` is inside this curve's own parameter domain: on the segment rather
    /// than on its infinite extension, and inside the arc's sweep rather than on the full circle.
    public func contains(parameter: Double) -> Bool {
        switch self {
        case .line: parameter >= -1e-12 && parameter <= 1 + 1e-12
        case .cubic: parameter >= -1e-12 && parameter <= 1 + 1e-12
        case .circle: true
        case .arc(let a): SnapCurveMath.arcContains(a, angle: parameter)
        case .ellipseArc(let e): e.contains(parameter: parameter)
        }
    }

    /// The curve's own terminal points, if it has any. A circle has none.
    ///
    /// Used to suppress a false intersection: where two edges of the same outline meet
    /// end-to-end, the shared point is a **corner**, not a crossing, and reporting it as an
    /// intersection would put a misleading label on the right coordinate. The endpoint
    /// candidate at that exact point is emitted anyway, so nothing becomes unreachable.
    public var terminals: [PDFPoint] {
        switch self {
        case .line(let s): [s.start, s.end]
        case .cubic(let p0, _, _, let p3): [p0, p3]
        case .circle: []
        case .arc(let a): [a.startPoint, a.endPoint]
        case .ellipseArc(let e): [e.start, e.end]
        }
    }

    /// The curves a primitive decomposes into, restricted to those whose bounding box comes
    /// within `radius` of `focus`.
    ///
    /// - Parameter vertexLimit: an upper bound on the edges taken from one ring, so a hostile
    ///   200 000-vertex polygon cannot turn one query into a scan of the whole page. Edges are
    ///   taken in ring order, which is deterministic.
    /// The default edge cap of ``decompose(_:near:within:vertexLimit:)``.
    public static let defaultVertexLimit = 4096

    /// ``decompose(_:near:within:vertexLimit:)`` for an index entry: a quarter of a markup
    /// ellipse (kind set ``SnapEntryKindSet/zenitMarkupSmoothCurve``, stored as its standard
    /// cubic) decomposes into the exact ellipse quarter it stands for (U-089); everything else
    /// into its geometry's curves.
    static func decompose(
        _ entry: SnapIndexEntry,
        near focus: PDFPoint,
        within radius: Double
    ) -> [SnapLocalCurve] {
        if let ellipse = entry.ellipseArc {
            guard let box = ellipse.bounds, box.insetBy(radius).contains(focus) else { return [] }
            return [SnapLocalCurve(ordinal: 0, curve: .ellipseArc(ellipse))]
        }
        return decompose(entry.primitive.geometry, near: focus, within: radius)
    }

    public static func decompose(
        _ geometry: PrimitiveGeometry,
        near focus: PDFPoint,
        within radius: Double,
        vertexLimit: Int = SnapCurve.defaultVertexLimit
    ) -> [SnapLocalCurve] {
        // `PDFRect.insetBy` grows on a positive amount and shrinks on a negative one — the
        // opposite of `CGRect.insetBy`. Growing is what is wanted here: a curve is relevant when
        // the cursor is within `radius` of its bounding box.
        func isNear(_ curve: SnapCurve) -> Bool {
            guard let box = curve.bounds else { return false }
            return box.insetBy(radius).contains(focus)
        }
        func single(_ curve: SnapCurve) -> [SnapLocalCurve] {
            isNear(curve) ? [SnapLocalCurve(ordinal: 0, curve: curve)] : []
        }

        switch geometry {
        case .point:
            return []

        case .segment(let s):
            return single(.line(s))

        case .polyline(let points, let isClosed):
            guard points.count >= 2 else { return [] }
            var result: [SnapLocalCurve] = []
            let edgeCount = isClosed ? points.count : points.count - 1
            var taken = 0
            // The box test written out on the coordinates: this loop runs over every edge of
            // the ring on every pointer event, and building a curve and a rectangle per edge
            // to reject almost all of them was most of the cost of a large contour (IM-088).
            // It is inclusive at the boundary, so it accepts at least what the rectangle test
            // accepted; every target an edge produces is filtered by its true distance anyway.
            for i in 0..<edgeCount {
                let start = points[i]
                let end = points[(i + 1) % points.count]
                if focus.x < Swift.min(start.x, end.x) - radius { continue }
                if focus.x > Swift.max(start.x, end.x) + radius { continue }
                if focus.y < Swift.min(start.y, end.y) - radius { continue }
                if focus.y > Swift.max(start.y, end.y) + radius { continue }
                result.append(
                    SnapLocalCurve(ordinal: i, curve: .line(SegmentGeometry(start: start, end: end)))
                )
                taken += 1
                if taken >= vertexLimit { break }
            }
            return result

        case .cubicCurve(let start, let c1, let c2, let end):
            return single(.cubic(p0: start, p1: c1, p2: c2, p3: end))

        case .quadraticCurve(let start, let control, let end):
            let (p0, p1, p2, p3) = SnapCurveMath.elevate(start, control, end)
            return single(.cubic(p0: p0, p1: p1, p2: p2, p3: p3))

        case .rectangle(let rect):
            let r = rect.standardized
            let corners = [
                PDFPoint(x: r.minX, y: r.minY),
                PDFPoint(x: r.maxX, y: r.minY),
                PDFPoint(x: r.maxX, y: r.maxY),
                PDFPoint(x: r.minX, y: r.maxY)
            ]
            var result: [SnapLocalCurve] = []
            for i in 0..<4 {
                let curve = SnapCurve.line(
                    SegmentGeometry(start: corners[i], end: corners[(i + 1) % 4])
                )
                if isNear(curve) { result.append(SnapLocalCurve(ordinal: i, curve: curve)) }
            }
            return result

        case .circle(let c):
            return single(.circle(c))

        case .ellipticalArc(let a):
            return single(.arc(a))
        }
    }
}

/// One curve of a primitive's decomposition, with the ordinal that identifies it within the
/// primitive across queries.
///
/// The ordinal is the edge index of a polyline or rectangle and `0` for a segment, cubic,
/// circle or arc. It is what a cursor-following candidate is keyed by: the *position* in the
/// decomposed array is not stable, because only the edges near the cursor are decomposed and
/// that set changes as the cursor moves (CR-38).
public struct SnapLocalCurve: Sendable, Hashable {
    public let ordinal: Int
    public let curve: SnapCurve

    public init(ordinal: Int, curve: SnapCurve) {
        self.ordinal = ordinal
        self.curve = curve
    }
}
