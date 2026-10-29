import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Regressions in the curve mathematics (BH-033, BH-216).
///
/// Every expected value is derived by hand in a comment from the fixture's own numbers, or by an
/// independent method written in this file; nothing is copied from the code under test.
@Suite("Curve math regressions")
struct CurveMathRegressionTests {

    // MARK: - BH-033: roundoff-small leading coefficient

    /// The symmetric arch `p0 = (x, y)`, `p1 = (x, y + h)`, `p2 = (x + w, y + h)`,
    /// `p3 = (x + w, y)`. Its Bernstein expansion gives
    ///
    ///     y(t) = y + h (3 (1-t)^2 t + 3 (1-t) t^2) = y + 3 h t (1 - t)
    ///     x(t) = x + w (3 (1-t) t^2 + t^3)         = x + w t^2 (3 - 2 t)
    ///
    /// so the `t^3` coefficient of `y(t)` is exactly zero and a horizontal line across the arch
    /// is the case where `lineCubic` hands the cubic solver a leading coefficient that is pure
    /// roundoff (BH-033). The crossings with `y = y + k` are the roots of
    /// `t^2 - t + k / (3 h) = 0`, i.e. `t = (1 +/- sqrt(1 - 4 k / (3 h))) / 2`.
    static func archCrossings(
        x: Double, y: Double, w: Double, h: Double, k: Double
    ) -> [PDFPoint] {
        let root = (1 - 4 * k / (3 * h)).squareRoot()
        return [(1 - root) / 2, (1 + root) / 2].map { t in
            PDFPoint(x: x + w * t * t * (3 - 2 * t), y: y + k)
        }
    }

    @Test("A horizontal line across a symmetric arch yields both crossings (BH-033)")
    func archCrossings() throws {
        // x = 100, y = 200, w = 300, h = 100, k = 50:
        //   t = (1 +/- sqrt(1 - 200 / 300)) / 2 = (1 +/- sqrt(1/3)) / 2
        //   t1 = 0.21132486540518713  x1 = 100 + 300 * t1^2 (3 - 2 t1) = 134.52994616207485
        //   t2 = 0.78867513459481287  x2 = 100 + 300 * t2^2 (3 - 2 t2) = 365.47005383792515
        // (x1 + x2 = 500 by the arch's symmetry about x = 250.)
        let expected = Self.archCrossings(x: 100, y: 200, w: 300, h: 100, k: 50)
        #expect(Swift.abs(expected[0].x + expected[1].x - 500) <= 1e-9)

        // With these round coordinates the projected t^3 coefficient happens to cancel to an
        // exact zero and the old solver took its quadratic branch, so this case documents the
        // closed form; the case below it is the one the old solver lost.
        try Self.expectArchCrossings(x: 100, y: 200, w: 300, h: 100, k: 50, expected: expected)

        // The first case the seeded sweep below loses on the old code. Nothing cancels: the
        // t^3 coefficient is ~1e-11 of the others, Cardano divides by it, and the roots come
        // back far outside 0...1. Old output: hits [] for both operand orders.
        let x = 351.6300978811145, y = 304.6669073565658
        let w = 95.25467416349406, h = 160.57196031102967, k = 24.719622665552883
        try Self.expectArchCrossings(
            x: x, y: y, w: w, h: h, k: k,
            expected: Self.archCrossings(x: x, y: y, w: w, h: h, k: k)
        )
    }

