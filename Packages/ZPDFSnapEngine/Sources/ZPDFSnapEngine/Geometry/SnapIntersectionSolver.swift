import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Intersections between two elementary curves.
///
/// This is the expensive derived target and the reason the engine never precomputes anything:
/// intersections are quadratic in the number of primitives, so they are solved only for the
/// small set of curves that is already inside the query radius.
///
/// Three rules apply to every pair (`QUALITY_BAR` S3, S4, S5):
///
/// - a well-conditioned crossing (>= 5 degrees) must land within `1e-9` page points of the
///   closed-form point, so every result is Newton-polished against both curves;
/// - a shallow crossing ([0.5, 5) degrees) is genuinely ill-conditioned, so the guarantee is
///   weakened to "within `1e-7` of both curves" rather than "near a particular point";
/// - below 0.5 degrees, and for exactly parallel curves, **no candidate is emitted at all**. An
///   arbitrary point 800 page points away is a failure even when it is the true intersection.
public enum SnapIntersectionSolver {

    /// One intersection, with the crossing angle that produced it.
    public struct Intersection: Sendable, Hashable {
        public let point: PDFPoint
        /// Radians in `(0, pi/2]`: the acute angle between the two tangents.
        public let crossingAngle: Double
    }

    /// Every intersection of `a` and `b` that lies within `radius` of `focus`.
    ///
    /// Results are returned in ascending `(x, y)` order so the caller never has to rely on the
    /// order the solver happened to find them in.
    public static func intersections(
        _ a: SnapCurve,
        _ b: SnapCurve,
        near focus: PDFPoint,
        within radius: Double
    ) -> [Intersection] {
        guard let boxA = a.bounds, let boxB = b.bounds else { return [] }
        // `PDFRect.insetBy` grows on a positive amount; the epsilon keeps two curves that
        // touch exactly at a shared bounding-box edge from being rejected outright.
        guard boxA.insetBy(1e-9).intersects(boxB.insetBy(1e-9)) else { return [] }

        let raw: [PDFPoint]
        switch (a, b) {
        case (.line(let s1), .line(let s2)):
            raw = lineLine(s1, s2)
        case (.line(let s), .circle(let c)), (.circle(let c), .line(let s)):
            raw = lineCircle(s, center: c.center, radius: c.radius, filter: { _ in true })
        case (.line(let s), .arc(let arc)), (.arc(let arc), .line(let s)):
            raw = lineCircle(s, center: arc.center, radius: arc.radius) {
                SnapCurveMath.arcContains(arc, angle: $0)
            }
        case (.circle(let c1), .circle(let c2)):
            raw = circleCircle(c1.center, c1.radius, c2.center, c2.radius)
        case (.circle(let c), .arc(let arc)), (.arc(let arc), .circle(let c)):
            raw = circleCircle(c.center, c.radius, arc.center, arc.radius)
                .filter { SnapCurveMath.arcContains(arc, angle: PDFVector(from: arc.center, to: $0).angle) }
        case (.arc(let a1), .arc(let a2)):
            raw = circleCircle(a1.center, a1.radius, a2.center, a2.radius)
                .filter {
                    SnapCurveMath.arcContains(a1, angle: PDFVector(from: a1.center, to: $0).angle)
                        && SnapCurveMath.arcContains(a2, angle: PDFVector(from: a2.center, to: $0).angle)
                }
        case (.line(let s), .cubic(let p0, let p1, let p2, let p3)),
             (.cubic(let p0, let p1, let p2, let p3), .line(let s)):
            raw = lineCubic(s, p0, p1, p2, p3)
        case (.line(let s), .ellipseArc(let e)), (.ellipseArc(let e), .line(let s)):
            raw = lineEllipse(s, e)
        case (.circle, .cubic), (.arc, .cubic),
             (.circle, .ellipseArc), (.arc, .ellipseArc), (.cubic, .ellipseArc):
            // Walk the short curve — the cubic, or the ellipse quarter — and measure against
            // the other. Walking the circle measured every sample against the cubic through a
            // nearest-point solve — 25 samples and a Newton each — at every one of 64 steps
            // and every bisection step (IM-090). Against an ellipse quarter it was worse
            // (V-083): the circle's 64 steps are 49 pt apart at R = 500, so two crossings
            // 11 pt apart fell in one step and neither was found, and the quarter's nearest
            // point clamps to its ends, so the circle's crossings of the end tangents came
            // back as sign changes that each cost a full bisection. The quarter spans at
            // most a quarter turn, so its 64 steps isolate every crossing, and a circle's or
            // arc's signed distance is closed form. A cubic against a quarter walks the
            // quarter too, so the answer never depends on which participant is nearer the
            // cursor. `refine` treats its two curves symmetrically.
            raw = numeric(b, a)
        default:
            // cubic x cubic, cubic x circle, cubic x arc, quarter x quarter: no closed form,
            // so subdivide the parameter domain to isolate the roots and refine each with a
            // 2D Newton.
            raw = numeric(a, b)
        }

        var result: [Intersection] = []
        for point in raw {
            guard point.isFinite, point.distance(to: focus) <= radius else { continue }
            guard let refined = refine(point, on: a, and: b) else { continue }
            guard refined.point.distance(to: focus) <= radius else { continue }
            result.append(refined)
        }
        result.sort {
            $0.point.x != $1.point.x ? $0.point.x < $1.point.x : $0.point.y < $1.point.y
        }
        return dedupe(result)
    }

