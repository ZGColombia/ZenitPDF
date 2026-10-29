import CoreGraphics
import Foundation

/// Turns curves into polylines for indexing and hit testing only.
///
/// Curves are stored as curves; adaptive flattening exists only for indexing and hit
/// testing. Nothing here ever replaces a stored ``VectorCubic`` — the output is a
/// throwaway approximation whose error is bounded by ``flatness``.
public struct VectorFlattener: Sendable, Hashable, Codable {
    /// Maximum distance, in page points, between the curve and the polyline that
    /// replaces it.
    public let flatness: Double
    /// Recursion cap. A malformed curve with infinite or enormous control points must
    /// not subdivide forever; 20 levels is already 1 048 576 potential pieces.
    public let maximumSubdivisionDepth: Int
    /// Hard cap on emitted points per curve, so a caller cannot be surprised by an
    /// allocation proportional to the pathology of the input.
    public let maximumPointsPerCurve: Int

    public init(
        flatness: Double = 0.1,
        maximumSubdivisionDepth: Int = 20,
        maximumPointsPerCurve: Int = 4096
    ) {
        self.flatness = flatness > 0 && flatness.isFinite ? flatness : 0.1
        self.maximumSubdivisionDepth = Swift.min(Swift.max(1, maximumSubdivisionDepth), 24)
        self.maximumPointsPerCurve = Swift.max(2, maximumPointsPerCurve)
    }

    public static let standard = VectorFlattener()

    /// The curve as a polyline, including both endpoints.
    ///
    /// Adaptive: a nearly straight curve returns two points, a tight one subdivides
    /// until the flatness test passes or the depth cap stops it. The test is the
    /// control-point deviation bound — the distance of `p1` and `p2` from the chord
    /// **segment** `p0→p3` — which is an upper bound on the true deviation of the curve
    /// from that segment: the curve lies in the convex hull of its control points, and
    /// the set of points within ``flatness`` of a segment is convex.
    public func flatten(_ cubic: VectorCubic) -> [CGPoint] {
        var output: [CGPoint] = [cubic.p0]
        output.reserveCapacity(16)
        guard cubic.p0.isFinite, cubic.p1.isFinite, cubic.p2.isFinite, cubic.p3.isFinite else {
            // A non-finite control point cannot be subdivided meaningfully. Return the
            // chord and let the caller's bounds check reject it.
            output.append(cubic.p3)
            return output
        }
        subdivide(cubic, depth: 0, into: &output)
        output.append(cubic.p3)
        return output
    }

    /// The polyline of any primitive: a line yields its two endpoints, a rectangle its
    /// four corners closed back to the first, a straight ring its vertices.
    ///
    /// A ring that **contains curves** yields nothing. Its vertex list holds the on-curve
    /// vertices only, and the polygon through them is not an approximation of the outline
    /// at any flatness — a four-Bézier circle's is the inscribed square, area `2r²` for
    /// `πr²`. The exact geometry lives in the ring's child `.cubic` and `.line` primitives,
    /// which flatten on their own; a consumer that wants the outline collects those (CR-36).
    public func flatten(_ primitive: VectorPrimitive) -> [CGPoint] {
        switch primitive.geometry {
        case .line(let line):
            return [line.start, line.end]
        case .cubic(let cubic):
            return flatten(cubic)
        case .rectangle(let quad):
            return [quad.c0, quad.c1, quad.c2, quad.c3, quad.c0]
        case .ring(let ring):
            guard !ring.containsCurves else { return [] }
            guard ring.isClosed, let first = ring.vertices.first else { return ring.vertices }
            return ring.vertices + [first]
        }
    }

    private func subdivide(_ cubic: VectorCubic, depth: Int, into output: inout [CGPoint]) {
        if depth >= maximumSubdivisionDepth || output.count >= maximumPointsPerCurve - 1 { return }
        if isFlat(cubic) { return }

        // de Casteljau split at t = 1/2, in exact halves so the split is reproducible.
        let p01 = midpoint(cubic.p0, cubic.p1)
        let p12 = midpoint(cubic.p1, cubic.p2)
        let p23 = midpoint(cubic.p2, cubic.p3)
        let p012 = midpoint(p01, p12)
        let p123 = midpoint(p12, p23)
        let mid = midpoint(p012, p123)

        subdivide(
            VectorCubic(p0: cubic.p0, p1: p01, p2: p012, p3: mid),
            depth: depth + 1,
            into: &output
        )
        if output.count < maximumPointsPerCurve { output.append(mid) }
        subdivide(
            VectorCubic(p0: mid, p1: p123, p2: p23, p3: cubic.p3),
            depth: depth + 1,
            into: &output
        )
    }

    /// `true` when both control points lie within ``flatness`` of the chord segment.
    ///
    /// The distance is to the *segment*, not to the infinite line through it. The
    /// perpendicular distance alone ignores a control point that overshoots the chord
    /// along its own direction: the collinear cubic `(0,0) (100,0) (−100,0) (10,0)` has
    /// zero perpendicular deviation and was returned as its 10 pt chord, although the
    /// curve sweeps out to x ≈ 29 and back past x ≈ −24 — hit testing and the polyline's
    /// length then saw a segment a tenth the length drawn (BH-868).
    private func isFlat(_ cubic: VectorCubic) -> Bool {
        let dx = cubic.p3.x - cubic.p0.x
        let dy = cubic.p3.y - cubic.p0.y
        let chordLengthSquared = dx * dx + dy * dy
        let chordLength = chordLengthSquared.squareRoot()
        if chordLength <= flatness * 1e-6 {
            // Degenerate chord: fall back to the control-point spread.
            let spread = Swift.max(
                (cubic.p1 - cubic.p0).magnitude,
                (cubic.p2 - cubic.p0).magnitude
            )
            return spread <= flatness
        }
        func distanceToChord(_ point: CGPoint) -> Double {
            let px = point.x - cubic.p0.x
            let py = point.y - cubic.p0.y
            let t = Swift.min(Swift.max((px * dx + py * dy) / chordLengthSquared, 0), 1)
            let qx = px - t * dx
            let qy = py - t * dy
            return (qx * qx + qy * qy).squareRoot()
        }
        return Swift.max(distanceToChord(cubic.p1), distanceToChord(cubic.p2)) <= flatness
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

extension CGPoint {
    var isFinite: Bool { x.isFinite && y.isFinite }
}
