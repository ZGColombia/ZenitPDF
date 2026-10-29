import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-03: the dry run a recalibration shows before it commits. Hand-derived values.
@Suite("Recalibration impact preview (NL-MEASURE-03)")
struct NLMeasureScaleImpactTests {

    /// Page at 1 m/pt; a 10 × 10 pt area (100 m²) and a 30 pt length (30 m). Recalibrating to
    /// 2 m/pt makes them 400 m² and 60 m: two measurements change, Plan Area 100 → 400 (+300 %),
    /// Plan Length 30 → 60 (+100 %). Nothing is stored by the dry run.
    @Test("A recalibration's impact counts the measurements and shows totals before and after")
    func impactOfDoubling() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 100, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let area = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
        let length = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: .length,
            subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 30, y: 0)]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(area))
        _ = try await session.apply(.addMarkup(length))
        let current = try #require(await session.scale(onPage: page.id))
        let candidate = try ScaleTransform.uniform(
            id: current.id, pageID: page.id, version: current.version + 1,
            metresPerPoint: 2, units: .metric, source: .calibrationTwoPoint
        )
        let impact = await session.scaleChangeImpact(page: page.id, candidate: candidate)
        #expect(impact.changedCount == 2)
        let planArea = try #require(impact.totals.first { $0.field == .netArea })
        #expect(planArea.before == 100)
        #expect(planArea.after == 400)
        #expect(planArea.relativeChange == 3)
        let planLength = try #require(impact.totals.first { $0.field == .planLength })
        #expect(planLength.before == 30)
        #expect(planLength.after == 60)
        #expect(await session.markup(area.id)?.measurement?[.netArea]?.value == 100, "the dry run stored nothing")

        // The same scale changes nothing.
        #expect(await session.scaleChangeImpact(page: page.id, candidate: current).changedCount == 0)
    }
}
