import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// The one Scale Region sampler (R-170).
@Suite("Iteration 1 — quantities core, geometry")
struct Iter1QuantitiesCoreGeometryTests {

    private func resolver() throws -> ScaleRegionResolver {
        try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: [
            ScaleRegion(
                id: Fixture.regionID(1),
                pageID: Fixture.pageID(0),
                scaleID: Fixture.scaleID(1),
                boundary: Fixture.rectRing(x: 0, y: 0, width: 400, height: 400)
            )
        ])
    }

    /// A loose arc from (100, 350) to (300, 350) about (200, 300): radius √(100² + 50²) =
    /// 111.80, top of the curve (200, 411.80) — above the region's top edge y = 400 while both
    /// ends are inside. Old output in the running app: `.region` — the committing path sampled a
    /// loose arc at its two ends only (AppCore's copy of the sampler), while the BH-552 test
    /// asserted `.ambiguous` on a copy production never called.
    @Test("R-170: a loose arc bulging out of a region is a crossing on the path the app commits through")
    func looseArcBulgingOut() throws {
        let radius = (100.0 * 100 + 50 * 50).squareRoot()
        let start = Foundation.atan2(50.0, 100.0)
        let arc = ArcGeometry(center: PDFPoint(x: 200, y: 300), radius: radius, startAngle: start, sweepAngle: .pi - 2 * start)
        let geometry = MeasurementGeometry(pageID: Fixture.pageID(0), arcs: [arc])
        let samples = ScaleRegionResolver.samplePoints(of: geometry)
        #expect(samples.contains { $0.y > 400 }, "a sample on the curve above the region")
        let r = try resolver()
        guard case .ambiguous = try r.resolve(geometry: samples) else {
            Issue.record("an arc leaving the region must be ambiguous")
            return
        }
        #expect(try r.resolve(geometry: geometry) == r.resolve(geometry: samples))
    }

    /// An area whose top edge is an arc bulging out of the region, every vertex inside:
    /// (100, 100) → (300, 100) → (300, 350) → arc → (100, 350), the arc a semicircle of radius
    /// 100 over the top edge, reaching y = 450. Old output of `resolve(geometry:)`: `.region` —
    /// the geometry package's copy read a ring's vertices only, never its arc edges.
    @Test("R-170: an area's arc edge is sampled along its curve")
    func areaArcEdgeSampled() throws {
        let ring = PolygonRing(
            points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 350), PDFPoint(x: 100, y: 350)],
            isClosed: true,
            bulges: [0, 0, 1, 0]
        )
        let geometry = MeasurementGeometry(pageID: Fixture.pageID(0), polygons: [PolygonGeometry(outer: ring)])
        guard case .ambiguous = try resolver().resolve(geometry: geometry) else {
            Issue.record("an area whose arc edge leaves the region must be ambiguous")
            return
        }
    }

    /// Every kind of geometry contributes its deciding points: a cutout's vertices (the app's
    /// copy skipped them) and a chain's arc edges.
    @Test("R-170: cutout vertices and chain arc edges are sampled")
    func cutoutsAndChainArcsSampled() {
        let outer = Fixture.rectRing(x: 0, y: 0, width: 10, height: 10)
        let hole = Fixture.rectRing(x: 2, y: 2, width: 1, height: 1)
        let area = MeasurementGeometry(pageID: Fixture.pageID(0), polygons: [PolygonGeometry(outer: outer, holes: [hole])])
        let samples = ScaleRegionResolver.samplePoints(of: area)
        for vertex in hole.points { #expect(samples.contains(vertex)) }

        // A chain (0,0) → (10,0) whose only edge is a semicircle (bulge 1): centre (5, 0),
        // radius 5. Every added sample lies on that circle, and the chords between samples stay
        // within the 0.25 pt tolerance of the curve, so some sample is at least 5 − 0.25 = 4.75
        // off the chord.
        let chain = MeasurementGeometry(
            pageID: Fixture.pageID(0),
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)],
            pointBulges: [1, 0]
        )
        let chainSamples = ScaleRegionResolver.samplePoints(of: chain)
        #expect(chainSamples.count > 2)
        let added = chainSamples.dropFirst(2)
        #expect(added.allSatisfy { abs(Foundation.hypot($0.x - 5, $0.y) - 5) <= 1e-9 })
        #expect(added.contains { abs($0.y) >= 4.75 })
    }
}
