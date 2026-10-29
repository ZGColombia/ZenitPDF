import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// NL-MEASURE-06: insert and delete vertices on a committed markup, each one `editVertices`
/// and one undo, with the quantity recomputed. Expected values are hand-derived at 1 m/pt.
@Suite("Vertex insert and delete on committed markups (NL-MEASURE-06)")
struct NLMeasureTopologyEditingTests {

    static let documentID = DocumentID(UUID())

    static func setUp() async throws -> (TakeoffSession, PageID) {
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        // 1 m per point: 100 pt = 100 m.
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 100, knownLengthUnit: .metre
        )
        return (session, page.id)
    }

    static func record(
        page: PageID, tool: MeasurementTool, geometry: MeasurementGeometry
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: tool,
            subject: "Floor", author: "t", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func square(page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
        ], isClosed: true))])
    }

    /// A 10 × 10 square is 100 m². A vertex inserted on the right edge at (15, 5) adds a
    /// triangle of base 10 and height 5: 100 + 25 = 125 m². Deleting it gives 100 back, and
    /// undoing the insert does too.
    @Test("Insert a vertex on an area edge, then delete it; each is one undoable edit")
    func insertAndDeleteOnArea() async throws {
        let (session, page) = try await Self.setUp()
        let area = Self.record(page: page, tool: .area, geometry: Self.square(page: page))
        _ = try await session.apply(.addMarkup(area))
        #expect(try #require(await session.markup(area.id)?.measurement?[.netArea]).value == 100)

        let stored = try #require(await session.markup(area.id)?.geometry)
        let hit = try #require(MarkupTopologyEditing.nearestEdge(
            to: PDFPoint(x: 10.4, y: 5), in: stored, tool: .area, tolerance: 1
        ))
        #expect(hit.startVertexIndex == 1, "the right edge starts at vertex 1, (10, 0)")
        #expect(hit.projected == PDFPoint(x: 10, y: 5))
        let inserted = try #require(MarkupTopologyEditing.inserting(
            PDFPoint(x: 15, y: 5), afterVertex: hit.startVertexIndex, in: stored, tool: .area
        ))
        let insert = try await session.apply(.editVertices(id: area.id, geometry: inserted))
        let afterInsert = try #require(await session.markup(area.id))
        #expect(afterInsert.geometry?.polygons.first?.outer.points.count == 5)
        #expect(try #require(afterInsert.measurement?[.netArea]).value == 125)
        #expect(afterInsert.id == area.id, "the markup keeps its identity")

        let insertedGeometry = try #require(afterInsert.geometry)
        let removed = try #require(MarkupTopologyEditing.removing(
            vertexAt: 2, in: insertedGeometry, tool: .area
        ))
        _ = try await session.apply(.editVertices(id: area.id, geometry: removed))
        #expect(try #require(await session.markup(area.id)?.measurement?[.netArea]).value == 100)

        // Undo of the insert alone, from the inserted state, is the square again.
        _ = try await session.apply(.editVertices(id: area.id, geometry: inserted))
        _ = try await session.revert(insert.inverse)
        #expect(try #require(await session.markup(area.id)?.measurement?[.netArea]).value == 100)
    }

    /// A polylength (0,0)-(30,0)-(30,40) is 30 + 40 = 70 m. Inserting (15, 20) on the first
    /// edge makes it |(15,20)| + |(15,-20)| + 40 = 25 + 25 + 40 = 90 m. (Continue builds its
    /// geometry from every placed point in the measurement tool since T-022; U-037 removed the
    /// second, unused description of it.)
    @Test("Insert on a polylength")
    func polylengthInsert() async throws {
        let (session, page) = try await Self.setUp()
        let line = Self.record(page: page, tool: .polylength, geometry: MeasurementGeometry(
            pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 30, y: 0), PDFPoint(x: 30, y: 40)]
        ))
        _ = try await session.apply(.addMarkup(line))
        #expect(try #require(await session.markup(line.id)?.measurement?[.planLength]).value == 70)
        let stored = try #require(await session.markup(line.id)?.geometry)
        let inserted = try #require(MarkupTopologyEditing.inserting(
            PDFPoint(x: 15, y: 20), afterVertex: 0, in: stored, tool: .polylength
        ))
        _ = try await session.apply(.editVertices(id: line.id, geometry: inserted))
        #expect(try #require(await session.markup(line.id)?.measurement?[.planLength]).value == 90)
        // No edge after the last vertex (index 3 of four) of an open chain.
        #expect(inserted.points.count == 4)
        #expect(MarkupTopologyEditing.inserting(PDFPoint(x: 1, y: 1), afterVertex: 3, in: inserted, tool: .polylength) == nil)
    }

    @Test("A shape is never edited below its tool's minimum, and fixed-count tools refuse")
    func minimumsAndFixedCounts() async throws {
        let page = PageID(UUID())
        let triangle = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 0, y: 10)
        ], isClosed: true))])
        #expect(MarkupTopologyEditing.removing(vertexAt: 0, in: triangle, tool: .area) == nil)
        let length = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)])
        #expect(MarkupTopologyEditing.removing(vertexAt: 0, in: length, tool: .polylength) == nil)
        #expect(MarkupTopologyEditing.inserting(PDFPoint(x: 5, y: 1), afterVertex: 0, in: length, tool: .length) == nil)
        #expect(MarkupTopologyEditing.nearestEdge(to: PDFPoint(x: 5, y: 0), in: length, tool: .angle, tolerance: 1) == nil)
        let marks = MeasurementGeometry(pageID: page, countPoints: [
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 1, y: 1)),
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 2, y: 2))
        ])
        let fewer = try #require(MarkupTopologyEditing.removing(vertexAt: 1, in: marks, tool: .count))
        #expect(fewer.countPoints.count == 1)
        #expect(MarkupTopologyEditing.removing(vertexAt: 0, in: fewer, tool: .count) == nil)
    }

    /// A 10 × 10 area split by the line x = 4 gives parts of 60 and 40 m² (descending), which
    /// sum to the parent's 100 m² exactly; the parent row is gone, and one revert of the batch
    /// brings it back and removes the parts.
    @Test("Split an area along a line into parts that sum to the parent; one undo reverses it")
    func splitArea() async throws {
        let (session, page) = try await Self.setUp()
        var area = Self.record(page: page, tool: .area, geometry: Self.square(page: page))
        area.label = "Area A"
        _ = try await session.apply(.addMarkup(area))
        let commands = try await session.splitCommands(markup: area.id, along: [PDFPoint(x: 4, y: -5), PDFPoint(x: 4, y: 15)])
        #expect(commands.count == 3)
        let outcome = try await session.applyBatch(commands)
        #expect(await session.markup(area.id) == nil, "the parent row is gone")
        let parts = await session.orderedMarkups.filter { $0.subject == "Floor" }
        #expect(parts.map(\.label) == ["Area A.1", "Area A.2"])
        let areas = parts.compactMap { $0.measurement?[.netArea]?.value }
        #expect(areas == [60, 40])
        #expect(areas.reduce(0, +) == 100)

        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(area.id)?.measurement?[.netArea]?.value == 100)
        #expect(await session.orderedMarkups.count == 1)
    }

    @Test("A split that misses, or an area with cutouts, is refused with a reason")
    func splitRefusals() async throws {
        let (session, page) = try await Self.setUp()
        let area = Self.record(page: page, tool: .area, geometry: Self.square(page: page))
        _ = try await session.apply(.addMarkup(area))
        await #expect(throws: AreaSplitRefusal.lineMissesArea) {
            _ = try await session.splitCommands(markup: area.id, along: [PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 10)])
        }
        var hole = Self.record(page: page, tool: .polygonCutout, geometry: MeasurementGeometry(pageID: page, polygons: [
            PolygonGeometry(outer: PolygonRing(points: [PDFPoint(x: 1, y: 1), PDFPoint(x: 2, y: 1), PDFPoint(x: 2, y: 2), PDFPoint(x: 1, y: 2)], isClosed: true))
        ]))
        hole.kind = .polygon
        _ = try await session.apply(.addCutout(parent: area.id, cutout: hole))
        await #expect(throws: AreaSplitRefusal.hasCutouts) {
            _ = try await session.splitCommands(markup: area.id, along: [PDFPoint(x: 4, y: -5), PDFPoint(x: 4, y: 15)])
        }
    }

    /// Continue on a count keeps the three existing marks — identities included — and adds two;
    /// the edit is one `editVertices` on the same markup. Old behaviour: no way to add to an
    /// existing count; a second count group had to be started.
    @Test("Continue a count: existing marks keep their identity, new marks append, one edit")
    @MainActor
    func continueCount() async throws {
        let (session, page) = try await Self.setUp()
        let environment = try await AppCoreEnvironment.make(session: session, documentID: Self.documentID)
        let marks = (0..<3).map { CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: Double($0) * 10, y: 5)) }
        var count = Self.record(page: page, tool: .count, geometry: MeasurementGeometry(pageID: page, countPoints: marks))
        count.kind = .count
        try await environment.commands.perform(.addMarkup(count))
        await environment.refresh()
        let measurement = environment.measurement
        measurement.setPage(page)
        measurement.onCommitContinuation = { id, geometry in
            Task { @MainActor in try? await environment.commands.perform(.editVertices(id: id, geometry: geometry)) }
        }
        let stored = try #require(await session.markup(count.id))
        #expect(measurement.beginContinuation(of: stored))
        #expect(measurement.placedPoints.count == 3)
        measurement.placePoint(PDFPointValue(x: 100, y: 100))
        measurement.placePoint(PDFPointValue(x: 200, y: 100))
        await measurement.settlePlacements()
        measurement.commitActiveMeasurement()
        #expect(measurement.continuingMarkupID == nil)
        for _ in 0..<50 where await session.markup(count.id)?.geometry?.countPoints.count != 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = try #require(await session.markup(count.id))
        #expect(after.geometry?.countPoints.count == 5)
        #expect(Array(after.geometry?.countPoints.prefix(3).map(\.id) ?? []) == marks.map(\.id))
        #expect(after.measurement?[.count]?.value == 5)
        #expect(await session.orderedMarkups.count == 1, "Continue made no new markup")
    }

    /// Two "Floor" areas [0,10]² and [5,15]×[0,10] (100 m² each, overlapping 50) merge into
    /// the first: 150 m², overlap counted once, the second row gone; one revert restores both.
    @Test("Merge two overlapping same-subject areas into the first; one undo restores both")
    func mergeAreas() async throws {
        let (session, page) = try await Self.setUp()
        let a = Self.record(page: page, tool: .area, geometry: Self.square(page: page))
        let b = Self.record(page: page, tool: .area, geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 5, y: 0), PDFPoint(x: 15, y: 0), PDFPoint(x: 15, y: 10), PDFPoint(x: 5, y: 10)
        ], isClosed: true))]))
        _ = try await session.apply(.addMarkup(a))
        _ = try await session.apply(.addMarkup(b))
        let outcome = try await session.applyBatch(try await session.mergePlan(markups: [a.id, b.id]).commands)
        #expect(await session.markup(b.id) == nil)
        #expect(await session.markup(a.id)?.measurement?[.netArea]?.value == 150)
        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(a.id)?.measurement?[.netArea]?.value == 100)
        #expect(await session.markup(b.id)?.measurement?[.netArea]?.value == 100)

        var apart = Self.record(page: page, tool: .area, geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 50, y: 50), PDFPoint(x: 60, y: 50), PDFPoint(x: 60, y: 60), PDFPoint(x: 50, y: 60)
        ], isClosed: true))]))
        apart.subject = "Floor"
        _ = try await session.apply(.addMarkup(apart))
        await #expect(throws: AreaSplitRefusal.areasApart) {
            _ = try await session.mergePlan(markups: [a.id, apart.id]).commands
        }
        var other = apart
        other.id = MarkupID(UUID())
        other.subject = "Screed"
        _ = try await session.apply(.addMarkup(other))
        await #expect(throws: AreaSplitRefusal.notMergeable) {
            _ = try await session.mergePlan(markups: [a.id, other.id]).commands
        }
    }
}
