import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// NL-MEASURE-05 / ADR-0030 §5: arc segments in chains and rings, measured exactly.
/// Every expected value is hand-derived at 1 m/pt (QUALITY_BAR §2: closed form, rel ≤ 1e-12).
@Suite("Arc segments in the engine (NL-MEASURE-05)")
struct ArcSegmentEngineTests {

    let engine = MeasurementEngine()

    /// The golden case: a 10 × 5 m rectangle whose right short side is an outward semicircle.
    static let goldenRing = PolygonRing(
        points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]),
        isClosed: true,
        bulges: [0, 1, 0, 0]
    )

    static func rel(_ value: Decimal?, _ expected: Double) -> Double {
        guard let value else { return .infinity }
        return Swift.abs(NumericPolicy.double(from: value) - expected) / Swift.abs(expected)
    }

    static func rel(_ value: Double?, _ expected: Double) -> Double {
        guard let value else { return .infinity }
        return Swift.abs(value - expected) / Swift.abs(expected)
    }

    /// Area 50 + π·2.5²/2 = 50 + 3.125π; perimeter 10 + 10 + 5 + π·2.5 = 25 + 2.5π (the two long
    /// sides, the left short side, and the half circle).
    @Test("Golden: area 50 + 3.125π and perimeter 25 + 2.5π, rel ≤ 1e-12")
    func golden() throws {
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Self.goldenRing)])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(result[.planArea]?.value, 50 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(result[.netArea]?.value, 50 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(result[.perimeter]?.value, 25 + 2.5 * .pi) <= 1e-12)

        // Clockwise, with the bulge sign flipped to keep the arc outward: the same numbers.
        let clockwise = PolygonRing(points: Fixture.points([(0, 0), (0, 5), (10, 5), (10, 0)]), isClosed: true, bulges: [0, 0, -1, 0])
        let cw = try engine.calculate(tool: .area, geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: clockwise)]), scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(cw[.planArea]?.value, 50 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(cw[.perimeter]?.value, 25 + 2.5 * .pi) <= 1e-12)
    }

    /// At 1:100 (0.0254·100/72 m/pt) every length scales by k and every area by k².
    @Test("Under a scale: length × k, area × k²")
    func scaled() throws {
        let k = Decimal(string: "0.0254")! * 100 / 72
        let kd = NumericPolicy.double(from: k)
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Self.goldenRing)])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.uniform(k), parameters: .default)
        #expect(Self.rel(result[.planArea]?.value, (50 + 3.125 * .pi) * kd * kd) <= 1e-12)
        #expect(Self.rel(result[.perimeter]?.value, (25 + 2.5 * .pi) * kd) <= 1e-12)
    }

    /// A 2 × 2 cutout at (2..4, 1..3), well clear of the arc: net = 50 + 3.125π − 4. The boolean
    /// runs on the flattened ring, and the cutout is exact because it does not touch the arc.
    @Test("A cutout clear of the arc is subtracted exactly")
    func cutout() throws {
        let hole = Fixture.ring([(2, 1), (4, 1), (4, 3), (2, 3)])
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Self.goldenRing, holes: [hole])])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(result[.planArea]?.value, 50 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(result[.netArea]?.value, 46 + 3.125 * .pi) <= 1e-9)
        #expect(Self.rel(result[.cutoutArea]?.value, 4) <= 1e-9)
        // Outer-only perimeter is the drawn boundary, exact.
        #expect(Self.rel(result[.perimeter]?.value, 25 + 2.5 * .pi) <= 1e-12)
    }

    /// A polylength (0,0) → (10,0) → (10,5) whose second edge is a semicircle: 10 + 2.5π.
    /// A quarter-circle edge (bulge tan(π/8)) from (0,0) to (10,10) has r = 10, length 5π.
    @Test("A chain with arc edges: straight + r·θ")
    func chain() throws {
        let semicircle = MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(0, 0), (10, 0), (10, 5)]), pointBulges: [0, 1, 0])
        let result = try engine.calculate(tool: .polylength, geometry: semicircle, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(result[.planLength]?.value, 10 + 2.5 * .pi) <= 1e-12)

        let quarter = MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(0, 0), (10, 10)]), pointBulges: [Foundation.tan(.pi / 8), 0])
        let q = try engine.calculate(tool: .length, geometry: quarter, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(q[.planLength]?.value, 5 * .pi) <= 1e-12)

        // Misaligned bulges are ignored: the straight 10 + 5 = 15.
        let misaligned = MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(0, 0), (10, 0), (10, 5)]), pointBulges: [1])
        let m = try engine.calculate(tool: .polylength, geometry: misaligned, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(m[.planLength]?.value, 15) <= 1e-12)
    }

    /// Uniform plane at s = 0.5 (fall line along +x): the true area is the plan area × √1.25
    /// exactly. The true perimeter follows the per-edge rule: the long sides along x stretch by
    /// √1.25, the left side (along y) does not, and the semicircle's true length is
    /// 2.5 · ∫_{−π/2}^{π/2} √(1 + s² sin²φ) dφ (the tilt stretches its x motion), evaluated by a
    /// 20 000-step Simpson rule as an independent oracle.
    @Test("Slope: true area exact; true perimeter by the per-edge rule on the arc")
    func slope() throws {
        var parameters = MeasurementParameters.default
        parameters.slope = .uniformPlane(.decimalRatio(Decimal(string: "0.5")!), azimuth: SlopeAzimuth(degrees: 0))
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Self.goldenRing)])
        let result = try engine.calculate(tool: .trueSlopedArea, geometry: geometry, scale: Fixture.unitScale, parameters: parameters)
        let plan = 50 + 3.125 * Double.pi
        #expect(Self.rel(result[.trueArea]?.value, plan * (1.25).squareRoot()) <= 1e-12)

        func integrand(_ phi: Double) -> Double { (1 + 0.25 * Foundation.sin(phi) * Foundation.sin(phi)).squareRoot() }
        let n = 20_000
        let a = -Double.pi / 2, b = Double.pi / 2, h = (b - a) / Double(n)
        var sum = integrand(a) + integrand(b)
        for i in 1..<n { sum += integrand(a + Double(i) * h) * (i % 2 == 1 ? 4 : 2) }
        let arcTrue = 2.5 * sum * h / 3
        let expected = 10 * (1.25).squareRoot() * 2 + 5 + arcTrue
        // The arc's true length is the exact plan length times the flattened true/plan ratio
        // (1° chords): agreement to 1e-6 is the method's, stated in ADR-0030 §5.
        #expect(Self.rel(result[.truePerimeter]?.value, expected) <= 1e-6, "\(String(describing: result[.truePerimeter]?.value)) vs \(expected)")
    }

    @Test("The digest sees a bulge; a geometry without one digests as before")
    func digest() {
        let straight = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Fixture.ring([(0, 0), (10, 0), (10, 5), (0, 5)]))])
        let arced = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: Self.goldenRing)])
        #expect(GeometryDigest.digest(of: straight) != GeometryDigest.digest(of: arced))
        var explicitNil = straight
        explicitNil.pointBulges = nil
        #expect(GeometryDigest.canonicalEncoding(of: straight) == GeometryDigest.canonicalEncoding(of: explicitNil))
        #expect(!String(decoding: GeometryDigest.canonicalEncoding(of: straight), as: UTF8.self).contains("RB"))
    }
}
