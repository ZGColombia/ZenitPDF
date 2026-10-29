import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

// Regression tests for the second bug hunt (engine fixes, package ZPDFGeometry).
// Every expected number is derived by hand in the comment beside it; "old:" records what the
// code returned before the fix, so each test is known to fail on the old code.

// MARK: - Scale Regions (BH-161, BH-162, BH-552, BH-553, IM-065)

@Suite("Scale Region resolution regressions (BH-161, BH-162, BH-552, BH-553, IM-065)")
struct ScaleRegionRegressionTests {

    private func region(
        _ n: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        scale: Int = 1,
        priority: Int = 0
    ) -> ScaleRegion {
        ScaleRegion(
            id: Fixture.regionID(n),
            pageID: Fixture.pageID(0),
            scaleID: Fixture.scaleID(scale),
            boundary: Fixture.rectRing(x: x, y: y, width: width, height: height),
            priority: priority
        )
    }

    private func resolver(
        _ regions: [ScaleRegion],
        epsilon: GeometryEpsilon = .standard
    ) throws -> ScaleRegionResolver {
        try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: regions, epsilon: epsilon)
    }

    // BH-161 -------------------------------------------------------------------------------

    /// Old: every pair below threw `overlappingRegions`, because any edge contact
    /// (`.collinearOverlap` along a shared edge, `.point` at a shared corner) counted as
    /// overlap. None of them shares any area.
    @Test("Regions touching along an edge, part of an edge or a corner are not overlap (BH-161)")
    func touchingRegionsAreNotOverlap() throws {
        // Shared full edge x = 100, y 0...100: area in common = 0.
        let abutting = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 100, y: 0, width: 100, height: 100, scale: 2)
        ])
        #expect(throws: Never.self) { try abutting.validateNoOverlap() }

        // Shared half edge x = 100, y 50...100: area in common = 0.
        let partialEdge = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 100, y: 50, width: 100, height: 100, scale: 2)
        ])
        #expect(throws: Never.self) { try partialEdge.validateNoOverlap() }

        // Shared corner (100, 100) only.
        let corner = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 100, y: 100, width: 100, height: 100, scale: 2)
        ])
        #expect(throws: Never.self) { try corner.validateNoOverlap() }

        // A T-junction: two half-height frames stacked against the right edge of a third.
        let tee = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 100, y: 0, width: 100, height: 50, scale: 2),
            region(3, x: 100, y: 50, width: 100, height: 50, scale: 3)
        ])
        #expect(throws: Never.self) { try tee.validateNoOverlap() }
    }

    @Test("Regions sharing area are still overlap, including identical and edge-sharing nested frames (BH-161)")
    func sharedAreaIsStillOverlap() throws {
        // x 50...100 in common: 50 x 100 = 5 000 pt^2 shared.
        let crossing = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 50, y: 0, width: 100, height: 100, scale: 2)
        ])
        #expect(throws: ScaleApplicationError.overlappingRegions(Fixture.regionID(1), Fixture.regionID(2))) {
            try crossing.validateNoOverlap()
        }
        // Identical frames: no vertex strictly inside, no proper crossing, 10 000 pt^2 shared.
        let identical = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 0, y: 0, width: 100, height: 100, scale: 2)
        ])
        #expect(throws: ScaleApplicationError.overlappingRegions(Fixture.regionID(1), Fixture.regionID(2))) {
            try identical.validateNoOverlap()
        }
        // Left half nested against three edges of the parent: 5 000 pt^2 shared.
        let nestedOnEdges = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 0, y: 0, width: 50, height: 100, scale: 2)
        ])
        #expect(throws: ScaleApplicationError.overlappingRegions(Fixture.regionID(1), Fixture.regionID(2))) {
            try nestedOnEdges.validateNoOverlap()
        }
    }

    @Test("Abutting regions: each side resolves to its own region, the shared edge stays ambiguous (BH-161)")
    func abuttingResolution() throws {
        let r = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100),
            region(2, x: 100, y: 0, width: 100, height: 100, scale: 2)
        ])
        #expect(r.resolve(point: PDFPoint(x: 99, y: 50)) == .region(Fixture.regionID(1)))
        #expect(r.resolve(point: PDFPoint(x: 101, y: 50)) == .region(Fixture.regionID(2)))
        #expect(
            r.resolve(point: PDFPoint(x: 100, y: 50))
                == .ambiguous(ScaleRegionAmbiguity(
                    candidates: [Fixture.regionID(1), Fixture.regionID(2)],
                    includesPageDefault: false,
                    reason: .pointInOverlappingRegions
                ))
        )
    }

    // BH-162 -------------------------------------------------------------------------------

    /// A = (0,0)-(100,100) priority 0, scale 0.01 m/pt; B = (50,0)-(150,100) priority 1,
    /// scale 0.02 m/pt. They overlap in x 50...100.
    private func overlappingPair(priorityA: Int = 0, priorityB: Int = 1) throws -> ScaleRegionResolver {
        try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100, scale: 1, priority: priorityA),
            region(2, x: 50, y: 0, width: 100, height: 100, scale: 2, priority: priorityB)
        ])
    }

    @Test("highestPriorityWins never assigns a region to geometry with a vertex outside it (BH-162)")
    func priorityNeedsEveryVertex() throws {
        let r = try overlappingPair()
        // v1 (25, 50) is in A only; v2 (75, 50) is in A and B. Per-vertex owners: A, then B
        // (B's priority 1 > A's 0). Owners differ, so the markup crosses from A's area into
        // the area priority gives to B. Old: .region(B), measuring v1's part with B's scale.
        let line = [PDFPoint(x: 25, y: 50), PDFPoint(x: 75, y: 50)]
        #expect(
            try r.resolve(geometry: line, policy: .highestPriorityWins)
                == .ambiguous(ScaleRegionAmbiguity(
                    candidates: [Fixture.regionID(2), Fixture.regionID(1)],
                    includesPageDefault: false,
                    reason: .geometryCrossesRegionBoundary
                ))
        )

        let scales = [
            Fixture.scaleID(1): try Fixture.uniformScale(1, metresPerPoint: Decimal(string: "0.01")!),
            Fixture.scaleID(2): try Fixture.uniformScale(2, metresPerPoint: Decimal(string: "0.02")!)
        ]
        let pageDefault = try Fixture.uniformScale(9, metresPerPoint: Decimal(string: "0.05")!)
        // Old: 50 pt x 0.02 m/pt = 1 m under B's scale. New: no scale, so no number at all.
        #expect(
            try r.scale(
                for: r.resolve(geometry: line, policy: .highestPriorityWins),
                pageDefault: pageDefault, scales: scales
            ) == nil
        )

        // Both vertices in A and B: owners B, B -> B, whose scale gives 50 pt x 0.02 m/pt = 1 m.
        let inOverlap = [PDFPoint(x: 75, y: 25), PDFPoint(x: 75, y: 75)]
        let overlapResolution = try r.resolve(geometry: inOverlap, policy: .highestPriorityWins)
        #expect(overlapResolution == .region(Fixture.regionID(2)))
        let overlapScale = try #require(try r.scale(for: overlapResolution, pageDefault: pageDefault, scales: scales))
        #expect(abs(overlapScale.matrix.length(from: inOverlap[0], to: inOverlap[1]) - 1) <= 1e-15)

        // v1 (125, 50) in B only, v2 (75, 50) in both: owners B, B -> B.
        #expect(
            try r.resolve(geometry: [PDFPoint(x: 125, y: 50), PDFPoint(x: 75, y: 50)], policy: .highestPriorityWins)
                == .region(Fixture.regionID(2))
        )

        // Priorities swapped (A = 5, B = 1): owners of v1 and v2 are both A. 50 pt x 0.01 = 0.5 m.
        let aOnTop = try overlappingPair(priorityA: 5, priorityB: 1)
        let aResolution = try aOnTop.resolve(geometry: line, policy: .highestPriorityWins)
        #expect(aResolution == .region(Fixture.regionID(1)))
        let aScale = try #require(try aOnTop.scale(for: aResolution, pageDefault: pageDefault, scales: scales))
        #expect(abs(aScale.matrix.length(from: line[0], to: line[1]) - 0.5) <= 1e-15)

        // A tie at a vertex stays a tie: both vertices in A and B at priority 3.
        let tied = try overlappingPair(priorityA: 3, priorityB: 3)
        guard case .ambiguous(let tie) = try tied.resolve(geometry: inOverlap, policy: .highestPriorityWins) else {
            Issue.record("a tied overlap must stay ambiguous")
            return
        }
        #expect(tie.reason == .tiedPriorities)
    }

    @Test("A line inside one of two abutting regions ending on the shared edge is not handed to the other (BH-162)")
    func priorityOnSharedEdge() throws {
        let r = try resolver([
            region(1, x: 0, y: 0, width: 100, height: 100, scale: 1, priority: 0),
            region(2, x: 100, y: 0, width: 100, height: 100, scale: 2, priority: 1)
        ])
        // v1 (50, 50) in A only; v2 (100, 50) on the shared edge, so in both. Owners A, B.
        // Old: .region(B) for a line lying entirely in A's closure.
        let resolution = try r.resolve(
            geometry: [PDFPoint(x: 50, y: 50), PDFPoint(x: 100, y: 50)],
            policy: .highestPriorityWins
        )
        #expect(resolution.isAmbiguous)
        if case .region(let owner) = resolution {
            Issue.record("Old: .region(\(owner)) for a line lying entirely in A's closure")
        }
    }

    // BH-552 -------------------------------------------------------------------------------

    @Test("An arc is sampled on its curve, not at its centre (BH-552)")
    func arcSampling() throws {
        let r = try resolver([region(1, x: 0, y: 0, width: 400, height: 400)])

        // Centre (200, -1000), radius 1100, sweep pi/2 -/+ 0.1: start (200 + 1100 sin 0.1,
        // -1000 + 1100 cos 0.1) = (309.8, 94.5), end (90.2, 94.5), mid-sweep (200, 100) — all
        // inside the region; the centre is 1000 pt below it. Old: .ambiguous(partly outside).
        let shallow = ArcGeometry(center: PDFPoint(x: 200, y: -1000), radius: 1100,
                                  startAngle: .pi / 2 - 0.1, sweepAngle: 0.2)
        let shallowGeometry = MeasurementGeometry(pageID: Fixture.pageID(0), arcs: [shallow])
        #expect(try r.resolve(geometry: shallowGeometry) == .region(Fixture.regionID(1)))

        // Centre (200, 300), radius 150, start pi -> (50, 300), sweep -pi -> end (350, 300),
        // mid-sweep angle pi/2 -> (200, 450): the arc leaves the region at the top. Old: start,
        // end and centre were all inside, so it resolved to region 1 despite the bulge.
        let bulging = ArcGeometry(center: PDFPoint(x: 200, y: 300), radius: 150,
                                  startAngle: .pi, sweepAngle: -.pi)
        let bulgingGeometry = MeasurementGeometry(pageID: Fixture.pageID(0), arcs: [bulging])
        guard case .ambiguous(let ambiguity) = try r.resolve(geometry: bulgingGeometry) else {
            Issue.record("an arc leaving the region must be ambiguous")
            return
        }
        #expect(ambiguity.reason == .geometryPartlyOutsideAnyRegion)
        #expect(ambiguity.includesPageDefault)
    }

    // BH-553 -------------------------------------------------------------------------------

    @Test("The R-tree prefilter honours the on-boundary tolerance on both sides of an edge (BH-553)")
    func prefilterMatchesBoundaryRule() throws {
        // onSegment = 2 pt. Region (0,0)-(100,100).
        let epsilon = GeometryEpsilon(
            pointMerge: 2e-3,
            onSegment: 2,
            parallel: GeometryEpsilon.standard.parallel,
            areaFloor: 4e-6
        )
        let r = try resolver([region(1, x: 0, y: 0, width: 100, height: 100)], epsilon: epsilon)
        // 1 pt inside the right edge: inside.
        #expect(r.resolve(point: PDFPoint(x: 99, y: 50)) == .region(Fixture.regionID(1)))
        // 1 pt outside it: distance 1 <= 2, on the boundary, which counts as inside.
        // Old: the zero-size query missed the bounding box (101 > maxX 100) -> .pageDefault.
        #expect(r.resolve(point: PDFPoint(x: 101, y: 50)) == .region(Fixture.regionID(1)))
        // 3 pt outside: distance 3 > 2 -> page default.
        #expect(r.resolve(point: PDFPoint(x: 103, y: 50)) == .pageDefault)
    }

    // IM-065 -------------------------------------------------------------------------------

    @Test("Rank lookup is built once and tolerates a duplicated region id (IM-065)")
    func rankTableIsRobust() throws {
        // Old: sortedByPriority built Dictionary(uniqueKeysWithValues:) per vertex, which traps
        // on a duplicated id the first time two regions are hit. Now the first occurrence wins.
        let duplicate = ScaleRegion(
            id: Fixture.regionID(1), pageID: Fixture.pageID(0), scaleID: Fixture.scaleID(2),
            boundary: Fixture.rectRing(x: 50, y: 0, width: 100, height: 100)
        )
        let r = try resolver([region(1, x: 0, y: 0, width: 100, height: 100), duplicate])
        #expect(r.resolve(point: PDFPoint(x: 75, y: 50)).isAmbiguous)
        #expect(r.resolve(point: PDFPoint(x: 25, y: 50)) == .region(Fixture.regionID(1)))

        // scale(for:) goes through the rank table: region 2 names scale 2 (0.02 m/pt).
        let pair = try overlappingPair()
        let scale2 = try Fixture.uniformScale(2, metresPerPoint: Decimal(string: "0.02")!)
        let found = try pair.scale(
            for: .region(Fixture.regionID(2)),
            pageDefault: try Fixture.uniformScale(9),
            scales: [Fixture.scaleID(2): scale2]
        )
        #expect(found == scale2)
        #expect(
            try pair.scale(for: .region(Fixture.regionID(77)), pageDefault: try Fixture.uniformScale(9), scales: [:])
                == nil
        )
    }

    // BH-551 -------------------------------------------------------------------------------

    @Test("A self-intersecting region boundary is reported as such, not as zero area (BH-551)")
    func bowTieBoundary() throws {
        // (0,0) -> (100,100) -> (100,0) -> (0,100) crosses itself at (50, 50).
        let bowTie = ScaleRegion(
            id: Fixture.regionID(1), pageID: Fixture.pageID(0), scaleID: Fixture.scaleID(1),
            boundary: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 100),
                PDFPoint(x: 100, y: 0), PDFPoint(x: 0, y: 100)
            ])
        )
        // Old: .invalidRegionBoundary(id, underlying: .degeneratePolygon(signedArea: 0)).
        #expect(throws: ScaleApplicationError.invalidRegionBoundary(Fixture.regionID(1), underlying: .selfIntersectingRing)) {
            try bowTie.validate()
        }
    }
}

