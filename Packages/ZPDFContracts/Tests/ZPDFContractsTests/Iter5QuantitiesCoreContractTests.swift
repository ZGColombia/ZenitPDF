import Foundation
import Testing
import ZPDFContracts

/// V-084: the one chord step rule for an arc.
/// Every expected value is derived by hand beside it; each test states the old output.
@Suite("V-084 — one chord step rule for an arc (contracts)")
struct Iter5QuantitiesCoreContractTests {

    /// The slab's top edge (1000, 500) → (0, 500) with bulge 0.001: chord c = 1000, sagitta
    /// s = b·c/2 = 0.5 (bulging up, outward of the counter-clockwise ring), radius
    /// r = ((c/2)² + s²)/(2s) = 250 000.25, centre (500, 500.5 − r) = (500, −249 499.75), included
    /// angle θ = 4·atan(0.001).
    static let start = PDFPoint(x: 1000, y: 500)
    static let end = PDFPoint(x: 0, y: 500)
    static let bulge = 0.001
    static let radius = 250_000.25
    static let centre = PDFPoint(x: 500, y: 500.5 - 250_000.25)

    /// The sagitta of the chord p → q on the circle about `centre` of `radius`: r − |centre − mid|.
    static func sagitta(_ p: PDFPoint, _ q: PDFPoint, centre: PDFPoint, radius: Double) -> Double {
        radius - centre.distance(to: PDFPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))
    }

    /// Chords of sagitta ≤ 1e-3: the widest step is 4·asin(√(1e-3 / 2r)) = 1.78885e-4 rad, so
    /// ⌈θ / step⌉ = ⌈0.0039999987 / 1.78885e-4⌉ = ⌈22.36⌉ = 23 chords, each of sagitta
    /// 2r·sin²(θ/92) = 9.45e-4 pt.
    /// Old output: 4 chords (the 1e-3 rad floor: ⌈θ / 1e-3⌉), each of sagitta r·(1 − cos(θ/8)) =
    /// 0.03125 pt — 31 times the tolerance the doc promised.
    @Test("V-084: a gently bent edge is flattened to chords within the tolerance")
    func gentleArcMeetsTheTolerance() throws {
        let arc = try #require(BulgeArc.arc(from: Self.start, to: Self.end, bulge: Self.bulge))
        #expect(Swift.abs(arc.radius - Self.radius) <= 1e-6 && arc.center.distance(to: Self.centre) <= 1e-6, "\(arc)")
        let flat = BulgeArc.flattened(from: Self.start, to: Self.end, bulge: Self.bulge, tolerance: 1e-3)
        #expect(flat.count == 23, "\(flat.count) chords; old 4")
        #expect(flat.last == Self.end)
        let path = [Self.start] + flat
        var largest = 0.0
        for index in 1..<path.count {
            largest = Swift.max(largest, Self.sagitta(path[index - 1], path[index], centre: Self.centre, radius: Self.radius))
        }
        #expect(largest <= 1e-3, "largest chord sagitta \(largest); old 0.03125")
        #expect(Swift.abs(largest - 9.45e-4) <= 1e-6, "\(largest)")
        #expect(BulgeArc.chordSteps(radius: Self.radius, sweep: 4 * atan(Self.bulge), tolerance: 1e-3) == 23)

        // The ring reports the sagitta its flattening reached: the arc's, at most the tolerance.
        let slab = PolygonRing(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1000, y: 0), Self.start, Self.end],
            isClosed: true, bulges: [0, 0, Self.bulge, 0]
        )
        let reached = slab.flatteningSagitta(tolerance: 1e-3)
        #expect(Swift.abs(reached - largest) <= 1e-9 && reached <= 1e-3, "\(reached) vs \(largest)")
        #expect(PolygonRing(points: slab.points).flatteningSagitta(tolerance: 1e-3) == 0, "no arcs, no chord error")
    }

    /// Past the cap the chords are longer than asked, and the sagitta says so: a whole circle of
    /// r = 1e7 pt at 1e-3 needs 4·asin(√(1e-3 / 2e7)) = 2.828e-5 rad steps, 222 144 of them; it
    /// gets 65 536, of sagitta 2r·sin²(2π / (4·65 536)) = 2e7·sin²(π / 131 072) = 1.149e-2 pt.
    @Test("V-084: past the chord cap, the reached sagitta is reported, not the tolerance")
    func capReportsItsSagitta() {
        #expect(BulgeArc.chordSteps(radius: 1e7, sweep: 2 * Double.pi, tolerance: 1e-3) == BulgeArc.maximumChordSteps)
        let reached = BulgeArc.chordSagitta(radius: 1e7, sweep: 2 * Double.pi, tolerance: 1e-3)
        let expected = 2e7 * pow(sin(Double.pi / 131_072), 2)
        #expect(Swift.abs(reached - expected) <= 1e-12 * expected && reached > 1e-3, "\(reached)")
        // A radius smaller than half the tolerance needs no more than the minimum.
        #expect(BulgeArc.chordSteps(radius: 1e-4, sweep: Double.pi, tolerance: 1e-3) == 2)
    }
}
