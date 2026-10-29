import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// V-085 — a hidden
/// cutout's hole, which the canvas still draws on the visible parent, stays a snap target, through
/// the shipping session: hiding by the markup's flag, by its layer, undo and a fresh index build.
@Suite("Iteration 5 — a hidden cutout's hole stays snappable (V-085)")
struct Iter5QuantitiesCoreSnapTests {

    static let layout = PageViewLayout(zoom: 1, backingScale: 2)
    static let stamp = Date(timeIntervalSince1970: 1_790_500_000)

    /// One 1 000 × 1 000 pt page (grid snap off), a calibration, a 400 × 300 area (100, 100)–
    /// (500, 400), and an Ellipse Cutout dragged over (200, 200)–(400, 300): centre (300, 250),
    /// semi-axes 100 and 50.
    static func session() async throws -> (TakeoffSession, ZPDFContracts.PageDescriptor, MarkupRecord, MarkupRecord) {
        let documentID = DocumentID(UUID(uuidString: "0B085000-0000-4000-8000-000000000001")!)
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID(uuidString: "0B085000-0000-4000-8000-000000000002")!), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        var settings = SnapSettings.default
        settings.enabledKinds.remove(.grid)
        let session = try TakeoffSession(documentID: documentID, pages: [page], snapSettings: settings)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                        knownLength: 10, knownLengthUnit: .metre)
        let parent = MarkupRecord(
            id: MarkupID(UUID(uuidString: "0B085000-0000-4000-8000-000000000003")!), documentID: documentID, pageID: page.id,
            kind: .measurement, tool: .area, subject: "Slab", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(parent))
        let cutout = MarkupRecord(
            id: MarkupID(UUID(uuidString: "0B085000-0000-4000-8000-000000000004")!), documentID: documentID, pageID: page.id,
            kind: .measurement, tool: .ellipseCutout, subject: "Opening", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 300)]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: cutout))
        return (session, page, parent, cutout)
    }

    /// The curve point at t = π/3, (350, 250 + 25√3), and the pointer 2 pt outside it along the
    /// ellipse's normal.
    static let t = Double.pi / 3
    static let onCurve = PDFPoint(x: 300 + 100 * cos(t), y: 250 + 50 * sin(t))
    static var pointer: PDFPoint {
        let nx = cos(t) / 100, ny = sin(t) / 50, norm = (nx * nx + ny * ny).squareRoot()
        return PDFPoint(x: onCurve.x + 2 * nx / norm, y: onCurve.y + 2 * ny / norm)
    }

    /// Whether the pointer lands on the ellipse as a markupEdge within S2's 1e-9 pt, with no
    /// markupVertex (a facet of the parent's derived ring, U-085) anywhere among the candidates.
    static func snapsOnEllipse(_ session: TakeoffSession, _ page: PageID) async throws -> Bool {
        await session.resetSnapState()
        let resolution = try await session.resolveSnap(pageID: page, pagePoint: pointer, layout: layout)
        let candidates = [resolution.winner].compactMap { $0 } + resolution.alternatives
        guard let winner = candidates.first else { return false }
        return winner.kind == .markupEdge
            && winner.position.distance(to: onCurve) <= 1e-9
            && !candidates.contains { $0.kind == .markupVertex }
    }

    /// Hide the cutout with the index installed: the pointer still lands on the ellipse; undo and
    /// redo follow, and an index built while it is hidden holds the hole too.
    /// Old output: after the hide, no candidate at all — the parent skipped its stored hole
    /// (U-085), the hidden cutout projected nothing, and only the cutout was re-projected — while
    /// the canvas went on stroking the hole on the visible parent.
    @Test("V-085: hiding an Ellipse Cutout keeps its drawn hole snappable; undo, redo and rebuild follow")
    func hiddenCutoutHoleStaysSnappable() async throws {
        let (session, page, _, cutout) = try await Self.session()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.snapsOnEllipse(session, page.id), "the visible cutout")

        let hide = try await session.apply(.setHidden(ids: [cutout.id], hidden: true))
        #expect(await session.markup(cutout.id)?.hidden == true)
        #expect(try await Self.snapsOnEllipse(session, page.id), "the hidden cutout's hole, drawn on the parent")

        let redo = try await session.revert(hide.inverse)
        #expect(try await Self.snapsOnEllipse(session, page.id), "undoing the hide")
        _ = try await session.revert(redo)
        #expect(try await Self.snapsOnEllipse(session, page.id), "redoing the hide")

        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.snapsOnEllipse(session, page.id), "an index built while the cutout is hidden")
    }

    /// The cutout on a Walls layer, and the layer hidden: the same.
    /// Old output: no candidate after the layer was hidden.
    @Test("V-085: a cutout on a hidden layer keeps its drawn hole snappable")
    func cutoutOnHiddenLayerStaysSnappable() async throws {
        let (session, page, _, cutout) = try await Self.session()
        let walls = MarkupLayer(id: LayerID(UUID(uuidString: "0B085000-0000-4000-8000-000000000005")!), name: "Walls", order: -1)
        _ = try await session.apply(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        _ = try await session.apply(.setMarkupLayer(ids: [cutout.id], layerID: walls.id))
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        #expect(try await Self.snapsOnEllipse(session, page.id))

        let hidden = try await session.markupLayerList.updating(walls.id) { $0.visible = false }
        let hide = try await session.apply(.setMarkupLayers(hidden.layers, change: .hide))
        #expect(try await Self.snapsOnEllipse(session, page.id), "the hole of a cutout on a hidden layer")
        _ = try await session.revert(hide.inverse)
        #expect(try await Self.snapsOnEllipse(session, page.id), "undoing the layer hide")
    }
}
