import CoreGraphics
import Foundation
import Testing
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// Cutout-pipeline findings from bug hunt 2 and the improvements list:
/// BH-165, BH-564, IM-004, IM-069, IM-070, IM-071.
///
/// Every expected number is derived by hand beside it (QUALITY_BAR §2.6).
@Suite("Cutout pipeline regressions (bug hunt 2)")
struct CutoutPipelineRegressionTests {
    static let options = MeasurementEngineOptions.default

    static func ring(_ pairs: [(Double, Double)]) -> PolygonRing {
        PolygonRing(points: pairs.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true)
    }

    static func square(_ x: Double, _ y: Double, _ side: Double) -> [(Double, Double)] {
        [(x, y), (x + side, y), (x + side, y + side), (x, y + side)]
    }

    static func resolve(_ polygon: PolygonGeometry, options: MeasurementEngineOptions = options) throws
        -> (CutoutSolver.Resolved, WarningLog) {
        var warnings = WarningLog()
        let resolved = try CutoutSolver.resolve(polygon, policy: .subtractFromArea, options: options, warnings: &warnings)
        return (resolved, warnings)
    }

    static func countingClipperCalls<T>(_ body: () throws -> T) rethrows -> (T, Int) {
        let counter = EngineClipper.CallCounter()
        let value = try EngineClipper.CallCounter.$current.withValue(counter) { try body() }
        return (value, counter.count)
    }

    // MARK: - BH-165

