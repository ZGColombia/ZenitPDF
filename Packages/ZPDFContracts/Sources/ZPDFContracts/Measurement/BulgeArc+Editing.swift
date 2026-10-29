import Foundation

// MARK: - Arc segments: points on an arc, splitting one, and drawing one (NL-MEASURE-05, ADR-0030 §5.6)
//
// The first slice gave a bulged edge its exact circle (`BulgeArc.arc`), its exact segment area and a
// flattening for the screen. These are the operations the edits and the export need on top of that:
// a point at a fraction of the sweep, the nearest point on the arc, the two bulges of an arc cut at a
// point, and the arc as cubic Béziers for a vector drawing. None of them changes a stored value; every
// quantity is still measured from the bulge itself.

extension BulgeArc {

    /// The bulge of an arc that sweeps `sweep` radians: `tan(θ/4)`, signed like the sweep.
    public static func bulge(forSweep sweep: Double) -> Double {
        Foundation.tan(sweep / 4)
    }

    /// The bulge of the arc from `a` to `b` through `p`: `0` when `p` is on the chord, `nil`
    /// when `p` is on an end or the chord is degenerate.
    ///
    /// The one rule for an arc given by a point on it: the drawing tools' through point and
    /// Curve an Edge (`MarkupTopologyEditing.bulge(from:to:through:)`, which reads this), and the
    /// arc a three-point Arc Length is drawn and snapped as (``MarkupRecord/drawnPointChain``).
    public static func bulge(from a: PDFPoint, to b: PDFPoint, through p: PDFPoint) -> Double? {
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = (dx * dx + dy * dy).squareRoot()
        guard chord > 0, p.distance(to: a) > 0, p.distance(to: b) > 0 else { return nil }
        // Signed distance of p from the chord, positive on the edge's left.
        let h = (dx * (p.y - a.y) - dy * (p.x - a.x)) / chord
        guard Swift.abs(h) > 1e-12 * chord else { return 0 }
        // The included angle at p subtends the chord: the arc a→p→b turns through
        // θ = 2·(π − ∠apb), with the sign of the turn — counter-clockwise (positive) when p
        // is on the right of the edge, the bulge side of a counter-clockwise arc.
        let ux = a.x - p.x, uy = a.y - p.y, vx = b.x - p.x, vy = b.y - p.y
        let angleAtP = Foundation.atan2(Swift.abs(ux * vy - uy * vx), ux * vx + uy * vy)
        let theta = 2 * (Double.pi - angleAtP)
        let magnitude = Foundation.tan(theta / 4)
        return h < 0 ? magnitude : -magnitude
    }

    /// The point at `fraction` (0 at `start`, 1 at `end`) of the edge from `start` to `end`: along
    /// the sweep for an arc — equal fractions are equal arc lengths — and along the chord for a
    /// straight edge. The two ends are returned exactly.
    public static func point(from start: PDFPoint, to end: PDFPoint, bulge: Double, at fraction: Double) -> PDFPoint {
        if fraction <= 0 { return start }
        if fraction >= 1 { return end }
        guard let arc = arc(from: start, to: end, bulge: bulge) else {
            return PDFPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }
        let angle = arc.startAngle + arc.sweepAngle * fraction
        return PDFPoint(x: arc.center.x + arc.radius * Foundation.cos(angle), y: arc.center.y + arc.radius * Foundation.sin(angle))
    }

    /// The midpoint of the edge by length: the arc's midpoint for an arc, the chord's for a straight edge.
    public static func midpoint(from start: PDFPoint, to end: PDFPoint, bulge: Double) -> PDFPoint {
        point(from: start, to: end, bulge: bulge, at: 0.5)
    }

    /// The fraction of the sweep at which `angle` (radians, about the centre) lies on `arc`, or `nil`
    /// when the angle is outside the sweep.
    public static func fraction(of angle: Double, on arc: ArcGeometry) -> Double? {
        let sweep = arc.sweepAngle
        guard sweep != 0, sweep.isFinite else { return nil }
        let turn = 2 * Double.pi
        var delta = (angle - arc.startAngle) * (sweep > 0 ? 1 : -1)
        delta = delta.truncatingRemainder(dividingBy: turn)
        if delta < 0 { delta += turn }
        let magnitude = Swift.abs(sweep)
        if delta <= magnitude { return delta / magnitude }
        // Just short of a full turn back to the start is the start itself, not "outside".
        if turn - delta < 1e-12 { return 0 }
        return nil
    }