// MARK: - Hole disjointness (BH-160)

/// BH-160 was found in `PolygonMath.requireDisjointInteriorHoles`, deleted with its only caller
/// `ScaleApplication` (R-174). The pairwise test it rested on, `interiorsOverlap`, is live (Scale
/// Region overlap validation), so the BH-160 configurations are asserted on it directly.
@Suite("Interior overlap regressions (BH-160)")
struct HoleDisjointnessRegressionTests {

    @Test("Rings that overlap while sharing boundary are overlap (BH-160)")
    func overlappingRingsSharingBoundary() throws {
        // A = (0,0)-(10,10) lies inside B = (0,0)-(10,20), sharing three edges.
        let a = Fixture.rectRing(x: 0, y: 0, width: 10, height: 10).points
        let b = Fixture.rectRing(x: 0, y: 0, width: 10, height: 20).points
        #expect(PolygonMath.interiorsOverlap(a, b))
        // The same 10 x 10 ring pasted twice, and pasted wound the other way.
        let pasted = Fixture.rectRing(x: 20, y: 20, width: 10, height: 10).points
        #expect(PolygonMath.interiorsOverlap(pasted, pasted))
        #expect(PolygonMath.interiorsOverlap(pasted, Array(pasted.reversed())))
    }

    @Test("Rings that only touch are not overlap (BH-160)")
    func touchingRingsAreNotOverlap() throws {
        // Sharing the edge x = 30.
        let left = Fixture.rectRing(x: 20, y: 20, width: 10, height: 10).points
        #expect(!PolygonMath.interiorsOverlap(left, Fixture.rectRing(x: 30, y: 20, width: 10, height: 10).points))
        // Sharing half an edge (x = 30, y 25...30), one wound clockwise.
        let clockwise = Array(Fixture.rectRing(x: 30, y: 25, width: 10, height: 10).points.reversed())
        #expect(!PolygonMath.interiorsOverlap(left, clockwise))
    }

