import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Trace regressions (l8-trace), through the shipping window: ⌥-click tracing and Detect Rooms on a
/// heavy A1 roof plan (L-73, L-73b) — the Synthetic Roof Plan of `ZPDFTestingSupport` — and a
/// Project Zone drawn round markups already on the sheet (L-92). The engine's side of L-73 is
/// `RoofPlanSheetTraceTests` in ZPDFSnapEngine; this is the path a person takes.
@MainActor
@Suite(.appTierSerialised)
struct L8TraceAppTests {

    /// The synthetic roof plan in the shared fixture cache, read in place: the document reads a
    /// PDF, it never writes it.
    private static func roofPlanURL() throws -> URL {
        try ZPDFFixtures.shared(.syntheticRoofPlan).url
    }

    private struct Window {
        let document: ZenitPDFProjectDocument
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
    }

    /// The roof plan in a real window controller, calibrated to its printed SKALA 1:50: 72 pt of
    /// paper is 1.27 m of roof.
    private func openRoofPlan() async throws -> Window {
        let url = try Self.roofPlanURL()
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let canvas = try #require(controller.canvasController(for: document))
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 72, y: 0),
            knownLength: 1.27, knownLengthUnit: .metre
        )
        await core.refresh()
        return Window(document: document, controller: controller, canvas: canvas, core: core, shell: shell)
    }

    // MARK: - L-73: ⌥-click on the heavy sheet

    @Test("L-73: ⌥-click inside the east roof facet of the heavy sheet commits its area, 64.40 m², and offers the snow guard")
    func altClickOnTheRoofPlanTracesTheFacet() async throws {
        let window = try await openRoofPlan()
        defer { window.document.close() }

        window.shell.perform(.measureArea)
        window.canvas.handleClick(at: PDFPointValue(x: 1420, y: 960), additive: false, optionHeld: true)
        await window.canvas.settleAutoTrace()

        var records = await window.core.session.orderedMarkups
        for _ in 0..<400 where records.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
            records = await window.core.session.orderedMarkups
        }
        let note = window.core.status.snapshot.activeToolNote ?? ""
        // Old output on the original sheet: no markup, and "Not traced: this sheet holds … vector
        // primitives, more than tracing can walk. Draw the area by hand."
        #expect(records.count == 1, "\(records.count) records; note: \(note)")
        // The facet's ring runs along no bridged gap, so the note claims none. Old output, after
        // the first fix: "Traced. … small gap(s) … were treated as joins." — every join in the
        // window, the sedum hatch next door, quoted for a five-corner facet.
        #expect(note == "Traced.", "\(note)")
        let value = try #require(records.first?.measurement?.values[.planArea]?.value)
        // Hand-derived in RoofPlanSheetTraceTests: 207 000 pt² × (1.27 / 72)² = 207 000 × 1.6129 / 5184
        // = 64.4039931 m². Old output, after the first fix: the facet less its snow guard, deducted
        // without a word.
        #expect(Swift.abs(NSDecimalNumber(decimal: value).doubleValue - 64.403_993_055) < 1e-6, "\(value) m²")
        // The snow guard tied to the eave is offered as a cutout instead (NL-AUTO-10):
        // 3 × 280 = 840 pt² × (1.27 / 72)² = 0.2613 m².
        #expect(await AppTestSupport.wait { window.core.document.warnings.contains { $0.actionTitle == "Deduct as Cutouts" } })
        let offer = try #require(window.core.document.warnings.first { $0.actionTitle == "Deduct as Cutouts" })
        #expect(offer.title == "1 closed outline(s) stand inside the traced area (0.26 m²).", "\(offer.title)")
    }

    // MARK: - L-73b: Detect Rooms on the heavy sheet

    @Test("L-73b: Detect Rooms on This Page proposes the roof plan's rooms, the east facet among them")
    func detectRoomsOnTheRoofPlan() async throws {
        let window = try await openRoofPlan()
        defer { window.document.close() }
        let previous = ProjectWindowController.roomReviewPresenter
        defer { ProjectWindowController.roomReviewPresenter = previous }
        var captured: RoomDetectionReviewModel?
        ProjectWindowController.roomReviewPresenter = { model, _ in
            captured = model
            return {}
        }

        window.controller.detectRooms(for: window.document)
        // A generous ceiling on a debug build: the poll ends as soon as the review is up.
        #expect(await AppTestSupport.wait(upTo: 300) { captured != nil }, "\(window.core.status.snapshot.activeToolNote ?? "")")
        // Old output: no review, and "This sheet is too complex to read all rooms at once. Use
        // ⌥-click to trace them one by one."
        let model = try #require(captured)
        #expect(model.rows.count >= 6, "\(model.rows.map(\.areaText))")
        // The east facet, hand-derived in RoofPlanSheetTraceTests: 64.4040 m² (old output on the
        // original sheet: the facet less its snow guard).
        #expect(model.rows.contains { $0.areaText == "64.40 m²" }, "\(model.rows.map(\.areaText))")
        #expect(model.caveat == nil, "the whole sheet was read")
        model.cancel()
    }

    // MARK: - L-92: a zone drawn round markups already on the sheet

    @Test("L-92: a zone drawn round existing markups files the ones inside it, in one undo step")
    func zoneFilesTheMarkupsInsideIt() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "L8 Zones.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        // Snap off: the clicks below are the points meant, not the drawing's nearest corner.
        var settings = await core.session.currentSnapSettings
        settings.isEnabled = false
        settings.enabledKinds = []
        try await core.session.setSnapSettings(settings)
        await core.refresh()
        document.refreshProjectStructureIfPossible()
        let canvas = PDFCanvasViewController(core: core, rasterSource: document.drawing?.rasterSource, toolbar: shell.toolbar)
        _ = canvas.view
        canvas.onShellCommand = { command in shell.perform(command) }

        func draw(_ kind: MeasurementKind, _ points: [PDFPointValue]) async {
            shell.toolbar.activateMeasurement(kind)
            for point in points { canvas.handleClick(at: point, additive: false) }
            await core.measurement.settlePlacements()
            core.measurement.commitActiveMeasurement()
        }
        // Inside the zone-to-be (100…300 × 100…300): four count marks and a polylength.
        await draw(.count, [
            PDFPointValue(x: 120, y: 120), PDFPointValue(x: 280, y: 120),
            PDFPointValue(x: 280, y: 280), PDFPointValue(x: 120, y: 280)
        ])
        await draw(.polylength, [PDFPointValue(x: 150, y: 150), PDFPointValue(x: 250, y: 150), PDFPointValue(x: 250, y: 250)])
        // Outside it: a length.
        await draw(.length, [PDFPointValue(x: 400, y: 400), PDFPointValue(x: 500, y: 400)])
        var drawn = await core.session.orderedMarkups
        for _ in 0..<200 where !drawn.contains(where: { $0.tool == .length }) {
            try? await Task.sleep(for: .milliseconds(25))
            drawn = await core.session.orderedMarkups
        }
        let inside = Set(drawn.filter { $0.tool == .count || $0.tool == .polylength }.map(\.id))
        let outside = Set(drawn.filter { $0.tool == .length }.map(\.id))
        #expect(!inside.isEmpty && outside.count == 1, "\(drawn.map { ($0.tool, $0.id) })")

        // The zone, drawn on the canvas the way the panel asks for it.
        let panel = shell.projectZones
        panel.beginZone()
        #expect(panel.beginBoundary())
        for point in [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 300, y: 100), PDFPointValue(x: 300, y: 300), PDFPointValue(x: 100, y: 300)] {
            canvas.handleClick(at: point, additive: false)
        }
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait { panel.draft?.hasBoundary == true })
        panel.setDraftName("Zone 1")
        #expect(panel.commitDraft())
        await document.settleStructureEdits()

        // Old output: no markup filed (the set below came back empty), the zone's markup count
        // stayed 0, no status note, and Group by Zone named no zone on any row: ["", "", ""].
        let zoneID = try #require(await core.session.projectZoneDefinitions.first?.id)
        let filed = await core.session.orderedMarkups
        #expect(Set(filed.filter { $0.zoneID == zoneID }.map(\.id)) == inside)
        #expect(filed.filter { outside.contains($0.id) }.allSatisfy { $0.zoneID == nil })
        #expect(await AppTestSupport.wait { panel.zones.first?.markupCount == inside.count })
        #expect(core.status.snapshot.activeToolNote == "Zone “Zone 1” created; \(inside.count) markup(s) inside its boundary were filed into it.")
        let projection = try await core.session.ledgerProjection(LedgerRequest(grouping: [.projectZone]))
        let names = (0..<projection.rowCount).compactMap { projection.row(at: $0)?.displayValue(.projectZone) }
        #expect(names.filter { $0 == "Zone 1" }.count == inside.count, "\(names)")

        // One ⌘Z takes back the zone and the filing together.
        await core.commands.undo()
        await core.refresh()
        #expect(await core.session.projectZoneDefinitions.isEmpty)
        #expect(await core.session.orderedMarkups.allSatisfy { $0.zoneID == nil })
    }
}
