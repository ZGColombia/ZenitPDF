import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// X-042 (a point-form Arc Length is
/// exactly three points), X-043 (a sloped arc is integrated on the curve) and X-044 (an Ellipse
/// Cutout's ring never reaches past its box, so a cutout flush with its parent's edge lies inside
/// it).
///
/// Every expected number is derived by hand beside it, or by the composite Simpson rule written in
/// this file — a different rule from the engine's Gauss-Legendre — never read from the code under
/// test (QUALITY_BAR §2.6). Each test states the output the old code produced.
@Suite("Iteration 7 — quantities core, engine")
struct Iter7QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    /// Composite Simpson on `intervals` (even) steps, Kahan-summed: the independent reference.
    static func simpson(_ from: Double, _ to: Double, intervals: Int = 20_000, _ f: (Double) -> Double) -> Double {
        let h = (to - from) / Double(intervals)
        var sum = 0.0, compensation = 0.0
        func add(_ term: Double) {
            let y = term - compensation
            let t = sum + y
            compensation = (t - sum) - y
            sum = t
        }
        for index in 0...intervals {
            let weight: Double = index == 0 || index == intervals ? 1 : (index % 2 == 1 ? 4 : 2)
            add(weight * f(from + Double(index) * h))
        }
        return sum * h / 3
    }

    /// Shoelace about the first vertex, Kahan-summed: the ring's area, written here.
    static func shoelace(_ ring: [PDFPoint]) -> Double {
        let origin = ring[0]
        var sum = 0.0, compensation = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            let term = (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y)
            let y = term - compensation
            let t = sum + y
            compensation = (t - sum) - y
            sum = t
        }
        return sum / 2
    }

    // MARK: - X-042: a point-form Arc Length is three points

    /// Four points (0, 0), (5, 5), (10, 0), (15, 5). Old output: 15.7079632679 m = 5π, the
    /// semicircle through the first three, with no warning — the fourth point was dropped.
    @Test("X-042: four points are refused, not measured as the arc through the first three")
    func fourPointsAreRefused() {
        let geometry = Fixture.polyline([(0, 0), (5, 5), (10, 0), (15, 5)])
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .threePoints)) {
            try engine.calculate(tool: .arcLength, geometry: geometry, scale: Fixture.unitScale)
        }
        // Two points are refused for the same reason; no points at all still asks for an arc.
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .threePoints)) {
            try engine.calculate(tool: .arcLength, geometry: Fixture.polyline([(0, 0), (10, 0)]), scale: Fixture.unitScale)
        }
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .arc)) {
            try engine.calculate(tool: .arcLength, geometry: MeasurementGeometry(pageID: Fixture.pageID), scale: Fixture.unitScale)
        }
    }

    /// A doubled start click, (0, 0) twice, then (5, 5) and (10, 0): three distinct points, the
    /// semicircle of radius 5 about (5, 0), 5π m, said to have collapsed a duplicate.
    /// Old output: the arc through (0, 0), (0, 0), (5, 5) — refused as nearly collinear.
    @Test("X-042: a doubled click is collapsed and the three distinct points measured")
    func duplicateIsCollapsed() throws {
        let geometry = Fixture.polyline([(0, 0), (0, 0), (5, 5), (10, 0)])
        let result = try engine.calculate(tool: .arcLength, geometry: geometry, scale: Fixture.unitScale)
        #expect(Self.rel(try Self.value(result, .arcLength), 5 * Double.pi) <= 1e-14)
        #expect(Self.rel(try Self.value(result, .radius), 5) <= 1e-14)
        #expect(result.warnings.contains { $0.code == .duplicatePointsCollapsed })
        // Exactly three points measure as before: the quarter arc of radius 10, 5π m.
        let quarter = Fixture.polyline([(10, 0), (10 * 0.7071067811865476, 10 * 0.7071067811865476), (0, 10)])
        let measured = try engine.calculate(tool: .arcLength, geometry: quarter, scale: Fixture.unitScale)
        #expect(Self.rel(try Self.value(measured, .arcLength), 5 * Double.pi) <= 1e-12)
        #expect(!measured.warnings.contains { $0.code == .duplicatePointsCollapsed })
    }

    /// The open of an Arc Length saved with four points keeps the three it was measured on, so
    /// its value is the old one (5π m) and is measured again rather than refused.
    @Test("X-042: a stored four-point Arc Length opens as its first three distinct points")
    func storedGeometryKeepsTheMeasuredThree() throws {
        let stored = Fixture.polyline([(0, 0), (5, 5), (10, 0), (15, 5)])
        let opened = ArcLengthCalculator.storedGeometry(stored)
        #expect(opened.points == Fixture.points([(0, 0), (5, 5), (10, 0)]))
        let result = try engine.calculate(tool: .arcLength, geometry: opened, scale: Fixture.unitScale)
        #expect(Self.rel(try Self.value(result, .arcLength), 5 * Double.pi) <= 1e-14)
        // A duplicate inside the first three is skipped, as the calculator collapses it.
        let doubled = ArcLengthCalculator.storedGeometry(Fixture.polyline([(0, 0), (0, 0), (5, 5), (10, 0), (15, 5)]))
        #expect(doubled.points == Fixture.points([(0, 0), (5, 5), (10, 0)]))
        // Nothing else changes: three points, an explicit arc, fewer than three distinct points.
        let three = Fixture.polyline([(0, 0), (5, 5), (10, 0)])
        #expect(ArcLengthCalculator.storedGeometry(three) == three)
        let arc = MeasurementGeometry(pageID: Fixture.pageID, arcs: [ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 1, startAngle: 0, sweepAngle: 1)])
        #expect(ArcLengthCalculator.storedGeometry(arc) == arc)
        let collapsed = Fixture.polyline([(0, 0), (0, 0), (5, 5), (5, 5)])
        #expect(ArcLengthCalculator.storedGeometry(collapsed) == collapsed)
    }

    /// Cycle 2 (X-042 re-check): a doubled click is kept as the three points it is measured on,
    /// so the record draws the arc it measures. Old output: no such rule — the session stored
    /// (0, 0), (0, 0), (5, 5), (10, 0), measured 5π as the arc and drawn as three chords, since
    /// `drawnPointChain` draws an arc only for exactly three stored points.
    @Test("X-042 c2: a point list that collapses to three is kept as those three; four distinct points are not")
    func measuredGeometryCollapsesToTheMeasuredThree() throws {
        let doubled = Fixture.polyline([(0, 0), (0, 0), (5, 5), (10, 0)])
        let kept = ArcLengthCalculator.measuredGeometry(doubled)
        #expect(kept.points == Fixture.points([(0, 0), (5, 5), (10, 0)]))
        // The value is the doubled list's, to the bit: the engine measured these three already.
        let before = try engine.calculate(tool: .arcLength, geometry: doubled, scale: Fixture.unitScale)
        let after = try engine.calculate(tool: .arcLength, geometry: kept, scale: Fixture.unitScale)
        #expect(try Self.value(after, .arcLength) == Self.value(before, .arcLength))
        #expect(MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: Fixture.pageID, kind: .measurement,
            tool: .arcLength, geometry: kept, createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        ).drawnPointChain?.hasArcs == true, "three stored points draw the arc")
        // Four distinct points are not shortened here: `calculate` refuses them on a commit.
        let four = Fixture.polyline([(0, 0), (5, 5), (10, 0), (15, 5)])
        #expect(ArcLengthCalculator.measuredGeometry(four) == four)
        // Exactly three, an explicit arc, and a list that collapses below three are unchanged.
        let three = Fixture.polyline([(0, 0), (5, 5), (10, 0)])
        #expect(ArcLengthCalculator.measuredGeometry(three) == three)
        let short = Fixture.polyline([(0, 0), (0, 0), (5, 5), (5, 5)])
        #expect(ArcLengthCalculator.measuredGeometry(short) == short)
    }

    // MARK: - X-043: a sloped arc is integrated on the curve

    /// The reviewer's case: a 45° arc of r = 100 pt from angle 0, at 1 m/pt, on a plane of slope
    /// s = 1 (100 %) climbing along +x (azimuth 0). The tangent is r·(−sin φ, cos φ), its rise
    /// s·r·sin φ, so the true length is ∫₀^{π/4} 100·√(1 + sin²φ) dφ = 85.2003393121 m (Simpson
    /// here; 85.20033931212983 to 1e-14).
    /// Old output: 85.1998211305 m — the plan length 25π times a 45-chord flattening's
    /// true-to-plan ratio, −6.08e-6 relative.
    @Test("X-043: a sloped arc's true length is the curve's, to 1e-12")
    func slopedArcOnTheCurve() throws {
        let arc = ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 100, startAngle: 0, sweepAngle: Double.pi / 4)
        let parameters = MeasurementParameters(slope: .uniformPlane(.percent(100), azimuth: SlopeAzimuth(degrees: 0)))
        let result = try engine.calculate(
            tool: .length,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, arcs: [arc]),
            scale: Fixture.unitScale,
            parameters: parameters
        )
        let reference = Self.simpson(0, Double.pi / 4) { 100 * (1 + Foundation.sin($0) * Foundation.sin($0)).squareRoot() }
        #expect(Self.rel(reference, 85.2003393121) <= 1e-11)
        let trueLength = try Self.value(result, .trueLength)
        #expect(Self.rel(trueLength, reference) <= 1e-12, "\(trueLength) against \(reference)")
        #expect(Self.rel(trueLength, 85.19982113049517) > 1e-6, "the old flattening ratio's value")
        #expect(Self.rel(try Self.value(result, .planLength), 25 * Double.pi) <= 1e-14)
    }

    /// Under a separate X/Y scale (0.02 m/pt across, 0.01 up): r = 100 pt from 0 over π/3, slope
    /// 50 % with the fall line drawn at 30° on the page. The fall line is the page azimuth mapped
    /// through the scale and renormalised (ADR-0004): u ∝ (0.02·cos 30°, 0.01·sin 30°). The mapped
    /// tangent is v = 100·(−0.02 sin φ, 0.01 cos φ) and its true length √(|v|² + (0.5·v·u)²),
    /// integrated by Simpson here: 1.470921620811465 m.
    @Test("X-043: a sloped arc under a separate X/Y scale is the curve's, to 1e-12")
    func slopedArcSeparateXY() throws {
        let arc = ArcGeometry(center: PDFPoint(x: 40, y: 70), radius: 100, startAngle: 0, sweepAngle: Double.pi / 3)
        let parameters = MeasurementParameters(slope: .uniformPlane(.percent(50), azimuth: SlopeAzimuth(degrees: 30)))
        let result = try engine.calculate(
            tool: .length,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, arcs: [arc]),
            scale: Fixture.separateXY(x: Decimal(string: "0.02")!, y: Decimal(string: "0.01")!),
            parameters: parameters
        )
        let mx = 0.02 * Foundation.cos(Double.pi / 6), my = 0.01 * Foundation.sin(Double.pi / 6)
        let norm = (mx * mx + my * my).squareRoot()
        let ux = mx / norm, uy = my / norm
        let reference = Self.simpson(0, Double.pi / 3) { phi in
            let vx = -2 * Foundation.sin(phi), vy = Foundation.cos(phi)
            let rise = 0.5 * (vx * ux + vy * uy)
            return (vx * vx + vy * vy + rise * rise).squareRoot()
        }
        #expect(Self.rel(reference, 1.470921620811465) <= 1e-11)
        #expect(Self.rel(try Self.value(result, .trueLength), reference) <= 1e-12)
    }

    /// The true perimeter of the ADR-0030 golden slab — 10 × 5, its right side the outward
    /// semicircle about (10, 2.5) of r = 2.5 — at 1 m/pt, slope 100 % with the fall line at 30°:
    /// straight edges √(|d|² + (d·u)²) summed (10 √(1 + cos²30°) twice, 5 √(1 + sin²30°)), the
    /// arc ∫_{−π/2}^{π/2} 2.5·√(1 + (−sin φ cos 30° + cos φ sin 30°)²) dφ by Simpson:
    /// 41.59817752696472 m. (The old ratio rule happened to agree here to 2e-15 — the sweep is
    /// symmetric about the fall line's normal — so this pins the area path, not the old defect.)
    @Test("X-043: a sloped slab's true perimeter reads the arc on the curve")
    func slopedPerimeterOnTheCurve() throws {
        let ring = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let parameters = MeasurementParameters(slope: .uniformPlane(.percent(100), azimuth: SlopeAzimuth(degrees: 30)))
        let result = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: ring)]),
            scale: Fixture.unitScale,
            parameters: parameters
        )
        let c = Foundation.cos(Double.pi / 6), s = Foundation.sin(Double.pi / 6)
        let straight = 2 * 10 * (1 + c * c).squareRoot() + 5 * (1 + s * s).squareRoot()
        let arc = Self.simpson(-Double.pi / 2, Double.pi / 2) { phi in
            let along = -Foundation.sin(phi) * c + Foundation.cos(phi) * s
            return 2.5 * (1 + along * along).squareRoot()
        }
        #expect(Self.rel(straight + arc, 41.59817752696472) <= 1e-11)
        #expect(Self.rel(try Self.value(result, .truePerimeter), straight + arc) <= 1e-12)
    }

    /// A zero slope is the identity: the true length of an arc is its plan length, bit for bit.
    @Test("X-043: under a zero slope the true length is the plan length exactly")
    func zeroSlopeIsTheIdentity() throws {
        let arc = ArcGeometry(center: PDFPoint(x: 3, y: -2), radius: 37.5, startAngle: 0.3, sweepAngle: 2.1)
        let measured = try LinearMeasure.measure(
            GeometryInput.Linear(polyline: [], isClosed: false, segments: [], arcs: [arc]),
            scale: Fixture.separateXY(x: Decimal(string: "0.02")!, y: Decimal(string: "0.01")!)
        )
        let flat = try DirectionalSlope.resolve(
            ratio: 0, areaFactor: 1, azimuth: SlopeAzimuth(degrees: 30),
            scale: Fixture.separateXY(x: Decimal(string: "0.02")!, y: Decimal(string: "0.01")!)
        )
        #expect(measured.trueLength(under: flat) == measured.totalMetres)
    }

    /// BH-565, carried over from the flattening: a finite but absurd sweep must not trap. Plan:
    /// r·|θ| = 1e18 m at 1 m/pt. Sloped (s = 1 along +x): a whole turn of r = 1 is
    /// 4·∫₀^{π/2} √(1 + sin²φ) dφ = 4·√2·E(½) = 7.640395578055 m, so 1e18 rad — its whole turns
    /// plus the rest — is 1e18 · 7.640395578055 / 2π m.
    /// Old output: the flattening clamped to 4096 chords and scaled the exact plan length by
    /// their ratio; before BH-565, `Int(5.7e19)` trapped.
    @Test("BH-565: an arc with an enormous finite sweep is measured, sloped or not, without trapping")
    func enormousSweepDoesNotTrap() throws {
        let huge = ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 1, startAngle: 0, sweepAngle: 1e18)
        let result = try engine.calculate(
            tool: .arcLength,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, arcs: [huge]),
            scale: Fixture.unitScale
        )
        #expect(Fixture.double(try #require(result[.planLength]).value) == 1e18)
        let measured = try LinearMeasure.measure(
            GeometryInput.Linear(polyline: [], isClosed: false, segments: [], arcs: [huge]), scale: Fixture.unitScale
        )
        let slope = try DirectionalSlope.resolve(
            ratio: 1, areaFactor: 2.0.squareRoot(), azimuth: SlopeAzimuth(degrees: 0), scale: Fixture.unitScale
        )
        let turn = 4 * Self.simpson(0, Double.pi / 2) { (1 + Foundation.sin($0) * Foundation.sin($0)).squareRoot() }
        #expect(Self.rel(turn, 7.640395578055) <= 1e-11)
        let sloped = measured.trueLength(under: slope)
        #expect(sloped.isFinite)
        #expect(Self.rel(sloped, 1e18 * turn / (2 * Double.pi)) <= 1e-12, "\(sloped)")
    }

    // MARK: - X-044: an Ellipse Cutout's ring stays in its box

    /// The ring of the box (−3.5, 2)…(36.5, 32): a = 20, b = 15. Its shoelace is πab = 300π, every
    /// vertex lies inside the box, and the four touching points are the box's edge midpoints
    /// exactly. Old output: the 0°, 90°, 180° and 270° vertices at 1.0000253854 × the radius, 2.5e-5
    /// of a radius past the box (x = 36.5005077 on the right).
    @Test("X-044: the ellipse cutout ring is area-preserving and never leaves its box")
    func ringStaysInItsBox() {
        for (corner, opposite) in [
            (PDFPoint(x: -3.5, y: 2), PDFPoint(x: 36.5, y: 32)),
            (PDFPoint(x: 1000.25, y: 700), PDFPoint(x: 900.25, y: 640.5)),
            (PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10))
        ] {
            let ring = EllipseCutoutRing.points(corner: corner, opposite: opposite)
            let minX = Swift.min(corner.x, opposite.x), maxX = Swift.max(corner.x, opposite.x)
            let minY = Swift.min(corner.y, opposite.y), maxY = Swift.max(corner.y, opposite.y)
            let a = (maxX - minX) / 2, b = (maxY - minY) / 2
            #expect(ring.count == 360)
            #expect(Self.rel(Self.shoelace(ring), Double.pi * a * b) <= 1e-12, "\(corner)…\(opposite)")
            #expect(ring.allSatisfy { $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY }, "\(corner)…\(opposite)")
            #expect(ring[0] == PDFPoint(x: maxX, y: (minY + maxY) / 2))
            #expect(ring[90] == PDFPoint(x: (minX + maxX) / 2, y: maxY))
            #expect(ring[180] == PDFPoint(x: minX, y: (minY + maxY) / 2))
            #expect(ring[270] == PDFPoint(x: (minX + maxX) / 2, y: minY))
            // Only the four touching points reach the box.
            #expect(ring.filter { $0.x == minX || $0.x == maxX || $0.y == minY || $0.y == maxY }.count == 4)
        }
    }

    /// The ring as it was built before X-044: 360 radii all scaled by √(π / (180·sin 1°)).
    static func oldRing(corner: PDFPoint, opposite: PDFPoint) -> [PDFPoint] {
        let cx = (corner.x + opposite.x) / 2, cy = (corner.y + opposite.y) / 2
        let step = 2 * Double.pi / 360
        let k = (Double.pi / (180 * Foundation.sin(step))).squareRoot()
        let rx = Swift.abs(opposite.x - corner.x) / 2 * k, ry = Swift.abs(opposite.y - corner.y) / 2 * k
        return (0..<360).map { PDFPoint(x: cx + rx * Foundation.cos(Double($0) * step), y: cy + ry * Foundation.sin(Double($0) * step)) }
    }

    /// A 100 × 60 area with an ellipse cutout whose box (0, 20)…(40, 50) is flush with its left
    /// edge: a = 20, b = 15, so the net is 6000 − 300π = 5057.52220392 m² at 1 m/pt, and the cutout
    /// lies wholly inside. Old output: the old ring stuck out of x = 0 by 5.1e-4 pt, was found
    /// "only 0.99999998 inside its parent", and the parent carried the blocking-style
    /// `cutoutOutsideParent` warning — asserted on the old ring below.
    @Test("X-044: an ellipse cutout flush with its parent's edge raises no cutoutOutsideParent")
    func flushEllipseCutoutIsInside() throws {
        let outer = Fixture.ring([(0, 0), (100, 0), (100, 60), (0, 60)])
        let corner = PDFPoint(x: 0, y: 20), opposite = PDFPoint(x: 40, y: 50)
        let hole = PolygonRing(points: EllipseCutoutRing.points(corner: corner, opposite: opposite), isClosed: true)
        let result = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [hole])]),
            scale: Fixture.unitScale
        )
        #expect(!result.warnings.contains { $0.code == .cutoutOutsideParent }, "\(result.warnings)")
        #expect(Self.rel(try Self.value(result, .netArea), 6000 - 300 * Double.pi) <= 1e-12)

        let old = PolygonRing(points: Self.oldRing(corner: corner, opposite: opposite), isClosed: true)
        let oldResult = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [old])]),
            scale: Fixture.unitScale
        )
        #expect(oldResult.warnings.contains { $0.code == .cutoutOutsideParent }, "the old ring is what warned")
    }

    /// The cutout's box is the whole 100 × 60 area — flush on all four sides: a = 50, b = 30, net
    /// 6000 − 1500π = 1287.61101961 m², no warning. Old output: the warning, the ring stuck out on
    /// all four sides.
    @Test("X-044: an ellipse cutout filling its parent's box raises no cutoutOutsideParent")
    func ellipseCutoutFillingTheBox() throws {
        let outer = Fixture.ring([(0, 0), (100, 0), (100, 60), (0, 60)])
        let hole = PolygonRing(points: EllipseCutoutRing.points(corner: PDFPoint(x: 0, y: 0), opposite: PDFPoint(x: 100, y: 60)), isClosed: true)
        let result = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [hole])]),
            scale: Fixture.unitScale
        )
        #expect(!result.warnings.contains { $0.code == .cutoutOutsideParent }, "\(result.warnings)")
        #expect(Self.rel(try Self.value(result, .netArea), 6000 - 1500 * Double.pi) <= 1e-12)
    }
}