    // MARK: - Closed forms

    private static func lineLine(_ s1: SegmentGeometry, _ s2: SegmentGeometry) -> [PDFPoint] {
        let d1 = PDFVector(from: s1.start, to: s1.end)
        let d2 = PDFVector(from: s2.start, to: s2.end)
        let m1 = d1.magnitude
        let m2 = d2.magnitude
        guard m1 > 1e-300, m2 > 1e-300 else { return [] }

        // The normalised cross product is exactly `sin` of the crossing angle, so this single
        // test implements S5's parallel refusal without a separate special case for exactly
        // parallel input.
        let cross = d1.cross(d2)
        let sine = Swift.abs(cross) / (m1 * m2)
        guard sine >= SnapCurveMath.minimumCrossingSine else { return [] }

        let delta = PDFVector(from: s1.start, to: s2.start)
        let t = delta.cross(d2) / cross
        let u = delta.cross(d1) / cross
        guard t >= -1e-12, t <= 1 + 1e-12, u >= -1e-12, u <= 1 + 1e-12 else { return [] }
        return [PDFPoint(x: s1.start.x + t * d1.dx, y: s1.start.y + t * d1.dy)]
    }

    private static func lineCircle(
        _ s: SegmentGeometry,
        center: PDFPoint,
        radius: Double,
        filter: (Double) -> Bool
    ) -> [PDFPoint] {
        let d = PDFVector(from: s.start, to: s.end)
        let f = PDFVector(from: center, to: s.start)
        let a = d.squaredMagnitude
        guard a > 1e-300, radius > 0 else { return [] }
        let b = 2 * f.dot(d)
        let c = f.squaredMagnitude - radius * radius
        return SnapCurveMath.quadraticRoots(a, b, c)
            .filter { $0 >= -1e-12 && $0 <= 1 + 1e-12 }
            .map { PDFPoint(x: s.start.x + $0 * d.dx, y: s.start.y + $0 * d.dy) }
            .filter { filter(PDFVector(from: center, to: $0).angle) }
    }

    private static func circleCircle(
        _ c1: PDFPoint, _ r1: Double, _ c2: PDFPoint, _ r2: Double
    ) -> [PDFPoint] {
        let delta = PDFVector(from: c1, to: c2)
        let d = delta.magnitude
        guard d > 1e-12, r1 > 0, r2 > 0 else { return [] }
        guard d <= r1 + r2, d >= Swift.abs(r1 - r2) else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let hSquared = r1 * r1 - a * a
        guard hSquared >= 0 else { return [] }
        let h = hSquared.squareRoot()
        let base = PDFPoint(x: c1.x + a * delta.dx / d, y: c1.y + a * delta.dy / d)
        if h <= 1e-15 { return [base] }
        let offset = PDFVector(dx: -delta.dy / d * h, dy: delta.dx / d * h)
        return [
            PDFPoint(x: base.x + offset.dx, y: base.y + offset.dy),
            PDFPoint(x: base.x - offset.dx, y: base.y - offset.dy)
        ]
    }

