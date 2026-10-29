import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// C-08 (ADR-0037): the Polygon Cutout draws and
/// bends arc edges, and its parent loses exactly the curved hole — through the shipping measurement
/// presenter and the session. Page scale 1 m per point, so page numbers are metres; every expected
/// value is hand-derived in the comment beside it.
@MainActor
@Suite("Iteration 3 — arc cutouts through the presenter and the session (C-08)")
struct Iter3QuantitiesCoreArcCutoutTests {

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    private func makePresenter() async throws -> (AppMeasurementToolPresenter, TakeoffSession, PageID) {
        let documentID = DocumentID(UUID(uuidString: "0C080000-0000-4000-8000-000000000001")!)
        let page = PageID(UUID(uuidString: "0C080000-0000-4000-8000-000000000002")!)
        let descriptor = ZPDFContracts.PageDescriptor(id: page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: page)
        return (presenter, session, page)
    }

    private func place(_ presenter: AppMeasurementToolPresenter, _ x: Double, _ y: Double) async {
        presenter.placePoint(PDFPointValue(x: x, y: y))
        await presenter.settlePlacements()
    }

    private func through(_ presenter: AppMeasurementToolPresenter, _ x: Double, _ y: Double) async {
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: x, y: y))
        await presenter.settlePlacements()
    }

    private func number(_ session: TakeoffSession, _ id: MarkupID, _ field: ZPDFContracts.MeasurementField) async -> Double? {
        guard let value = await session.markup(id)?.measurement?[field]?.value else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    /// The 10 × 10 parent area, drawn and committed through the presenter.
    private func drawParent(_ presenter: AppMeasurementToolPresenter, _ session: TakeoffSession) async throws -> MarkupID {
        var committed: MarkupRecord?
        presenter.onCommit = { committed = $0 }
        presenter.activate(kind: .area)
        for (x, y) in [(0.0, 0.0), (10, 0), (10, 10), (0, 10)] { await place(presenter, x, y) }
        presenter.commitActiveMeasurement()
        let parent = try #require(committed)
        _ = try await session.apply(.addMarkup(parent))
        return parent.id
    }

    /// A circle of radius 2 about (cx, cy) drawn as a Polygon Cutout: four vertices on the circle,
    /// each edge an arc through the point at 45° between its ends, the closing edge included.
    private func drawCircleCutout(
        _ presenter: AppMeasurementToolPresenter,
        _ session: TakeoffSession,
        parent: MarkupID,
        cx: Double,
        cy: Double
    ) async throws -> MarkupRecord {
        var committed: (MarkupID, MarkupRecord)?
        presenter.onCommitCutout = { committed = ($0, $1) }
        presenter.activate(kind: .polygonCutout)
        let d = 2.0.squareRoot()
        await place(presenter, cx + 2, cy)
        await through(presenter, cx + d, cy + d)
        await place(presenter, cx, cy + 2)
        await through(presenter, cx - d, cy + d)
        await place(presenter, cx - 2, cy)
        await through(presenter, cx - d, cy - d)
        await place(presenter, cx, cy - 2)
        await through(presenter, cx + d, cy - d)
        presenter.commitActiveCutout(parentMarkupID: parent.rawValue)
        let (owner, cutout) = try #require(committed)
        #expect(owner == parent)
        _ = try await session.apply(.addCutout(parent: parent, cutout: cutout))
        return cutout
    }

    /// Two round openings of radius 2 about (4, 5) and (6, 5) cut from a 10 × 10 slab. Each is
    /// stored as four quarter arcs (bulge tan(π/8)) and reports its own π·2² = 4π. They overlap in
    /// a lens of 2r²·acos(d/2r) − (d/2)·√(4r² − d²) = 8π/3 − 2√3 (d = 2), so the slab loses the
    /// union 16π/3 + 2√3 and keeps 100 − 16π/3 − 2√3 m².
    /// Old output: A did nothing on the Polygon Cutout (the presenter's `armedToolDrawsArcs` left
    /// it out), so each opening was committed as the square of its four vertices (8 m²; the two
    /// overlap in a 2 m² square), net 100 − 14 = 86; and had the arcs been stored, the engine
    /// removed the chords of their 1e-3 pt flattening, 1.1e-2 m² too little.
    @Test("C-08: a Polygon Cutout drawn with arcs; the parent loses exactly the curved union")
    func drawnArcCutoutsAreExact() async throws {
        let (presenter, session, _) = try await makePresenter()
        let parent = try await drawParent(presenter, session)
        let first = try await drawCircleCutout(presenter, session, parent: parent, cx: 4, cy: 5)
        let bulges = try #require(first.geometry?.polygons.first?.outer.validBulges)
        #expect(bulges.count == 4)
        for bulge in bulges { #expect(Swift.abs(bulge - tan(Double.pi / 8)) <= 1e-12) }
        #expect(Self.rel(try #require(await number(session, first.id, .cutoutArea)), 4 * Double.pi) <= 1e-12)

        _ = try await drawCircleCutout(presenter, session, parent: parent, cx: 6, cy: 5)
        let net = 100 - 16 * Double.pi / 3 - 2 * 3.0.squareRoot()
        let stored = try #require(await number(session, parent, .netArea))
        #expect(Self.rel(stored, net) <= 1e-12, "net \(stored) for \(net)")
        let record = try #require(await session.markup(parent))
        #expect(record.measurement?.formulaVersion == ContractVersion.measurementFormulaVersion)
        #expect(!(record.measurement?.warnings.contains { $0.code == .numericalPrecisionLoss } ?? true))
    }

    /// Measure ▸ Curve an Edge on a Polygon Cutout: the 4 × 4 opening (3, 3)–(7, 7) in the 10 × 10
    /// slab, its bottom edge bent through (5, 1). The circle through (3, 3), (5, 1), (7, 3) has its
    /// centre at (5, 3) and radius 2 (each point is 2 from it), so the edge becomes the semicircle
    /// below its chord, adding πr²/2 = 2π. The opening grows to 16 + 2π and the slab keeps 84 − 2π.
    /// Old output: `bending(tool: .polygonCutout)` returned nil — Curve an Edge refused every cutout.
    @Test("C-08: Curve an Edge bends a Polygon Cutout and the parent loses the exact segment")
    func curvedCutoutEdge() async throws {
        let (presenter, session, _) = try await makePresenter()
        let parent = try await drawParent(presenter, session)
        var committed: (MarkupID, MarkupRecord)?
        presenter.onCommitCutout = { committed = ($0, $1) }
        presenter.activate(kind: .polygonCutout)
        for (x, y) in [(3.0, 3.0), (7, 3), (7, 7), (3, 7)] { await place(presenter, x, y) }
        presenter.commitActiveCutout(parentMarkupID: parent.rawValue)
        let (_, cutout) = try #require(committed)
        _ = try await session.apply(.addCutout(parent: parent, cutout: cutout))
        #expect(Self.rel(try #require(await number(session, parent, .netArea)), 84) <= 1e-12)

        let stored = try #require(await session.markup(cutout.id)?.geometry)
        let bent = try #require(MarkupTopologyEditing.bending(edgeAfter: 0, through: PDFPoint(x: 5, y: 1), in: stored, tool: .polygonCutout))
        _ = try await session.apply(.editVertices(id: cutout.id, geometry: bent))
        let segment = 2 * Double.pi
        #expect(Self.rel(try #require(await number(session, cutout.id, .cutoutArea)), 16 + segment) <= 1e-12)
        #expect(Self.rel(try #require(await number(session, parent, .netArea)), 84 - segment) <= 1e-12)
        // An Ellipse Cutout is an ellipse, with no edge to bend.
        #expect(!MarkupTopologyEditing.allowsArcEdges(.ellipseCutout))
    }
}
