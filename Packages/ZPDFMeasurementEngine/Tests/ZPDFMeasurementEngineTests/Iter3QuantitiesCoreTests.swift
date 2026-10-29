import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Regressions for the engine findings T-073,
/// T-074 and T-075 and the carry-over C-08 (cutouts subtracted exactly from arc-edged areas).
///
/// Every expected number is derived by hand in the comment beside it, or by the independent AGM
/// oracle (``Iter2QuantitiesCoreTests/ellipsePerimeter(_:_:)``), never read from the code under
/// test (QUALITY_BAR §2.6). Each test states the output the old code produced.
@Suite("Iteration 3 — quantities core, engine")
struct Iter3QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID, points: [PDFPoint(x: x0, y: y0), PDFPoint(x: x1, y: y1)])
    }

    /// A deterministic 64-bit linear congruential generator (Knuth's MMIX constants), so the
    /// sampled boxes are the same on every run and every machine.
    struct Sampler {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    // MARK: - T-073 round ellipse gets Radius/Diameter wherever it is drawn

    /// A round Ellipse Area drawn by two clicks: the box side is `(x0 + d) − x0` across and
    /// `(y0 + d) − y0` up, which differ by rounding only (a few ulps of the corner's coordinate).
    /// Under 1:100 (0.0254·100/72 m/pt) the real semi-axes are both `k·d/2` to rounding, so
    /// Radius is `k·d/2` and Diameter `k·d` for every box. 2 000 boxes, corner in 0…3000 pt,
    /// side 50…1500 pt.
    /// Old output: the semi-axes came from `sqrt((F ± sqrt(F² − 4det²))/2)`, whose discriminant
    /// cancels; 128 of these 2 000 boxes (6.4 %) had |major − minor| above the 1e-6 pt circle
    /// test and were written without Radius and Diameter.
    @Test("T-073: a round Ellipse Area reports Radius and Diameter at any sheet position")
    func roundEllipseAnywhere() throws {
        let k = Decimal(string: "0.0254")! * 100 / 72
        let kd = NumericPolicy.double(from: k)
        var sampler = Sampler(state: 0x5EED_0073)
        var missing = 0
        for _ in 0..<2000 {
            let x0 = sampler.next() * 3000
            let y0 = sampler.next() * 3000
            let d = 50 + sampler.next() * 1450
            let result = try engine.calculate(tool: .ellipseArea, geometry: Self.box(x0, y0, x0 + d, y0 + d), scale: Fixture.uniform(k))
            guard let radius = result[.radius], let diameter = result[.diameter] else {
                missing += 1
                continue
            }
            #expect(Self.rel(Fixture.double(radius.value), kd * d / 2) <= 1e-12)
            #expect(Self.rel(Fixture.double(diameter.value), kd * d) <= 1e-12)
        }
        #expect(missing == 0, "\(missing) of 2000 round ellipses lost Radius/Diameter")
    }

    /// The same circle under a uniform scale turned by 30°: `M = s·R(30°)` with s = 0.02 m/pt,
    /// written as Decimal components (cos 30° = √3/2, sin 30° = ½). A rotation does not change a
    /// circle, so Radius is `s·d/2`. Old output: the rotated matrix's rounded components gave
    /// `F² − 4det²` noise of the same size, and some positions lost Radius here too.
    @Test("T-073: a circle under a rotated uniform scale keeps Radius and Diameter")
    func roundEllipseUnderRotation() throws {
        let s = 0.02
        let cosine = Decimal(string: "0.8660254037844386")! * Decimal(string: "0.02")!
        let sine = Decimal(string: "0.5")! * Decimal(string: "0.02")!
        let rotated = ScaleTransform(
            id: Fixture.scaleID,
            version: 1,
            matrix: AffineScaleMatrix(a: cosine, b: -sine, c: sine, d: cosine),
            units: .metric,
            source: .preset
        )
        var sampler = Sampler(state: 0x0730_0073)
        var missing = 0
        for _ in 0..<500 {
            let x0 = sampler.next() * 3000
            let y0 = sampler.next() * 3000
            let d = 50 + sampler.next() * 1450
            let result = try engine.calculate(tool: .ellipseArea, geometry: Self.box(x0, y0, x0 + d, y0 + d), scale: rotated)
            guard let radius = result[.radius] else {
                missing += 1
                continue
            }
            #expect(Self.rel(Fixture.double(radius.value), s * d / 2) <= 1e-9)
        }
        #expect(missing == 0, "\(missing) of 500 rotated circles lost Radius")
    }

    /// The circle test and the semi-axes, directly: `S = hypot(n00 + n11, n10 − n01)`,
    /// `D = hypot(n00 − n11, n10 + n01)`, major `(S + D)/2`, and the axis difference `min(S, D)`.
    /// Under diag(2, 3) m/pt a 20 × 10 box has semi-axes 20 m and 15 m exactly; under a reflection
    /// diag(1, −1) a circle is still a circle.
    @Test("T-073: semi-axes and axis difference from the hypot form")
    func semiAxesHypotForm() {
        let axes = EllipseMath.realSemiAxes(pageSemiAxisX: 10, pageSemiAxisY: 5, scale: Fixture.separateXY(x: 2, y: 3))
        #expect(axes.major == 20 && axes.minor == 15)
        #expect(axes.difference == 5)
        let mirror = ScaleTransform(
            id: Fixture.scaleID, version: 1, matrix: AffineScaleMatrix(a: 1, b: 0, c: 0, d: -1), units: .metric, source: .preset
        )
        let circle = EllipseMath.realSemiAxes(pageSemiAxisX: 7, pageSemiAxisY: 7, scale: mirror)
        #expect(circle.major == 7 && circle.minor == 7 && circle.difference == 0)
    }

    // MARK: - T-074 ellipse circumference by quadrature

    /// Ellipse Area over a 2a × 2b box at 1 m/pt: Circumference and Perimeter are the ellipse's
    /// perimeter, checked against the AGM oracle (60-digit references in the comments):
    /// 1 × ½ → 4.844224110273838, 1 × 0.1 → 4.063974180100896, 1 × 0.01 → 4.001098329722652.
    /// Old output (Ramanujan II): relative errors −4.56e-10, −1.156e-5 and −2.390e-4 — a 10 m ×
    /// 1 m ellipse 0.235 mm short — while its documentation promised 1e-12 and 1e-8.
    @Test("T-074: the ellipse circumference matches the AGM oracle at 2:1, 10:1 and 100:1")
    func circumferenceByQuadrature() throws {
        let references: [(Double, Double, Double)] = [
            (1, 0.5, 4.844224110273838),
            (1, 0.1, 4.063974180100896),
            (1, 0.01, 4.001098329722652),
            (1500, 3, Iter2QuantitiesCoreTests.ellipsePerimeter(1500, 3))
        ]
        for (a, b, reference) in references {
            let oracle = Iter2QuantitiesCoreTests.ellipsePerimeter(a, b)
            #expect(Self.rel(oracle, reference) <= 1e-15, "oracle \(a) × \(b)")
            let result = try engine.calculate(tool: .ellipseArea, geometry: Self.box(0, 0, 2 * a, 2 * b), scale: Fixture.unitScale)
            #expect(Self.rel(try Self.value(result, .circumference), oracle) <= 1e-13, "\(a) × \(b)")
            #expect(Self.rel(try Self.value(result, .perimeter), oracle) <= 1e-13, "\(a) × \(b)")
        }
    }

    /// Under a separate X/Y scale 2 × 3 m/pt a 20 × 10 pt box is an ellipse of semi-axes 20 m and
    /// 15 m, perimeter AGM(20, 15) = 110.5270613...; under a uniform scale turned by 30° a 40 × 10
    /// box is the 0.4 × 0.1 m ellipse (s = 0.02), perimeter AGM(0.4, 0.1). An Ellipse Cutout
    /// reports what it removes and writes the same circumference. A zero-height box is the
    /// degenerate ellipse, perimeter 4a exactly (old: (14/11)πa, 0.04 % short).
    @Test("T-074: circumference under separate X/Y, a rotated scale, a cutout, and b = 0")
    func circumferenceUnderAnyScale() throws {
        let separate = try engine.calculate(tool: .ellipseArea, geometry: Self.box(0, 0, 20, 10), scale: Fixture.separateXY(x: 2, y: 3))
        #expect(Self.rel(try Self.value(separate, .circumference), Iter2QuantitiesCoreTests.ellipsePerimeter(20, 15)) <= 1e-13)
        let cutout = try engine.calculate(tool: .ellipseCutout, geometry: Self.box(0, 0, 20, 10), scale: Fixture.separateXY(x: 2, y: 3))
        #expect(Self.rel(try Self.value(cutout, .circumference), Iter2QuantitiesCoreTests.ellipsePerimeter(20, 15)) <= 1e-13)

        let cosine = Decimal(string: "0.8660254037844386")! * Decimal(string: "0.02")!
        let sine = Decimal(string: "0.5")! * Decimal(string: "0.02")!
        let rotated = ScaleTransform(
            id: Fixture.scaleID, version: 1, matrix: AffineScaleMatrix(a: cosine, b: -sine, c: sine, d: cosine),
            units: .metric, source: .preset
        )
        let turned = try engine.calculate(tool: .ellipseArea, geometry: Self.box(100, 200, 140, 210), scale: rotated)
        #expect(Self.rel(try Self.value(turned, .circumference), Iter2QuantitiesCoreTests.ellipsePerimeter(0.4, 0.1)) <= 1e-12)

        let flat = try engine.calculate(tool: .ellipseArea, geometry: Self.box(0, 0, 2, 0), scale: Fixture.unitScale)
        #expect(Swift.abs(try Self.value(flat, .circumference) - 4) <= 1e-13)
        #expect(flat.hasWarning(.degenerateArea))
    }

    // MARK: - T-075 Arc Length under a separate X/Y scale

    /// Arc Length through (0,0), (5,5), (10,0): the upper semicircle of radius 5 about (5,0).
    /// Under 0.02 × 0.01 m/pt it maps to half of the 0.1 × 0.05 m ellipse: half of
    /// 0.4844224110273838 = 0.2422112055136919 m, by the same quadrature Length uses. Radius and
    /// Angle belong to a circle and are not written for the mapped ellipse. Under a uniform
    /// 0.02 m/pt the fast path is unchanged: 5π·0.02 m, Radius 0.1 m, Angle π.
    /// Old output: the tool refused with directionRequiredForNonUniformScale.
    @Test("T-075: Arc Length measures an arc under a separate X/Y scale")
    func arcLengthUnderSeparateXY() throws {
        let geometry = Fixture.polyline([(0, 0), (5, 5), (10, 0)])
        let result = try engine.calculate(tool: .arcLength, geometry: geometry, scale: Fixture.separateXY(x: 0.02, y: 0.01))
        let expected = Iter2QuantitiesCoreTests.ellipsePerimeter(0.1, 0.05) / 2
        #expect(Swift.abs(expected - 0.2422112055136919) <= 1e-15)
        #expect(Self.rel(try Self.value(result, .arcLength), expected) <= 1e-12)
        #expect(Self.rel(try Self.value(result, .planLength), expected) <= 1e-12)
        #expect(result[.radius] == nil && result[.angle] == nil)

        let uniform = try engine.calculate(tool: .arcLength, geometry: geometry, scale: Fixture.uniform(Decimal(string: "0.02")!))
        #expect(Self.rel(try Self.value(uniform, .arcLength), 5 * Double.pi * 0.02) <= 1e-14)
        #expect(Self.rel(try Self.value(uniform, .radius), 0.1) <= 1e-14)
        #expect(Self.rel(try Self.value(uniform, .angle), Double.pi) <= 1e-14)
    }

    // MARK: - C-08 cutouts subtracted exactly on the arcs

    static let square = Fixture.ring([(0, 0), (10, 0), (10, 10), (0, 10)])

    /// A circle of radius `r` about (cx, cy) as a ring of four quarter arcs (bulge tan(π/8)).
    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> PolygonRing {
        let bulge = tan(Double.pi / 8)
        return PolygonRing(
            points: Fixture.points([(cx + r, cy), (cx, cy + r), (cx - r, cy), (cx, cy - r)]),
            isClosed: true,
            bulges: [bulge, bulge, bulge, bulge]
        )
    }

    static func area(_ outer: PolygonRing, holes: [PolygonRing]) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: holes)])
    }

    static let edges = MeasurementParameters(perimeterPolicy: .outerPlusCutoutEdges)

    /// A circular cutout of radius 2 about (9.5, 5) hangs over the square's right edge x = 10 by
    /// the segment at distance d = 0.5 from its centre: `r²·acos(d/r) − d·√(r² − d²)` =
    /// 4·acos(0.25) − 0.5·√3.75. The part removed is the disc less that segment, so
    /// net = 100 − 4π + 4·acos(0.25) − 0.5·√3.75 = 92.2601858... pt².
    /// Old output: the boolean on the ring flattened to chords of sagitta ≤ 1e-3 pt removed the
    /// chord polygon, 3.1e-3 pt² too little (net 92.604...+3.1e-3).
    @Test("C-08: an arc cutout over the outer edge removes exactly the part inside")
    func arcCutoutOverTheEdge() throws {
        let expected = 100 - 4 * Double.pi + 4 * acos(0.25) - 0.5 * 3.75.squareRoot()
        let result = try engine.calculate(tool: .area, geometry: Self.area(Self.square, holes: [Self.circle(9.5, 5, 2)]), scale: Fixture.unitScale)
        let measured = try Self.value(result, .netArea)
        #expect(Self.rel(measured, expected) <= 1e-12, "net \(measured) for \(expected)")
        #expect(try Self.value(result, .planArea) == 100)
        #expect(result.hasWarning(.cutoutOutsideParent))
    }

    /// Two circular cutouts of radius 2 about (4, 5) and (6, 5) overlap in a lens of
    /// `2r²·acos(d/2r) − (d/2)·√(4r² − d²)` = 8π/3 − 2√3 (d = 2). Their union is
    /// 8π − (8π/3 − 2√3) = 16π/3 + 2√3, so net = 100 − 16π/3 − 2√3. Under outerPlusCutoutEdges
    /// the boundary is the square's 40 plus each circle less the arc of 2·acos(½) = 2π/3 inside
    /// the other: 2·(2π − 2π/3)·2 = 16π/3, with no chord anywhere.
    /// Old output: the union of the flattened rings removed 1.2e-3 pt² too little, and the
    /// perimeter was their chords (−5.7e-5 pt) under a numericalPrecisionLoss warning.
    @Test("C-08: two overlapping arc cutouts: exact union, exact boundary")
    func overlappingArcCutouts() throws {
        let geometry = Self.area(Self.square, holes: [Self.circle(4, 5, 2), Self.circle(6, 5, 2)])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale, parameters: Self.edges)
        let net = 100 - 16 * Double.pi / 3 - 2 * 3.0.squareRoot()
        let measured = try Self.value(result, .netArea)
        #expect(Self.rel(measured, net) <= 1e-12, "net \(measured) for \(net)")
        #expect(Self.rel(try Self.value(result, .perimeter), 40 + 16 * Double.pi / 3) <= 1e-12)
        #expect(!result.warnings.contains { $0.code == .numericalPrecisionLoss })
    }

    /// The golden 10 × 5 area with its right side an outward semicircle of radius 2.5 about
    /// (10, 2.5) (area 50 + 3.125π), and a straight 4 × 3 cutout (9, 1)–(13, 4) across the arc.
    /// Removed: the 1 × 3 strip left of x = 10, plus the half-disc between y = 1 and y = 4,
    /// `∫ √(r² − t²) dt` over t ∈ [−1.5, 1.5] = 3 + 6.25·asin(0.6), so 6 + 6.25·asin(0.6) and
    /// net = 44 + 3.125π − 6.25·asin(0.6). Boundary under outerPlusCutoutEdges: the outer 25 + 2.5π
    /// less the arc inside the cutout (2.5 · 2·asin(0.6)), plus the cutout's edges inside the area:
    /// x = 9 (3), y = 1 and y = 4 from x = 9 to the circle at x = 12 (3 each):
    /// 34 + 2.5π − 5·asin(0.6).
    /// Old output: the arc inside the cutout was its chords — net 1.5e-5 pt² off, perimeter chords
    /// under numericalPrecisionLoss.
    @Test("C-08: a straight cutout across an arc edge of the outer ring")
    func straightCutoutAcrossAnArc() throws {
        let outer = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let hole = Fixture.ring([(9, 1), (13, 1), (13, 4), (9, 4)])
        let result = try engine.calculate(tool: .area, geometry: Self.area(outer, holes: [hole]), scale: Fixture.unitScale, parameters: Self.edges)
        let net = 44 + 3.125 * Double.pi - 6.25 * asin(0.6)
        #expect(Self.rel(try Self.value(result, .planArea), 50 + 3.125 * Double.pi) <= 1e-12)
        let measured = try Self.value(result, .netArea)
        #expect(Self.rel(measured, net) <= 1e-12, "net \(measured) for \(net)")
        #expect(Self.rel(try Self.value(result, .perimeter), 34 + 2.5 * Double.pi - 5 * asin(0.6)) <= 1e-12)
        #expect(!result.warnings.contains { $0.code == .numericalPrecisionLoss })
    }

    /// A cutout drawn exactly on an arc-edged outer ring removes all of it: net exactly 0
    /// (QUALITY_BAR §2.5, "cutout equals parent").
    /// Old output: the exact outer less the flattened boolean's removal — the chords' residue,
    /// about 8e-5 pt² left standing.
    @Test("C-08: a cutout equal to an arc-edged parent leaves exactly nothing")
    func cutoutEqualToArcParent() throws {
        let outer = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let result = try engine.calculate(tool: .area, geometry: Self.area(outer, holes: [outer]), scale: Fixture.unitScale, parameters: Self.edges)
        let net = try #require(result[.netArea]).value
        #expect(net == 0, "net \(net)")
        #expect(try Self.value(result, .perimeter) == 0)
    }

    /// QUALITY_BAR P5 and P11 on the exact path: the three cutouts — the two overlapping circles
    /// and a circle of radius r = 0.01 centred on the first one's rim at (2, 5) — give one net
    /// area in every drawn order, and adding the small one lowers the net by exactly its part
    /// outside the big circle (R = 2, centres d = 2 apart): `πr² − lens`, the lens being
    /// `r²·acos((d² + r² − R²)/2dr) + R²·acos((d² + R² − r²)/2dR) − ½√((−d+r+R)(d+r−R)(d−r+R)(d+r+R))`,
    /// 1.5725e-4 — more than half the small disc, because the big disc lies inside the tangent
    /// half-plane at that point.
    /// Old output: drop 1.4452e-4, less than half — the chords of the flattened rings.
    @Test("C-08: the exact path is order-free and adding a cutout never raises the net")
    func exactPathOrderAndMonotonicity() throws {
        let a = Self.circle(4, 5, 2), b = Self.circle(6, 5, 2), small = Self.circle(2, 5, 0.01)
        let two = try engine.calculate(tool: .area, geometry: Self.area(Self.square, holes: [a, b]), scale: Fixture.unitScale)
        let twoNet = try Self.value(two, .netArea)
        var values: Set<Decimal> = []
        for order in [[a, b, small], [a, small, b], [b, a, small], [b, small, a], [small, a, b], [small, b, a]] {
            let result = try engine.calculate(tool: .area, geometry: Self.area(Self.square, holes: order), scale: Fixture.unitScale)
            values.insert(try #require(result[.netArea]).value)
        }
        #expect(values.count == 1)
        let threeNet = Fixture.double(try #require(values.first))
        let drop = twoNet - threeNet
        let (r, bigR, d) = (0.01, 2.0, 2.0)
        let lens = r * r * acos((d * d + r * r - bigR * bigR) / (2 * d * r))
            + bigR * bigR * acos((d * d + bigR * bigR - r * r) / (2 * d * bigR))
            - 0.5 * ((-d + r + bigR) * (d + r - bigR) * (d - r + bigR) * (d + r + bigR)).squareRoot()
        let expected = Double.pi * r * r - lens
        #expect(expected > Double.pi * r * r / 2 && Swift.abs(expected - 1.5725e-4) < 1e-8, "hand value \(expected)")
        #expect(Swift.abs(drop - expected) <= 1e-10, "drop \(drop) for \(expected)")
    }

    /// Cutouts clear of each other and of the arcs keep the exact path they always had, bit for
    /// bit: the golden area less a 2 × 2 square and a radius-1 circle, 50 + 3.125π − 4 − π.
    @Test("C-08: disjoint cutouts inside an arc-edged area are unchanged")
    func disjointCutoutsUnchanged() throws {
        let outer = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let result = try engine.calculate(
            tool: .area,
            geometry: Self.area(outer, holes: [Fixture.ring([(2, 1), (4, 1), (4, 3), (2, 3)]), Self.circle(7, 2.5, 1)]),
            scale: Fixture.unitScale
        )
        #expect(Self.rel(try Self.value(result, .netArea), 46 + 2.125 * Double.pi) <= 1e-12)
    }

    // MARK: - Formula version 7

    /// Every value T-073, T-074, T-075 and C-08 changed is stamped with a formula version past 6
    /// (7 from ADR-0037, now 8 from ADR-0041), so a value stored under version 6 is recognisably
    /// from the old formula.
    /// Old output: stamped 6.
    @Test("T-073…T-075, C-08: the changed results are stamped a formula version past 6 (now 8)")
    func changedResultsCarryVersionSeven() throws {
        #expect(ContractVersion.measurementFormulaVersion == 8)
        let results = [
            try engine.calculate(tool: .ellipseArea, geometry: Self.box(0, 0, 20, 2), scale: Fixture.unitScale),
            try engine.calculate(tool: .arcLength, geometry: Fixture.polyline([(0, 0), (5, 5), (10, 0)]), scale: Fixture.separateXY(x: 0.02, y: 0.01)),
            try engine.calculate(tool: .area, geometry: Self.area(Self.square, holes: [Self.circle(9.5, 5, 2)]), scale: Fixture.unitScale)
        ]
        for result in results {
            #expect(result.formulaVersion == 8)
        }
    }
}