    @Test("A ring filling the notch of a concave ring does not overlap it (BH-160)")
    func ringInNotchIsNotOverlap() throws {
        // U shape: 30 x 30 minus the notch x 10...20, y 10...30. The notch rectangle shares
        // three edges with the U and lies outside it.
        let u = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 30, y: 0), PDFPoint(x: 30, y: 30),
            PDFPoint(x: 20, y: 30), PDFPoint(x: 20, y: 10), PDFPoint(x: 10, y: 10),
            PDFPoint(x: 10, y: 30), PDFPoint(x: 0, y: 30)
        ]
        #expect(PolygonMath.area(u) == 700)
        #expect(!PolygonMath.interiorsOverlap(u, Fixture.rectRing(x: 10, y: 10, width: 10, height: 20).points))
    }
}

// MARK: - Low-level polygon, epsilon and summation fixes (BH-549, BH-550, BH-554, BH-555, BH-556)

@Suite("Polygon, epsilon and summation regressions (BH-549, BH-550, BH-554, BH-555, BH-556)")
struct LowLevelGeometryRegressionTests {

    @Test("Wrap-around duplicate removal repeats until the ring is clean (BH-549)")
    func wrapAroundDedupRepeats() throws {
        // A (0,0), B (100,0), X (0, 8e-7), Y (8e-7, 0). |XY| = 8e-7 * sqrt 2 = 1.13e-6 > 1e-6,
        // so the sequential pass keeps both. Wrap: |YA| = 8e-7 <= 1e-6 drops Y, then
        // |XA| = 8e-7 drops X. Old: [A, B, X] with one duplicate removed.
        let a = PDFPoint(x: 0, y: 0)
        let b = PDFPoint(x: 100, y: 0)
        let ring = [a, b, PDFPoint(x: 0, y: 8e-7), PDFPoint(x: 8e-7, y: 0)]
        let result = try PolygonCleanup.cleanup(ring)
        #expect(result.points == [a, b])
        #expect(result.removedDuplicates == 2)
        // Old: accepted as a three-vertex sliver of ~zero area.
        #expect(throws: GeometryError.fewerThanThreeUniquePoints(count: 2)) {
            try PolygonMath.requireSimplePolygon(ring)
        }
    }

    @Test("An open two-edge polyline that folds back is reported (BH-550)")
    func openSpike() throws {
        let a = PDFPoint(x: 0, y: 0)
        let b = PDFPoint(x: 10, y: 0)
        // Old: [] and isSimple == true for the documented A -> B -> A spike.
        let found = try PolygonMath.selfIntersections([a, b, a], isClosed: false)
        #expect(found.count == 1)
        #expect(found.first?.kind == .collinearOverlap)
        #expect(found.first?.firstEdgeIndex == 0)
        #expect(found.first?.secondEdgeIndex == 1)
        // Controls: a straight and a bent three-point polyline are simple.
        #expect(try PolygonMath.selfIntersections([a, b, PDFPoint(x: 20, y: 0)], isClosed: false).isEmpty)
        #expect(try PolygonMath.selfIntersections([a, b, PDFPoint(x: 10, y: 10)], isClosed: false).isEmpty)
    }

    @Test("An infinite term gives an infinite total, not NaN (BH-555)")
    func kahanInfinity() {
        var accumulator = KahanAccumulator()
        accumulator.add(1)
        accumulator.add(.infinity)
        accumulator.add(2)
        // 1 + inf + 2 = inf. Old: compensation (inf - inf) + 1 = NaN, total NaN.
        #expect(accumulator.total == .infinity)

        var negative = KahanAccumulator()
        negative.add(-.infinity)
        #expect(negative.total == -.infinity)

        // inf + (-inf) has no sum: NaN is the honest answer.
        var both = KahanAccumulator()
        both.add(.infinity)
        both.add(-.infinity)
        #expect(both.total.isNaN)

        // Finite terms keep the compensated result: 1e16 + 1 - 1e16 = 1 exactly (naive: 0).
        var finite = KahanAccumulator()
        for term in [1e16, 1, -1e16] { finite.add(term) }
        #expect(finite.total == 1)
        #expect(finite.total == NumericPolicy.kahanSum([1e16, 1, -1e16]))

        // Perimeter of an open chain through an infinite vertex: inf + inf = inf. Old: NaN.
        let chain = [PDFPoint(x: 0, y: 0), PDFPoint(x: .infinity, y: 0), PDFPoint(x: 0, y: 1)]
        #expect(PolygonMath.perimeter(chain, isClosed: false) == .infinity)
    }

    @Test("vector(to:) is other - self, as the corrected contract says (BH-556)")
    func vectorDirection() {
        let p = PDFPoint(x: 1, y: 2)
        let q = PDFPoint(x: 4, y: 6)
        // q - p = (3, 4).
        #expect(p.vector(to: q) == PDFVector(dx: 3, dy: 4))
        #expect(p.vector(to: q) == PDFVector(from: p, to: q))
        #expect(p.offset(by: p.vector(to: q)) == q)
    }
}