    /// The point of the edge nearest `probe`, its fraction along the edge, and its distance.
    ///
    /// On an arc the nearest point is the radial projection when that falls inside the sweep, and
    /// otherwise the nearer end.
    public static func nearestPoint(
        to probe: PDFPoint,
        from start: PDFPoint,
        to end: PDFPoint,
        bulge: Double
    ) -> (point: PDFPoint, fraction: Double, distance: Double) {
        guard let arc = arc(from: start, to: end, bulge: bulge) else {
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return (start, 0, start.distance(to: probe)) }
            let t = Swift.max(0, Swift.min(1, ((probe.x - start.x) * dx + (probe.y - start.y) * dy) / lengthSquared))
            let point = PDFPoint(x: start.x + t * dx, y: start.y + t * dy)
            return (point, t, point.distance(to: probe))
        }
        let vx = probe.x - arc.center.x, vy = probe.y - arc.center.y
        let magnitude = (vx * vx + vy * vy).squareRoot()
        if magnitude > 0, let f = fraction(of: Foundation.atan2(vy, vx), on: arc) {
            let point = PDFPoint(x: arc.center.x + vx / magnitude * arc.radius, y: arc.center.y + vy / magnitude * arc.radius)
            return (point, f, point.distance(to: probe))
        }
        let toStart = start.distance(to: probe), toEnd = end.distance(to: probe)
        return toStart <= toEnd ? (start, 0, toStart) : (end, 1, toEnd)
    }

    /// The edge cut at `fraction` of its sweep: the cut point and the bulges of the two pieces.
    ///
    /// Hand geometry: an arc of sweep θ cut at fraction f gives pieces of sweep fθ and (1 − f)θ on
    /// the same circle, so the bulges are `tan(fθ/4)` and `tan((1 − f)θ/4)`, both with the sign of
    /// the original. A straight edge cuts into two straight ones. `nil` for a fraction that is not
    /// strictly inside the edge.
    public static func split(
        from start: PDFPoint,
        to end: PDFPoint,
        bulge: Double,
        at fraction: Double
    ) -> (point: PDFPoint, firstBulge: Double, secondBulge: Double)? {
        guard fraction > 0, fraction < 1, fraction.isFinite else { return nil }
        let point = point(from: start, to: end, bulge: bulge, at: fraction)
        guard let arc = arc(from: start, to: end, bulge: bulge) else { return (point, 0, 0) }
        return (point, Self.bulge(forSweep: arc.sweepAngle * fraction), Self.bulge(forSweep: arc.sweepAngle * (1 - fraction)))
    }

    /// Whether two consecutive bulged edges `a → b` (bulge `first`) and `b → c` (bulge `second`) lie
    /// on one circle and turn the same way, so they can be joined into one arc `a → c` without
    /// changing the curve. Returns the joined bulge, or `nil` when they cannot be joined exactly.
    ///
    /// `tolerance` is relative to the radius: the two centres and radii must agree to it.
    public static func joined(
        _ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint,
        first: Double, second: Double,
        tolerance: Double = 1e-9
    ) -> Double? {
        guard let arc1 = arc(from: a, to: b, bulge: first), let arc2 = arc(from: b, to: c, bulge: second),
              (first > 0) == (second > 0) else { return nil }
        let scale = Swift.max(arc1.radius, arc2.radius)
        guard Swift.abs(arc1.radius - arc2.radius) <= tolerance * scale,
              arc1.center.distance(to: arc2.center) <= tolerance * scale else { return nil }
        let sweep = arc1.sweepAngle + arc2.sweepAngle
        // A joined arc must stay a single arc: a full turn or more has no bulge.
        guard Swift.abs(sweep) < 2 * Double.pi - 1e-9 else { return nil }
        return bulge(forSweep: sweep)
    }

    // MARK: Drawing as cubic Béziers

    /// One cubic Bézier piece: two control points and the end point (the start is the previous end).
    public struct CubicPiece: Hashable, Sendable {
        public var control1: PDFPoint
        public var control2: PDFPoint
        public var end: PDFPoint

        public init(control1: PDFPoint, control2: PDFPoint, end: PDFPoint) {
            self.control1 = control1
            self.control2 = control2
            self.end = end
        }
    }

    /// The default drawing tolerance of the Bézier form, in page points: the same hundredth of a
    /// point the canvas flattens arcs to (ADR-0030 §5.2 item 5).
    public static let bezierDrawingTolerance = 0.01

    /// The largest distance from the true circle, as a fraction of the radius, of the standard cubic
    /// that spans `sweep` radians (handles `k = 4/3 · tan(φ/4)` along the end tangents), measured by
    /// sampling the cubic. It grows like φ⁶: about `2.7e-4` for a quarter turn.
    public static func cubicRelativeError(sweep: Double) -> Double {
        let phi = Swift.abs(sweep)
        guard phi > 0, phi.isFinite else { return 0 }
        let k = 4.0 / 3.0 * Foundation.tan(phi / 4)
        // Unit circle, piece from angle 0 to φ.
        let p0 = (x: 1.0, y: 0.0)
        let p1 = (x: 1.0, y: k)
        let p3 = (x: Foundation.cos(phi), y: Foundation.sin(phi))
        let p2 = (x: p3.x + k * Foundation.sin(phi), y: p3.y - k * Foundation.cos(phi))
        var worst = 0.0
        let samples = 64
        for step in 1..<samples {
            let t = Double(step) / Double(samples)
            let u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            worst = Swift.max(worst, Swift.abs((x * x + y * y).squareRoot() - 1))
        }
        return worst
    }

    /// The edge as cubic Béziers for a vector drawing, never for a quantity.
    ///
    /// The arc is cut into equal pieces of at most a quarter turn, and into more while one piece
    /// would stray more than `tolerance` page points from the circle. Each piece starts and ends on
    /// the circle exactly, with its handles along the tangents at length `k·r`, `k = 4/3 · tan(φ/4)`.
    /// A straight edge is one piece with its handles at the thirds, which draws the same line.
    public static func cubicPieces(
        from start: PDFPoint,
        to end: PDFPoint,
        bulge: Double,
        tolerance: Double = bezierDrawingTolerance
    ) -> [CubicPiece] {
        guard let arc = arc(from: start, to: end, bulge: bulge) else {
            return [CubicPiece(
                control1: PDFPoint(x: start.x + (end.x - start.x) / 3, y: start.y + (end.y - start.y) / 3),
                control2: PDFPoint(x: start.x + (end.x - start.x) * 2 / 3, y: start.y + (end.y - start.y) * 2 / 3),
                end: end
            )]
        }
        let sweep = arc.sweepAngle
        var count = Swift.max(1, Int((Swift.abs(sweep) / (Double.pi / 2)).rounded(.up)))
        let limit = tolerance > 0 && tolerance.isFinite ? tolerance : bezierDrawingTolerance
        while count < 256, arc.radius * cubicRelativeError(sweep: sweep / Double(count)) > limit {
            count *= 2
        }
        let phi = sweep / Double(count)
        let k = 4.0 / 3.0 * Foundation.tan(phi / 4)
        var pieces: [CubicPiece] = []
        pieces.reserveCapacity(count)
        var angle = arc.startAngle
        var from = start
        for index in 0..<count {
            let next = angle + phi
            let to = index == count - 1 ? end : PDFPoint(
                x: arc.center.x + arc.radius * Foundation.cos(next),
                y: arc.center.y + arc.radius * Foundation.sin(next)
            )
            // Tangent at an angle a, in the direction of increasing angle: (−sin a, cos a).
            let c1 = PDFPoint(
                x: from.x - k * arc.radius * Foundation.sin(angle),
                y: from.y + k * arc.radius * Foundation.cos(angle)
            )
            let c2 = PDFPoint(
                x: to.x + k * arc.radius * Foundation.sin(next),
                y: to.y - k * arc.radius * Foundation.cos(next)
            )
            pieces.append(CubicPiece(control1: c1, control2: c2, end: to))
            angle = next
            from = to
        }
        return pieces
    }
}

extension PolygonRing {

    /// The ring's edges with their bulges: `(start, end, bulge)`, the closing edge last for a closed
    /// ring. Consecutive duplicates are kept out, and a bulge that does not line up is `0`.
    public var bulgedEdges: [(start: PDFPoint, end: PDFPoint, bulge: Double)] {
        let bulges = validBulges
        let count = points.count
        guard count >= 2 else { return [] }
        let upper = isClosed ? count : count - 1
        var result: [(start: PDFPoint, end: PDFPoint, bulge: Double)] = []
        result.reserveCapacity(upper)
        for index in 0..<upper {
            let start = points[index], end = points[(index + 1) % count]
            guard start != end else { continue }
            result.append((start, end, bulges?[index] ?? 0))
        }
        return result
    }

}
