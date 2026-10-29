import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// V-084 through the engine — a cutout across a
/// gently bent edge keeps the exact net area.
///
/// Page scale 1 m per point. Every expected number is derived by hand in the comment beside it.
@Suite("Iteration 5 — quantities core, engine")
struct Iter5QuantitiesCoreTests {

    let engine = MeasurementEngine()

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        Fixture.double(try #require(result[field]).value)
    }

    /// The slab (0, 0)–(1000, 500), counter-clockwise, its top edge (1000, 500) → (0, 500) bent up
    /// by bulge 0.001: sagitta 0.5 pt, r = 250 000.25, θ = 4·atan(0.001). Plan area 500 000 plus the
    /// circular segment r²/2·(θ − sin θ) = r²/2·(θ³/6 − θ⁵/120 + …) ≈ 333.333 pt².
    /// The strip cutout (−10, 490)–(1010, 510) runs past both sides and above the arc's apex
    /// (y = 500.5), so it removes everything above y = 490, arc segment and all: net 1000 × 490 =
    /// 490 000 exactly — what ArcCutoutNet answers.
    /// Old output: net 490 020.83 under "cutouts meeting arc edges subtracted as chords of sagitta
    /// <= 0.001 pt". The edge was flattened to 4 chords of sagitta 0.031 pt (the 1e-3 rad step
    /// floor), a chord band of 20.83 pt² where 23 chords leave 0.63, so the flattened cross-check
    /// sat 20.8 pt² from the exact answer, past its 10.2 pt² slack, and the exact net was thrown
    /// away for the chord value.
    @Test("V-084: a cutout across a gently bent edge keeps the exact net area")
    func stripAcrossGentleArc() throws {
        let slab = PolygonRing(points: Fixture.points([(0, 0), (1000, 0), (1000, 500), (0, 500)]), isClosed: true, bulges: [0, 0, 0.001, 0])
        let strip = Fixture.ring([(-10, 490), (1010, 490), (1010, 510), (-10, 510)])
        let geometry = MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: slab, holes: [strip])])
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)

        let net = try Self.value(result, .netArea)
        #expect(Swift.abs(net - 490_000) <= 1e-12 * 490_000, "net \(net); old 490020.83")
        #expect(!result.warnings.contains { $0.code == .numericalPrecisionLoss && $0.field == .netArea },
                "\(result.warnings.map { ($0.code, $0.field, $0.detail) })")

        let theta = 4 * atan(0.001), r = 250_000.25
        let square = theta * theta
        let segment = r * r / 2 * (theta * square / 6 - theta * square * square / 120 + theta * square * square * square / 5040)
        let plan = try Self.value(result, .planArea)
        #expect(Swift.abs(plan - (500_000 + segment)) <= 1e-9 * plan, "plan \(plan) for \(500_000 + segment)")
    }

    /// Every warning that names the chords' error reads the sagitta the flattening reached. On a
    /// page-sized ring that is the tolerance, so the text is unchanged: the self-crossing slab
    /// below (a bowtie whose right side bulges) is normalised and says "sagitta <= 0.001 pt".
    @Test("V-084: the chord warnings name the sagitta reached, 0.001 pt on a page-sized ring")
    func chordWarningNamesReachedSagitta() throws {
        let bowtie = PolygonRing(points: Fixture.points([(0, 0), (10, 10), (10, 0), (0, 10)]), isClosed: true, bulges: [0, 0.2, 0, 0])
        let result = try engine.calculate(tool: .area, geometry: MeasurementGeometry(pageID: Fixture.pageID, polygons: [PolygonGeometry(outer: bowtie)]),
                                          scale: Fixture.unitScale)
        #expect(result.warnings.contains { $0.code == .numericalPrecisionLoss && $0.field == .planArea
            && $0.detail == "arc edges of a normalised outer ring measured as chords of sagitta <= 0.001 pt" },
                "\(result.warnings.map { ($0.code, $0.field, $0.detail) })")
        #expect(ArealMeasure.chordSagitta(of: PolygonGeometry(outer: bowtie)) == ArealMeasure.arcFlatteningTolerance)
    }
}
