import Foundation
import ZPDFContracts
import ZPDFGeometry

/// A quarter of a markup ellipse, exactly: `P(θ) = centre + u·cos θ + v·sin θ` for θ in
/// `[0, π/2]`, from the quadrant point `centre + u` to the quadrant point `centre + v` (U-089).
///
/// The frozen `PrimitiveGeometry` of SNAP_CONTRACT has no ellipse, so the index stores each quarter
/// of an Ellipse annotation, Ellipse Area or Ellipse Cutout as the standard cubic
/// (``SnapMarkupGeometry/ellipsePieces(in:)``), which leaves the curve by up to `2.7e-4` of the
/// semi-axis between the quadrants — 0.054 pt at a 200 pt semi-axis, where `QUALITY_BAR` S2 allows
/// `1e-9` pt. The snap engine answers on the ellipse itself instead: that cubic, from `A` to `B`
/// with handle `k = 4/3·(√2 − 1)`, has control points `A + k·v` and `B + k·u` — an affine image of
/// the quarter circle — so the conic is recovered from it exactly, `v = (p1 − p0)/k` and
/// `u = (p2 − p3)/k`, and checked: both give the same centre, or it is not an ellipse quarter.
///
/// The same holds after a markup is turned (``SnapMarkupGeometry/turned(_:about:degrees:)``): a
/// rotation is affine, and `u` and `v` turn with it.
public struct SnapEllipseArc: Sendable, Hashable {

    /// The centre of the ellipse.
    public let centre: PDFPoint
    /// From the centre to the quarter's start, the quadrant point at θ = 0.
    public let u: PDFVector
    /// From the centre to the quarter's end, the quadrant point at θ = π/2.
    public let v: PDFVector

    /// The standard quarter-circle handle, `4/3·(√2 − 1)`.
    static let handle = 4.0 / 3.0 * (2.0.squareRoot() - 1)

    /// The end of the parameter domain.
    static let quarter = Double.pi / 2

    public init(centre: PDFPoint, u: PDFVector, v: PDFVector) {
        self.centre = centre
        self.u = u
        self.v = v
    }

    /// The ellipse quarter a standard quarter cubic stands for, or `nil` when the four points are
    /// not that construction.
    public init?(cubic p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint) {
        let k = Self.handle
        let v = PDFVector(dx: (p1.x - p0.x) / k, dy: (p1.y - p0.y) / k)
        let u = PDFVector(dx: (p2.x - p3.x) / k, dy: (p2.y - p3.y) / k)
        let fromStart = PDFPoint(x: p0.x - u.dx, y: p0.y - u.dy)
        let fromEnd = PDFPoint(x: p3.x - v.dx, y: p3.y - v.dy)
        let scale = Swift.max(1, u.magnitude, v.magnitude, Swift.abs(p0.x), Swift.abs(p0.y))
        guard u.isFinite, v.isFinite, fromStart.isFinite, fromEnd.isFinite,
              u.magnitude > 0, v.magnitude > 0, Swift.abs(u.cross(v)) > 0,
              fromStart.distance(to: fromEnd) <= 1e-9 * scale else { return nil }
        self.init(centre: fromStart, u: u, v: v)
    }

    /// The point at parameter `theta`.
    public func point(at theta: Double) -> PDFPoint {
        let c = Foundation.cos(theta), s = Foundation.sin(theta)
        return PDFPoint(x: centre.x + u.dx * c + v.dx * s, y: centre.y + u.dy * c + v.dy * s)
    }

    /// `dP/dθ` at `theta`.
    public func derivative(at theta: Double) -> PDFVector {
        let c = Foundation.cos(theta), s = Foundation.sin(theta)
        return PDFVector(dx: -u.dx * s + v.dx * c, dy: -u.dy * s + v.dy * c)
    }

    /// The quarter's two ends: the quadrant points.
    public var start: PDFPoint { PDFPoint(x: centre.x + u.dx, y: centre.y + u.dy) }
    public var end: PDFPoint { PDFPoint(x: centre.x + v.dx, y: centre.y + v.dy) }

    /// The control-point box of the standard cubic, which contains the quarter (an affine image
    /// of the quarter circle, which lies inside its control polygon).
    public var bounds: PDFRect? {
        let k = Self.handle
        return PDFRect.boundingBox(of: [
            start,
            PDFPoint(x: start.x + k * v.dx, y: start.y + k * v.dy),
            PDFPoint(x: end.x + k * u.dx, y: end.y + k * u.dy),
            end
        ])
    }

    /// Whether `theta` lies on the quarter.
    public func contains(parameter theta: Double) -> Bool {
        theta >= -1e-12 && theta <= Self.quarter + 1e-12
    }

