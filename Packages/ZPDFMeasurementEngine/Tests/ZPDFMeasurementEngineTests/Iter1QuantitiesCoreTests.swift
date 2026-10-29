import Foundation
import Testing
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFMeasurementEngine

/// Regressions for the engine findings.
///
/// Every expected number is derived by hand in the comment beside it, or by an independent exact
/// oracle written here, never read from the code under test (QUALITY_BAR §2.6). Each test states
/// the output the old code produced.
@Suite("Iteration 1 — quantities core, engine")
struct Iter1QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static let tenByTen: [(Double, Double)] = [(0, 0), (10, 0), (10, 10), (0, 10)]
    /// A bowtie whose edges (4,4)→(6,6) and (6,4)→(4,6) cross at (5,5). Its lobes are the
    /// triangles (5,5),(6,6),(6,4) and (5,5),(4,6),(4,4), each ½ · 2 · 1 = 1, so it covers 2.
    /// Its raw shoelace is 0: the lobes wind in opposite directions and cancel.
    static let bowtie: [(Double, Double)] = [(4, 4), (6, 6), (6, 4), (4, 6)]

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    // MARK: - R-166 self-intersecting cutout

    /// Old output: net 100 on the one-hole exact path (the bowtie's shoelace, 0, was removed),
    /// with no warning — and 97 with a second 1 × 1 cutout, because the union filled both lobes.
    /// Now: 100 − 2 = 98 and 100 − 2 − 1 = 97, both warned.
    @Test("R-166: a bowtie cutout removes the 2 it covers, on the one-hole and the multi-hole path")
    func bowtieCutoutRemovesItsLobes() throws {
        let one = try engine.calculate(
            tool: .area, geometry: Fixture.polygon(Self.tenByTen, holes: [Self.bowtie]), scale: Fixture.unitScale
        )
        #expect(abs(try Self.value(one, .netArea) - 98) <= 1e-12 * 98)
        #expect(abs(try Self.value(one, .cutoutArea) - 2) <= 1e-12 * 2)
        #expect(one.warnings.contains { $0.code == .selfIntersectingPolygon && $0.field == .cutoutArea })
        #expect(one.warnings.contains { $0.code == .polygonNormalized && $0.field == .cutoutArea })

        let two = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon(Self.tenByTen, holes: [Self.bowtie, [(1, 1), (2, 1), (2, 2), (1, 2)]]),
            scale: Fixture.unitScale
        )
        #expect(abs(try Self.value(two, .netArea) - 97) <= 1e-12 * 97)
        #expect(two.warnings.contains { $0.code == .selfIntersectingPolygon && $0.field == .cutoutArea })

        // The cutout's own row measures its outer through the same check: 2, as the parent removes.
        let row = try engine.calculate(
            tool: .polygonCutout, geometry: Fixture.polygon(Self.bowtie), scale: Fixture.unitScale
        )
        #expect(abs(try Self.value(row, .cutoutArea) - 2) <= 1e-12 * 2)
    }

    /// Old output: accepted under `.reject` — only the outer ring was ever checked.
    @Test("R-166: under the reject policy a crossing cutout is refused")
    func bowtieCutoutRefusedUnderReject() {
        let strict = MeasurementEngine(options: MeasurementEngineOptions(selfIntersectionPolicy: .reject))
        #expect(throws: MeasurementEngineError.measurement(.selfIntersectingPolygon)) {
            try strict.calculate(
                tool: .area, geometry: Fixture.polygon(Self.tenByTen, holes: [Self.bowtie]), scale: Fixture.unitScale
            )
        }
    }

    /// Old output: a bowtie wholly outside its parent was accepted and removed nothing, because
    /// its shoelace (0) made the containment check skip it; one lobe outside was not flagged.
    /// The bowtie shifted by +10 in x covers (14..16) × (4..6), clear of the 10 × 10 parent.
    @Test("R-166: a crossing cutout outside its parent is refused, a half-outside one is flagged")
    func bowtieCutoutContainment() throws {
        let outside = Self.bowtie.map { ($0.0 + 10, $0.1) }
        #expect(throws: MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: 0))) {
            try engine.calculate(
                tool: .area, geometry: Fixture.polygon(Self.tenByTen, holes: [outside]), scale: Fixture.unitScale
            )
        }
        // Shifted by +5 in x: the lobes sit at x 9..10 (inside) and 10..11 (outside), so one of
        // the two square units lies inside. Net 100 − 1 = 99, flagged as only half inside.
        let straddling = Self.bowtie.map { ($0.0 + 5, $0.1) }
        let result = try engine.calculate(
            tool: .area, geometry: Fixture.polygon(Self.tenByTen, holes: [straddling]), scale: Fixture.unitScale
        )
        #expect(abs(try Self.value(result, .netArea) - 99) <= 1e-9)
        #expect(result.hasWarning(.cutoutOutsideParent))
    }

    // MARK: - R-167 origin-shifted shoelace, exact oracle

    /// Exact twice-signed-area of a ring whose coordinates all sit on the 2⁻³⁹ grid (every Double
    /// in [8192, 16384) does), as a 128-bit integer in units of 2⁻⁷⁸, rounded to Double once.
    /// Written here from integer arithmetic only, so it shares nothing with the code under test.
    static func exactTwiceArea(_ ring: [PDFPoint]) -> Double {
        let grid = 549_755_813_888.0 // 2^39
        func integer(_ value: Double) -> Int64 {
            let scaled = value * grid
            precondition(scaled == scaled.rounded(), "coordinate off the 2^-39 grid")
            return Int64(scaled)
        }
        let x0 = integer(ring[0].x)
        let y0 = integer(ring[0].y)
        var high: Int64 = 0
        var low: UInt64 = 0
        func add(_ product: (high: Int64, low: UInt64), negate: Bool) {
            var h = product.high
            var l = product.low
            if negate {
                // Two's complement of the 128-bit value.
                l = ~l &+ 1
                h = ~h &+ (l == 0 ? 1 : 0)
            }
            let (sum, carry) = low.addingReportingOverflow(l)
            low = sum
            high = high &+ h &+ (carry ? 1 : 0)
        }
        for index in ring.indices {
            let a = ring[index]
            let b = ring[index + 1 == ring.count ? 0 : index + 1]
            let ax = integer(a.x) - x0, ay = integer(a.y) - y0
            let bx = integer(b.x) - x0, by = integer(b.y) - y0
            add(ax.multipliedFullWidth(by: by), negate: false)
            add(bx.multipliedFullWidth(by: ay), negate: true)
        }
        let value = Double(high) * 18_446_744_073_709_551_616.0 + Double(low)
        return value / (grid * grid)
    }

    /// The trapezoid form Clipper2.area used before R-167, kept here only to show the old output.
    static func legacyTrapezoidArea(_ ring: [PDFPoint]) -> Double {
        var sum = 0.0
        var compensation = 0.0
        var previous = ring[ring.count - 1]
        for point in ring {
            let term = (previous.x - point.x) * (previous.y + point.y)
            let adjusted = term - compensation
            let next = sum + adjusted
            compensation = (next - sum) - adjusted
            sum = next
            previous = point
        }
        return sum * 0.5
    }

    /// A rotated rectangle `width × height` about `centre`, counter-clockwise.
    static func rotatedRectangle(centre: PDFPoint, width: Double, height: Double, angle: Double) -> [PDFPoint] {
        let c = Foundation.cos(angle), s = Foundation.sin(angle)
        return [(-width / 2, -height / 2), (width / 2, -height / 2), (width / 2, height / 2), (-width / 2, height / 2)]
            .map { PDFPoint(x: centre.x + $0.0 * c - $0.1 * s, y: centre.y + $0.0 * s + $0.1 * c) }
    }

    /// A 100 × 97 pt slab, rotated, centred between 12 000 and 14 000 pt, with a rotated
    /// 1.13 × 0.97 pt cutout strictly inside. Against the exact oracle the stored cutout area must
    /// hold rel ≤ 1e-12 (M-A2) and the net area rel ≤ 1e-14. Old output: the trapezoid shoelace
    /// took the net area, and the cutout area (plan − net) was off by up to about 4.6e-10
    /// relative on this family; the legacy formula is run below on the same data to show it.
    @Test("R-167: net and cutout areas far from the origin meet the exact oracle")
    func farFromOriginAgainstExactOracle() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var worstCutout = 0.0
        var worstNet = 0.0
        var worstLegacyCutout = 0.0
        for _ in 0..<200 {
            let centre = PDFPoint(x: 12_000 + 2_000 * next(), y: 12_000 + 2_000 * next())
            let outer = Self.rotatedRectangle(centre: centre, width: 100, height: 97, angle: 2 * .pi * next())
            let holeCentre = PDFPoint(x: centre.x + 20 * (next() - 0.5), y: centre.y + 20 * (next() - 0.5))
            let hole = Self.rotatedRectangle(centre: holeCentre, width: 1.13, height: 0.97, angle: 2 * .pi * next())
            var warnings = WarningLog()
            let resolved = try CutoutSolver.resolve(
                PolygonGeometry(outer: PolygonRing(points: outer, isClosed: true), holes: [PolygonRing(points: hole, isClosed: true)]),
                policy: .subtractFromArea,
                options: .default,
                warnings: &warnings
            )
            let exactOuter = abs(Self.exactTwiceArea(outer)) / 2
            let exactHole = abs(Self.exactTwiceArea(hole)) / 2
            let exactNet = exactOuter - exactHole
            worstNet = max(worstNet, abs(resolved.netPDFArea - exactNet) / exactNet)
            worstCutout = max(worstCutout, abs(resolved.cutoutPDFArea - exactHole) / exactHole)

            let legacyNet = abs(Self.legacyTrapezoidArea(outer) + (-abs(Self.legacyTrapezoidArea(hole))))
            worstLegacyCutout = max(worstLegacyCutout, abs((resolved.outerPDFArea - legacyNet) - exactHole) / exactHole)
        }
        #expect(worstNet <= 1e-14, "net area rel error \(worstNet)")
        #expect(worstCutout <= 1e-12, "cutout area rel error \(worstCutout)")
        // The old formula on the same slabs: far outside the quality bar.
        #expect(worstLegacyCutout > 1e-11, "legacy cutout rel error \(worstLegacyCutout)")
    }

    /// One ring, measured by the bridge and by the geometry package, gives the same bits: the
    /// bridge now uses the same origin shift, term order and compensation.
    @Test("R-167: Clipper2.area and PolygonMath.signedArea agree bit for bit")
    func bridgeAndGeometryShoelaceAgree() {
        let ring = Self.rotatedRectangle(centre: PDFPoint(x: 13_579.25, y: 12_345.5), width: 100, height: 97, angle: 0.7)
        let bridge = Clipper2.area(of: ring.map { CGPoint(x: $0.x, y: $0.y) })
        #expect(bridge == PolygonMath.signedArea(ring))
    }

    // MARK: - R-168 flat perpendicular thickness

    /// Old output: `unsupportedField(.trueArea)` — a flat markup has no plane to take a factor
    /// from. Now: sqrt(1 + 0²) = 1, so 100 m² × 0.2 m = 20 m³, equal to the plumb depth.
    @Test("R-168: a perpendicular thickness on a flat markup is plan area × thickness")
    func flatPerpendicularThickness() throws {
        let parameters = MeasurementParameters(
            depth: .length(Decimal(string: "0.2")!),
            volumeDepthReference: .perpendicularThickness
        )
        let result = try engine.calculate(
            tool: .volume, geometry: Fixture.polygon(Self.tenByTen), scale: Fixture.unitScale, parameters: parameters
        )
        #expect(try #require(result[.volume]).value == 20)
        #expect(result[.trueArea] == nil)
    }

    // MARK: - R-169 coordinate bound

    /// Old output: 1 m² for a 1 × 1 square at 1e9 pt — a plausible number from a corrupt file.
    @Test("R-169: coordinates above 1e7 pt are refused with coordinateOutOfRange")
    func hugeCoordinatesRefused() throws {
        let huge = Fixture.polygon([(1e9, 1e9), (1e9 + 1, 1e9), (1e9 + 1, 1e9 + 1), (1e9, 1e9 + 1)])
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .area, geometry: huge, scale: Fixture.unitScale)
        }
        // Every kind of coordinate is bounded: a line vertex, a circle radius, a count point.
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .length, geometry: Fixture.polyline([(0, 0), (2e7, 0)]), scale: Fixture.unitScale)
        }
        let circle = MeasurementGeometry(
            pageID: Fixture.pageID, circles: [CircleGeometry(center: PDFPoint(x: 0, y: 0), radius: 1.5e7)]
        )
        #expect(throws: MeasurementEngineError.measurement(.coordinateOutOfRange)) {
            try engine.calculate(tool: .radius, geometry: circle, scale: Fixture.unitScale)
        }
        // At the bound itself the value is measured: a 1 × 1 square touching x = 1e7 is 1 m².
        let edge = Fixture.polygon([(1e7 - 1, 0), (1e7, 0), (1e7, 1), (1e7 - 1, 1)])
        let result = try engine.calculate(tool: .area, geometry: edge, scale: Fixture.unitScale)
        #expect(try #require(result[.netArea]).value == 1)
    }

    // MARK: - R-171 cutout order

    /// Four overlapping, non-integer cutouts in a non-integer parent: every one of the 24 orders
    /// stores the same Decimal net area, cutout area and net-boundary perimeter (QUALITY_BAR P5,
    /// exact equality), and every order sorts to the same canonical sequence — the sort P5 asks
    /// the test to assert exists. Old code fed the union in drawn order.
    @Test("R-171: the stored net area is identical under every permutation of the cutouts")
    func cutoutPermutationsAreExact() throws {
        let parent: [(Double, Double)] = [(0.31, 0.17), (20.73, 0.29), (20.61, 15.83), (0.43, 15.71)]
        let holes: [[(Double, Double)]] = [
            [(2.13, 2.07), (7.91, 2.21), (7.77, 6.93), (2.29, 6.81)],
            [(5.37, 4.11), (11.03, 4.23), (10.89, 9.97), (5.51, 9.83)],
            [(9.71, 1.93), (14.17, 3.01), (13.09, 8.47), (8.63, 7.39)],
            [(3.3, 8.1), (6.7, 12.9), (1.9, 13.7)]
        ]
        var parameters = MeasurementParameters()
        parameters.perimeterPolicy = .outerPlusCutoutEdges
        var reference: MeasurementResult?
        var referenceOrder: [[PDFPoint]]?
        for permutation in Self.permutations(of: Array(holes.indices)) {
            let ordered = permutation.map { holes[$0] }
            let result = try engine.calculate(
                tool: .area, geometry: Fixture.polygon(parent, holes: ordered), scale: Fixture.unitScale, parameters: parameters
            )
            let rings = ordered.map(Fixture.points)
            let canonical = CutoutSolver.canonicalOrder(of: rings).map { rings[$0] }
            if let reference, let referenceOrder {
                #expect(result[.netArea] == reference[.netArea], "order \(permutation)")
                #expect(result[.cutoutArea] == reference[.cutoutArea], "order \(permutation)")
                #expect(result[.perimeter] == reference[.perimeter], "order \(permutation)")
                #expect(canonical == referenceOrder, "order \(permutation)")
            } else {
                reference = result
                referenceOrder = canonical
            }
        }
    }

    static func permutations(of values: [Int]) -> [[Int]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[Int]] in
            var rest = values
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
    }

    // R-179 (a sloped length flattened each arc twice) is gone with the flattening itself: X-043
    // integrates a sloped arc on the curve, pinned by `Iter7QuantitiesCoreTests`.

    // MARK: - R-181 exact arc perimeter with cutouts

    /// The ADR-0030 golden slab — 10 × 5 with its right short side an outward semicircle of
    /// radius 2.5 — with a 2 × 2 cutout at (2..4, 1..3) strictly inside. Under
    /// outerPlusCutoutEdges the boundary is the drawn outer ring plus the cutout ring:
    /// 25 + 2.5π + 8 = 33 + 2.5π. Old output: the arc counted as the chords of the flattened
    /// boolean, about t / (3r) = 1e-3 / 7.5 = 1.3e-4 short on the 7.85 arc — 1e-3 absolute,
    /// rel ≈ 2.6e-5 on the perimeter.
    @Test("R-181: an arc-edged slab with an interior cutout counts the arc at r·θ")
    func arcPerimeterWithCutoutIsExact() throws {
        let outer = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let hole = Fixture.ring([(2, 1), (4, 1), (4, 3), (2, 3)])
        var parameters = MeasurementParameters()
        parameters.perimeterPolicy = .outerPlusCutoutEdges
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [hole])])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale, parameters: parameters)
        let expected = 33 + 2.5 * Double.pi
        #expect(abs(try Self.value(result, .perimeter) - expected) / expected <= 1e-12)
        #expect(!result.hasWarning(.numericalPrecisionLoss))

        // Two cutouts that do not meet: 33 + 2.5π + 4 (a 1 × 1 at (6..7, 1..2)).
        let second = Fixture.ring([(6, 1), (7, 1), (7, 2), (6, 2)])
        let two = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [hole, second])]),
            scale: Fixture.unitScale,
            parameters: parameters
        )
        #expect(abs(try Self.value(two, .perimeter) - (expected + 4)) / (expected + 4) <= 1e-12)

        // A cutout with an arc edge of its own: the 2 × 2 with its right side an outward
        // semicircle of radius 1 has boundary 2 + 2 + 2 + π, so 25 + 2.5π + 6 + π.
        let arcHole = PolygonRing(points: Fixture.points([(2, 1), (4, 1), (4, 3), (2, 3)]), isClosed: true, bulges: [0, 1, 0, 0])
        let curved = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [arcHole])]),
            scale: Fixture.unitScale,
            parameters: parameters
        )
        let curvedExpected = 31 + 3.5 * Double.pi
        #expect(abs(try Self.value(curved, .perimeter) - curvedExpected) / curvedExpected <= 1e-12)
    }

    /// A cutout that overhangs the arc: the boundary genuinely follows the boolean. Iteration 1
    /// measured the flattened ring there and said the arc part was chords; since C-08 (iteration
    /// 3, ADR-0037) the boundary and the net area are taken on the arc itself, and no chord is
    /// left to warn about.
    ///
    /// The cutout (11, 2)–(13, 3) meets the semicircle of radius 2.5 about (10, 2.5) at
    /// x = 10 + √6 on y = 2 and y = 3. Boundary: the outer 25 + 2.5π less the arc between
    /// y = 2 and 3 (2.5 · 2·asin(0.2)), plus the cutout's left edge (1) and its top and bottom
    /// edges up to the circle (√6 − 1 each): 24 + 2.5π − 5·asin(0.2) + 2√6. Removed:
    /// `∫ (√(6.25 − t²) − 1) dt` over t ∈ [−0.5, 0.5] = 0.5√6 + 6.25·asin(0.2) − 1, so
    /// net = 51 + 3.125π − 0.5√6 − 6.25·asin(0.2).
    /// Old output (iteration 1 and 2): the chords of the flattened boolean under a
    /// numericalPrecisionLoss warning on the perimeter.
    @Test("R-181, C-08: a cutout crossing an arc edge is measured on the arc, boundary and net")
    func cutoutCrossingArcWarns() throws {
        let outer = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])
        let hole = Fixture.ring([(11, 2), (13, 2), (13, 3), (11, 3)])
        var parameters = MeasurementParameters()
        parameters.perimeterPolicy = .outerPlusCutoutEdges
        let result = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: [hole])]),
            scale: Fixture.unitScale,
            parameters: parameters
        )
        #expect(!result.warnings.contains { $0.code == .numericalPrecisionLoss })
        let perimeter = 24 + 2.5 * Double.pi - 5 * asin(0.2) + 2 * 6.0.squareRoot()
        #expect(abs(try Self.value(result, .perimeter) - perimeter) / perimeter <= 1e-12)
        let net = 51 + 3.125 * Double.pi - 0.5 * 6.0.squareRoot() - 6.25 * asin(0.2)
        #expect(abs(try Self.value(result, .netArea) - net) / net <= 1e-12)
    }

    // MARK: - R-182 opening areas

    /// Old output: 30 m² of wall with a −5 m² opening stored a net wall area of 35 m².
    @Test("R-182: a negative or NaN opening area is refused")
    func negativeOpeningRefused() {
        for bad in [Decimal(-5), Decimal.nan] {
            #expect(throws: MeasurementEngineError.measurement(.negativeParameter(.openingAreas))) {
                try engine.calculate(
                    tool: .wallArea, geometry: Fixture.polyline([(0, 0), (10, 0)]), scale: Fixture.unitScale,
                    parameters: MeasurementParameters(height: .length(3), openingAreas: [bad])
                )
            }
        }
    }

    // MARK: - R-183 page-space tolerances

    /// A box 10 × (10 + 4e-6) pt: semi-axes 5 and 5 + 2e-6, so the page-space mismatch 2e-6 pt
    /// is above the 1e-6 pt point tolerance and the shape is not a circle at any scale. Old
    /// output: at 0.01 m/pt the mismatch was 2e-8 m, compared with 1e-6 as if it were points, so
    /// a radius and a diameter appeared; at 1 m/pt they did not.
    @Test("R-183: whether an ellipse is a circle does not depend on the drawing scale")
    func ellipseCircleTestIsScaleFree() throws {
        let geometry = Fixture.polyline([(0, 0), (10, 10.000004)])
        for scale in [Fixture.unitScale, Fixture.uniform(Decimal(string: "0.01")!)] {
            let result = try engine.calculate(tool: .ellipseArea, geometry: geometry, scale: scale)
            #expect(result[.radius] == nil)
            #expect(result[.diameter] == nil)
        }
        // A true page circle is a circle at both scales: r = 5 pt, i.e. 5 m and 0.05 m.
        let round = Fixture.polyline([(0, 0), (10, 10)])
        let unit = try engine.calculate(tool: .ellipseArea, geometry: round, scale: Fixture.unitScale)
        #expect(try #require(unit[.radius]).value == 5)
        let small = try engine.calculate(tool: .ellipseArea, geometry: round, scale: Fixture.uniform(Decimal(string: "0.01")!))
        #expect(abs(try Self.value(small, .radius) - 0.05) <= 1e-15)
    }

    /// A radius of 1e-4 pt: the page disc is π·1e-8 ≈ 3.1e-8 pt², above the 1e-9 pt² floor, so it
    /// is not degenerate at any scale. Old output: at 0.01 m/pt the disc was 3.1e-12 m², compared
    /// with the pt² floor and flagged degenerate; at 1 m/pt it was not.
    @Test("R-183: the degenerate-disc warning does not depend on the drawing scale")
    func degenerateDiscIsScaleFree() throws {
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, circles: [CircleGeometry(center: PDFPoint(x: 1, y: 1), radius: 1e-4)])
        for scale in [Fixture.unitScale, Fixture.uniform(Decimal(string: "0.01")!)] {
            let result = try engine.calculate(tool: .radius, geometry: geometry, scale: scale)
            #expect(!result.hasWarning(.degenerateArea))
            let ellipse = try engine.calculate(tool: .ellipseArea, geometry: geometry, scale: scale)
            #expect(!ellipse.hasWarning(.degenerateArea))
        }
    }

    // MARK: - R-184 angle from deltas

    /// Rays (2⁻¹⁰, 2⁻¹⁰) and (−2⁻¹⁰, 2⁻¹⁰) from a vertex at (12345.5, 13579.25): exactly
    /// perpendicular, and every page delta is exact. Mapped as deltas at s m/pt the rays are
    /// (s·2⁻¹⁰, s·2⁻¹⁰) and (−s·2⁻¹⁰, s·2⁻¹⁰): dot 0 exactly, angle π/2 exactly. Old output:
    /// the absolute points were mapped (s·12345.5 ≈ 435) and subtracted, leaving about
    /// ulp(435) / (s·2⁻¹⁰) ≈ 1.7e-9 relative error in each ray and a dot product that is not 0.
    @Test("R-184: the angle maps page deltas, not absolute points")
    func angleUsesDeltas() throws {
        let step = 1.0 / 1024
        let vertex = PDFPoint(x: 12_345.5, y: 13_579.25)
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, points: [
            PDFPoint(x: vertex.x + step, y: vertex.y + step),
            vertex,
            PDFPoint(x: vertex.x - step, y: vertex.y + step)
        ])
        let scale = Fixture.uniform(Decimal(string: "0.0254")! * 100 / 72)
        let result = try engine.calculate(tool: .angle, geometry: geometry, scale: scale)
        let angle = try Self.value(result, .angle)
        #expect(abs(angle - Double.pi / 2) / (Double.pi / 2) <= 1e-14)
    }
}