    static func expectArchCrossings(
        x: Double, y: Double, w: Double, h: Double, k: Double, expected: [PDFPoint]
    ) throws {
        let arch = SnapCurve.cubic(
            p0: PDFPoint(x: x, y: y), p1: PDFPoint(x: x, y: y + h),
            p2: PDFPoint(x: x + w, y: y + h), p3: PDFPoint(x: x + w, y: y)
        )
        let line = SnapCurve.line(
            SegmentGeometry(start: PDFPoint(x: x - 50, y: y + k), end: PDFPoint(x: x + w + 50, y: y + k))
        )
        for (a, b) in [(arch, line), (line, arch)] {
            let hits = SnapIntersectionSolver.intersections(
                a, b, near: PDFPoint(x: x + w / 2, y: y + k), within: w
            )
            #expect(hits.count == 2, "hits: \(hits)" as Comment)
            for point in expected {
                #expect(
                    hits.contains { $0.point.distance(to: point) <= 1e-9 },
                    "missing crossing at \(point) in \(hits.map(\.point))" as Comment
                )
            }
        }
    }

    @Test("An elevated quadratic crossed by a line snaps to the closed-form intersection (BH-033)")
    func elevatedQuadraticCrossing() throws {
        // The symmetric quadratic q0 = (x, y), q1 = (x + w/2, y + g), q2 = (x + w, y):
        //   y(t) = y + 2 g t (1 - t)
        //   x(t) = x (1-t)^2 + 2 (x + w/2) t (1-t) + (x + w) t^2 = x + w t
        // The line y + k crosses it where 2 g t (1 - t) = k, i.e. t = (1 +/- sqrt(1 - 2k/g)) / 2.
        // With x = 351.63, y = 304.67, w = 95.25, g = 80.29, k = 24.72 (the arch case above,
        // whose 3h equals this 2g): sqrt(1 - 49.44/80.29) = sqrt(0.38424...) = 0.61987...,
        // t1 = 0.19006..., x1 = 351.63 + 95.25 * 0.19006 = 369.73...
        // `SnapCurve.decompose` elevates every quadratic to a cubic, and the elevated cubic's
        // t^3 coefficient along the line normal is mathematically zero.
        let x = 351.6300978811145, y = 304.6669073565658
        let w = 95.25467416349406, g = 160.57196031102967 / 2, k = 24.719622665552883
        let t1 = (1 - (1 - 2 * k / g).squareRoot()) / 2
        let expected = PDFPoint(x: x + w * t1, y: y + k)
        #expect(Swift.abs(t1 - 0.19006) <= 1e-4)

        let page = try SnapScene.letterPage()
        let quadratic = SnapPrimitive(
            id: 1,
            bounds: PDFRect(x: x, y: y, width: w, height: g),
            kind: .quadraticCurve,
            geometry: .quadraticCurve(
                start: PDFPoint(x: x, y: y),
                control: PDFPoint(x: x + w / 2, y: y + g),
                end: PDFPoint(x: x + w, y: y)
            ),
            sourceObjectID: 1,
            confidence: 1,
            layerID: nil
        )
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                quadratic,
                SnapScene.segment(id: 2, PDFPoint(x: x - 50, y: y + k), PDFPoint(x: x + w + 50, y: y + k))
            ]
        )
        var settings = SnapSettings.default
        settings.enabledKinds = [.intersection]
        let layout = SnapReplay.layout(zoom: 1.0)
        var engine = SnapEngine()
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(
                        PDFPoint(x: expected.x + 1, y: expected.y + 1), page: page, layout: layout
                    ),
                    layout: layout
                ),
                settings: settings
            ),
            in: scene.index
        )
        // Old output: winner nil — no intersection candidate at all.
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .intersection)
        #expect(winner.position.distance(to: expected) <= 1e-9)
    }

    @Test("Seeded sweep: 500 random arches crossed by horizontal lines lose no crossing (BH-033)")
    func archSweep() throws {
        var random = SnapDeterministicRandom(seed: 0xB033)
        var lost = 0
        var worst = 0.0
        var firstLost = ""
        for _ in 0..<500 {
            let x = random.nextUnitDouble() * 400
            let y = random.nextUnitDouble() * 400
            let w = 40 + random.nextUnitDouble() * 300
            let h = 40 + random.nextUnitDouble() * 200
            // Strictly between the chord and the apex (3h/4), away from both so the crossing is
            // well conditioned.
            let k = h * (0.1 + 0.55 * random.nextUnitDouble())
            let expected = Self.archCrossings(x: x, y: y, w: w, h: h, k: k)
            let arch = SnapCurve.cubic(
                p0: PDFPoint(x: x, y: y), p1: PDFPoint(x: x, y: y + h),
                p2: PDFPoint(x: x + w, y: y + h), p3: PDFPoint(x: x + w, y: y)
            )
            let line = SnapCurve.line(
                SegmentGeometry(start: PDFPoint(x: x - 10, y: y + k), end: PDFPoint(x: x + w + 10, y: y + k))
            )
            let hits = SnapIntersectionSolver.intersections(
                arch, line, near: PDFPoint(x: x + w / 2, y: y + k), within: w
            )
            for point in expected {
                let nearest = hits.map { $0.point.distance(to: point) }.min() ?? .infinity
                if nearest > 1e-9 {
                    lost += 1
                    if firstLost.isEmpty {
                        firstLost = "x \(x) y \(y) w \(w) h \(h) k \(k) hits \(hits.map(\.point))"
                    }
                }
                if nearest.isFinite { worst = Swift.max(worst, nearest) }
            }
        }
        // Old output: 704 of the 1 000 crossings lost, worst error 332 page points.
        #expect(lost == 0, "\(lost) crossings lost, worst error \(worst); first: \(firstLost)" as Comment)
    }

    // MARK: - BH-216: nearest point on a cubic

    /// An independent reference for the nearest point on a cubic: 2 001 uniform samples, then a
    /// golden-section search of the distance inside the best sample's bracket. It shares no
    /// code with the engine's sample-then-Newton routine.
    static func referenceNearestDistance(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, to q: PDFPoint
    ) -> Double {
        referenceNearest(p0, p1, p2, p3, to: q).distance
    }

    static func referenceNearest(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, to q: PDFPoint
    ) -> (t: Double, distance: Double) {
        func point(_ t: Double) -> PDFPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return PDFPoint(
                x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
            )
        }
        func distance(_ t: Double) -> Double { point(t).distance(to: q) }

        let samples = 2000
        var bestIndex = 0
        var best = Double.infinity
        for i in 0...samples {
            let d = distance(Double(i) / Double(samples))
            if d < best { best = d; bestIndex = i }
        }
        var lo = Double(Swift.max(0, bestIndex - 1)) / Double(samples)
        var hi = Double(Swift.min(samples, bestIndex + 1)) / Double(samples)
        let phi = (5.0.squareRoot() - 1) / 2
        var c = hi - phi * (hi - lo)
        var d = lo + phi * (hi - lo)
        var fc = distance(c)
        var fd = distance(d)
        for _ in 0..<100 {
            if fc < fd {
                hi = d; d = c; fd = fc
                c = hi - phi * (hi - lo); fc = distance(c)
            } else {
                lo = c; c = d; fc = fd
                d = lo + phi * (hi - lo); fd = distance(d)
            }
        }
        if fc <= fd, fc <= best { return (c, fc) }
        if fd <= best { return (d, fd) }
        return (Double(bestIndex) / Double(samples), best)
    }

    /// The engine's own coarse grid, evaluated independently: the best of 25 uniform samples.
    static func coarseSampledNearest(
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, to q: PDFPoint
    ) -> (t: Double, distance: Double) {
        var best = (t: 0.0, distance: Double.infinity)
        for i in 0...24 {
            let t = Double(i) / 24
            let d = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t).distance(to: q)
            if d < best.distance { best = (t, d) }
        }
        return best
    }

    @Test("Newton never returns a point farther than the sampled minimum (BH-216)")
    func nearestPointNeverWorseThanSampled() throws {
        // The worst case of the seeded sweep below on the old code, kept as a literal so it
        // reproduces on its own. Old output: parameter 1.0, distance 199.6152102047307 page
        // points, while the reference nearest point is 82.17147291688366 away — Newton stepped
        // toward a distance maximum, was clamped to the far endpoint, and that was returned
        // without being compared to the sampled minimum.
        let p0 = PDFPoint(x: 102.70853865683685, y: 22.310138758819107)
        let p1 = PDFPoint(x: 150.35786016186367, y: 22.353759543693876)
        let p2 = PDFPoint(x: 133.47009719440527, y: 109.19240507526713)
        let p3 = PDFPoint(x: 182.68551850264697, y: 135.69168420070423)
        let q = PDFPoint(x: 20.59644226400725, y: 19.186905289351188)
        let reference = Self.referenceNearestDistance(p0, p1, p2, p3, to: q)
        let t = SnapCurveMath.nearestParameterOnCubic(p0, p1, p2, p3, to: q)
        let distance = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t).distance(to: q)
        #expect(distance <= reference + 1e-9, "t \(t) distance \(distance) reference \(reference)" as Comment)
        #expect(distance >= reference - 1e-9)
    }

    @Test("Seeded sweep: 5 000 random cubic/query pairs never lose to the coarse grid (BH-216)")
    func nearestPointSweep() throws {
        var random = SnapDeterministicRandom(seed: 0xB216)
        var worseThanSampled = 0
        var worseThanReferenceInBasin = 0
        var basinMisses = 0
        var worstExcess = 0.0
        var worstCase = ""
        for _ in 0..<5000 {
            func point() -> PDFPoint {
                PDFPoint(x: random.nextUnitDouble() * 200, y: random.nextUnitDouble() * 200)
            }
            let p0 = point(), p1 = point(), p2 = point(), p3 = point(), q = point()
            let reference = Self.referenceNearest(p0, p1, p2, p3, to: q)
            let sampled = Self.coarseSampledNearest(p0, p1, p2, p3, to: q)
            let t = SnapCurveMath.nearestParameterOnCubic(p0, p1, p2, p3, to: q)
            let distance = SnapCurveMath.cubicPoint(p0, p1, p2, p3, at: t).distance(to: q)

            // The routine may never return a point farther than the coarse grid it starts
            // from: that is exactly the defect.
            if distance > sampled.distance + 1e-12 { worseThanSampled += 1 }

            // Inside the basin the grid picked — the dense minimum lies within one grid step
            // of the best sample — the refined point must match the reference to S2's 1e-9.
            // A minimum in a basin the fixed 24-sample grid never sees (a tight loop between
            // two samples) is the documented limitation of the fixed count, not this defect,
            // and is only counted.
            if Swift.abs(reference.t - sampled.t) <= 1.0 / 24 + 1e-12 {
                let excess = distance - reference.distance
                if excess > 1e-9 {
                    worseThanReferenceInBasin += 1
                    if excess > worstExcess {
                        worstExcess = excess
                        worstCase = "p0 \(p0) p1 \(p1) p2 \(p2) p3 \(p3) q \(q) t \(t) distance \(distance) reference \(reference)"
                    }
                }
            } else {
                basinMisses += 1
            }
        }
        // Old output: 174 of 5 000 pairs returned a point farther than the dense reference,
        // the worst by 117.44 page points (the case pinned above); every one of them was also
        // farther than the coarse grid's own best sample.
        #expect(worseThanSampled == 0, "\(worseThanSampled) pairs worse than the coarse grid" as Comment)
        #expect(
            worseThanReferenceInBasin == 0,
            "\(worseThanReferenceInBasin) pairs off the reference inside the sampled basin; worst by \(worstExcess): \(worstCase)" as Comment
        )
        print("BH-216 sweep: \(basinMisses) of 5000 minima lie in a basin the 24-sample grid does not see")
    }
}

