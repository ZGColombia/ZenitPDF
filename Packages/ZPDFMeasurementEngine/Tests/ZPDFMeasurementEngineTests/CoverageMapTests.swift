import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// The coverage map (an opt-in toggle), engine half.
///
/// Every expected number below is derived by hand from the fixture and written out in the comment
/// above it, so a failure says which piece of geometry is wrong rather than which snapshot moved.
/// No fixture depends on a previously recorded engine output.
///
/// The tolerance is `1e-9` square PDF points on values of order 1e4 — `1e-13` relative, which is
/// QUALITY_BAR §2.1's floating-point-level agreement for closed-form geometry. It is affordable
/// because every coordinate in every fixture is an exact multiple of the Clipper2 lattice step
/// (1e-6 pt), so the booleans introduce no quantisation at all. Where a fraction is a dyadic
/// rational — a half, a quarter, a sixteenth — it is asserted with `==`, not with a tolerance.
@Suite("Coverage map")
struct CoverageMapTests {

    let map = CoverageMap()

    static let exact = 1e-9

    // MARK: - Helpers

    private func ring(_ pairs: [(Double, Double)]) -> PolygonRing {
        PolygonRing(points: pairs.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true)
    }

    private func polygon(
        _ outer: [(Double, Double)],
        holes: [[(Double, Double)]] = []
    ) -> PolygonGeometry {
        PolygonGeometry(outer: ring(outer), holes: holes.map(ring))
    }

    /// An axis-aligned rectangle as a measured area, corner to corner.
    private func rect(
        _ minX: Double,
        _ minY: Double,
        _ maxX: Double,
        _ maxY: Double
    ) -> PolygonGeometry {
        polygon([(minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)])
    }

    /// The net area of one measured polygon in square PDF points, through the coverage map's
    /// single area routine (what the deleted `CoverageMap.measuredPDFArea` returned).
    private func netArea(_ polygon: PolygonGeometry) throws -> Double {
        CoverageRegions.pdfArea(of: try CoverageRegions.netRegion(of: polygon, options: .default))
    }

    private func area(_ polygon: PolygonGeometry) -> Double {
        CoverageRegions.pdfArea(of: polygon)
    }

    private func totalArea(_ polygons: [PolygonGeometry]) -> Double {
        polygons.reduce(0) { $0 + area($1) }
    }

    private func minX(_ polygon: PolygonGeometry) -> Double {
        polygon.outer.uniquePoints.map(\.x).min() ?? .nan
    }

    private func maxX(_ polygon: PolygonGeometry) -> Double {
        polygon.outer.uniquePoints.map(\.x).max() ?? .nan
    }

    private func hasVertex(_ polygon: PolygonGeometry, _ x: Double, _ y: Double) -> Bool {
        polygon.outer.uniquePoints.contains { abs($0.x - x) <= 1e-6 && abs($0.y - y) <= 1e-6 }
    }