    /// Old output: warning "cutout 0 is only 0.99999995 inside its parent" (blocking). The hole's
    /// raw shoelace is 10.00000049 x 20 = 200.0000098 pt², but the intersection's vertices sit on
    /// the 1e-6 pt lattice: 10.00000049 * 1e6 = 10000000.49 rounds to 10000000, so insideArea =
    /// 10 x 20 = 200 and 200 / 200.0000098 = 0.999999951 < 1 - 1e-9. Now both sides are on the
    /// lattice: 200 / 200 = 1, no warning.
    /// S-108 (iteration-2 re-fix): the net area no longer stores the lattice hole either. The
    /// hole is wholly inside (it touches the left edge from inside), so it removes its drawn
    /// 200.0000098: net 9799.9999902, where it used to be 10000 − 200 (the lattice copy) = 9800.
    @Test("BH-165: a cutout wholly inside its parent is not flagged because of lattice rounding")
    func offLatticeCutoutIsNotFlagged() throws {
        // The hole touches the parent's left edge, so the strict-inside shortcut declines and the
        // Clipper2 containment check really runs.
        let polygon = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 100)),
            holes: [Self.ring([(0, 40), (10.00000049, 40), (10.00000049, 60), (0, 60)])]
        )
        let (resolved, warnings) = try Self.resolve(polygon)
        #expect(!warnings.warnings.contains { $0.code == .cutoutOutsideParent })
        // Net area through the boolean, measured against the drawn hole: 10000 - 200.0000098.
        #expect(abs(resolved.netPDFArea - 9799.9999902) < 1e-9)

        // A genuinely partial cutout still warns: half of a 20 x 20 hole hangs outside, inside = 0.5.
        let partial = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 100)),
            holes: [Self.ring(Self.square(-10, 40, 20))]
        )
        let (_, partialWarnings) = try Self.resolve(partial)
        #expect(partialWarnings.warnings.contains { $0.code == .cutoutOutsideParent })
    }

    // MARK: - IM-069

    /// Old output: the one-hole case went through the union, the intersection and the difference,
    /// so the hole was measured on the lattice: its corners 3 + 2^-21 and 5 + 2^-20 round to
    /// 3.000000 and 5.000001, side 2.000001, net = 100 - 4.000004000001 = 95.999995999999.
    /// Exact: side = 2 + 2^-21, hole = (2 + 2^-21)^2 = 4 + 2^-19 + 2^-42 (representable), so
    /// net = 100 - (2 + 2^-21)^2, with no Clipper2 call at all.
    @Test("IM-069: one hole strictly inside a simple outer uses the exact shoelace, no boolean")
    func oneHoleExactPath() throws {
        let side = 2 + 0x1p-21
        let offset = 3 + 0x1p-21
        let polygon = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 10)),
            holes: [Self.ring(Self.square(offset, offset, side))]
        )
        let ((resolved, warnings), calls) = try Self.countingClipperCalls { try Self.resolve(polygon) }
        #expect(calls == 0)
        #expect(resolved.netPDFArea == 100 - side * side)
        #expect(resolved.cutoutPDFArea == side * side)
        #expect(warnings.warnings.isEmpty)
        // Clipper2's orientation for a region with a hole: outer positive, hole negative.
        #expect(PolygonMath.signedArea(resolved.netRings[0]) > 0)
        #expect(PolygonMath.signedArea(resolved.netRings[1]) < 0)
        let reference = try Clipper2.difference(
            [Self.square(0, 0, 10).map { CGPoint(x: $0.0, y: $0.1) }],
            [Self.square(3, 3, 2).map { CGPoint(x: $0.0, y: $0.1) }],
            fillRule: .nonZero, scale: .pagePoints
        )
        let signs = reference.map { Clipper2.area(of: $0) > 0 }.sorted { $0 && !$1 }
        #expect(signs == [true, false], "the boolean's own output is outer-positive, hole-negative")

        // A clockwise outer and a counter-clockwise hole come out in the same convention.
        let reversed = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 10).reversed()),
            holes: [Self.ring(Self.square(3, 3, 2))]
        )
        let (flipped, _) = try Self.resolve(reversed)
        #expect(flipped.netPDFArea == 96)
        #expect(PolygonMath.signedArea(flipped.netRings[0]) > 0)
        #expect(PolygonMath.signedArea(flipped.netRings[1]) < 0)
    }

    // MARK: - IM-004 / IM-071

    /// Old count: resolve ran union + one intersection per hole + difference = 4, and
    /// CoverageRegions.netRegion then ran union + difference again = 6 booleans for one polygon
    /// with two holes. IM-004/IM-071 brought it to union + difference = 2; since S-108 two
    /// strictly-inside holes that do not meet take the exact path and the net region reuses its
    /// paths, so no boolean runs at all.
    @Test("IM-004/IM-071/S-108: a two-hole net region with apart holes costs no boolean")
    func twoHoleNetRegionBooleanCount() throws {
        let polygon = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 100)),
            holes: [Self.ring(Self.square(10, 10, 20)), Self.ring(Self.square(50, 50, 20))]
        )
        let (paths, calls) = try Self.countingClipperCalls {
            try CoverageRegions.netRegion(of: polygon, options: Self.options)
        }
        #expect(calls == 0)
        // 10000 - 400 - 400 = 9200.
        #expect(abs(CoverageRegions.pdfArea(of: paths) - 9200) < 1e-9)

        // A hole hanging over the edge still pays for its containment check: union + its one
        // intersection + difference = 3 (the other, strictly inside, is skipped).
        let mixed = PolygonGeometry(
            outer: Self.ring(Self.square(0, 0, 100)),
            holes: [Self.ring(Self.square(10, 10, 20)), Self.ring(Self.square(90, 50, 20))]
        )
        let (_, mixedCalls) = try Self.countingClipperCalls {
            try CoverageRegions.netRegion(of: mixed, options: Self.options)
        }
        #expect(mixedCalls == 3)
    }

    /// IM-004 verify: the coverage map reuses the solver's net paths, on random polygons with
    /// overlapping holes. Where no boolean shaped the net (the exact path) the two areas are
    /// Clipper2.area of the same paths, bit for bit. Where the union and the difference ran, the
    /// paths sit on the 1e-6 pt lattice and, since S-108's iteration-2 re-fix, the solver's net
    /// is measured against the drawn rings, so the two differ by the drawn rings' own lattice
    /// rounding: each coordinate moves by at most h = 5e-7 pt, which moves a ring's area by at
    /// most h·Σ(|dx| + |dy|) ≤ √2·h·perimeter ≈ 0.71e-6 pt × perimeter.
    @Test("IM-004: coverage net area equals the solver's on the exact path, within the rings' lattice rounding otherwise")
    func coverageAreaMatchesSolver() throws {
        var generator = SplitMix(seed: 0x1D_004)
        var exactPaths = 0
        var booleanPaths = 0
        for _ in 0..<200 {
            let outerSide = 50 + generator.unit() * 50
            var holes: [PolygonRing] = []
            for _ in 0..<(1 + Int(generator.unit() * 4)) {
                let side = 3 + generator.unit() * 15
                let x = generator.unit() * (outerSide - side)
                let y = generator.unit() * (outerSide - side)
                holes.append(Self.ring(Self.square(x, y, side)))
            }
            let polygon = PolygonGeometry(outer: Self.ring(Self.square(0, 0, outerSide)), holes: holes)
            let (resolved, _) = try Self.resolve(polygon)
            let region = try CoverageRegions.netRegion(of: polygon, options: Self.options)
            if resolved.boundary == .outerPlusDisjointHoles {
                exactPaths += 1
                #expect(CoverageRegions.pdfArea(of: region) == resolved.netPDFArea)
            } else {
                booleanPaths += 1
                let perimeter = 4 * outerSide + holes.reduce(0) { $0 + PolygonMath.perimeter($1.uniquePoints, isClosed: true) }
                #expect(abs(CoverageRegions.pdfArea(of: region) - resolved.netPDFArea) <= 0.71e-6 * perimeter + 1e-9)
            }
        }
        #expect(exactPaths > 0)
        #expect(booleanPaths > 0)
    }

    /// IM-071 verify: whenever the shortcut says "strictly inside", the Clipper2 boolean agrees
    /// that the whole hole is inside; random holes against a non-convex (L-shaped) parent.
    @Test("IM-071: the strict-inside shortcut never contradicts the Clipper2 containment check")
    func shortcutAgreesWithBoolean() throws {
        let lShape: [(Double, Double)] = [(0, 0), (100, 0), (100, 40), (40, 40), (40, 100), (0, 100)]
        let outer = lShape.map { PDFPoint(x: $0.0, y: $0.1) }
        var generator = SplitMix(seed: 0x1D_071)
        var shortcutTaken = 0
        var declined = 0
        for _ in 0..<2_000 {
            let side = 2 + generator.unit() * 30
            let x = -10 + generator.unit() * 110
            let y = -10 + generator.unit() * 110
            let hole = Self.square(x, y, side).map { PDFPoint(x: $0.0, y: $0.1) }
            let holeArea = side * side
            let inside = try Clipper2.intersection(
                [hole.map(CutoutSolver.cgPoint)], [outer.map(CutoutSolver.cgPoint)],
                fillRule: .nonZero, scale: .pagePoints
            )
            let insideArea = abs(Clipper2.area(of: inside))
            if CutoutContainment.isStrictlyInside(hole, outer: outer, epsilon: .standard) {
                shortcutTaken += 1
                #expect(abs(insideArea - holeArea) <= holeArea * 1e-9 + 1e-4, "shortcut accepted a hole that is not inside")
            } else {
                declined += 1
            }
        }
        // Both branches were exercised.
        #expect(shortcutTaken > 100)
        #expect(declined > 100)
    }

    /// IM-071 measurement: a 500-vertex parent with 200 small interior cutouts. Old: 200
    /// intersections + union + difference = 202 booleans; IM-071 brought it to 2, and since
    /// S-108 the 200 apart holes take the exact path: 0.
    @Test("IM-071/S-108: 200 apart interior cutouts run no boolean")
    func manyInteriorCutouts() throws {
        let outer = (0..<500).map { index -> (Double, Double) in
            let angle = Double(index) / 500 * 2 * Double.pi
            return (1000 * cos(angle), 1000 * sin(angle))
        }
        var holes: [PolygonRing] = []
        for row in 0..<10 {
            for column in 0..<20 {
                holes.append(Self.ring(Self.square(-500 + Double(column) * 50, -250 + Double(row) * 50, 10)))
            }
        }
        let polygon = PolygonGeometry(outer: Self.ring(outer), holes: holes)
        let ((resolved, warnings), calls) = try Self.countingClipperCalls { try Self.resolve(polygon) }
        #expect(calls == 0)
        #expect(!warnings.warnings.contains { $0.code == .cutoutOutsideParent })
        // 200 disjoint 10 x 10 holes remove 20 000 pt². Before S-108 cutoutPDFArea was the raw
        // outer shoelace minus a lattice net area and carried the 500-gon's lattice rounding (up
        // to ~3.1e-3 pt²); both sides are raw shoelaces now, so only Double rounding on a
        // ~3.1e6 pt² outer is left.
        #expect(abs(resolved.cutoutPDFArea - 20_000) < 1e-6)
    }

    // MARK: - BH-564 / IM-070

    /// Old output: above selfIntersectionVertexLimit the check answered "not self-intersecting"
    /// silently, so a figure-eight was stored as the difference of its lobes with no warning even
    /// under `.reject`. Now the skipped check is reported on the result — since ADR-0018 under
    /// its own code, `selfIntersectionCheckSkipped`. The interim fix-2 code emitted
    /// `numericalPrecisionLoss` with a detail string, which the UI mapped to nothing.
    @Test("BH-564/IM-070: a ring above the self-intersection vertex limit says the check was skipped")
    func skippedSelfIntersectionCheckIsReported() throws {
        func circle(_ count: Int) -> [PDFPoint] {
            (0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * Double.pi
                return PDFPoint(x: 100 * cos(angle), y: 100 * sin(angle))
            }
        }
        let limited = MeasurementEngineOptions(selfIntersectionPolicy: .reject, selfIntersectionVertexLimit: 100)
        let engine = MeasurementEngine(options: limited)
        let over = MeasurementGeometry(
            pageID: Fixture.pageID,
            polygons: [PolygonGeometry(outer: PolygonRing(points: circle(101), isClosed: true))]
        )
        let result = try engine.calculate(tool: .area, geometry: over, scale: Fixture.unitScale)
        #expect(result.warnings.contains {
            $0.code == .selfIntersectionCheckSkipped && $0.field == .planArea
                && $0.detail == "vertices=101 limit=100"
        })
        // The interim code is gone from this path (ADR-0018, IM-070).
        #expect(!result.warnings.contains { $0.code == .numericalPrecisionLoss })
        // The number is still returned: a warning never replaces a value.
        #expect(result[.planArea] != nil)
        let under = MeasurementGeometry(
            pageID: Fixture.pageID,
            polygons: [PolygonGeometry(outer: PolygonRing(points: circle(100), isClosed: true))]
        )
        let clean = try engine.calculate(tool: .area, geometry: under, scale: Fixture.unitScale)
        #expect(clean.warnings.isEmpty)
    }

    /// IM-070's own verification, at the shipping limit of 50 000 vertices: a 60 000-vertex
    /// ring carries the new code, a 49 999-vertex simple ring does not.
    @Test("IM-070: at the default vertex limit, 60 000 vertices warn and 49 999 do not")
    func defaultLimitWarnsOnlyAboveIt() throws {
        func circle(_ count: Int) -> [PDFPoint] {
            (0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * Double.pi
                return PDFPoint(x: 1_000 * cos(angle), y: 1_000 * sin(angle))
            }
        }
        #expect(MeasurementEngineOptions.default.selfIntersectionVertexLimit == 50_000)
        let engine = MeasurementEngine()
        func warnings(_ count: Int) throws -> [MeasurementWarning] {
            let geometry = MeasurementGeometry(
                pageID: Fixture.pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: circle(count), isClosed: true))]
            )
            return try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale).warnings
        }
        #expect(try warnings(60_000).contains { $0.code == .selfIntersectionCheckSkipped })
        #expect(try !warnings(49_999).contains { $0.code == .selfIntersectionCheckSkipped })
    }
}

/// Deterministic generator for the property tests (SplitMix64).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
