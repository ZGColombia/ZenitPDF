import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// V-084 — the Scale Region samplers
/// call the one chord step rule (`BulgeArc.chordSteps`) instead of copying it with its 1e-3 rad floor.
@Suite("Iteration 5 — quantities core, geometry")
struct Iter5QuantitiesCoreGeometryTests {

    /// A loose arc of r = 1e7 pt about the origin from 0 through 0.01 rad (a 100 000 pt chord, inside
    /// the 1e7 coordinate bound). At the 0.25 pt sampling tolerance the widest step is
    /// 4·asin(√(0.25 / 2e7)) = 4.472e-4 rad, so ⌈0.01 / 4.472e-4⌉ = ⌈22.36⌉ = 23 chords: 22 samples
    /// strictly inside, every chord's sagitta 2r·sin²(0.01/92) = 0.236 pt ≤ 0.25.
    /// Old output: 9 samples (10 chords, the 1e-3 rad floor), each chord of sagitta
    /// r·(1 − cos(0.0005)) = 1.25 pt — five times the tolerance.
    @Test("V-084: a loose arc's samples keep every chord within the sampling tolerance")
    func looseArcSamplesMeetTheTolerance() {
        let arc = ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 1e7, startAngle: 0, sweepAngle: 0.01)
        let samples = ScaleRegionResolver.curveSamples(of: arc)
        #expect(samples.count == 22, "\(samples.count) samples; old 9")
        let path = [arc.startPoint] + samples + [arc.endPoint]
        var largest = 0.0
        for index in 1..<path.count {
            let mid = PDFPoint(x: (path[index - 1].x + path[index].x) / 2, y: (path[index - 1].y + path[index].y) / 2)
            largest = Swift.max(largest, 1e7 - mid.distance(to: arc.center))
        }
        #expect(largest <= ScaleRegionResolver.arcSampleTolerance, "largest chord sagitta \(largest); old 1.25")
    }

    /// The ellipse inscribed in (20, 60)–(180, 140) — R = max(80, 40) = 80 — is sampled at the same
    /// rule: 4·asin(√(0.25 / 160)) = 0.15813 rad, ⌈2π / 0.15813⌉ = ⌈39.73⌉ = 40 curve samples, the
    /// count the old acos form gave too (it only differed past its floor).
    @Test("V-084: the ellipse sampler uses the one step rule")
    func ellipseSamplerUsesTheOneRule() {
        let box = PDFRect(x: 20, y: 60, width: 160, height: 80)
        #expect(ScaleRegionResolver.ellipseSamples(in: box).count == 5 + 40)
        #expect(BulgeArc.chordSteps(radius: 80, sweep: 2 * Double.pi, tolerance: ScaleRegionResolver.arcSampleTolerance, minimum: 4) == 40)
    }
}
