import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Engine regressions for U-087 (a normalised
/// self-crossing cutout no longer sends every cutout back to the chords), U-091 (an open-flagged
/// ring with arcs reads one ring everywhere) and U-092 (one arc cutting and placing routine).
///
/// Page scale 1 m per point. Every expected number is derived by hand in the comment beside it.
@Suite("Iteration 4 — quantities core, engine")
struct Iter4QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func area(_ outer: PolygonRing, holes: [PolygonRing]) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: outer, holes: holes)])
    }

    /// The golden 10 × 5 with its right side an outward semicircle of radius 2.5 about (10, 2.5).
    static let golden = PolygonRing(points: Fixture.points([(0, 0), (10, 0), (10, 5), (0, 5)]), isClosed: true, bulges: [0, 1, 0, 0])

    // MARK: - U-087

    /// The straight 4 × 3 cutout (9, 1)–(13, 4) across the golden area's arc removes
    /// 6 + 6.25·asin(0.6) (Iter3QuantitiesCoreTests.straightCutoutAcrossAnArc), so the net is
    /// 44 + 3.125π − 6.25·asin(0.6). A bowtie (2, 2), (2.001, 2.001), (2.001, 2), (2, 2.001) — its
    /// diagonals cross at (2.0005, 2.0005) — is normalised to its two lobes, triangles of
    /// ½·0.001·0.0005 each: it removes 5e-7 more, all of it clear of everything else.
    /// Old output: the bowtie made ArcCutoutNet refuse the whole call, so the cutout across the arc
    /// was subtracted as chords, 1.5e-5 pt² too little: net(with bowtie) = net + 1.45e-5, higher
    /// than net(without) — adding a cutout raised the net area (QUALITY_BAR P11).
    @Test("U-087: a tiny self-crossing cutout never raises an arc-edged area's net")
    func bowtieBesideArcCutout() throws {
        let across = Fixture.ring([(9, 1), (13, 1), (13, 4), (9, 4)])
        let bowtie = Fixture.ring([(2, 2), (2.001, 2.001), (2.001, 2), (2, 2.001)])
        let net = 44 + 3.125 * Double.pi - 6.25 * asin(0.6)

        let without = try engine.calculate(tool: .area, geometry: Self.area(Self.golden, holes: [across]), scale: Fixture.unitScale)
        let withBowtie = try engine.calculate(tool: .area, geometry: Self.area(Self.golden, holes: [across, bowtie]), scale: Fixture.unitScale)
        let netWithout = try Self.value(without, .netArea)
        let netWith = try Self.value(withBowtie, .netArea)
        #expect(Self.rel(netWithout, net) <= 1e-12, "net \(netWithout) for \(net)")
        #expect(netWith <= netWithout, "adding a cutout raised the net: \(netWith) > \(netWithout)")
        #expect(Swift.abs(netWith - (net - 5e-7)) <= 1e-12 * net, "net \(netWith) for \(net - 5e-7)")
        // Exact on the arcs: the bowtie is warned about as normalised, the net is not a chord value.
        #expect(!withBowtie.warnings.contains { $0.code == .numericalPrecisionLoss && $0.field == .netArea })
        #expect(withBowtie.warnings.contains { $0.code == .polygonNormalized && $0.field == .cutoutArea })
        // Whichever order the two cutouts are drawn in (P5).
        let reversed = try engine.calculate(tool: .area, geometry: Self.area(Self.golden, holes: [bowtie, across]), scale: Fixture.unitScale)
        #expect(try #require(reversed[.netArea]).value == (try #require(withBowtie[.netArea]).value))
    }

    // MARK: - U-091

    /// The golden ring flagged open. An area is closed, so it measures exactly as the closed ring:
    /// plan 50 + 3.125π, perimeter 10 + 2.5π + 10 + 5 = 25 + 2.5π.
    /// Old output: plan 50 (the exact area added arc segments only for a closed ring) while the
    /// perimeter was 25 + 2.5π — a 16 % disagreement with its own boundary.
    @Test("U-091: an open-flagged ring with an arc measures as the closed ring, plan and perimeter")
    func openFlaggedArcRing() throws {
        let open = PolygonRing(points: Self.golden.points, isClosed: false, bulges: Self.golden.bulges)
        let result = try engine.calculate(tool: .area, geometry: Self.area(open, holes: []), scale: Fixture.unitScale)
        let closed = try engine.calculate(tool: .area, geometry: Self.area(Self.golden, holes: []), scale: Fixture.unitScale)
        let plan = try Self.value(result, .planArea)
        #expect(Self.rel(plan, 50 + 3.125 * Double.pi) <= 1e-12, "plan \(plan); old 50")
        #expect(Self.rel(try Self.value(result, .perimeter), 25 + 2.5 * Double.pi) <= 1e-12)
        #expect(result[.planArea]?.value == closed[.planArea]?.value)
        #expect(result[.netArea]?.value == closed[.netArea]?.value)
        #expect(result.warnings.contains { $0.code == .openPolygonClosedImplicitly })
    }

    /// The arc on the closing edge: the open ring (0, 0), (10, 0), (10, 5), (0, 5) whose last bulge
    /// bends (0, 5) → (0, 0) into a semicircle bulging left (bulge 1 on a counter-clockwise ring
    /// bulges outwards). Closed, it is 50 + 3.125π with perimeter 25 + 2.5π; a 1 × 1 cutout at
    /// (4, 2)–(5, 3) leaves 49 + 3.125π.
    /// Old output: plan 50 (no arc), the boolean's flattening dropped the closing arc (net 49), and
    /// the perimeter kept it (25 + 2.5π).
    @Test("U-091: an arc on an open-flagged ring's closing edge is part of the area")
    func openFlaggedClosingArc() throws {
        let open = PolygonRing(points: Self.golden.points, isClosed: false, bulges: [0, 0, 0, 1])
        let hole = Fixture.ring([(4, 2), (5, 2), (5, 3), (4, 3)])
        let result = try engine.calculate(tool: .area, geometry: Self.area(open, holes: [hole]), scale: Fixture.unitScale)
        #expect(Self.rel(try Self.value(result, .planArea), 50 + 3.125 * Double.pi) <= 1e-12)
        #expect(Self.rel(try Self.value(result, .netArea), 49 + 3.125 * Double.pi) <= 1e-12)
        #expect(Self.rel(try Self.value(result, .perimeter), 25 + 2.5 * Double.pi) <= 1e-12)
    }

    // MARK: - U-092

    /// The shared arrangement answers both callers alike. A 4 × 4 square (3, 3)–(7, 7) whose top
    /// edge is bent into a semicircle of radius 2 above it (bulge 1): as a cutout of the 10 × 10
    /// square it removes 16 + 2π; as the second ring of an exact difference the square keeps
    /// 100 − 16 − 2π; the exact intersection is 16 + 2π; and pieces the two rings share are
    /// classified the same way by both (a cutout equal to its parent leaves exactly 0, a ring
    /// minus itself is empty).
    @Test("U-092: the exact cutout net and the exact boolean agree on one arrangement")
    func oneArrangementForBoth() throws {
        let square = Fixture.ring([(0, 0), (10, 0), (10, 10), (0, 10)])
        let bent = PolygonRing(points: Fixture.points([(3, 3), (7, 3), (7, 7), (3, 7)]), isClosed: true, bulges: [0, 0, 1, 0])
        let removed = 16 + 2 * Double.pi
        let net = try #require(ArcCutoutNet.net(outer: square, holes: [bent]))
        #expect(Self.rel(net.area, 100 - removed) <= 1e-12)
        let outer = try #require(ArcRing(square)), inner = try #require(ArcRing(bent))
        let difference = try ArcRingBoolean.apply(.difference, outer, inner)
        #expect(Self.rel(difference.reduce(0) { $0 + $1.signedArea }, 100 - removed) <= 1e-12)
        let intersection = try ArcRingBoolean.apply(.intersection, outer, inner)
        #expect(Self.rel(intersection.reduce(0) { $0 + $1.signedArea }, removed) <= 1e-12)
        #expect(try #require(ArcCutoutNet.net(outer: bent, holes: [bent])).area == 0)
        #expect(try ArcRingBoolean.apply(.difference, inner, inner).isEmpty)
    }
}
