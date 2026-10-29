import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MEASURE-06 through the shipping canvas and window controller: ⌥-click inserts a vertex on
/// the selected area's edge, Delete removes the focused vertex, and Split Area divides the area
/// along two clicks. Each is one undo step.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureGeometryEditingTests {

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let page: PageID
        let area: MarkupID
        let url: URL
    }

    /// An A4 page at 1 m/pt (100 pt = 100 m) with a 100 × 100 pt area at (100, 100): 10 000 m².
    private func makeHarness(_ name: String) async throws -> Harness {
        ZenitModalPresenter.reset()
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil && document.drawing != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let page = try #require(await core.session.firstPageID)
        _ = try await core.commands.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 100, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let area = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: page,
            kind: .measurement, tool: .area, subject: "Floor", label: "Area A", author: "t",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(area))
        await core.refresh()
        let canvas = try #require(controller.canvasController(for: document))
        _ = canvas.view
        shell.perform(.selectTool)
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        return Harness(document: document, controller: controller, core: core, shell: shell, canvas: canvas, page: page, area: area.id, url: url)
    }

    private func tearDown(_ harness: Harness) {
        harness.controller.window?.close()
        harness.document.updateChangeCount(.changeCleared)
        harness.document.close()
        try? FileManager.default.removeItem(at: harness.url.deletingLastPathComponent())
        ZenitModalPresenter.reset()
    }

    /// Polls an actor-side condition, as `AppTestSupport.wait` polls a main-actor one.
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func vertexCount(_ harness: Harness) async -> Int {
        await harness.core.session.markup(harness.area)?.geometry?.polygons.first?.outer.points.count ?? 0
    }

    /// Old output: ⌥-click on an edge in Select mode did nothing but select; Delete removed the
    /// whole markup.
    @Test("⌥-click on an edge inserts a vertex; Delete removes the focused vertex, not the markup")
    func insertAndDelete() async throws {
        let harness = try await makeHarness("Edit Vertices.pdf")
        defer { tearDown(harness) }
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 100.5), additive: false, optionHeld: true)
        #expect(await eventually { await self.vertexCount(harness) == 5 })
        #expect(harness.canvas.focusedVertex?.index == 1)
        await harness.core.refresh()
        await harness.canvas.settleScene()
        harness.canvas.delete(nil)
        #expect(await eventually { await self.vertexCount(harness) == 4 })
        #expect(await harness.core.session.markup(harness.area) != nil, "Delete on a vertex removed the markup")
        #expect(await harness.core.session.markup(harness.area)?.measurement?[.netArea]?.value == 10_000)
    }

    /// Split Area on the 100 × 100 area along x = 140 gives 6 000 + 4 000 m², in one undo step.
    @Test("Split Area divides the selected area along two clicks, and one undo restores it")
    func splitThroughTheMenu() async throws {
        let harness = try await makeHarness("Split Menu.pdf")
        defer { tearDown(harness) }
        harness.controller.beginSplitArea(for: harness.document)
        #expect(harness.canvas.isCalibrating, "the two-click pick is armed")
        harness.controller.finishCalibration(
            points: [PDFPointValue(x: 140, y: 50), PDFPointValue(x: 140, y: 250)],
            for: harness.document
        )
        #expect(await eventually { await harness.core.session.markup(harness.area) == nil })
        let parts = await harness.core.session.orderedMarkups
        #expect(parts.compactMap { $0.measurement?[.netArea]?.value } == [6_000, 4_000])
        harness.canvas.endCalibration()
        await harness.core.commands.undo()
        #expect(await harness.core.session.markup(harness.area)?.measurement?[.netArea]?.value == 10_000)
        #expect(await harness.core.session.orderedMarkups.count == 1)
    }

    /// A polylength (300,300)-(400,300) is 100 m. Continue Measurement re-arms it with both
    /// points preloaded; one more click at (400,400) and Finish make it 200 m — the same markup,
    /// no new row.
    @Test("Continue Measurement extends the selected polylength as one edit of the same markup")
    func continuePolylength() async throws {
        let harness = try await makeHarness("Continue Line.pdf")
        defer { tearDown(harness) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let line = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .polylength, subject: "Wall", label: "Polylength A", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, points: [PDFPoint(x: 300, y: 300), PDFPoint(x: 400, y: 300)]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await harness.core.commands.perform(.addMarkup(line))
        await harness.core.refresh()
        harness.core.canvas.select(markupIDs: [line.id.rawValue], additive: false)
        harness.controller.beginContinueMeasurement(for: harness.document)
        #expect(await eventually { harness.core.measurement.continuingMarkupID == line.id })
        #expect(harness.core.measurement.placedPoints.count == 2)
        harness.core.measurement.appendRawPoints([PDFPointValue(x: 400, y: 400)])
        harness.core.measurement.commitActiveMeasurement()
        #expect(await eventually { await harness.core.session.markup(line.id)?.geometry?.points.count == 3 })
        #expect(await harness.core.session.markup(line.id)?.measurement?[.planLength]?.value == 200)
        #expect(await harness.core.session.orderedMarkups.count == 2, "Continue made no new row")
    }

    /// Area A [100,200]² (10 000 m²) and a "Floor" area [200,300]×[100,200] beside it merge
    /// into Area A: 20 000 m², one row, one undo back.
    @Test("Merge Areas joins adjacent same-subject areas into the first, one undo step")
    func mergeThroughTheMenu() async throws {
        let harness = try await makeHarness("Merge Menu.pdf")
        defer { tearDown(harness) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let neighbour = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Floor", label: "Area B", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 200, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await harness.core.commands.perform(.addMarkup(neighbour))
        await harness.core.refresh()
        harness.core.canvas.select(markupIDs: [harness.area.rawValue, neighbour.id.rawValue], additive: false)
        ZenitAppCommandTable.perform(.mergeAreas, controller: harness.controller, document: harness.document)
        #expect(await eventually { await harness.core.session.markup(neighbour.id) == nil })
        #expect(await harness.core.session.markup(harness.area)?.measurement?[.netArea]?.value == 20_000)
        await harness.core.commands.undo()
        #expect(await harness.core.session.markup(neighbour.id)?.measurement?[.netArea]?.value == 10_000)
    }
}
