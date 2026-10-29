import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// Area split, engine half: split a committed area with a line.
///
/// Every expected number in this suite is derived by hand from the fixture and written out in
/// the comment above it, so a failure says which piece of geometry is wrong rather than which
/// snapshot moved. No fixture depends on a previously recorded engine output.
///
/// The tolerance is `1e-9` square PDF points on values of order 1e4 — that is `1e-13` relative,
/// which is QUALITY_BAR §2.1's floating-point-level agreement for closed-form geometry. It is
/// affordable here because every coordinate in every fixture is an exact multiple of the
/// Clipper2 lattice step (1e-6 pt), so the boolean introduces no quantisation at all.
@Suite("Area split")
struct PolygonSplitTests {

    let splitter = PolygonSplitter()

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

    private func cut(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    /// Fails the test with the refusal's name if the split refused.
    private func requireParts(
        _ result: SplitResult,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [PolygonGeometry] {
        switch result {
        case let .parts(parts):
            return parts
        case .lineMissesPolygon:
            Issue.record("\(comment): refused with .lineMissesPolygon", sourceLocation: sourceLocation)
            throw SplitTestFailure.refused
        case let .degenerate(area):
            Issue.record(
                "\(comment): refused with .degenerate(smallestPartPDFArea: \(area))",
                sourceLocation: sourceLocation
            )
            throw SplitTestFailure.refused
        }
    }

    /// Asserts the split invariant on a concrete split, and prints the numbers it checked.
    private func assertInvariant(
        original: PolygonGeometry,
        parts: [PolygonGeometry],
        label: String
    ) throws {
        let error = try splitter.areaCheck(original: original, parts: parts)
        let tolerance = try splitter.invariantPDFTolerance(for: original)
        let magnitude = abs(NumericPolicy.double(from: error))
        let originalArea = try splitter.netPDFArea(of: original)
        var areas: [Double] = []
        for part in parts { areas.append(try splitter.netPDFArea(of: part)) }
        print(
            """
            [split] \(label): original net = \(originalArea) pt^2, \
            parts = \(areas.map { String($0) }.joined(separator: " + ")), \
            areaCheck = \(error) pt^2, tolerance = \(tolerance) pt^2
            """
        )
        #expect(magnitude <= tolerance, "areaCheck \(error) exceeded tolerance \(tolerance)")
        // Independently of the tolerance: on lattice-exact fixtures the error must be
        // floating-point zero, not merely small.
        #expect(magnitude <= Self.exact)
    }

    private func area(_ polygon: PolygonGeometry) throws -> Double {
        try splitter.netPDFArea(of: polygon)
    }

    private func hasVertex(_ polygon: PolygonGeometry, _ x: Double, _ y: Double) -> Bool {
        polygon.outer.uniquePoints.contains { abs($0.x - x) <= 1e-6 && abs($0.y - y) <= 1e-6 }
    }

    // MARK: - 1. Rectangle cut down the middle

    /// A 200 x 100 rectangle, cut on the vertical line x = 100 by a stroke whose two endpoints
    /// both sit *inside* the rectangle. The extension is what makes that work.
    ///
    /// Hand-derived: 200 x 100 = 20 000 pt^2 splits into 100 x 100 = 10 000 pt^2 twice.
    @Test("A 200 x 100 rectangle cut down the middle gives two exact 100 x 100 halves")
    func rectangleSplitInHalf() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        let result = try splitter.split(rectangle, along: cut([(100, 20), (100, 80)]))
        let parts = try requireParts(result, "vertical mid-cut of a 200 x 100 rectangle")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] rectangle halves: \(areas)")
        #expect(abs(areas[0] - 10_000) <= Self.exact)
        #expect(abs(areas[1] - 10_000) <= Self.exact)

        // Equal areas, so the tie-break decides the order: leftmost part first, every run.
        #expect(hasVertex(parts[0], 0, 0))
        #expect(hasVertex(parts[0], 100, 0))
        #expect(hasVertex(parts[1], 200, 100))
        #expect(parts[0].holes.isEmpty)
        #expect(parts[1].holes.isEmpty)

        try assertInvariant(original: rectangle, parts: parts, label: "rectangle mid-cut")
    }

    // MARK: - 2. Diagonal cut of a square

