import CoreGraphics
import Foundation

/// A straight segment in page space.
public struct VectorLine: Sendable, Hashable, Codable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public var bounds: VectorBounds { VectorBounds(point: start).union(end) }
    public var midpoint: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
    public var length: Double { (end - start).magnitude }
    /// `true` when both endpoints coincide exactly.
    public var isDegenerate: Bool { start == end }
}

/// A cubic Bézier segment, stored as a curve.
///
/// `QUALITY_BAR` 3.6 requires curves to survive extraction as
/// curves: flattening is an indexing and hit-testing convenience, never the stored form.
public struct VectorCubic: Sendable, Hashable, Codable {
    public var p0: CGPoint
    public var p1: CGPoint
    public var p2: CGPoint
    public var p3: CGPoint

    public init(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }

    /// De Casteljau evaluation, `t` clamped to `[0, 1]`.
    public func point(at t: Double) -> CGPoint {
        let u = Swift.min(Swift.max(t, 0), 1)
        let m = 1 - u
        let w0 = m * m * m
        let w1 = 3 * m * m * u
        let w2 = 3 * m * u * u
        let w3 = u * u * u
        return CGPoint(
            x: w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
            y: w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y
        )
    }

    /// The convex hull of the four control points. Always contains the curve.
    public var controlHullBounds: VectorBounds {
        VectorBounds(point: p0).union(p1).union(p2).union(p3)
    }

    /// The exact bounds of the curve, from the roots of the component derivatives.
    ///
    /// The control hull is an over-estimate, sometimes by a wide margin; a spatial index
    /// built on it produces false candidates that the snap scorer then has to reject.
    public var bounds: VectorBounds {
        var result = VectorBounds(point: p0).union(p3)
        for t in Self.extremumParameters(p0.x, p1.x, p2.x, p3.x) { result = result.union(point(at: t)) }
        for t in Self.extremumParameters(p0.y, p1.y, p2.y, p3.y) { result = result.union(point(at: t)) }
        return result
    }

    /// Roots in `(0, 1)` of the derivative of one Bézier component.
    ///
    /// B'(t) = 3[(a1-a0)(1-t)^2 + 2(a2-a1)(1-t)t + (a3-a2)t^2], expanded to At^2 + Bt + C.
    ///
    /// Solved in the cancellation-free form `q = −½(B + sign(B)·√disc)`, `t = q/A` and
    /// `t = C/q`. The textbook `(−B ± √disc) / 2A` loses every digit when `A` is rounding
    /// noise — which it is for every quadratic elevated to a cubic (TrueType arcs,
    /// quadratic-spline CAD output): `A` is exactly zero in exact arithmetic and about
    /// `1e-13` after the CTM, above any fixed branch cut, and `√disc == |B|` then yields
    /// roots of `0` and `−B/A`, both rejected, so the bounds collapsed to the chord's
    /// endpoints and the arc's bulge was lost to the snap index (BH-059). The stable form
    /// needs no branch cut at all: as `A → 0`, `q/A → ∞` is rejected and `C/q → −C/B` is
    /// the linear root, accurate to the last digit.
    static func extremumParameters(_ a0: Double, _ a1: Double, _ a2: Double, _ a3: Double) -> [Double] {
        let d0 = a1 - a0
        let d1 = a2 - a1
        let d2 = a3 - a2
        let a = d0 - 2 * d1 + d2
        let b = 2 * (d1 - d0)
        let c = d0

        var roots: [Double] = []
        func accept(_ t: Double) {
            if t.isFinite, t > 0, t < 1, !roots.contains(t) { roots.append(t) }
        }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return roots }
        let sq = discriminant.squareRoot()
        let q = -0.5 * (b + (b < 0 ? -sq : sq))
        if q != 0 {
            if a != 0 { accept(q / a) }
            accept(c / q)
        } else if a != 0 {
            // B == 0 and disc == 0: the double root −B/2A == 0, never interior — but
            // stated rather than relied on.
            accept(-b / (2 * a))
        }
        return roots
    }
}

/// Four corners of a rectangle built by the `re` operator, after the CTM.
///
/// A `re` under a rotating or shearing CTM is no longer axis-aligned, so the corners are
/// stored individually rather than as a rectangle. `c0…c3` are in the order PDF appends
/// them: `(x, y)`, `(x+w, y)`, `(x+w, y+h)`, `(x, y+h)`.
public struct VectorQuad: Sendable, Hashable, Codable {
    public var c0: CGPoint
    public var c1: CGPoint
    public var c2: CGPoint
    public var c3: CGPoint

    public init(c0: CGPoint, c1: CGPoint, c2: CGPoint, c3: CGPoint) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public var corners: [CGPoint] { [c0, c1, c2, c3] }
    public var bounds: VectorBounds { VectorBounds(point: c0).union(c1).union(c2).union(c3) }
    /// The intersection of the diagonals, which for a parallelogram is the centroid.
    public var center: CGPoint {
        CGPoint(x: (c0.x + c1.x + c2.x + c3.x) / 4, y: (c0.y + c1.y + c2.y + c3.y) / 4)
    }
}

/// The on-curve vertices of one subpath, in drawing order.
///
/// For a subpath that contains curves the ring is the polygon through the on-curve
/// points only; the exact curve geometry lives in the child `.cubicCurve` primitives,
/// which is why `containsCurves` is recorded rather than left to be inferred.
public struct VectorRing: Sendable, Hashable, Codable {
    public var vertices: [CGPoint]
    public var isClosed: Bool
    public var containsCurves: Bool

    public init(vertices: [CGPoint], isClosed: Bool, containsCurves: Bool) {
        self.vertices = vertices
        self.isClosed = isClosed
        self.containsCurves = containsCurves
    }

    public var bounds: VectorBounds? { VectorBounds.containing(vertices) }
}

/// The geometry carried by a ``VectorPrimitive``.
public enum VectorGeometry: Sendable, Hashable, Codable {
    case line(VectorLine)
    case cubic(VectorCubic)
    case rectangle(VectorQuad)
    case ring(VectorRing)

    public var bounds: VectorBounds {
        switch self {
        case .line(let line): return line.bounds
        case .cubic(let cubic): return cubic.bounds
        case .rectangle(let quad): return quad.bounds
        case .ring(let ring): return ring.bounds ?? VectorBounds(point: .zero)
        }
    }
}

// MARK: - Point arithmetic

extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    var magnitude: Double { (x * x + y * y).squareRoot() }
}
