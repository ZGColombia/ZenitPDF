import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// IM-235: circle fits and segment angles are computed once per engine, so a query is a
/// filter over stored fits rather than a refit of every chain.
struct CircleFitCacheTests {

    @Test("Twenty radius queries over 10 000 circles are a filter, not twenty refits")
    func repeatedCircleQueriesReuseTheFits() throws {
        // 5 000 circles of radius 10 and 5 000 of radius 20 on a 100 × 100 grid, each its
        // own subpath (distinct sourceObjectID) so every one is a chain of four cubics.
        var curves: [GeometryQueryCurve] = []
        curves.reserveCapacity(40_000)
        var nextID: UInt64 = 1
        for index in 0..<10_000 {
            let radius = index % 2 == 0 ? 10.0 : 20.0
            let centre = CGPoint(x: 50 + Double(index % 100) * 60, y: 50 + Double(index / 100) * 60)
            curves += ValidationGuardTests.circleCurves(
                firstID: nextID, sourceObjectID: UInt64(index), centre: centre, radius: radius
            )
            nextID += 4
        }
        let engine = try GeometryQueryEngine(segments: [], curves: curves)
        #expect(engine.curveChainFits.count == 10_000)

        // Hand-derived: exactly 5 000 chains fit radius 10 (the four-cubic circle
        // deviates by 2.7253e-4 · r, far inside the 1 % bar, with a full 2π sweep) and
        // exactly 5 000 fit radius 20; the default result limit is 5 000 and CR-46 says
        // a page with exactly the limit is complete, not truncated.
        let clock = ContinuousClock()
        var found = 0
        let queryTime = clock.measure {
            for step in 0..<20 {
                let radius = step % 2 == 0 ? 10.0 : 20.0
                let result = engine.circles(radius: radius, tolerance: 0.5)
                #expect(result.count == 5_000)
                #expect(result.status == .complete)
                found += result.count
            }
        }
        #expect(found == 100_000)
        #expect(engine.circles(radius: 15, tolerance: 0.5).count == 0)

        // What every query used to do: regroup the chains and refit each one.
        var refitted = 0
        let refitTime = clock.measure {
            for _ in 0..<20 {
                for chain in GeometryQueryEngine.curveChains(curves) {
                    if GeometryQueryEngine.rawCircleFit(chain)?
                        .isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1) == true {
                        refitted += 1
                    }
                }
            }
        }
        #expect(refitted == 200_000)
        print("IM-235: 20 circle queries over 10 000 chains: filter \(queryTime), refit \(refitTime)")
        #expect(queryTime < refitTime / 5, "stored fits should make a query far cheaper than a refit")
    }

    @Test("W-086: one acceptance bar, max(floor, fraction × radius), shared by circles() and the refit baseline")
    func oneAcceptanceBar() throws {
        func fit(radius: Double, deviation: Double) -> GeometryQueryEngine.CircleFit {
            GeometryQueryEngine.CircleFit(center: .zero, radius: radius, maximumDeviation: deviation, sweepRadians: 2 * .pi)
        }
        // Radius 10, fraction 1 %: 0.1 pt, equal to the 0.1 pt floor — on the bar is accepted.
        #expect(fit(radius: 10, deviation: 0.1).isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1))
        #expect(!fit(radius: 10, deviation: 0.1000001).isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1))
        // Radius 100: the fraction wins, 1 pt.
        #expect(fit(radius: 100, deviation: 0.99).isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1))
        #expect(!fit(radius: 100, deviation: 1.01).isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1))
        // Radius 2: the floor wins, 0.1 pt, not 0.02.
        #expect(fit(radius: 2, deviation: 0.05).isAccepted(fitToleranceFraction: 0.01, minimumFitTolerance: 0.1))

        // The baseline and the product filter agree chain for chain. A four-cubic circle of
        // radius 10 deviates from the true circle by up to 2.7253e-4 · 10 ≈ 0.0027 pt, so its
        // fit deviation is inside a 0.1 pt bar and outside a 1e-6 pt one (fraction 0 leaves
        // only the floor).
        let curves = ValidationGuardTests.circleCurves(firstID: 1, sourceObjectID: 1, centre: CGPoint(x: 50, y: 50), radius: 10)
        let engine = try GeometryQueryEngine(segments: [], curves: curves)
        let chain = try #require(GeometryQueryEngine.curveChains(curves).first)
        for (fraction, floor) in [(0.01, 0.1), (0.0, 1e-6)] {
            let baseline = GeometryQueryEngine.rawCircleFit(chain)?
                .isAccepted(fitToleranceFraction: fraction, minimumFitTolerance: floor) == true
            let product = engine.circles(
                radius: 10, tolerance: 0.5, fitToleranceFraction: fraction, minimumFitTolerance: floor
            ).count == 1
            #expect(baseline == product)
            #expect(baseline == (fraction > 0))
        }
    }

    @Test("The stored angles are the segments' own")
    func storedAnglesMatch() throws {
        let segments = (0..<200).map { index -> GeometryQuerySegment in
            let angle = Double(index) * 0.031
            return GeometryQuerySegment(
                primitiveID: UInt64(index + 1),
                start: CGPoint(x: Double(index), y: 0),
                end: CGPoint(x: Double(index) + cos(angle) * 10, y: sin(angle) * 10)
            )
        }
        let engine = try GeometryQueryEngine(segments: segments)
        #expect(engine.lineAngles == segments.map(\.lineAngle))
    }
}
