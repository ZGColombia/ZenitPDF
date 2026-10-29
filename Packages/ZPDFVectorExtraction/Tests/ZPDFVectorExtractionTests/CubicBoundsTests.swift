import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// BH-059: `VectorCubic.bounds` lost the apex of a quadratic-elevated cubic.
///
/// A quadratic Bézier elevated to a cubic (`p1 = p0 + ⅔(q − p0)`, `p2 = p3 + ⅔(q − p3)`) —
/// what TrueType outlines and quadratic-spline CAD exporters emit — has a derivative
/// coefficient `a = d0 − 2·d1 + d2` that is exactly zero in exact arithmetic and rounds
/// to `≈1e-13` in doubles after the CTM. That is above the old `1e-15` linear branch cut,
/// and the textbook `(−b ± √(b² − 4ac)) / 2a` then cancels every digit: `√disc == |b|`,
/// so the roots come out as `0` and `−b/a ≈ 1e16`, both rejected, and the bounds shrink
/// to the chord's endpoints. The snap index and the crop-box filter both consume those
/// bounds, so an arc's bulge was invisible to snap.
///
/// Every expected value here is derived by hand in the comment beside it, never from the
/// code under test (`QUALITY_BAR` 2.6).
struct CubicBoundsTests {

    /// SplitMix64, as in `GeometryQueryPerformanceTests`: a seeded corpus, the same on
    /// every run.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        mutating func inRange(_ low: Double, _ high: Double) -> Double {
            low + unit() * (high - low)
        }
    }

    @Test("The x-extremum of a quadratic-elevated cubic is found when `a` is rounding noise (BH-059)")
    func elevatedQuadraticApexIsInsideTheBounds() {
        // The finding's reproduced case. x-components: p0 = −1747.09, p1 = 3388.68,
        // p2 = 3478.90, p3 = −1476.43. In doubles a = d0 − 2d1 + d2 = −9.09e-13.
        //
        // By hand, the equivalent quadratic control point is Q = p0 + 1.5(p1 − p0)
        //   = −1747.09 + 1.5 × 5135.77 = 5956.565.
        // The vertex of B(t) = p0 + 2(Q − p0)t + (p0 − 2Q + p3)t² is at
        //   t = (Q − p0) / (2Q − p0 − p3) = 7703.655 / 15136.65 = 0.508941,
        // and its value is p0 − (Q − p0)² / (p0 − 2Q + p3)
        //   = −1747.09 − 7703.655² / (−15136.65) = −1747.09 + 3920.70 = 2173.61.
        //
        // Old output: extremumParameters returned [], bounds.maxX = −1476.43.
        let cubic = VectorCubic(
            p0: CGPoint(x: -1747.09, y: 0),
            p1: CGPoint(x: 3388.68, y: 10),
            p2: CGPoint(x: 3478.90, y: 20),
            p3: CGPoint(x: -1476.43, y: 30)
        )
        let bounds = cubic.bounds
        #expect(abs(bounds.maxX - 2173.61) < 0.01, "maxX was \(bounds.maxX)")
        #expect(bounds.minX == -1747.09)
        #expect(bounds.minY == 0 && bounds.maxY == 30)

        let roots = VectorCubic.extremumParameters(-1747.09, 3388.68, 3478.90, -1476.43)
        #expect(roots.count == 1)
        #expect(abs((roots.first ?? 0) - 0.508941) < 1e-5)
    }

    @Test("A genuinely linear derivative (a == 0 exactly) still yields its single root")
    func exactlyLinearDerivative() {
        // p = (0, 1, 2, 3): d0 = d1 = d2 = 1, a = 0, b = 0, c = 1 — monotone, no root.
        #expect(VectorCubic.extremumParameters(0, 1, 2, 3).isEmpty)
        // p = (0, 2, 2, 0): d0 = 2, d1 = 0, d2 = −2, a = 2 − 0 − 2 = 0, b = 2(0 − 2) = −4,
        // c = 2 — linear, root t = −c/b = 0.5. Value there: 0.125·0 + 0.375·2 + 0.375·2 + 0 = 1.5.
        let roots = VectorCubic.extremumParameters(0, 2, 2, 0)
        #expect(roots == [0.5])
        let cubic = VectorCubic(
            p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 1, y: 2), p2: CGPoint(x: 2, y: 2), p3: CGPoint(x: 3, y: 0)
        )
        #expect(cubic.bounds == VectorBounds(minX: 0, minY: 0, maxX: 3, maxY: 1.5))
    }

    @Test("A double root (disc == 0) and a constant component are handled")
    func degenerateDiscriminants() {
        // Constant: every coefficient zero → no roots, no NaN.
        #expect(VectorCubic.extremumParameters(5, 5, 5, 5).isEmpty)
        // p = (0, 0, 0, 1): d0 = 0, d1 = 0, d2 = 1, a = 1, b = 0, c = 0 → B'(t) = 3t²,
        // double root at t = 0, which is not interior. No roots.
        #expect(VectorCubic.extremumParameters(0, 0, 0, 1).isEmpty)
        // p = (1, 0, 0, 0): d0 = −1, d1 = 0, d2 = 0, a = −1, b = 2, c = −1 → −(t − 1)²,
        // double root at t = 1, not interior. No roots.
        #expect(VectorCubic.extremumParameters(1, 0, 0, 0).isEmpty)
    }

    @Test("Over 20 000 seeded quadratic-elevated cubics at page scale, every sampled point is inside the bounds and the bounds are inside the hull")
    func seededElevatedQuadraticsSweep() {
        // Old output (this corpus, run on the old solver): "5052 curves had a point
        // outside their bounds, worst by 1815.67541925 pt".
        var random = SplitMix64(state: 0x5EED_0059)
        var misses = 0
        var worst = 0.0
        for _ in 0..<20_000 {
            func elevate() -> (Double, Double, Double, Double) {
                let p0 = (random.inRange(-2_000, 2_000) * 100).rounded() / 100
                let q = (random.inRange(-2_000, 2_000) * 100).rounded() / 100
                let p3 = (random.inRange(-2_000, 2_000) * 100).rounded() / 100
                let p1 = ((p0 + 2.0 / 3.0 * (q - p0)) * 100).rounded() / 100
                let p2 = ((p3 + 2.0 / 3.0 * (q - p3)) * 100).rounded() / 100
                return (p0, p1, p2, p3)
            }
            let x = elevate()
            let y = elevate()
            let cubic = VectorCubic(
                p0: CGPoint(x: x.0, y: y.0), p1: CGPoint(x: x.1, y: y.1),
                p2: CGPoint(x: x.2, y: y.2), p3: CGPoint(x: x.3, y: y.3)
            )
            let bounds = cubic.bounds
            let hull = cubic.controlHullBounds
            #expect(hull.contains(bounds))
            var curveMiss = 0.0
            for step in 0...200 {
                let point = cubic.point(at: Double(step) / 200)
                curveMiss = Swift.max(
                    curveMiss,
                    bounds.minX - point.x, point.x - bounds.maxX,
                    bounds.minY - point.y, point.y - bounds.maxY
                )
            }
            if curveMiss > 1e-9 {
                misses += 1
                worst = Swift.max(worst, curveMiss)
            }
        }
        #expect(misses == 0, "\(misses) curves had a point outside their bounds, worst by \(worst) pt")
    }
}