    /// Covered and uncovered are exact complements inside the extent — one is `extent ∩ union`,
    /// the other is `extent - union`. This is asserted on every fixture, not just where it is
    /// interesting, because a coverage map whose two halves do not add up to the sheet is a
    /// coverage map that is hiding a region somewhere.
    private func assertComplement(_ result: CoverageResult, label: String) {
        let coveredFromPolygons = totalArea(result.coveredPolygons)
        let uncoveredFromPolygons = totalArea(result.uncoveredPolygons)
        print(
            """
            [coverage] \(label): covered = \(result.coveredPDFArea) pt^2 \
            (polygons \(coveredFromPolygons)), uncovered = \(result.extentPDFArea - result.coveredPDFArea) pt^2 \
            (polygons \(uncoveredFromPolygons)), extent = \(result.extentPDFArea) pt^2, \
            fraction = \(result.coveredFraction) of \(result.denominator.rawValue)
            """
        )
        #expect(abs(coveredFromPolygons - result.coveredPDFArea) <= Self.exact)
        #expect(abs(uncoveredFromPolygons - Swift.max(result.extentPDFArea - result.coveredPDFArea, 0)) <= Self.exact)
        #expect(
            abs(result.coveredPDFArea + uncoveredFromPolygons - result.extentPDFArea)
                <= Self.exact
        )
        #expect(result.coveredFraction >= 0 && result.coveredFraction <= 1)
    }

    // MARK: - 1. Nothing measured

    /// An empty measured list over a 200 x 100 page box: 20 000 pt^2, none of it covered, all of
    /// it uncovered, and the uncovered region is the extent itself.
    @Test("With nothing measured, the whole extent is uncovered and the fraction is zero")
    func emptyMeasuredCoversNothing() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 200, height: 100))
        let result = try map.coverage(of: [], within: extent)

        #expect(result.coveredPolygons.isEmpty)
        #expect(result.coveredPDFArea == 0)
        #expect(abs(result.extentPDFArea - 20_000) <= Self.exact)
        #expect(result.coveredFraction == 0)
        #expect(result.denominator == .pageBox)

        // Uncovered is the extent, whole and in one piece.
        #expect(result.uncoveredPolygons.count == 1)
        let uncovered = try #require(result.uncoveredPolygons.first)
        #expect(abs(area(uncovered) - 20_000) <= Self.exact)
        #expect(uncovered.outer.uniquePoints.count == 4)
        #expect(uncovered.holes.isEmpty)
        #expect(hasVertex(uncovered, 0, 0))
        #expect(hasVertex(uncovered, 200, 0))
        #expect(hasVertex(uncovered, 200, 100))
        #expect(hasVertex(uncovered, 0, 100))

        assertComplement(result, label: "empty measured")
    }

    // MARK: - 2. Half a sheet measured

    /// One 100 x 100 area in a 200 x 100 extent.
    ///
    /// Hand-derived: covered 100 x 100 = 10 000, extent 200 x 100 = 20 000, so the fraction is
    /// exactly 1/2 and the uncovered half is the rectangle [100,200] x [0,100] = 10 000.
    @Test("One 100 x 100 area in a 200 x 100 extent is exactly half, and the other half is named")
    func oneAreaCoversExactlyHalf() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 200, height: 100))
        let result = try map.coverage(of: [rect(0, 0, 100, 100)], within: extent)

        #expect(abs(result.coveredPDFArea - 10_000) <= Self.exact)
        #expect(abs(result.extentPDFArea - 20_000) <= Self.exact)
        // 10 000 / 20 000 is representable exactly; a tolerance here would hide a real drift.
        #expect(result.coveredFraction == 0.5)

        #expect(result.coveredPolygons.count == 1)
        #expect(result.uncoveredPolygons.count == 1)
        let uncovered = try #require(result.uncoveredPolygons.first)
        #expect(abs(area(uncovered) - 10_000) <= Self.exact)
        #expect(minX(uncovered) == 100)
        #expect(maxX(uncovered) == 200)

        assertComplement(result, label: "half measured")
    }

    // MARK: - 3. Two adjacent areas tiling the extent

    /// [0,100] x [0,100] and [100,200] x [0,100] in a 200 x 100 extent. They share the edge
    /// x = 100 and nothing else: 10 000 + 10 000 = 20 000 = the whole extent, fraction 1.
    ///
    /// The shared edge is also the case that must **not** register as an overlap: adjacency is
    /// how a takeoff covers a plan, and a warning there would fire on every drawing.
    @Test("Two adjacent areas tile the extent: fraction 1, nothing uncovered, no overlap")
    func adjacentAreasTileTheExtent() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 200, height: 100))
        let measured = [rect(0, 0, 100, 100), rect(100, 0, 200, 100)]
        let result = try map.coverage(of: measured, within: extent)

        #expect(abs(result.coveredPDFArea - 20_000) <= Self.exact)
        #expect(result.coveredFraction == 1.0)
        #expect(result.uncoveredPolygons.isEmpty)
        #expect(result.extentPDFArea - result.coveredPDFArea <= Self.exact)

        // The union is one rectangle, not two abutting ones: the shared edge is gone.
        #expect(result.coveredPolygons.count == 1)
        let covered = try #require(result.coveredPolygons.first)
        #expect(covered.outer.uniquePoints.count == 4)

        // Sharing an edge is not a double count (the engine's one overlap rule, R-175).
        #expect(try OverlapGuard.overlaps(of: measured).isEmpty)

        assertComplement(result, label: "adjacent tiles")
    }

    // MARK: - 4. Two overlapping areas

    /// A = [0,120] x [0,100] = 12 000. B = [70,200] x [0,100] = 13 000. Sum 25 000.
    /// They share the 50 pt strip [70,120] x [0,100] = **5 000**, so the union is
    /// [0,200] x [0,100] = **20 000**.
    ///
    /// The extent is 400 x 100 = 40 000, chosen so both candidate answers are exact and
    /// different: the union gives 20 000 / 40 000 = **0.5**, the sum would give
    /// 25 000 / 40 000 = **0.625**. A coverage map that added the areas would read 62.5 % on a
    /// sheet that is half measured.
    @Test("Overlapping areas are unioned, not summed, and overlaps() returns the shared strip")
    func overlappingAreasAreCountedOnce() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 400, height: 100))
        let a = rect(0, 0, 120, 100)
        let b = rect(70, 0, 200, 100)
        let result = try map.coverage(of: [a, b], within: extent)

        let sumOfAreas = try netArea(a) + netArea(b)
        print("[coverage] sum of measured areas = \(sumOfAreas) pt^2")
        #expect(abs(sumOfAreas - 25_000) <= Self.exact)

        #expect(abs(result.coveredPDFArea - 20_000) <= Self.exact)
        #expect(abs(result.extentPDFArea - 40_000) <= Self.exact)
        #expect(result.coveredFraction == 0.5)
        // The number the sum would have produced, pinned so the distinction cannot rot.
        #expect(result.coveredFraction != 0.625)

        // Uncovered is the right-hand [200,400] x [0,100] = 20 000.
        #expect(result.uncoveredPolygons.count == 1)
        let uncovered = try #require(result.uncoveredPolygons.first)
        #expect(abs(area(uncovered) - 20_000) <= Self.exact)
        #expect(minX(uncovered) == 200)
        #expect(maxX(uncovered) == 400)

        // The double count itself: exactly the 50 pt strip, once, through the engine's one
        // overlap rule (R-175).
        let overlaps = try OverlapGuard.overlaps(of: [a, b])
        #expect(overlaps.count == 1)
        let pair = try #require(overlaps.first)
        #expect(pair.first == 0 && pair.second == 1)
        #expect(abs(pair.pageArea - 5_000) <= Self.exact)
        let strip = try #require(pair.region.first)
        #expect(abs(area(strip) - 5_000) <= Self.exact)
        #expect(strip.outer.uniquePoints.count == 4)
        #expect(minX(strip) == 70)
        #expect(maxX(strip) == 120)

        // sum - union is the overlap, from one area routine on both sides.
        #expect(abs(sumOfAreas - result.coveredPDFArea - 5_000) <= Self.exact)

        assertComplement(result, label: "overlapping areas")
    }

    // MARK: - 5. A hole is not covered

    /// A 200 x 100 measured area with a 40 x 20 courtyard cut out of it, in a 200 x 100 page box.
    ///
    /// Hand-derived: the hole is 40 x 20 = 800, so the net measured region is 20 000 - 800 =
    /// **19 200**, the fraction is 19 200 / 20 000 = **0.96**, and the uncovered region is the
    /// courtyard itself — nobody measured it, so it stays lit.
    @Test("A hole in a measured area stays uncovered, as its own region")
    func holeStaysUncovered() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 200, height: 100))
        let courtyard = polygon(
            [(0, 0), (200, 0), (200, 100), (0, 100)],
            holes: [[(80, 40), (120, 40), (120, 60), (80, 60)]]
        )
        let result = try map.coverage(of: [courtyard], within: extent)

        #expect(abs(result.coveredPDFArea - 19_200) <= Self.exact)
        #expect(abs(result.coveredFraction - 0.96) <= 1e-12)
        #expect(abs(result.extentPDFArea - result.coveredPDFArea - 800) <= Self.exact)

        // The covered region keeps the courtyard as a hole.
        #expect(result.coveredPolygons.count == 1)
        let covered = try #require(result.coveredPolygons.first)
        #expect(covered.holes.count == 1)

        // And the courtyard comes back as an uncovered region in its own right.
        #expect(result.uncoveredPolygons.count == 1)
        let hole = try #require(result.uncoveredPolygons.first)
        print("[coverage] uncovered courtyard area = \(area(hole)) pt^2")
        #expect(abs(area(hole) - 800) <= Self.exact)
        #expect(hole.outer.uniquePoints.count == 4)
        #expect(hasVertex(hole, 80, 40))
        #expect(hasVertex(hole, 120, 60))

        assertComplement(result, label: "hole stays uncovered")
    }

    // MARK: - 6. An area that runs off the extent

    /// Extent [0,100] x [0,100] = 10 000. The measured area is [50,250] x [0,100] = 20 000 —
    /// twice the extent, and mostly outside it.
    ///
    /// Only the inside part counts: [50,100] x [0,100] = **5 000**, fraction exactly 1/2. Without
    /// the clip the fraction would be 2.0, which is why it is asserted rather than assumed.
    @Test("A measured area partly outside the extent contributes only the part inside")
    func areaOutsideTheExtentIsClipped() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 100, height: 100))
        let overhanging = rect(50, 0, 250, 100)

        let unclipped = try netArea(overhanging)
        print("[coverage] measured area before clipping = \(unclipped) pt^2")
        #expect(abs(unclipped - 20_000) <= Self.exact)

        let result = try map.coverage(of: [overhanging], within: extent)
        #expect(abs(result.coveredPDFArea - 5_000) <= Self.exact)
        #expect(abs(result.extentPDFArea - 10_000) <= Self.exact)
        #expect(result.coveredFraction == 0.5)

        // The covered region is clipped at the extent's right edge, not at the area's.
        #expect(result.coveredPolygons.count == 1)
        let covered = try #require(result.coveredPolygons.first)
        #expect(minX(covered) == 50)
        #expect(maxX(covered) == 100)

        // Uncovered is the strip the area never reached: [0,50] x [0,100] = 5 000.
        #expect(result.uncoveredPolygons.count == 1)
        let uncovered = try #require(result.uncoveredPolygons.first)
        #expect(abs(area(uncovered) - 5_000) <= Self.exact)
        #expect(minX(uncovered) == 0)
        #expect(maxX(uncovered) == 50)

        assertComplement(result, label: "area clipped to extent")
    }

    // MARK: - 7. The denominator changes the answer and says so

    /// One 100 x 100 area at [100,200] x [100,200] = 10 000, measured twice against the same
    /// input with two different denominators:
    ///
    /// * page box 400 x 400 = 160 000 -> 10 000 / 160 000 = **0.0625**
    /// * ink bounds 200 x 200 = 40 000 -> 10 000 / 40 000 = **0.25**
    ///
    /// Four times apart on identical geometry. This is the coverage invariant — the
    /// percentage has to name what it is a percentage of, "or an A1 sheet with a small plan reads
    /// as 80 % forgotten" — and the result carries the name.
    @Test("Ink bounds and page box give different fractions, and the result names which it used")
    func denominatorIsNamedAndChangesTheFraction() throws {
        let measured = [rect(100, 100, 200, 200)]

        let onPage = try map.coverage(
            of: measured,
            within: .pageBox(PDFRect(x: 0, y: 0, width: 400, height: 400))
        )
        let onInk = try map.coverage(
            of: measured,
            within: .inkBounds(PDFRect(x: 50, y: 50, width: 200, height: 200))
        )

        print(
            "[coverage] same geometry: \(onPage.coveredFraction) of \(onPage.denominator.rawValue) vs \(onInk.coveredFraction) of \(onInk.denominator.rawValue)"
        )

        // Same numerator both times.
        #expect(abs(onPage.coveredPDFArea - 10_000) <= Self.exact)
        #expect(abs(onInk.coveredPDFArea - 10_000) <= Self.exact)

        // Different denominators, both exact dyadic rationals.
        #expect(abs(onPage.extentPDFArea - 160_000) <= Self.exact)
        #expect(onPage.coveredFraction == 0.0625)
        #expect(onPage.denominator == .pageBox)

        #expect(abs(onInk.extentPDFArea - 40_000) <= Self.exact)
        #expect(onInk.coveredFraction == 0.25)
        #expect(onInk.denominator == .inkBounds)

        #expect(onPage.coveredFraction != onInk.coveredFraction)

        assertComplement(onPage, label: "page-box denominator")
        assertComplement(onInk, label: "ink-bounds denominator")
    }

    // MARK: - 8. Three areas on one room

    /// A = [0,100] x [0,100], B = [50,150] x [0,100], C = [25,125] x [0,100].
    ///
    /// Pairwise: A∩B = [50,100] = 5 000, A∩C = [25,100] = 7 500, B∩C = [50,125] = 7 500. The
    /// engine's overlap rule (R-175) names every pair, in first-then-second order, so the ledger
    /// can say which two markups double count.
    @Test("Three areas on one room: every overlapping pair is named with its shared area")
    func threeAreasOnOneRoom() throws {
        let measured = [rect(0, 0, 100, 100), rect(50, 0, 150, 100), rect(25, 0, 125, 100)]
        let overlaps = try OverlapGuard.overlaps(of: measured)
        #expect(overlaps.map { [$0.first, $0.second] } == [[0, 1], [0, 2], [1, 2]])
        #expect(abs(overlaps[0].pageArea - 5_000) <= Self.exact)
        #expect(abs(overlaps[1].pageArea - 7_500) <= Self.exact)
        #expect(abs(overlaps[2].pageArea - 7_500) <= Self.exact)
    }

    /// Areas that are nowhere near each other never reach a boolean at all: the R-tree offers no
    /// candidate pair, so no Clipper2 call is made.
    @Test("Disjoint areas produce no candidate pairs and no overlaps")
    func disjointAreasHaveNoOverlap() throws {
        let measured = [rect(0, 0, 10, 10), rect(500, 500, 510, 510)]
        #expect(CoverageMap.intersectingPartners(of: measured.map(\.bounds)) == [[], []])
        let (overlaps, calls) = try CutoutPipelineRegressionTests.countingClipperCalls {
            try OverlapGuard.overlaps(of: measured)
        }
        #expect(overlaps.isEmpty)
        #expect(calls == 0)
        #expect(try OverlapGuard.overlaps(of: [measured[0]]).isEmpty)
        #expect(try OverlapGuard.overlaps(of: []).isEmpty)
    }

    // MARK: - 9. Determinism

    /// A 300 x 100 extent with one 100 x 100 area in the middle leaves two uncovered regions of
    /// **exactly equal** area — 10 000 each — so the area alone decides nothing and the
    /// tie-breakers do all the work. Leftmost first, on every run.
    @Test("Region order is total and stable, including for regions of exactly equal area")
    func orderingIsDeterministic() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 300, height: 100))
        let measured = [rect(100, 0, 200, 100)]

        var seen: [[Double]] = []
        for _ in 0..<8 {
            let result = try map.coverage(of: measured, within: extent)
            #expect(result.uncoveredPolygons.count == 2)
            #expect(abs(area(result.uncoveredPolygons[0]) - 10_000) <= Self.exact)
            #expect(abs(area(result.uncoveredPolygons[1]) - 10_000) <= Self.exact)
            seen.append(result.uncoveredPolygons.map { minX($0) })
        }
        print("[coverage] leading x of the uncovered regions over 8 runs: \(seen)")
        #expect(seen.allSatisfy { $0 == seen[0] })
        #expect(seen[0] == [0, 200])

        // Input order must not change the answer either.
        let reversed = try map.coverage(
            of: [rect(0, 0, 50, 100), rect(100, 0, 200, 100)].reversed(),
            within: extent
        )
        let forward = try map.coverage(
            of: [rect(0, 0, 50, 100), rect(100, 0, 200, 100)],
            within: extent
        )
        #expect(reversed.coveredPDFArea == forward.coveredPDFArea)
        #expect(reversed.uncoveredPolygons.map { minX($0) } == forward.uncoveredPolygons.map { minX($0) })
    }

    // MARK: - 10. Degenerate and refused input

    /// A page whose ink bounds collapsed to a line has no denominator. Zero coverage of a zero
    /// extent is the honest answer, and it is not an error.
    @Test("A zero-area extent yields a zero fraction rather than a division by zero")
    func degenerateExtentIsZeroNotNaN() throws {
        let extent = CoverageExtent.inkBounds(PDFRect(x: 10, y: 10, width: 200, height: 0))
        let result = try map.coverage(of: [rect(0, 0, 100, 100)], within: extent)
        print("[coverage] degenerate extent: fraction = \(result.coveredFraction), extent = \(result.extentPDFArea)")
        #expect(result.extentPDFArea == 0)
        #expect(result.coveredFraction == 0)
        #expect(result.coveredFraction.isFinite)
        #expect(result.coveredPolygons.isEmpty)
        #expect(result.uncoveredPolygons.isEmpty)
        #expect(result.denominator == .inkBounds)
    }

    @Test("A non-finite extent is an error, not a fraction")
    func nonFiniteExtentThrows() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: .nan, height: 100))
        #expect(throws: MeasurementEngineError.measurement(.nonFiniteCoordinate)) {
            _ = try map.coverage(of: [], within: extent)
        }
    }

    @Test("A measured polygon with a non-finite coordinate fails the map rather than vanishing")
    func nonFiniteMeasuredThrows() throws {
        let extent = CoverageExtent.pageBox(PDFRect(x: 0, y: 0, width: 200, height: 100))
        let broken = polygon([(0, 0), (100, 0), (.nan, 100)])
        #expect(throws: MeasurementEngineError.measurement(.nonFiniteCoordinate)) {
            _ = try map.coverage(of: [broken], within: extent)
        }
    }

    // MARK: - 11. Translation invariance (QUALITY_BAR P2)

    /// The same fixture as test 2, moved 12 000 x 9 000 pt away from the origin. A fraction that
    /// moves with the page position would be a quantisation bug, not a coverage answer.
    @Test("Moving the sheet and its measurements together changes no fraction")
    func translationInvariance() throws {
        let dx = 12_000.0
        let dy = 9_000.0
        let extent = CoverageExtent.inkBounds(PDFRect(x: dx, y: dy, width: 200, height: 100))
        let result = try map.coverage(
            of: [rect(dx, dy, dx + 100, dy + 100)],
            within: extent
        )
        print("[coverage] translated fraction = \(result.coveredFraction)")
        #expect(abs(result.coveredPDFArea - 10_000) <= Self.exact)
        #expect(result.coveredFraction == 0.5)
        assertComplement(result, label: "translated sheet")
    }
}
