import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Review fixes to the arc-segment engine paths (ADR-0030 §5.7). Every expected value is
/// hand-derived at 1 m/pt.
@Suite("Arc engine review fixes (ADR-0030 §5.7)")
struct ArcReviewFixEngineTests {

    let engine = MeasurementEngine()

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func double(_ value: Decimal?) -> Double {
        NumericPolicy.double(from: value ?? 0)
    }

    /// The golden ring: a 10 × 5 rectangle, counter-clockwise, whose right side (10,0)→(10,5) is an
    /// outward semicircle (bulge 1, centre (10, 2.5), r = 2.5).
    static let golden = PolygonGeometry(outer: PolygonRing(
        points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]),
        isClosed: true,
        bulges: [0, 1, 0, 0]
    ))

    // MARK: Rectangle Area keeps its arcs

    /// What Merge Areas stores when a Rectangle Area [0,10]×[5,8] (selected first, so the merged
    /// record keeps its tool) is merged with the golden area: (0,0) → (10,0) ⌒ (10,5) → (10,8) →
    /// (0,8), the semicircle kept. Area 30 + 50 + π·2.5²/2 = 80 + 3.125π; perimeter
    /// 10 + 2.5π + 3 + 10 + 8 = 31 + 2.5π.
    ///
    /// Old output: the Rectangle Area calculator rebuilt the ring without its bulges and measured
    /// the chords — 80.0 m² and 36.0 m, 10.9 % short, while the canvas drew the arc.
    @Test("A Rectangle Area record with an arc is measured on the arc: 80 + 3.125π, 31 + 2.5π")
    func rectangleAreaKeepsArcs() throws {
        let merged = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: PolygonRing(
            points: Fixture.points([(0, 0), (10, 0), (10, 5), (10, 8), (0, 8)]),
            isClosed: true,
            bulges: [0, 1, 0, 0, 0]
        ))])
        let rectangle = try engine.calculate(tool: .rectangleArea, geometry: merged, scale: Fixture.unitScale, parameters: .default)
        #expect(Self.rel(Self.double(rectangle[.netArea]?.value), 80 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(Self.double(rectangle[.planArea]?.value), 80 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(Self.double(rectangle[.perimeter]?.value), 31 + 2.5 * .pi) <= 1e-12)
        // The Area tool measures the same stored ring the same way.
        let area = try engine.calculate(tool: .area, geometry: merged, scale: Fixture.unitScale, parameters: .default)
        #expect(rectangle[.netArea]?.value == area[.netArea]?.value)
        #expect(rectangle[.perimeter]?.value == area[.perimeter]?.value)
        // A straight Rectangle Area is measured exactly as before: 10 × 3 = 30, perimeter 26.
        let plain = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: PolygonRing(
            points: Fixture.points([(0, 5), (10, 5), (10, 8), (0, 8)])
        ))])
        let straight = try engine.calculate(tool: .rectangleArea, geometry: plain, scale: Fixture.unitScale, parameters: .default)
        #expect(straight[.netArea]?.value == 30)
        #expect(straight[.perimeter]?.value == 26)
    }

    // MARK: Double-count guard and coverage see arcs

    /// A 1 × 1 square [11,12]×[2,3] lies inside the golden semicircle's bulge (its far corners are
    /// √(2² + 0.5²) ≈ 2.06 from the centre (10, 2.5), inside r = 2.5, more than 0.4 clear of the
    /// circle) and wholly outside the chord box [0,10]×[0,5]. The shared region is the square: 1.
    ///
    /// Old output: `[]` — the rings entered Clipper as their chords, and the box prefilter used the
    /// vertices only, so the overlap was never looked at.
    @Test("An overlap inside an arc's bulge is found: 1 pt²")
    func overlapInsideTheBulge() throws {
        let square = PolygonGeometry(outer: PolygonRing(points: Fixture.points([(11, 2), (12, 2), (12, 3), (11, 3)])))
        let overlaps = try OverlapGuard.overlaps(of: [Self.golden, square])
        #expect(overlaps.count == 1)
        #expect(Swift.abs((overlaps.first?.pageArea ?? 0) - 1) <= 1e-9)
    }

    /// The coverage map's area of the golden ring is the flattened boolean's (ADR-0030 §5.2 item 3):
    /// every chord of the 1e-3 pt flattening is inscribed, so the area lies between the exact
    /// 50 + 3.125π and that minus the segments cut off — each at most (2/3)·ℓ·s for a chord ℓ of
    /// sagitta s ≤ 1e-3, together at most (2/3)·1e-3·2.5π — give or take the 1e-6 pt lattice.
    ///
    /// Old output: 50, the chord rectangle.
    @Test("Coverage measures an arc ring on its 1e-3 pt flattening, not its chords")
    func coverageSeesArcs() {
        let exact = 50 + 3.125 * Double.pi
        let bound = 2.0 / 3.0 * 1e-3 * 2.5 * Double.pi
        let area = CoverageRegions.pdfArea(of: Self.golden)
        #expect(area <= exact + 1e-5, "\(area)")
        #expect(area >= exact - bound - 1e-5, "\(area) vs \(exact) − \(bound)")
    }

    // MARK: Numerics

    /// The rounded-corner ring 84 + 4π measured by the engine at the origin and at two sheet
    /// positions (each an exact translation; see the contracts suite). Old output: rel 4.8e-12 at
    /// (3000.37, 2000.61) and 1.5e-10 at (14000.37, 13000.61).
    @Test("The engine's area of a ring with an arc does not drift with its position on the sheet")
    func areaAtSheetPositions() throws {
        let expected = 84 + 4 * Double.pi
        for (dx, dy) in [(0.0, 0.0), (3000.37, 2000.61), (14000.37, 13000.61)] {
            let ring = PolygonRing(
                points: [(0.0, 0.0), (10, 0), (10, 6), (6, 10), (0, 10)].map { PDFPoint(x: $0.0 + dx, y: $0.1 + dy) },
                isClosed: true,
                bulges: [0, 0, Foundation.tan(Double.pi / 8), 0, 0]
            )
            let result = try engine.calculate(
                tool: .area,
                geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: ring)]),
                scale: Fixture.unitScale,
                parameters: .default
            )
            #expect(Self.rel(Self.double(result[.netArea]?.value), expected) <= 1e-12, "offset (\(dx), \(dy))")
        }
    }

    /// A 100 × 50 rectangle whose bottom edge (0,0)→(100,0) bows out by a nearly straight arc: area
    /// 5000 + (c²·b/3)(1 + b²/5) with c = 100 (the series of the contracts suite). Old output:
    /// rel 1.6e-10 at b = 1e-7, 1.6e-9 at b = 1e-8, 3.3e-9 at b = 5e-9.
    @Test("A nearly straight arc edge measures exactly: 5000 + c²b/3·(1 + b²/5)")
    func nearlyStraightArcEdge() throws {
        for bulge in [1e-4, 1e-7, 1e-8, 5e-9] {
            let ring = PolygonRing(points: Fixture.points([(0, 0), (100, 0), (100, 50), (0, 50)]), isClosed: true, bulges: [bulge, 0, 0, 0])
            let result = try engine.calculate(
                tool: .area,
                geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: ring)]),
                scale: Fixture.unitScale,
                parameters: .default
            )
            let expected = 5000 + 100.0 * 100.0 * bulge / 3 * (1 + bulge * bulge / 5)
            #expect(Self.rel(Self.double(result[.netArea]?.value), expected) <= 1e-12, "b = \(bulge)")
        }
    }
}
