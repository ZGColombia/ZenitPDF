import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// T-072 (snap): a markup
/// on a hidden markup layer is not a snap target — not drawn, not hit-tested (ADR-0032), and now
/// not snapped to — and undoing the hide makes it one again.
@Suite("Iteration 3 — hidden markup layers leave the snap index (T-072)")
struct Iter3QuantitiesCoreSnapLayerTests {

    static let layout = PageViewLayout(zoom: 1, backingScale: 2)

    /// One 1 000 × 1 000 pt page, a Walls layer, and a Length (100, 100) → (300, 100) on it.
    static func session() async throws -> (TakeoffSession, ZPDFContracts.PageDescriptor, MarkupLayer, MarkupRecord) {
        let documentID = DocumentID(UUID(uuidString: "07200000-0000-4000-8000-000000000001")!)
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID(uuidString: "07200000-0000-4000-8000-000000000002")!), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let walls = MarkupLayer(id: LayerID(UUID(uuidString: "07200000-0000-4000-8000-000000000003")!), name: "Walls", order: -1)
        _ = try await session.apply(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        let stamp = Date(timeIntervalSince1970: 0)
        let length = MarkupRecord(
            id: MarkupID(UUID(uuidString: "07200000-0000-4000-8000-000000000004")!), documentID: documentID, pageID: page.id,
            kind: .measurement, tool: .length, subject: "Wall", author: "test", layerID: walls.id,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(length))
        #expect(await session.markup(length.id)?.layerID == walls.id)
        return (session, page, walls, length)
    }

    /// The pointer 1 pt off the Length's first vertex: that vertex, a markupVertex, when the layer
    /// is shown; nothing of the markup when it is hidden.
    static func vertexHit(_ session: TakeoffSession, _ page: PageID) async throws -> Bool {
        let resolution = try await session.resolveSnap(pageID: page, pagePoint: PDFPoint(x: 101, y: 101), layout: layout)
        let candidates = [resolution.winner].compactMap { $0 } + resolution.alternatives
        return candidates.contains { $0.kind == .markupVertex && $0.position == PDFPoint(x: 100, y: 100) }
    }

    /// Hide the layer with the index installed, then undo and redo the hide.
    /// Old output: the vertex stayed a priority-0 target after the hide — the refresh re-upserted
    /// the raw record, whose own `hidden` is false — and a freshly built index held it too.
    @Test("T-072: hiding a layer removes its markups from the snap index; undo and redo follow")
    func hiddenLayerIsNotSnapped() async throws {
        let (session, page, walls, _) = try await Self.session()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.vertexHit(session, page.id))

        let hidden = try await session.markupLayerList.updating(walls.id) { $0.visible = false }
        let hide = try await session.apply(.setMarkupLayers(hidden.layers, change: .hide))
        #expect(try await !Self.vertexHit(session, page.id), "a markup on a hidden layer must not capture the cursor")

        let redo = try await session.revert(hide.inverse)
        #expect(try await Self.vertexHit(session, page.id), "undoing the hide makes it a target again")
        _ = try await session.revert(redo)
        #expect(try await !Self.vertexHit(session, page.id), "redoing the hide takes it out again")

        // An index built while the layer is hidden never holds it.
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await !Self.vertexHit(session, page.id))
    }
}
