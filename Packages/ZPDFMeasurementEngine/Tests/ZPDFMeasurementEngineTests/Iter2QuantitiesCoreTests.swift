import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// Regressions for the engine findings
/// S-105 to S-110.
///
/// Every expected number is derived by hand in the comment beside it, or by an independent oracle
/// written here (the AGM ellipse perimeter), never read from the code under test (QUALITY_BAR
/// §2.6). Each test states the output the old code produced.
@Suite("Iteration 2 — quantities core, engine")
struct Iter2QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    static func area(_ ring: PolygonRing, holes: [PolygonRing] = []) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: ring, holes: holes)])
    }

    // MARK: - S-105 crossing arc-edged outer ring

    /// The bowtie (0,0) → (10,10) → (10,0) → (0,10) with bulge 0.1 on its first edge. Straight,
    /// its edges cross at (5,5) and its non-zero normalisation is two triangles of ½·10·5 = 25:
    /// 50. The arc's midpoint moves along the chord's perpendicular bisector, which is the other
    /// diagonal x + y = 10, so the crossing moves to that midpoint X; the lobes become
    /// (0,0),X,(0,10) and X,(10,10),(10,0) — ½·10·x_X and ½·10·(10 − x_X), 50 together — plus and
    /// minus the two half-arc segments, which are mirror images across that diagonal and cancel,
    /// flattened or not. So the region is 50 pt², up to the 1e-6 pt Clipper lattice (perimeter
    /// ≈ 48 pt × 5e-7 pt ≈ 2.4e-5 pt²).
    /// Old output: the drawn ring's shoelace (0) plus the arc's segment r²/2·(θ − sin θ) =
    /// 637.5625 × (0.3986746 − 0.3881972) ≈ 6.68 pt², under warnings saying it was normalised.
    @Test("S-105: a bowtie with a bulged edge stores its normalised 50, not the lobes' 6.68")
    func bulgedBowtieIsNormalised() throws {
        let ring = PolygonRing(
            points: Fixture.points([(0, 0), (10, 10), (10, 0), (0, 10)]), isClosed: true, bulges: [0.1, 0, 0, 0]
        )
        let result = try engine.calculate(tool: .area, geometry: Self.area(ring), scale: Fixture.unitScale)
        #expect(abs(try Self.value(result, .planArea) - 50) <= 1e-4)
        #expect(try #require(result[.netArea]).value == (try #require(result[.planArea]).value))
        #expect(result.warnings.contains { $0.code == .selfIntersectingPolygon && $0.field == .planArea })
        #expect(result.warnings.contains { $0.code == .polygonNormalized && $0.field == .planArea })
        #expect(result.warnings.contains { $0.code == .numericalPrecisionLoss && $0.field == .planArea })
        #expect(result.warnings.contains { $0.code == .numericalPrecisionLoss && $0.field == .perimeter })
        // The boundary is the normalisation's: 10 + 10 on the straight sides, the two pieces of
        // the other diagonal meeting at X (10√2 together), and the arc r·θ, whose chords of
        // sagitta ≤ 1e-3 pt (27 equal steps of φ = θ/27) fall short by 27·r·φ³/24 ≈ 1.29e-4 pt;
        // the normalised rings' vertices sit on the 1e-6 pt lattice, ≤ 1e-4 pt more either way.
        let radius = 10 * 2.0.squareRoot() * 1.01 / 0.4          // c·(1 + b²) / (4b)
        let theta = 4 * atan(0.1)
        let exactBoundary = 20 + 10 * 2.0.squareRoot() + radius * theta
        let perimeter = try Self.value(result, .perimeter)
        #expect(perimeter <= exactBoundary + 1e-4)
        #expect(perimeter >= exactBoundary - 2.5e-4)

        let strict = MeasurementEngine(options: MeasurementEngineOptions(selfIntersectionPolicy: .reject))
        #expect(throws: MeasurementEngineError.measurement(.selfIntersectingPolygon)) {
            try strict.calculate(tool: .area, geometry: Self.area(ring), scale: Fixture.unitScale)
        }
    }

    /// A simple drawn rectangle 10 × 1 whose bottom edge bends inward with a sagitta of 2
    /// (bulge −2s/c = −0.4), so only the flattened ring crosses: the arc rises through the top
    /// edge. Hand geometry: the circle through (0,0) and (10,0) with sagitta 2 has
    /// r = (5² + 2²) / (2·2) = 7.25 and centre (5, −5.25); the full segment it cuts off is
    /// S = r²/2·(θ − sin θ), θ = 2·asin(5 / 7.25); the cap above y = 1 (distance d = 6.25 from the
    /// centre, half-chord w = √(r² − d²)) is C = r²·acos(d/r) − d·w. The drawn ring's signed area
    /// is 10 − S (≈ −3.75); the region it encloses under the non-zero rule is the rectangle minus
    /// the part of S inside it, 10 − (S − C), plus the cap C: 10 − S + 2C ≈ 6.19 (S ≈ 13.75,
    /// C ≈ 4.97). The chords of sagitta ≤ 1e-3 pt along the 11.04 pt arc move it by at most
    /// ⅔·11.04·1e-3 ≈ 7.4e-3 pt².
    /// Old output: |10 − S| ≈ 3.75.
    @Test("S-105: an arc that bulges across another edge measures the region, not the cancelling lobes")
    func arcAcrossAnotherEdge() throws {
        let ring = PolygonRing(
            points: Fixture.points([(0, 0), (10, 0), (10, 1), (0, 1)]), isClosed: true, bulges: [-0.4, 0, 0, 0]
        )
        let result = try engine.calculate(tool: .area, geometry: Self.area(ring), scale: Fixture.unitScale)
        let r = 7.25
        let theta = 2 * asin(5 / r)
        let segment = r * r / 2 * (theta - sin(theta))
        let d = 6.25
        let cap = r * r * acos(d / r) - d * (r * r - d * d).squareRoot()
        let region = 10 - segment + 2 * cap
        #expect(abs(region - 6.19) < 0.01, "hand value \(region)")
        #expect(abs(try Self.value(result, .planArea) - region) <= 7.5e-3)
        #expect(result.warnings.contains { $0.code == .selfIntersectingPolygon })
    }

    // MARK: - S-106 arc edges under a separate X/Y scale

    /// The ellipse perimeter by the arithmetic-geometric mean, an independent oracle:
    /// P = 2π / M(a, b) · (a² − Σ 2^(n−1) c_n²), c₀² = a² − b², c_(n+1) = (a_n − b_n) / 2.
    static func ellipsePerimeter(_ semiA: Double, _ semiB: Double) -> Double {
        var a = semiA
        var b = semiB
        var sum = (semiA * semiA - semiB * semiB) / 2
        var power = 1.0
        for _ in 0..<32 where a != b {
            let c = (a - b) / 2
            let nextA = (a + b) / 2
            b = (a * b).squareRoot()
            a = nextA
            sum += power * c * c
            power *= 2
        }
        return 2 * Double.pi / a * (semiA * semiA - sum)
    }

    /// Hand check of the oracle: a = 1, b = ½ has the tabulated perimeter 4.844224110273838.
    @Test("S-106: the AGM oracle reproduces the tabulated 2:1 ellipse perimeter")
    func oracleIsRight() {
        #expect(abs(Self.ellipsePerimeter(1, 0.5) - 4.844224110273838) <= 1e-15 * 4.85)
        #expect(abs(Self.ellipsePerimeter(3, 3) - 6 * Double.pi) <= 1e-15 * 19)
    }

    /// The 10 × 10 square with its bottom edge an outward semicircle of radius 5 (bulge 1 on a
    /// counter-clockwise ring), under 0.02 m/pt across and 0.01 m/pt up. Area: (100 + 12.5π) pt²
    /// × det 2e-4 = 0.02 + 0.0025π m², exact under any affine map. Perimeter: the three straight
    /// sides 10·0.01 + 10·0.02 + 10·0.01 = 0.4 m, and the semicircle maps to half an ellipse of
    /// semi-axes 0.1 m and 0.05 m: half of 0.4844224110273838 = 0.2422112055136919.
    /// Old output: the whole measurement refused with directionRequiredForNonUniformScale.
    @Test("S-106: an arc-edged area under a separate X/Y scale is measured, the arc by quadrature")
    func arcAreaUnderSeparateXY() throws {
        let scale = Fixture.separateXY(x: 0.02, y: 0.01)
        let ring = PolygonRing(
            points: Fixture.points([(0, 0), (10, 0), (10, 10), (0, 10)]), isClosed: true, bulges: [1, 0, 0, 0]
        )
        let result = try engine.calculate(tool: .area, geometry: Self.area(ring), scale: scale)
        let expectedArea = 0.02 + 0.0025 * Double.pi
        #expect(abs(try Self.value(result, .planArea) - expectedArea) <= 1e-12 * expectedArea)
        #expect(abs(try Self.value(result, .netArea) - expectedArea) <= 1e-12 * expectedArea)
        let expectedPerimeter = 0.4 + Self.ellipsePerimeter(0.1, 0.05) / 2
        #expect(abs(expectedPerimeter - 0.6422112055136919) <= 1e-15)
        #expect(abs(try Self.value(result, .perimeter) - expectedPerimeter) <= 1e-12 * expectedPerimeter)

        // Volume and Wall Area go through the same measure and no longer refuse.
        let volume = MeasurementParameters(depth: .length(2))
        let volumeResult = try engine.calculate(tool: .volume, geometry: Self.area(ring), scale: scale, parameters: volume)
        #expect(abs(try Self.value(volumeResult, .volume) - 2 * expectedArea) <= 1e-12 * 2 * expectedArea)
    }

    /// A chain from (0,0) to (10,0) that is one semicircle (bulge 1), and a quarter arc from
    /// (5,−5) to (10,0) about (5,0) (bulge tan(π/8)), under 0.02 × 0.01 m/pt: half and a quarter
    /// of the 0.1 × 0.05 m ellipse's perimeter, 0.2422112055136919 and 0.12110560275684595 m.
    /// On a uniform scale the fast path is untouched: the semicircle at 0.02 m/pt is 5π·0.02.
    /// Old output: Length and Polylength refused with directionRequiredForNonUniformScale.
    @Test("S-106: Length and Polylength measure an arc edge under a separate X/Y scale")
    func arcChainUnderSeparateXY() throws {
        let scale = Fixture.separateXY(x: 0.02, y: 0.01)
        let perimeter = Self.ellipsePerimeter(0.1, 0.05)
        let semicircle = MeasurementGeometry(
            pageID: Fixture.pageID, points: Fixture.points([(0, 0), (10, 0)]), pointBulges: [1, 0]
        )
        for tool in [MeasurementTool.length, .polylength] {
            let result = try engine.calculate(tool: tool, geometry: semicircle, scale: scale)
            #expect(abs(try Self.value(result, .planLength) - perimeter / 2) <= 1e-12 * perimeter)
        }
        let quarter = MeasurementGeometry(
            pageID: Fixture.pageID, points: Fixture.points([(5, -5), (10, 0)]), pointBulges: [tan(Double.pi / 8), 0]
        )
        let quarterResult = try engine.calculate(tool: .length, geometry: quarter, scale: scale)
        #expect(abs(try Self.value(quarterResult, .planLength) - perimeter / 4) <= 1e-12 * perimeter)

        let uniform = try engine.calculate(tool: .length, geometry: semicircle, scale: Fixture.uniform(0.02))
        #expect(abs(try Self.value(uniform, .planLength) - 5 * Double.pi * 0.02) <= 1e-14 * 0.32)
    }

    /// A 3:1 ratio at a steep sweep, against the oracle: a full circle of radius 7 as four
    /// quarter arcs under 0.03 × 0.01 m/pt is the whole 0.21 × 0.07 m ellipse.
    @Test("S-106: a full circle of arc edges under 3:1 axes is the ellipse's perimeter")
    func fullCircleUnderThreeToOne() throws {
        let scale = Fixture.separateXY(x: 0.03, y: 0.01)
        let bulge = tan(Double.pi / 8)
        let ring = PolygonRing(
            points: Fixture.points([(7, 0), (0, 7), (-7, 0), (0, -7)]), isClosed: true, bulges: [bulge, bulge, bulge, bulge]
        )
        let result = try engine.calculate(tool: .area, geometry: Self.area(ring), scale: scale)
        let expected = Self.ellipsePerimeter(0.21, 0.07)
        #expect(abs(try Self.value(result, .perimeter) - expected) <= 1e-12 * expected)
        // Area: π·7² pt² × 3e-4 = 0.0147π m².
        #expect(abs(try Self.value(result, .planArea) - 0.0147 * Double.pi) <= 1e-12 * 0.05)
    }

    // MARK: - S-107 thin ellipse

    /// Ellipse Area over a two-point box at 1 m/pt: semi-axes a and b give π·a·b exactly.
    /// Old output (the minor axis by cancellation): 500 × 0.005 → rel 2.4e-8; 1000 × 0.0005 →
    /// rel 3.8e-6; 5000 × 5e-6 → 0 (a representable 0.0785 m² reported as nothing, and no
    /// degenerateArea warning, since the page area is far above the 1e-9 pt² floor).
    @Test("S-107: a thin ellipse keeps its area to rounding at any aspect ratio")
    func thinEllipseArea() throws {
        for (a, b) in [(500.0, 0.005), (1000.0, 0.0005), (5000.0, 5e-6), (3.0, 2.0)] {
            let geometry = MeasurementGeometry(
                pageID: Fixture.pageID, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 2 * a, y: 2 * b)]
            )
            let result = try engine.calculate(tool: .ellipseArea, geometry: geometry, scale: Fixture.unitScale)
            let expected = Double.pi * a * b
            #expect(abs(try Self.value(result, .planArea) - expected) <= 1e-12 * expected, "\(a) × \(b)")
            #expect(!result.hasWarning(.degenerateArea))
        }
    }

    // MARK: - S-108 exact multi-cutout path

    /// Parent (0.3000004, 0.2000004)–(1000.3000006, 1000.2000006): every coordinate half a
    /// lattice step off, rounding outward, so the 1e-6 pt lattice grows it to 1000.000001² —
    /// 1.6e-3 pt² more than its raw 1000.0000002². One 10 × 10 cutout (exact path either way),
    /// then a second 0.01 × 0.01 one: net must fall by 1e-4 (QUALITY_BAR P11).
    /// Old output: the two-cutout net went through the lattice and came out about 1.5e-3 pt²
    /// ABOVE the one-cutout net.
    @Test("S-108: a second tiny cutout lowers the net area (P11), exactly by its own area")
    func secondCutoutNeverRaisesNet() throws {
        let parent = PolygonRing(
            points: Fixture.points([(0.3000004, 0.2000004), (1000.3000006, 0.2000004), (1000.3000006, 1000.2000006), (0.3000004, 1000.2000006)]),
            isClosed: true
        )
        let big = Fixture.ring([(100, 100), (110, 100), (110, 110), (100, 110)])
        let tiny = Fixture.ring([(500.5, 500.5), (500.51, 500.5), (500.51, 500.51), (500.5, 500.51)])
        let one = try engine.calculate(tool: .area, geometry: Self.area(parent, holes: [big]), scale: Fixture.unitScale)
        let two = try engine.calculate(tool: .area, geometry: Self.area(parent, holes: [big, tiny]), scale: Fixture.unitScale)
        let netOne = try #require(one[.netArea]).value
        let netTwo = try #require(two[.netArea]).value
        #expect(netTwo < netOne)
        // Raw: 1000.0000002² − 100 − 0.0001 = 999900.0003000000400…; stored to 15 digits.
        #expect(abs(Fixture.double(netTwo) - 999_900.0003) <= 1e-8)
        #expect(abs(Fixture.double(netOne - netTwo) - 1e-4) <= 1e-8)

        // The net boundary is the drawn rings, not their lattice copies: under
        // outerPlusCutoutEdges 4 × 1000.0000002 + 40 + 0.04 = 4040.0400008 (the lattice copy
        // was 3.2e-6 longer, rel 8e-10).
        var parameters = MeasurementParameters()
        parameters.perimeterPolicy = .outerPlusCutoutEdges
        let bounded = try engine.calculate(
            tool: .area, geometry: Self.area(parent, holes: [big, tiny]), scale: Fixture.unitScale, parameters: parameters
        )
        #expect(abs(try Self.value(bounded, .perimeter) - 4040.0400008) <= 1e-12 * 4040)
    }

    /// Three apart cutouts in every one of the six drawn orders: one stored Decimal (P5), and no
    /// Clipper2 boolean at all.
    @Test("S-108: apart cutouts are order-independent and run no boolean")
    func apartCutoutsExactAndOrderFree() throws {
        let parent = Fixture.ring([(0.31, 0.17), (20.73, 0.29), (20.61, 15.83), (0.43, 15.71)])
        let holes = [
            Fixture.ring([(2.13, 2.07), (4.91, 2.21), (4.77, 4.93), (2.29, 4.81)]),
            Fixture.ring([(8.37, 6.11), (11.03, 6.23), (10.89, 9.97), (8.51, 9.83)]),
            Fixture.ring([(14.71, 1.93), (17.17, 3.01), (16.09, 5.47)])
        ]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var nets: Set<Decimal> = []
        for order in orders {
            let counter = EngineClipper.CallCounter()
            let result = try EngineClipper.CallCounter.$current.withValue(counter) {
                try engine.calculate(tool: .area, geometry: Self.area(parent, holes: order.map { holes[$0] }), scale: Fixture.unitScale)
            }
            #expect(counter.count == 0)
            nets.insert(try #require(result[.netArea]).value)
        }
        #expect(nets.count == 1)
    }

    // MARK: - S-109 coordinate bound on bulged edges

    /// Old output: a bulge of 1e12 on the 100 pt bottom edge made an arc of radius ≈ 2.5e13 pt
    /// and a stored area of about π·r² ≈ 2e27 m²; the chain likewise a length of r·θ ≈ 1.6e14 m.
    @Test("S-109: an arc whose extent leaves the coordinate bound is refused")
    func hugeBulgeRefused() throws {
        let square = PolygonRing(
            points: Fixture.points([(0, 0), (100, 0), (100, 100), (0, 100)]), isClosed: true, bulges: [1e12, 0, 0, 0]
        )
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .area, geometry: Self.area(square), scale: Fixture.unitScale)
        }
        let chain = MeasurementGeometry(
            pageID: Fixture.pageID, points: Fixture.points([(0, 0), (100, 0)]), pointBulges: [1e12, 0]
        )
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .length, geometry: chain, scale: Fixture.unitScale)
        }
        // A cutout's arc counts too.
        let hole = PolygonRing(
            points: Fixture.points([(10, 10), (20, 10), (20, 20), (10, 20)]), isClosed: true, bulges: [0, 0, -1e12, 0]
        )
        let plain = Fixture.ring([(0, 0), (100, 0), (100, 100), (0, 100)])
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .area, geometry: Self.area(plain, holes: [hole]), scale: Fixture.unitScale)
        }
        // Vertices on the bound, an outward semicircle (bulge 1) on the edge x = 1e7 reaches
        // x = 1e7 + 5: refused, where its vertices alone passed.
        let atBound = PolygonRing(
            points: Fixture.points([(1e7 - 10, 0), (1e7, 0), (1e7, 10), (1e7 - 10, 10)]), isClosed: true, bulges: [0, 1, 0, 0]
        )
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .area, geometry: Self.area(atBound), scale: Fixture.unitScale)
        }
    }

    /// A nearly straight arc keeps its centre far off the page but every point on it: bulge
    /// 2e-9 on a 100 pt edge has r = c·(1 + b²)/(4b) = 1.25e10 pt and sagitta s = b·c/2 = 1e-7 pt,
    /// so the square gains the segment ⅔·c·s = 6.667e-6 pt². Measured, not refused.
    @Test("S-109: a nearly straight arc with a huge radius stays measurable")
    func nearlyStraightArcMeasured() throws {
        let square = PolygonRing(
            points: Fixture.points([(0, 0), (100, 0), (100, 100), (0, 100)]), isClosed: true, bulges: [2e-9, 0, 0, 0]
        )
        let result = try engine.calculate(tool: .area, geometry: Self.area(square), scale: Fixture.unitScale)
        #expect(abs(try Self.value(result, .planArea) - (10_000 + 2.0 / 3.0 * 100 * 1e-7)) <= 1e-9)
    }

    // MARK: - S-110 per-segment rise/drop order

    /// The run (0,0) → (10,0) straight, (10,0) → (10,10) an outward semicircle (bulge 1, r 5,
    /// length 5π), (10,10) → (0,10) straight, with rises [3, 4, 0] in drawn order:
    /// √(10² + 3²) + √((5π)² + 4²) + 10 = 10.440306508910550 + 16.209013278… + 10.
    /// Old output: the rises went to [edge, edge, arc], √109 + √(10² + 4²) + 5π ≈ 36.92.
    @Test("S-110: a rise per piece in drawn order, an arc in the middle of the chain included")
    func perSegmentRiseFollowsTheDrawnOrder() throws {
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(0, 0), (10, 0), (10, 10), (0, 10)]),
            pointBulges: [0, 1, 0, 0]
        )
        let result = try engine.calculate(
            tool: .riseDrop, geometry: geometry, scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .perSegment([3, 4, 0]))
        )
        let arc = 5 * Double.pi
        let expected = (100.0 + 9).squareRoot() + (arc * arc + 16).squareRoot() + 10
        #expect(abs(try Self.value(result, .trueLength) - expected) <= 1e-12 * expected)
        #expect(abs(try Self.value(result, .run) - (20 + arc)) <= 1e-12 * 36)
        #expect(!result.hasWarning(.riseDropCountMismatch))
    }
}