    /// The point of the quarter nearest to `q`: the foot of the perpendicular where there is one
    /// on the quarter, else the nearer end.
    ///
    /// `f(θ) = (P(θ) − q)·P'(θ)` is zero at the foot, with `f' = |P'|² + (P − q)·P''` and
    /// `P'' = −(P − centre)`. A fixed 64-step scan brackets the nearest sample's sign change, and
    /// a safeguarded Newton — bisection whenever the step leaves the bracket — polishes it to the
    /// last bit, so the answer depends on nothing but the input.
    public func nearest(to q: PDFPoint) -> (point: PDFPoint, parameter: Double, distance: Double) {
        let steps = 64
        var bestIndex = 0
        var bestDistance = Double.infinity
        for index in 0...steps {
            let distance = point(at: Self.quarter * Double(index) / Double(steps)).distance(to: q)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        func f(_ theta: Double) -> Double {
            let p = point(at: theta)
            return PDFVector(from: q, to: p).dot(derivative(at: theta))
        }
        var best = (point: point(at: Self.quarter * Double(bestIndex) / Double(steps)),
                    parameter: Self.quarter * Double(bestIndex) / Double(steps), distance: bestDistance)
        // The foot lies in the samples' neighbourhood: f rises through zero at a minimum.
        for (lowIndex, highIndex) in [(bestIndex - 1, bestIndex), (bestIndex, bestIndex + 1)]
        where lowIndex >= 0 && highIndex <= steps {
            var lo = Self.quarter * Double(lowIndex) / Double(steps)
            var hi = Self.quarter * Double(highIndex) / Double(steps)
            var fLo = f(lo)
            let fHi = f(hi)
            guard fLo <= 0, fHi >= 0 else { continue }
            var theta = 0.5 * (lo + hi)
            for _ in 0..<100 {
                let value = f(theta)
                if value == 0 { break }
                if (value < 0) == (fLo < 0) { lo = theta; fLo = value } else { hi = theta }
                let p = point(at: theta)
                let d = derivative(at: theta)
                let slope = d.squaredMagnitude - PDFVector(from: q, to: p).dot(PDFVector(from: centre, to: p))
                var next = slope > 0 ? theta - value / slope : 0.5 * (lo + hi)
                if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
                if next == theta || Swift.abs(next - theta) <= 1e-17 { theta = next; break }
                theta = next
            }
            let foot = point(at: theta)
            let distance = foot.distance(to: q)
            if distance < best.distance { best = (foot, theta, distance) }
        }
        return best
    }

    /// The parameters on the quarter where the tangent passes through `anchor`, ascending.
    ///
    /// With `w = centre − anchor`, tangency `(P − anchor) × P' = 0` reads
    /// `(w × v)·cos θ − (w × u)·sin θ + u × v = 0` — closed form: `R·cos(θ − φ) = −(u × v)` with
    /// `R = hypot(w × v, w × u)`. No solution when the anchor is inside the ellipse.
    public func tangentParameters(from anchor: PDFPoint) -> [Double] {
        let w = PDFVector(from: anchor, to: centre)
        let a = w.cross(v)
        let b = -w.cross(u)
        let d = u.cross(v)
        let r = (a * a + b * b).squareRoot()
        guard r > 0, Swift.abs(d) < r else { return [] }
        let phi = Foundation.atan2(b, a)
        let opening = Foundation.acos(-d / r)
        var result: [Double] = []
        for candidate in [phi - opening, phi + opening] {
            var theta = candidate.truncatingRemainder(dividingBy: 2 * Double.pi)
            if theta < -1e-12 { theta += 2 * Double.pi }
            if contains(parameter: theta) { result.append(Swift.min(Self.quarter, Swift.max(0, theta))) }
        }
        return result.sorted()
    }

    /// The point halfway along the quarter by arc length.
    ///
    /// The arc length `∫|P'|dθ` is integrated by adaptive 8-point Gauss–Legendre to a relative
    /// `1e-15` (a speed that changes on the scale `b/a` near a very flat ellipse's ends is split
    /// until it is resolved), and `s(θ) = L/2` is solved by a safeguarded Newton, whose slope is
    /// the speed itself.
    public var arcLengthMidpoint: PDFPoint {
        func speed(_ theta: Double) -> Double { derivative(at: theta).magnitude }
        func gauss(_ lo: Double, _ hi: Double) -> Double {
            let half = 0.5 * (hi - lo), mid = 0.5 * (hi + lo)
            var sum = 0.0
            for (node, weight) in zip(SnapCurveMath.gaussNodes, SnapCurveMath.gaussWeights) {
                sum += weight * (speed(mid - half * node) + speed(mid + half * node))
            }
            return sum * half
        }
        func length(_ lo: Double, _ hi: Double, _ whole: Double, depth: Int) -> Double {
            let mid = 0.5 * (lo + hi)
            let left = gauss(lo, mid), right = gauss(mid, hi)
            if depth >= 40 || Swift.abs(left + right - whole) <= 1e-15 * Swift.max(Swift.abs(left + right), 1e-300) {
                return left + right
            }
            return length(lo, mid, left, depth: depth + 1) + length(mid, hi, right, depth: depth + 1)
        }
        let total = length(0, Self.quarter, gauss(0, Self.quarter), depth: 0)
        guard total.isFinite, total > 0 else { return point(at: Self.quarter / 2) }
        let target = 0.5 * total
        var lo = 0.0, hi = Self.quarter
        var theta = Self.quarter / 2
        for _ in 0..<100 {
            let value = length(0, theta, gauss(0, theta), depth: 0) - target
            if value == 0 { break }
            if value < 0 { lo = theta } else { hi = theta }
            let slope = speed(theta)
            var next = slope > 0 ? theta - value / slope : 0.5 * (lo + hi)
            if !(next > lo && next < hi) { next = 0.5 * (lo + hi) }
            if next == theta || Swift.abs(next - theta) <= 1e-17 { theta = next; break }
            theta = next
        }
        return point(at: theta)
    }
}

extension SnapIndexEntry {

    /// The exact ellipse quarter this entry stands for, when it is a quarter of a markup ellipse:
    /// kind set ``SnapEntryKindSet/zenitMarkupSmoothCurve`` (``SnapMarkupGeometry/Role/smoothCurve``,
    /// which only ``SnapMarkupGeometry/ellipsePieces(in:)`` assigns) on a standard quarter cubic.
    var ellipseArc: SnapEllipseArc? {
        guard kindSet == .zenitMarkupSmoothCurve,
              case .cubicCurve(let p0, let p1, let p2, let p3) = primitive.geometry else { return nil }
        return SnapEllipseArc(cubic: p0, p1, p2, p3)
    }
}