/// BH-663: the midpoint of a curve is the point halfway along it.
@Suite("Cubic arc-length midpoint (BH-663)")
struct CubicMidpointTests {

    @Test("A straight cubic with uneven control points has its midpoint at half its length")
    func straightCubicClosedForm() throws {
        // p0 = p1 = p2 = (100, 200), p3 = (190, 200): B(t) = (100 + 90 t^3, 200). The curve is
        // the segment from x = 100 to x = 190, so halfway along it is (145, 200), at
        // t = 0.5^(1/3) = 0.7937005259840998. The parametric t = 0.5 is (111.25, 200) — the old
        // output, 33.75 page points short.
        let p0 = PDFPoint(x: 100, y: 200), p3 = PDFPoint(x: 190, y: 200)
        let t = SnapCurveMath.arcLengthMidpointParameter(p0, p0, p0, p3)
        #expect(Swift.abs(t - Foundation.pow(0.5, 1.0 / 3.0)) <= 1e-12)
        let point = SnapCurveMath.cubicPoint(p0, p0, p0, p3, at: t)
        #expect(point.distance(to: PDFPoint(x: 145, y: 200)) <= 1e-9)

        // Through the engine: the midpoint candidate is (145, 200).
        let page = try SnapScene.letterPage()
        let cubic = try #require(SnapScene.cubic(id: 1, p0, p0, p0, p3))
        let scene = try SnapScene.withVectorContent(page: page, primitives: [cubic])
        var settings = SnapSettings.default
        settings.enabledKinds = [.midpoint]
        let layout = SnapReplay.layout(zoom: 1)
        var engine = SnapEngine()
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(PDFPoint(x: 145.5, y: 200.5), page: page, layout: layout),
                    layout: layout
                ),
                settings: settings
            ),
            in: scene.index
        )
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .midpoint)
        // Old output: no winner here — the parametric point (111.25, 200) is 34 points away.
        #expect(winner.position.distance(to: PDFPoint(x: 145, y: 200)) <= 1e-9)
    }

    @Test("The finding's curve: the midpoint splits the length in two halves")
    func findingCurve() throws {
        // p0 = p1 = (0, 0), p2 = (0, 100), p3 = (100, 100). The parametric midpoint is
        // (12.5, 50); the halves of the length are checked with an independent dense
        // integration (the trapezoid rule on 200 000 chords, converged to ~1e-9).
        let p0 = PDFPoint(x: 0, y: 0), p2 = PDFPoint(x: 0, y: 100), p3 = PDFPoint(x: 100, y: 100)
        let t = SnapCurveMath.arcLengthMidpointParameter(p0, p0, p2, p3)
        func chordLength(_ a: Double, _ b: Double) -> Double {
            let n = 200_000
            var total = 0.0
            var previous = SnapCurveMath.cubicPoint(p0, p0, p2, p3, at: a)
            for i in 1...n {
                let point = SnapCurveMath.cubicPoint(p0, p0, p2, p3, at: a + (b - a) * Double(i) / Double(n))
                total += point.distance(to: previous)
                previous = point
            }
            return total
        }
        let first = chordLength(0, t)
        let second = chordLength(t, 1)
        #expect(Swift.abs(first - second) <= 1e-6, "halves \(first) and \(second)" as Comment)
        let point = SnapCurveMath.cubicPoint(p0, p0, p2, p3, at: t)
        // The finding's own estimate: (28.0, 72.4), 27.3 page points from (12.5, 50).
        #expect(Swift.abs(point.x - 28.0) <= 0.1 && Swift.abs(point.y - 72.4) <= 0.1, "\(point)" as Comment)
        #expect(point.distance(to: PDFPoint(x: 12.5, y: 50)) > 27)
    }
}
