import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Curve mathematics the snap engine needs and `ZPDFGeometry` does not provide: cubic Bézier
/// evaluation, nearest point on a curve, tangency from a point, and the polynomial solvers the
/// intersection code is built on.
///
/// Everything here operates on curves as curves. Flattening exists in this package only for
/// R-tree bounds; a snap onto a cubic returns a point **on the cubic**, not on a chord
/// (`SNAP_CONTRACT` 13.4).
///
/// Numerical policy: every refinement is Newton with a bisection fallback, iterated to a
/// residual below `1e-15` or 64 iterations, whichever comes first. `QUALITY_BAR` S3 asks for
/// `1e-9` page points on a well-conditioned intersection, so the solver is deliberately run an
/// order of magnitude tighter than the acceptance threshold.
public enum SnapCurveMath {

    public static let newtonIterationLimit = 64
    public static let newtonResidual = 1e-15

    /// The crossing-angle floor of `QUALITY_BAR` S5, in radians. Below it, no intersection
    /// candidate is emitted at all: an arbitrary far-away point is a failure even when it is
    /// mathematically the true intersection of two almost-parallel lines.
    public static let minimumCrossingAngle = 0.5 * Double.pi / 180

    /// `sin` of the crossing-angle floor, precomputed because it is the quantity actually
    /// tested (a normalised cross product).
    public static let minimumCrossingSine = Foundation.sin(minimumCrossingAngle)

    // MARK: - Cubic Bézier