    /// A 100 x 100 square cut corner to corner. Two right triangles, each 100 * 100 / 2 = 5 000.
    ///
    /// The cut endpoints land exactly on two vertices, which is the case where a naive
    /// implementation produces a degenerate ring at each corner.
    @Test("A square cut corner to corner gives two exact triangles")
    func squareCutDiagonally() throws {
        let square = polygon([(0, 0), (100, 0), (100, 100), (0, 100)])
        let result = try splitter.split(square, along: cut([(0, 0), (100, 100)]))
        let parts = try requireParts(result, "diagonal cut of a 100 x 100 square")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] diagonal halves: \(areas)")
        #expect(abs(areas[0] - 5_000) <= Self.exact)
        #expect(abs(areas[1] - 5_000) <= Self.exact)
        // Each part is a triangle: three unique vertices, no more.
        #expect(parts[0].outer.uniquePoints.count == 3)
        #expect(parts[1].outer.uniquePoints.count == 3)

        try assertInvariant(original: square, parts: parts, label: "square diagonal")
    }

    // MARK: - 3. A concave polygon that legitimately yields three parts

    /// An L-shape, and one straight line that crosses its boundary four times.
    ///
    /// The L is the union of a bar `[0,60] x [0,20]` (1 200 pt^2) and a column
    /// `[0,20] x [20,60]` (800 pt^2): 2 000 pt^2 in total. The cut runs on `y = 40 - x/2`, which
    /// meets the boundary at (0,40), (20,30), (40,20) and (60,10) — all four exactly on the
    /// lattice, so there is nothing to round.
    ///
    /// Above the line the L falls into **two** disconnected pieces:
    ///   * the top of the column: a trapezoid (0,40)-(20,30)-(20,60)-(0,60), parallel sides 20
    ///     and 30, width 20, so 20 * (20 + 30) / 2 = **500**;
    ///   * the right end of the bar: a right triangle (40,20)-(60,20)-(60,10), legs 20 and 10,
    ///     so **100**.
    /// Below the line is one piece: 2 000 - 500 - 100 = **1 400**.
    @Test("A concave L cut by one straight line returns all three parts, and they sum")
    func concaveLGivesThreeParts() throws {
        let shape = polygon([(0, 0), (60, 0), (60, 20), (20, 20), (20, 60), (0, 60)])
        #expect(abs(try area(shape) - 2_000) <= Self.exact)

        let result = try splitter.split(shape, along: cut([(0, 40), (60, 10)]))
        let parts = try requireParts(result, "four-crossing cut of an L-shape")

        #expect(parts.count == 3)
        let areas = try parts.map { try area($0) }
        print("[split] L-shape parts (descending): \(areas)")
        #expect(abs(areas[0] - 1_400) <= Self.exact)
        #expect(abs(areas[1] - 500) <= Self.exact)
        #expect(abs(areas[2] - 100) <= Self.exact)
        #expect(abs(areas.reduce(0, +) - 2_000) <= Self.exact)

        try assertInvariant(original: shape, parts: parts, label: "L-shape three-way")
    }

    // MARK: - 4. A hole the cut passes through

    /// 200 x 100 rectangle, 40 x 20 hole centred on (100, 50): net 20 000 - 800 = 19 200.
    /// Cutting on x = 100 halves both, so each part is 10 000 - 400 = **9 600**, and the hole is
    /// gone as a hole: it is a bite out of each part's outer boundary.
    @Test("A hole the cut passes through becomes boundary in both parts, and halves correctly")
    func holeStraddlingTheCut() throws {
        let shape = polygon(
            [(0, 0), (200, 0), (200, 100), (0, 100)],
            holes: [[(80, 40), (120, 40), (120, 60), (80, 60)]]
        )
        #expect(abs(try area(shape) - 19_200) <= Self.exact)

        let result = try splitter.split(shape, along: cut([(100, 10), (100, 90)]))
        let parts = try requireParts(result, "cut through a centred hole")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] U-halves: \(areas), holes per part = \(parts.map(\.holes.count))")
        #expect(abs(areas[0] - 9_600) <= Self.exact)
        #expect(abs(areas[1] - 9_600) <= Self.exact)

        // Measured, not assumed: a straddling hole survives as boundary, not as a hole.
        #expect(parts[0].holes.isEmpty)
        #expect(parts[1].holes.isEmpty)
        // The former hole's left edge is now part of the left half's outer ring, and its right
        // edge part of the right half's. Eight vertices each: the U.
        #expect(hasVertex(parts[0], 80, 40))
        #expect(hasVertex(parts[0], 80, 60))
        #expect(parts[0].outer.uniquePoints.count == 8)
        #expect(hasVertex(parts[1], 120, 40))
        #expect(hasVertex(parts[1], 120, 60))
        #expect(parts[1].outer.uniquePoints.count == 8)

        try assertInvariant(original: shape, parts: parts, label: "cut through hole")
    }

    /// The other half of the hole question, and the one the no-double-count invariant depends on:
    /// a hole entirely on one side has to stay a hole *there* and nowhere else. Same fixture,
    /// cut at x = 40, so the hole `[80,120] x [40,60]` sits wholly in the right part.
    ///
    /// Left: 40 x 100 = **4 000**, no holes. Right: 160 x 100 - 800 = **15 200**, one hole.
    @Test("A hole entirely on one side stays a hole on that side only")
    func holeEntirelyOnOneSide() throws {
        let shape = polygon(
            [(0, 0), (200, 0), (200, 100), (0, 100)],
            holes: [[(80, 40), (120, 40), (120, 60), (80, 60)]]
        )
        let result = try splitter.split(shape, along: cut([(40, 25), (40, 75)]))
        let parts = try requireParts(result, "cut clear of the hole")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] hole kept: \(areas), holes per part = \(parts.map(\.holes.count))")
        #expect(abs(areas[0] - 15_200) <= Self.exact)
        #expect(abs(areas[1] - 4_000) <= Self.exact)
        #expect(parts[0].holes.count == 1)
        #expect(parts[1].holes.isEmpty)
        // The hole came back as the hole that went in, all four corners.
        let hole = try #require(parts[0].holes.first)
        #expect(hole.uniquePoints.count == 4)
        #expect(abs(PolygonMath.area(hole.points) - 800) <= Self.exact)

        try assertInvariant(original: shape, parts: parts, label: "hole on one side")
    }

    // MARK: - 5. Refusals

    @Test("A cut that never reaches the area is refused, not split")
    func cutOutsideTheAreaIsRefused() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        // The line y = 200, extended along itself for ever, never enters the rectangle.
        let result = try splitter.split(rectangle, along: cut([(0, 200), (200, 200)]))
        print("[split] outside cut -> \(result)")
        #expect(result == .lineMissesPolygon)
    }

    @Test("A cut lying along an existing edge is refused, never a sliver plus the original")
    func cutCollinearWithAnEdgeIsRefused() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        let result = try splitter.split(rectangle, along: cut([(0, 0), (200, 0)]))
        print("[split] collinear cut -> \(result)")
        #expect(result.isRefusal)
        // Whichever refusal the geometry produces, the thing that must never come back is a
        // pair of parts one of which is the original area.
        #expect(result.partsIfSplit == nil)
    }

    @Test("A cut a hair off an edge is refused as degenerate rather than shaving a sliver")
    func slverCutIsRefusedAsDegenerate() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        // 200 pt long, 1e-5 pt off the bottom edge: a sliver of 200 * 1e-5 = 2e-3 pt^2, which is
        // above the area floor (1e-9) and below the 0.01 pt^2 minimum part area.
        let result = try splitter.split(rectangle, along: cut([(0, 1e-5), (200, 1e-5)]))
        print("[split] sliver cut -> \(result)")
        guard case let .degenerate(smallest) = result else {
            Issue.record("expected .degenerate, got \(result)")
            return
        }
        #expect(abs(smallest - 2e-3) <= 1e-9)
    }

    @Test("A one-point cut is an error, not a refusal")
    func degenerateCutThrows() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        #expect(throws: MeasurementEngineError.geometry(.degenerateSegment)) {
            _ = try splitter.split(rectangle, along: cut([(50, 50), (50, 50)]))
        }
    }

    @Test("A non-finite cut coordinate is an error, not a refusal")
    func nonFiniteCutThrows() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        #expect(throws: MeasurementEngineError.measurement(.nonFiniteCoordinate)) {
            _ = try splitter.split(rectangle, along: cut([(0, 50), (.nan, 50)]))
        }
    }

    // MARK: - 6. A bent cut

    /// A two-segment cut, which has no half-plane at all: it is the corner wedge in
    /// ``CutRegion`` that makes this work.
    ///
    /// 200 x 100 rectangle. The cut runs up x = 100 from below the rectangle to (100,50), then
    /// right along y = 50 to (200,50) and on out of the rectangle. It isolates the bottom-right
    /// block `[100,200] x [0,50]` = 100 * 50 = **5 000**; the rest is 20 000 - 5 000 = **15 000**.
    @Test("A bent two-segment cut splits on the polyline, not on the chord")
    func bentPolylineCut() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        let result = try splitter.split(
            rectangle,
            along: cut([(100, -50), (100, 50), (180, 50)])
        )
        let parts = try requireParts(result, "two-segment bent cut")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] bent-cut parts: \(areas)")
        #expect(abs(areas[0] - 15_000) <= Self.exact)
        #expect(abs(areas[1] - 5_000) <= Self.exact)
        // The small part is the bottom-right block, with the bend's corner on its boundary.
        #expect(hasVertex(parts[1], 100, 50))
        #expect(hasVertex(parts[1], 200, 50))
        #expect(parts[1].outer.uniquePoints.count == 4)
        // The large part is the L that surrounds it: six corners.
        #expect(parts[0].outer.uniquePoints.count == 6)

        try assertInvariant(original: rectangle, parts: parts, label: "bent cut")
    }

    // MARK: - 7. The invariant as a working guard

    /// `areaCheck` has to be able to *fail*, or it is decoration. Handing it a part list that is
    /// missing a piece must produce exactly the missing area, with a sign that says area was
    /// lost — which is what the command layer keys its refusal off.
    @Test("areaCheck reports the signed error, and catches a part list that does not add up")
    func areaCheckCatchesABadPartList() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        let parts = try requireParts(
            try splitter.split(rectangle, along: cut([(100, 20), (100, 80)])),
            "mid-cut for the areaCheck guard"
        )

        let honest = try splitter.areaCheck(original: rectangle, parts: parts)
        print("[split] areaCheck(complete) = \(honest)")
        #expect(abs(NumericPolicy.double(from: honest)) <= Self.exact)

        // Drop one half: 10 000 pt^2 of the parent goes unaccounted for.
        let dropped = try splitter.areaCheck(original: rectangle, parts: [parts[0]])
        print("[split] areaCheck(one part dropped) = \(dropped)")
        #expect(abs(NumericPolicy.double(from: dropped) + 10_000) <= Self.exact)

        // Count one half twice: 10 000 pt^2 of area that does not exist. This is the double
        // count a split must never produce, and it is positive so the caller can name it.
        let doubled = try splitter.areaCheck(
            original: rectangle,
            parts: parts + [parts[0]]
        )
        print("[split] areaCheck(one part doubled) = \(doubled)")
        #expect(abs(NumericPolicy.double(from: doubled) - 10_000) <= Self.exact)

        let tolerance = try splitter.invariantPDFTolerance(for: rectangle)
        print("[split] invariantPDFTolerance(200 x 100) = \(tolerance)")
        #expect(abs(NumericPolicy.double(from: dropped)) > tolerance)
        #expect(abs(NumericPolicy.double(from: doubled)) > tolerance)
    }

    // MARK: - 8. Ordering is total and deterministic

    @Test("Part order is stable across runs, including for parts of exactly equal area")
    func partOrderIsDeterministic() throws {
        let rectangle = polygon([(0, 0), (200, 0), (200, 100), (0, 100)])
        var seen: [[Double]] = []
        for _ in 0..<8 {
            let parts = try requireParts(
                try splitter.split(rectangle, along: cut([(100, 20), (100, 80)])),
                "repeat run"
            )
            seen.append(parts.map { $0.outer.uniquePoints.map(\.x).min() ?? .nan })
        }
        print("[split] leading x of part 0 over 8 runs: \(seen.map { $0[0] })")
        #expect(seen.allSatisfy { $0 == seen[0] })
        #expect(seen[0][0] == 0)
        #expect(seen[0][1] == 100)
    }

    // MARK: - 9. Translation invariance (QUALITY_BAR P2)

    /// The same cut, on the same shape, a long way from the origin. Areas must not move.
    @Test("Moving the area and the cut together changes no part area")
    func translationInvariance() throws {
        let offsetX = 12_000.0
        let offsetY = 9_000.0
        let shape = polygon([
            (offsetX, offsetY), (offsetX + 60, offsetY), (offsetX + 60, offsetY + 20),
            (offsetX + 20, offsetY + 20), (offsetX + 20, offsetY + 60), (offsetX, offsetY + 60)
        ])
        let result = try splitter.split(
            shape,
            along: cut([(offsetX, offsetY + 40), (offsetX + 60, offsetY + 10)])
        )
        let parts = try requireParts(result, "translated L-shape cut")
        let areas = try parts.map { try area($0) }
        print("[split] translated L parts: \(areas)")
        #expect(parts.count == 3)
        #expect(abs(areas[0] - 1_400) <= Self.exact)
        #expect(abs(areas[1] - 500) <= Self.exact)
        #expect(abs(areas[2] - 100) <= Self.exact)

        try assertInvariant(original: shape, parts: parts, label: "translated L-shape")
    }

    // MARK: - 10. Crossings that are not representable on the lattice

    /// Every fixture above crosses the boundary at a point that happens to be an exact multiple
    /// of the 1e-6 pt lattice, so the split is exact. This one deliberately does not, and pins
    /// what the engine does then.
    ///
    /// A 100 x 100 square, cut by a stroke from (30,30) to (70,71) — both endpoints inside, so
    /// the crossings come from the extension. The line has direction (40,41), so it leaves the
    /// bottom edge at `x = 30 - 40 * 30/41 = 30/41` and the top edge at
    /// `x = 30 + 40 * 70/41 = 4030/41`. Neither is a lattice multiple: 1/41 does not terminate
    /// in decimal.
    ///
    /// The left part is the trapezoid (0,0)-(30/41,0)-(4030/41,100)-(0,100):
    /// `100 * (30/41 + 4030/41) / 2 = 203000/41` = 4951.219512195122 pt^2. The right part is the
    /// remaining 5048.780487804878 pt^2.
    @Test("A cut whose crossings are not lattice multiples stays inside the stated tolerance")
    func crossingsOffTheLattice() throws {
        let square = polygon([(0, 0), (100, 0), (100, 100), (0, 100)])
        let result = try splitter.split(square, along: cut([(30, 30), (70, 71)]))
        let parts = try requireParts(result, "cut with non-representable crossings")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        let expectedRight = 203_000.0 / 41.0
        let expectedLeft = 10_000 - expectedRight
        let tolerance = try splitter.invariantPDFTolerance(for: square)
        print(
            """
            [split] off-lattice cut: parts = \(areas), \
            closed form = [\(expectedLeft), \(expectedRight)], \
            deviations = [\(abs(areas[0] - expectedLeft)), \(abs(areas[1] - expectedRight))], \
            tolerance = \(tolerance)
            """
        )
        #expect(abs(areas[0] - expectedLeft) <= tolerance)
        #expect(abs(areas[1] - expectedRight) <= tolerance)
        try assertInvariantWithinTolerance(
            original: square,
            parts: parts,
            label: "off-lattice crossings"
        )
    }

    // MARK: - 11. Two holes at once

    /// One hole the cut passes through and one it does not, in the same area, so the two
    /// behaviours are proved to coexist rather than each being proved on its own fixture.
    ///
    /// 200 x 100 outer = 20 000. Hole A `[90,110] x [40,60]` = 400, straddling x = 100.
    /// Hole B `[20,60] x [20,50]` = 1 200, wholly left of it. Net = 20 000 - 400 - 1 200 =
    /// **18 400**. Cutting on x = 100: the left part is 10 000 - 200 (half of A) - 1 200 (all of
    /// B) = **8 600** and keeps B as a hole; the right part is 10 000 - 200 = **9 800** and has
    /// no hole at all.
    @Test("Two holes, one straddling the cut and one not, behave differently in the same split")
    func twoHolesAtOnce() throws {
        let shape = polygon(
            [(0, 0), (200, 0), (200, 100), (0, 100)],
            holes: [
                [(90, 40), (110, 40), (110, 60), (90, 60)],
                [(20, 20), (60, 20), (60, 50), (20, 50)]
            ]
        )
        #expect(abs(try area(shape) - 18_400) <= Self.exact)

        let result = try splitter.split(shape, along: cut([(100, 10), (100, 90)]))
        let parts = try requireParts(result, "cut across one of two holes")

        #expect(parts.count == 2)
        let areas = try parts.map { try area($0) }
        print("[split] two holes: \(areas), holes per part = \(parts.map(\.holes.count))")
        #expect(abs(areas[0] - 9_800) <= Self.exact)
        #expect(abs(areas[1] - 8_600) <= Self.exact)
        // The right part is the one with no hole; the left keeps hole B intact.
        #expect(parts[0].holes.isEmpty)
        #expect(parts[1].holes.count == 1)
        let kept = try #require(parts[1].holes.first)
        #expect(abs(PolygonMath.area(kept.points) - 1_200) <= Self.exact)

        try assertInvariant(original: shape, parts: parts, label: "two holes")
    }

    // MARK: - 12. The invariant, swept

    /// The invariant: never the original **and** the parts both in the ledger. The
    /// engine cannot write a ledger, so its form of that rule is: whenever the engine returns
    /// parts, they partition the parent — they sum to it, and none of them *is* it.
    ///
    /// This sweeps three shapes against 24 cut directions at 5 offsets each — 360 splits — and
    /// asserts both halves of that on every one that is not a refusal. It is deterministic:
    /// every angle and offset is computed, nothing is sampled from a generator.
    @Test("Across 360 cuts, parts always partition the parent and never reproduce it")
    func sweepOfCutsAlwaysPartitions() throws {
        let shapes: [(String, PolygonGeometry)] = [
            ("rectangle", polygon([(0, 0), (200, 0), (200, 100), (0, 100)])),
            ("L", polygon([(0, 0), (60, 0), (60, 20), (20, 20), (20, 60), (0, 60)])),
            (
                "holed",
                polygon(
                    [(0, 0), (200, 0), (200, 100), (0, 100)],
                    holes: [
                        [(90, 40), (110, 40), (110, 60), (90, 60)],
                        [(20, 20), (60, 20), (60, 50), (20, 50)]
                    ]
                )
            )
        ]

        var split = 0
        var missed = 0
        var degenerate = 0
        var worstError = 0.0
        var mostParts = 0

        for (name, shape) in shapes {
            let parentArea = try area(shape)
            let tolerance = try splitter.invariantPDFTolerance(for: shape)
            let xs = shape.outer.uniquePoints.map(\.x)
            let ys = shape.outer.uniquePoints.map(\.y)
            let centreX = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
            let centreY = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
            let span = Swift.min((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            for step in 0..<24 {
                let angle = Double(step) * Double.pi / 12
                let dx = cos(angle)
                let dy = sin(angle)
                for offsetStep in 0..<5 {
                    let offset = Double(offsetStep - 2) * span / 6
                    let originX = centreX - dy * offset
                    let originY = centreY + dx * offset
                    let line = [
                        PDFPoint(x: originX - dx * 5, y: originY - dy * 5),
                        PDFPoint(x: originX + dx * 5, y: originY + dy * 5)
                    ]
                    switch try splitter.split(shape, along: line) {
                    case .lineMissesPolygon:
                        missed += 1
                    case .degenerate:
                        degenerate += 1
                    case let .parts(parts):
                        split += 1
                        mostParts = Swift.max(mostParts, parts.count)
                        #expect(parts.count >= 2, "\(name) at \(step)/\(offsetStep)")

                        let error = try splitter.areaCheck(original: shape, parts: parts)
                        let magnitude = abs(NumericPolicy.double(from: error))
                        worstError = Swift.max(worstError, magnitude)
                        #expect(
                            magnitude <= tolerance,
                            "\(name) at \(step)/\(offsetStep): areaCheck \(error)"
                        )

                        // No part may be the parent. A part that large means the cut produced
                        // the original plus a sliver, which is the double count.
                        for part in parts {
                            let partArea = try area(part)
                            #expect(
                                partArea <= parentArea - splitter.options.minimumPartArea,
                                "\(name) at \(step)/\(offsetStep): part of \(partArea) vs parent \(parentArea)"
                            )
                        }
                    }
                }
            }
        }

        print(
            """
            [split] sweep: 360 cuts -> \(split) split, \(missed) missed, \
            \(degenerate) degenerate; most parts from one cut = \(mostParts); \
            worst areaCheck magnitude = \(worstError) pt^2
            """
        )
        #expect(split + missed + degenerate == 360)
        #expect(split > 300, "the sweep must mostly produce real splits, or it proves nothing")
        #expect(mostParts >= 3, "the sweep must reach the multi-part case")
    }

    /// Asserts the invariant against the engine's own stated tolerance, without also demanding
    /// floating-point zero. Used where the crossings are genuinely not representable.
    private func assertInvariantWithinTolerance(
        original: PolygonGeometry,
        parts: [PolygonGeometry],
        label: String
    ) throws {
        let error = try splitter.areaCheck(original: original, parts: parts)
        let tolerance = try splitter.invariantPDFTolerance(for: original)
        let magnitude = abs(NumericPolicy.double(from: error))
        print("[split] \(label): areaCheck = \(error) pt^2, tolerance = \(tolerance) pt^2")
        #expect(magnitude <= tolerance)
    }
}

private enum SplitTestFailure: Error {
    case refused
}
