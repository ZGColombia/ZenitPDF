import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-11: ⇧⌥-click adds a traced face to the selected area. Hand-derived at 1 m/pt.
@Suite("Traced union (NL-MEASURE-11)")
struct NLMeasureTracedUnionTests {

    /// Room A [0,10]×[0,8] = 80 m² selected; the next room [10,16]×[0,8] shares the wall at
    /// x = 10: the union is one 16 × 8 = 128 m² ring. A face at [20,24]² is apart: refused.
    @Test("A neighbouring face joins the selected area; one apart is refused")
    func union() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 0)
        let room = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: .area, subject: "Floor", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 8), PDFPoint(x: 0, y: 8)
            ]))]), createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(room))
        let neighbour = [PDFPoint(x: 10, y: 0), PDFPoint(x: 16, y: 0), PDFPoint(x: 16, y: 8), PDFPoint(x: 10, y: 8)]
        let plan = try TracedUnion.plan(adding: neighbour, to: try #require(await session.markup(room.id)))
        #expect(plan.keptGaps == 0)
        #expect(plan.commands.count == 1, "one editVertices: no gap to keep")
        let outcome = try await session.applyBatch(plan.commands)
        #expect(await session.markup(room.id)?.measurement?[.netArea]?.value == 128)
        #expect(await session.orderedMarkups.count == 1, "one markup, grown")
        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(room.id)?.measurement?[.netArea]?.value == 80)

        let apart = [PDFPoint(x: 20, y: 20), PDFPoint(x: 24, y: 20), PDFPoint(x: 24, y: 24), PDFPoint(x: 20, y: 24)]
        #expect(throws: TracedUnion.Refusal.apart) {
            _ = try TracedUnion.plan(adding: apart, to: room)
        }
    }
}