    public static func cubicPoint(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, at t: Double
    ) -> PDFPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return PDFPoint(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
        )
    }

    public static func cubicDerivative(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, at t: Double
    ) -> PDFVector {
        let u = 1 - t
        let a = 3 * u * u
        let b = 6 * u * t
        let c = 3 * t * t
        return PDFVector(
            dx: a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
            dy: a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y)
        )
    }

    public static func cubicSecondDerivative(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, at t: Double
    ) -> PDFVector {
        let u = 1 - t
        return PDFVector(
            dx: 6 * u * (p2.x - 2 * p1.x + p0.x) + 6 * t * (p3.x - 2 * p2.x + p1.x),
            dy: 6 * u * (p2.y - 2 * p1.y + p0.y) + 6 * t * (p3.y - 2 * p2.y + p1.y)
        )
    }

    /// A quadratic Bézier raised to the equivalent cubic, exactly.
    public static func elevate(
        _ q0: PDFPoint, _ q1: PDFPoint, _ q2: PDFPoint
    ) -> (PDFPoint, PDFPoint, PDFPoint, PDFPoint) {
        let c1 = PDFPoint(
            x: q0.x + (2.0 / 3.0) * (q1.x - q0.x),
            y: q0.y + (2.0 / 3.0) * (q1.y - q0.y)
        )
        let c2 = PDFPoint(
            x: q2.x + (2.0 / 3.0) * (q1.x - q2.x),
            y: q2.y + (2.0 / 3.0) * (q1.y - q2.y)
        )
        return (q0, c1, c2, q2)
    }

    /// The parameter of the point on the cubic nearest to `q`.
    ///
    /// Coarse sampling picks the basin, then Newton on `d/dt |B(t) - q|^2` converges inside it.
    /// The sample count is fixed at 24, not adaptive: an adaptive count would make the answer
    /// depend on the curve's size in page points, and therefore on the zoom at which the page
    /// was authored, which is exactly the kind of hidden state `QUALITY_BAR` 3.4 forbids.
    ///
    /// Newton on `f = (B - q) . B'` finds *stationary* points of the distance, and where `f'`
    /// is negative it walks toward a distance maximum or off the end of the curve. So the
    /// iteration is confined to the bracket between the best sample's neighbours, stops when
    /// `f'` is not positive, and its answer is only returned when it is no farther than the
    /// best sample; otherwise the stationary points of the bracket are located by sign-change
    /// bisection and the nearest of everything evaluated is returned. The result is never
    /// farther from `q` than the sampled minimum (BH-216).
    public static func nearestParameterOnCubic(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, to q: PDFPoint
    ) -> Double {
        let sampleCount = 24
        var bestT = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0...sampleCount {
            let t = Double(i) / Double(sampleCount)
            let d = cubicPoint(p0, p1, p2, p3, at: t).distance(to: q)
            if d < bestDistance {
                bestDistance = d
                bestT = t
            }
        }

        let step = 1 / Double(sampleCount)
        let lower = Swift.max(0, bestT - step)
        let upper = Swift.min(1, bestT + step)

        /// `d/dt |B(t) - q|^2 / 2` and its derivative.
        func slope(at t: Double) -> (f: Double, df: Double) {
            let point = cubicPoint(p0, p1, p2, p3, at: t)
            let d1 = cubicDerivative(p0, p1, p2, p3, at: t)
            let d2 = cubicSecondDerivative(p0, p1, p2, p3, at: t)
            let dx = point.x - q.x
            let dy = point.y - q.y
            let f = dx * d1.dx + dy * d1.dy
            let df = d1.dx * d1.dx + d1.dy * d1.dy + dx * d2.dx + dy * d2.dy
            return (f, df)
        }

        var t = bestT
        var converged = false
        for _ in 0..<newtonIterationLimit {
            let (f, df) = slope(at: t)
            // A non-positive `df` means the distance is locally concave: a Newton step would
            // climb toward a maximum, so the bracketed fallback below takes over instead.
            guard df > 1e-300 else { break }
            let next = Swift.min(upper, Swift.max(lower, t - f / df))
            if Swift.abs(next - t) <= newtonResidual { t = next; converged = true; break }
            t = next
        }
        let newtonDistance = cubicPoint(p0, p1, p2, p3, at: t).distance(to: q)
        if converged, newtonDistance <= bestDistance { return t }

        // Newton did not settle, or settled somewhere worse than the sample it started from.
        // Locate every stationary point in the bracket by sign change instead and keep the
        // nearest of the sample, Newton's result and those.
        var resultT = bestT
        var resultDistance = bestDistance
        if newtonDistance < resultDistance {
            resultT = t
            resultDistance = newtonDistance
        }
        for root in roots(of: { slope(at: $0).f }, over: lower...upper, sampleCount: 8) {
            let d = cubicPoint(p0, p1, p2, p3, at: root).distance(to: q)
            if d < resultDistance {
                resultDistance = d
                resultT = root
            }
        }
        return resultT
    }

    /// The parameter of the point halfway along the cubic by **arc length** — the midpoint a
    /// user means when snapping to the middle of a curved wall.
    ///
    /// The parametric `t = 0.5` is not it: for `p0 = p1 = (0, 0)`, `p2 = (0, 100)`,
    /// `p3 = (100, 100)` it lies 27 page points from the true midpoint of a 159-point curve, and
    /// it was emitted with the midpoint label (BH-663).
    ///
    /// The length is integrated with 8-point Gauss-Legendre over fixed pieces: sixteen uniform
    /// ones, split further at every interior stationary point of the speed `|B'(t)|` (roots of
    /// `B' . B'' = 0`), so a cusp or a sharp bend, where the speed has a kink or a narrow dip,
    /// falls on a piece boundary instead of inside a quadrature interval. The half-length
    /// parameter is then found by safeguarded Newton inside the piece that contains it. Every
    /// step is fixed, so the answer is a function of the control points alone.
    public static func arcLengthMidpointParameter(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint
    ) -> Double {
        func speed(_ t: Double) -> Double { cubicDerivative(p0, p1, p2, p3, at: t).magnitude }

        // Stationary points of |B'|^2 / 2: B' . B'' = 0, a cubic in t.
        let a = PDFVector(dx: p1.x - p0.x, dy: p1.y - p0.y)
        let b = PDFVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
        let c = PDFVector(dx: p3.x - p2.x, dy: p3.y - p2.y)
        // B'(t) = 3 (A t^2 + B t + C) with A = a - 2b + c, B = 2 (b - a), C = a.
        let qa = PDFVector(dx: a.dx - 2 * b.dx + c.dx, dy: a.dy - 2 * b.dy + c.dy)
        let qb = PDFVector(dx: 2 * (b.dx - a.dx), dy: 2 * (b.dy - a.dy))
        let qc = a
        // (A t^2 + B t + C) . (2 A t + B) = 2 A.A t^3 + 3 A.B t^2 + (B.B + 2 A.C) t + B.C
        let aa = qa.dot(qa)
        let ab = qa.dot(qb)
        let bb = qb.dot(qb)
        let ac = qa.dot(qc)
        let bc = qb.dot(qc)
        var breaks = (0...16).map { Double($0) / 16 }
        for root in cubicRoots(2 * aa, 3 * ab, bb + 2 * ac, bc) where root > 1e-9 && root < 1 - 1e-9 {
            breaks.append(root)
        }
        breaks.sort()

        func gauss(_ lo: Double, _ hi: Double) -> Double {
            let half = 0.5 * (hi - lo)
            let mid = 0.5 * (hi + lo)
            var sum = 0.0
            for (node, weight) in zip(Self.gaussNodes, Self.gaussWeights) {
                sum += weight * (speed(mid - half * node) + speed(mid + half * node))
            }
            return sum * half
        }

        var cumulative = [0.0]
        cumulative.reserveCapacity(breaks.count)
        for i in 1..<breaks.count {
            cumulative.append(cumulative[i - 1] + gauss(breaks[i - 1], breaks[i]))
        }
        let total = cumulative[cumulative.count - 1]
        guard total.isFinite, total > 0 else { return 0.5 }
        let target = 0.5 * total

        var piece = 1
        while piece < breaks.count - 1, cumulative[piece] < target { piece += 1 }
        var lo = breaks[piece - 1]
        var hi = breaks[piece]
        let base = cumulative[piece - 1]
        let pieceLength = cumulative[piece] - base
        var t = pieceLength > 0 ? lo + (hi - lo) * (target - base) / pieceLength : 0.5 * (lo + hi)
        let start = lo
        for _ in 0..<newtonIterationLimit {
            let f = base + gauss(start, t) - target
            if f == 0 { return t }
            if f < 0 { lo = t } else { hi = t }
            let v = speed(t)
            var next = v > 1e-300 ? t - f / v : 0.5 * (lo + hi)
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            if Swift.abs(next - t) <= newtonResidual { return next }
            t = next
        }
        return t
    }

    /// 8-point Gauss-Legendre: the positive nodes and their weights.
    static let gaussNodes: [Double] = [
        0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363
    ]
    static let gaussWeights: [Double] = [
        0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763
    ]

    /// Parameters at which the tangent to the cubic passes through `anchor`.
    ///
    /// Solves `(B(t) - anchor) x B'(t) = 0`, a quintic, by sign change over a fixed sampling
    /// followed by bisection and Newton. Roots are returned in ascending `t`.
    public static func tangentParametersOnCubic(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, from anchor: PDFPoint
    ) -> [Double] {
        func f(_ t: Double) -> Double {
            let b = cubicPoint(p0, p1, p2, p3, at: t)
            let d = cubicDerivative(p0, p1, p2, p3, at: t)
            return (b.x - anchor.x) * d.dy - (b.y - anchor.y) * d.dx
        }
        return roots(of: f, over: 0...1, sampleCount: 48)
    }

    // MARK: - Root finding

    /// Every sign-change root of a continuous function on `range`, bisected then Newton-refined
    /// by secant steps, in ascending order.
    ///
    /// Sampling is uniform and the count is fixed so the result depends only on the function,
    /// never on the magnitude of the coordinates or on how many events have been processed.
    public static func roots(
        of f: (Double) -> Double,
        over range: ClosedRange<Double>,
        sampleCount: Int
    ) -> [Double] {
        guard sampleCount >= 2 else { return [] }
        var result: [Double] = []
        let lower = range.lowerBound
        let span = range.upperBound - range.lowerBound
        var previousT = lower
        var previousValue = f(previousT)
        if previousValue == 0 { result.append(previousT) }

        for i in 1...sampleCount {
            let t = lower + span * Double(i) / Double(sampleCount)
            let value = f(t)
            if value == 0 {
                result.append(t)
            } else if (value < 0) != (previousValue < 0) {
                result.append(bisect(f, previousT, previousValue, t, value))
            }
            previousT = t
            previousValue = value
        }
        return result
    }

    private static func bisect(
        _ f: (Double) -> Double, _ a0: Double, _ fa0: Double, _ b0: Double, _ fb0: Double
    ) -> Double {
        var a = a0, b = b0, fa = fa0, fb = fb0
        for _ in 0..<newtonIterationLimit {
            // Illinois-regula-falsi: superlinear, and it cannot leave the bracket, which a raw
            // Newton step on a quintic can.
            let denominator = fb - fa
            let mid: Double
            if Swift.abs(denominator) > 1e-300 {
                let candidate = b - fb * (b - a) / denominator
                mid = (candidate > Swift.min(a, b) && candidate < Swift.max(a, b))
                    ? candidate
                    : 0.5 * (a + b)
            } else {
                mid = 0.5 * (a + b)
            }
            let fm = f(mid)
            if fm == 0 || Swift.abs(b - a) <= newtonResidual { return mid }
            if (fm < 0) != (fa < 0) {
                b = mid
                fb = fm
                fa *= 0.5
            } else {
                a = mid
                fa = fm
                fb *= 0.5
            }
        }
        return 0.5 * (a + b)
    }

    /// Real roots of `a t^3 + b t^2 + c t + d`, by Cardano, then one Newton polish each.
    ///
    /// Written with explicit intermediates rather than a fused expression: `QUALITY_BAR` 3.4
    /// rule 5 requires that an expression whose FMA contraction would differ between arm64 and
    /// x86_64 be written to forbid contraction, and separate `let`s are how Swift expresses that.
    ///
    /// The degeneracy test is **relative**: a leading coefficient below
    /// ``cubicLeadingCoefficientFloor`` of the largest other coefficient is treated as the
    /// roundoff it almost certainly is. A line crossing a symmetric arch, or any degree-elevated
    /// quadratic, projects to a cubic whose `t^3` term is mathematically zero and numerically
    /// ~1e-13; dividing by it sent Cardano's trigonometric branch off by ~1e6 and lost every
    /// crossing (BH-033). Such a polynomial is solved as the quadratic it is, and its two
    /// roots are then polished on the full cubic. A cubic that degenerate can only have a
    /// third real root of magnitude ~1/floor, far outside any Bézier parameter domain; that
    /// root is not reported.
    public static func cubicRoots(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> [Double] {
        let scale = Swift.max(Swift.abs(b), Swift.abs(c), Swift.abs(d))
        if Swift.abs(a) <= cubicLeadingCoefficientFloor * scale {
            return quadraticRoots(b, c, d).map { root in
                polish(root, a: a, b: b, c: c, d: d)
            }
        }
        let inverseA = 1 / a
        let bb = b * inverseA
        let cc = c * inverseA
        let dd = d * inverseA

        let bbOverThree = bb / 3
        let p = cc - bb * bbOverThree
        let q = 2 * bbOverThree * bbOverThree * bbOverThree - bbOverThree * cc + dd

        var roots: [Double] = []
        let halfQ = q / 2
        let thirdP = p / 3
        let discriminant = halfQ * halfQ + thirdP * thirdP * thirdP

        if discriminant > 0 {
            let sqrtDiscriminant = discriminant.squareRoot()
            let u = Foundation.cbrt(-halfQ + sqrtDiscriminant)
            let v = Foundation.cbrt(-halfQ - sqrtDiscriminant)
            roots = [u + v - bbOverThree]
        } else if discriminant == 0 {
            let u = Foundation.cbrt(-halfQ)
            roots = [2 * u - bbOverThree, -u - bbOverThree]
        } else {
            let r = (-thirdP * thirdP * thirdP).squareRoot()
            let phi = Foundation.acos(Swift.min(1, Swift.max(-1, -halfQ / r)))
            let m = 2 * Foundation.cbrt(r)
            roots = [
                m * Foundation.cos(phi / 3) - bbOverThree,
                m * Foundation.cos((phi + 2 * Double.pi) / 3) - bbOverThree,
                m * Foundation.cos((phi + 4 * Double.pi) / 3) - bbOverThree
            ]
        }

        // One Newton polish on the original coefficients recovers the digits Cardano's
        // trigonometric branch loses.
        return roots.map { root in polish(root, a: a, b: b, c: c, d: d) }
    }

    /// Below this fraction of the largest lower-order coefficient, a cubic's leading
    /// coefficient is roundoff. Cardano's trigonometric branch loses about `3e-9 * |b / a|`
    /// per root, so at this floor a seed is at worst ~3e-3 off and the polish recovers it;
    /// any smaller `a` is handled as a quadratic.
    public static let cubicLeadingCoefficientFloor = 1e-6

    private static func polish(_ root: Double, a: Double, b: Double, c: Double, d: Double) -> Double {
        var t = root
        for _ in 0..<8 {
            let f = ((a * t + b) * t + c) * t + d
            let df = (3 * a * t + 2 * b) * t + c
            guard Swift.abs(df) > 1e-300 else { break }
            let step = f / df
            t -= step
            if Swift.abs(step) <= newtonResidual * Swift.max(1, Swift.abs(t)) { break }
        }
        return t
    }

    public static func quadraticRoots(_ a: Double, _ b: Double, _ c: Double) -> [Double] {
        if Swift.abs(a) < 1e-300 {
            if Swift.abs(b) < 1e-300 { return [] }
            return [-c / b]
        }
        let discriminant = b * b - 4 * a * c
        if discriminant < 0 { return [] }
        if discriminant == 0 { return [-b / (2 * a)] }
        let sqrtDiscriminant = discriminant.squareRoot()
        // The numerically stable pairing: one root from the well-conditioned branch, the other
        // by Vieta, so a near-tangent line to a circle does not lose half its digits.
        let q = -0.5 * (b + (b < 0 ? -sqrtDiscriminant : sqrtDiscriminant))
        return [q / a, c / q].filter(\.isFinite)
    }

    // MARK: - Angles

    /// Normalises an angle into `[0, 2pi)`.
    public static func normalizedAngle(_ angle: Double) -> Double {
        let twoPi = 2 * Double.pi
        var value = angle.truncatingRemainder(dividingBy: twoPi)
        if value < 0 { value += twoPi }
        return value
    }

    /// Whether `angle` lies on the arc that starts at `startAngle` and sweeps `sweepAngle`.
    public static func arcContains(_ arc: ArcGeometry, angle: Double) -> Bool {
        let sweep = arc.sweepAngle
        if Swift.abs(sweep) >= 2 * Double.pi { return true }
        let start = normalizedAngle(arc.startAngle)
        let offset = normalizedAngle(sweep >= 0 ? angle - start : start - angle)
        return offset <= Swift.abs(sweep) + 1e-12
    }
}
