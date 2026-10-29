import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// U-090 — a Scale Region resolves an
/// Ellipse Area or Ellipse Cutout on its ellipse, never at the box corners it is stored as.
@Suite("Iteration 4 — quantities core, geometry")
struct Iter4QuantitiesCoreGeometryTests {

    private func resolver(_ boundary: [(Double, Double)]) throws -> ScaleRegionResolver {
        try ScaleRegionResolver(pageID: Fixture.pageID(0), regions: [
            ScaleRegion(
                id: Fixture.regionID(1),
                pageID: Fixture.pageID(0),
                scaleID: Fixture.scaleID(1),
                boundary: PolygonRing(points: boundary.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true)
            )
        ])
    }

    private func ellipse(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: Fixture.pageID(0), points: [PDFPoint(x: x0, y: y0), PDFPoint(x: x1, y: y1)])
    }

    /// The diamond (100, 0), (200, 100), (100, 200), (0, 100) — edges x ± y = 100 or 300 — holds
    /// the circle of radius 60 about (100, 100) wholly: every edge is |100 + 100 − 300| / √2 =
    /// 70.7 from the centre. Its box (40, 40)–(160, 160) pokes out at both stored corners
    /// (40 + 40 = 80 < 100, 160 + 160 = 320 > 300).
    /// Old output: `.pageDefault` — the sampler read only the two corners, both outside, so an
    /// ellipse lying wholly inside the region measured at the sheet's scale.
    @Test("U-090: an ellipse wholly inside a region whose box corners poke out resolves to the region")
    func ellipseInsideDiamond() throws {
        let r = try resolver([(100, 0), (200, 100), (100, 200), (0, 100)])
        let geometry = ellipse(40, 40, 160, 160)
        for tool in [MeasurementTool.ellipseArea, .ellipseCutout] {
            #expect(try r.resolve(geometry: geometry, tool: tool) == .region(Fixture.regionID(1)))
            let samples = ScaleRegionResolver.samplePoints(of: geometry, tool: tool)
            #expect(!samples.contains(PDFPoint(x: 40, y: 40)) && !samples.contains(PDFPoint(x: 160, y: 160)))
        }
        // The same two points read as a polyline are still the two corners: `.pageDefault`.
        #expect(try r.resolve(geometry: geometry) == .pageDefault)
    }

    /// The square (0, 0)–(200, 200) with a notch x 80…120 above y 150. The ellipse in the box
    /// (20, 20)–(180, 180) — centre (100, 100), semi-axes 80 — has its top quadrant (100, 180) in
    /// the notch, outside the region, while both stored corners are inside.
    /// Old output: `.region` — the markup bulged into the bare sheet and silently took the
    /// region's scale.
    @Test("U-090: an ellipse bulging out through a notch with both corners inside is partly outside")
    func ellipseThroughNotch() throws {
        let r = try resolver([(0, 0), (200, 0), (200, 200), (120, 200), (120, 150), (80, 150), (80, 200), (0, 200)])
        let geometry = ellipse(20, 20, 180, 180)
        let samples = ScaleRegionResolver.samplePoints(of: geometry, tool: .ellipseArea)
        #expect(samples.contains(PDFPoint(x: 100, y: 180)))
        #expect(samples.contains(PDFPoint(x: 100, y: 100)))
        guard case .ambiguous(let ambiguity) = try r.resolve(geometry: geometry, tool: .ellipseArea) else {
            Issue.record("an ellipse leaving the region must be ambiguous")
            return
        }
        #expect(ambiguity.includesPageDefault)
        #expect(ambiguity.reason == .geometryPartlyOutsideAnyRegion)
        #expect(try r.resolve(geometry: geometry) == .region(Fixture.regionID(1)), "the corners alone")
    }

    /// Every sample lies on the ellipse (x − 100)²/80² + (y − 100)²/40² = 1, apart from the centre,
    /// and consecutive curve samples are close enough that no chord strays more than the 0.25 pt
    /// tolerance from the curve: for R = 80 the step is 2·acos(1 − 0.25/80) = 0.1581 rad, so at
    /// least 40 samples on the curve.
    @Test("U-090: ellipse samples lie on the ellipse, densely enough")
    func ellipseSamplesAreOnTheCurve() {
        let samples = ScaleRegionResolver.samplePoints(of: ellipse(20, 60, 180, 140), tool: .ellipseCutout)
        let onCurve = samples.dropFirst()
        #expect(samples.first == PDFPoint(x: 100, y: 100))
        #expect(onCurve.count >= 40 + 4)
        for point in onCurve {
            let value = pow((point.x - 100) / 80, 2) + pow((point.y - 100) / 40, 2)
            #expect(Swift.abs(value - 1) <= 1e-12, "\(point)")
        }
    }
}