    private static func lineCubic(
        _ s: SegmentGeometry,
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint
    ) -> [PDFPoint] {
        let d = PDFVector(from: s.start, to: s.end)
        guard d.magnitude > 1e-300 else { return [] }
        // Implicit line form n . (X - start) = 0, with n the (unnormalised) normal. Substituting
        // the Bézier gives a cubic in t whose coefficients are the Bernstein values projected
        // onto n, which is the numerically well-behaved formulation.
        let nx = -d.dy
        let ny = d.dx
        func project(_ p: PDFPoint) -> Double {
            nx * (p.x - s.start.x) + ny * (p.y - s.start.y)
        }
        let f0 = project(p0)
        let f1 = project(p1)
        let f2 = project(p2)
        let f3 = project(p3)

        let a = -f0 + 3 * f1 - 3 * f2 + f3
        let b = 3 * f0 - 6 * f1 + 3 * f2
        let c = -3 * f0 + 3 * f1
        let dd = f0

        return SnapCurveMath.cubicRoots(a, b, c, dd)
            .filter { $0 >= -1e-12 && $0 <= 1 + 1e-12 }
            .map { SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: Swift.min(1, Swift.max(0, $0))) }
            .filter { point in
                let squared = d.squaredMagnitude
                let u = ((point.x - s.start.x) * d.dx + (point.y - s.start.y) * d.dy) / squared
                return u >= -1e-9 && u <= 1 + 1e-9
            }
    }

    /// A segment and an ellipse quarter (U-089), closed form: with `n` the segment's normal,
    /// `n·(centre + u·cos θ + v·sin θ − start) = 0` is `A·cos θ + B·sin θ = −D`.
    private static func lineEllipse(_ s: SegmentGeometry, _ e: SnapEllipseArc) -> [PDFPoint] {
        let d = PDFVector(from: s.start, to: s.end)
        let squared = d.squaredMagnitude
        guard squared > 1e-300 else { return [] }
        let n = d.perpendicular
        let a = n.dot(e.u), b = n.dot(e.v)
        let offset = n.dot(PDFVector(from: s.start, to: e.centre))
        let r = (a * a + b * b).squareRoot()
        guard r > 0, Swift.abs(offset) <= r else { return [] }
        let phi = Foundation.atan2(b, a)
        let opening = Foundation.acos(Swift.max(-1, Swift.min(1, -offset / r)))
        var points: [PDFPoint] = []
        for candidate in [phi - opening, phi + opening] {
            var theta = candidate.truncatingRemainder(dividingBy: 2 * Double.pi)
            if theta < -1e-12 { theta += 2 * Double.pi }
            guard e.contains(parameter: theta) else { continue }
            let point = e.point(at: Swift.min(SnapEllipseArc.quarter, Swift.max(0, theta)))
            let along = ((point.x - s.start.x) * d.dx + (point.y - s.start.y) * d.dy) / squared
            if along >= -1e-9 && along <= 1 + 1e-9 { points.append(point) }
        }
        return points
    }

    // MARK: - Numeric fallback

    /// Isolates roots by walking a fixed grid over one curve's parameter domain, testing the
    /// signed distance to the other, and refining each sign change.
    ///
    /// The grid is uniform and fixed at 64 steps for the same reason the sampling in
    /// ``SnapCurveMath`` is: an adaptive count would make the answer depend on the coordinate
    /// magnitudes of the page.
    private static func numeric(_ a: SnapCurve, _ b: SnapCurve) -> [PDFPoint] {
        let steps = 64
        guard let domain = parameterDomain(a) else { return [] }
        var seeds: [PDFPoint] = []
        var previousT = domain.lowerBound
        var previousSigned = signedDistance(point(on: a, at: previousT), to: b)

        for i in 1...steps {
            let t = domain.lowerBound
                + (domain.upperBound - domain.lowerBound) * Double(i) / Double(steps)
            let p = point(on: a, at: t)
            let signed = signedDistance(p, to: b)
            if signed == 0 {
                seeds.append(p)
            } else if let previous = previousSigned, let current = signed,
                      (previous < 0) != (current < 0) {
                var lo = previousT
                var hi = t
                for _ in 0..<80 {
                    let mid = 0.5 * (lo + hi)
                    // The bracket cannot shrink below one ulp; bisecting on past that point
                    // re-evaluated the same parameter for the remaining iterations. `refine`
                    // polishes the seed onto both curves afterwards (IM-090).
                    guard mid > lo, mid < hi else { break }
                    guard let value = signedDistance(point(on: a, at: mid), to: b) else { break }
                    if (value < 0) == (previous < 0) { lo = mid } else { hi = mid }
                }
                seeds.append(point(on: a, at: 0.5 * (lo + hi)))
            }
            previousT = t
            previousSigned = signed
        }
        return seeds
    }

    private static func parameterDomain(_ curve: SnapCurve) -> ClosedRange<Double>? {
        switch curve {
        case .line, .cubic: 0...1
        case .ellipseArc: 0...SnapEllipseArc.quarter
        case .circle: 0...(2 * Double.pi)
        case .arc(let a):
            a.sweepAngle >= 0
                ? a.startAngle...(a.startAngle + a.sweepAngle)
                : (a.startAngle + a.sweepAngle)...a.startAngle
        }
    }

    private static func point(on curve: SnapCurve, at t: Double) -> PDFPoint {
        switch curve {
        case .line(let s): SegmentMath.point(on: s, at: t)
        case .cubic(let p0, let p1, let p2, let p3):
            SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t)
        case .circle(let c):
            PDFPoint(x: c.center.x + c.radius * Foundation.cos(t),
                     y: c.center.y + c.radius * Foundation.sin(t))
        case .arc(let a):
            PDFPoint(x: a.center.x + a.radius * Foundation.cos(t),
                     y: a.center.y + a.radius * Foundation.sin(t))
        case .ellipseArc(let e):
            e.point(at: t)
        }
    }

    /// A signed distance from `p` to `curve`, so a sign change brackets a crossing.
    ///
    /// For a line the sign is the side of the line; for a circle or arc it is inside/outside;
    /// for a cubic it is the side of the tangent at the nearest point, which is a valid sign
    /// function everywhere the curve is not self-intersecting inside the radius.
    private static func signedDistance(_ p: PDFPoint, to curve: SnapCurve) -> Double? {
        switch curve {
        case .line(let s):
            return try? SegmentMath.signedDistance(from: p, toLineThrough: s.start, and: s.end)
        case .circle(let c):
            return p.distance(to: c.center) - c.radius
        case .arc(let a):
            return p.distance(to: a.center) - a.radius
        case .cubic(let p0, let p1, let p2, let p3):
            let t = SnapCurveMath.nearestParameterOnCubic(p0, p1, p2, p3, to: p)
            let base = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t)
            let tangent = SnapCurveMath.cubicDerivative(p0, p1, p2, p3, at: t)
            let magnitude = tangent.magnitude
            guard magnitude > 1e-300 else { return nil }
            let delta = PDFVector(from: base, to: p)
            return tangent.cross(delta) / magnitude
        case .ellipseArc(let e):
            let nearest = e.nearest(to: p)
            let tangent = e.derivative(at: nearest.parameter)
            let magnitude = tangent.magnitude
            guard magnitude > 1e-300 else { return nil }
            return tangent.cross(PDFVector(from: nearest.point, to: p)) / magnitude
        }
    }

    // MARK: - Refinement and conditioning

    /// Polishes a seed point onto both curves and measures the crossing angle.
    ///
    /// Returns `nil` when the crossing is shallower than S5's floor, when the point falls
    /// outside either curve's own parameter domain, or when the polish does not converge to
    /// S4's `1e-7` of both curves — refusing is always better than emitting a point that is on
    /// neither curve.
    private static func refine(
        _ seed: PDFPoint, on a: SnapCurve, and b: SnapCurve
    ) -> Intersection? {
        var point = seed
        for _ in 0..<32 {
            guard let na = a.nearestPoint(to: point), let nb = b.nearestPoint(to: point) else {
                return nil
            }
            let next = PDFPoint(
                x: 0.5 * (na.point.x + nb.point.x),
                y: 0.5 * (na.point.y + nb.point.y)
            )
            let movement = next.distance(to: point)
            point = next
            if movement <= 1e-16 { break }
        }

        guard let na = a.nearestPoint(to: point), let nb = b.nearestPoint(to: point) else {
            return nil
        }
        guard a.contains(parameter: na.parameter), b.contains(parameter: nb.parameter) else {
            return nil
        }
        // S4: the returned point must be within 1e-7 page points of *both* primitives. An
        // averaging iteration that stalls between two nearly parallel curves fails this and is
        // discarded rather than reported.
        guard na.distance <= 1e-7, nb.distance <= 1e-7 else { return nil }

        guard let ta = a.tangent(at: na.parameter), let tb = b.tangent(at: nb.parameter) else {
            return nil
        }
        let sine = Swift.abs(ta.cross(tb))
        guard sine >= SnapCurveMath.minimumCrossingSine else { return nil }

        return Intersection(
            point: PDFPoint(
                x: 0.5 * (na.point.x + nb.point.x),
                y: 0.5 * (na.point.y + nb.point.y)
            ),
            crossingAngle: Foundation.asin(Swift.min(1, sine))
        )
    }

    private static func dedupe(_ sorted: [Intersection]) -> [Intersection] {
        var result: [Intersection] = []
        for item in sorted {
            if let last = result.last, last.point.distance(to: item.point) <= 1e-9 { continue }
            result.append(item)
        }
        return result
    }
}
