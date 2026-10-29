import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Bug hunt 2: tabs that are still loading, structure edits, Revision Overlay, snippets and the
/// ledger JSON import.
@MainActor
@Suite(.appTierSerialised)
struct Fix2WorkflowStructureTests {

    // MARK: - Tabs

    @Test("BH-367 / BH-368 / BH-372: a loading tab shows its own opening state, and Close works on it")
    func loadingTabIsItsOwnContent() async throws {
        let harness = try await Fix2Harness.make("BH367.pdf", calibrate: false)
        defer { harness.tearDown() }
        let otherURL = try AppTestSupport.writeFixturePDF(named: "Loading.pdf")
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        // Attached but never loaded: no core, no shell — the state of a drawing still opening.
        let loading = ZenitPDFProjectDocument()
        try loading.read(from: otherURL, ofType: "com.adobe.pdf")
        loading.fileURL = otherURL
        harness.controller.attach(document: loading)
        harness.controller.activateTab(id: loading.documentIdentity)
        // Old: the previous tab's canvas stayed as the window content under the new title.
        #expect(!(harness.controller.contentViewController is ProjectWindowLayoutController),
                "the previous tab's layout is still live under a loading tab")
        #expect(harness.controller.loadingPlaceholder?.nameLabel.stringValue.contains("Loading") == true)
        // ⌘W on the loading tab: old code returned at `guard let shell` and nothing happened.
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZPDFCommandID.closeTab.rawValue
        harness.controller.performZenitCommand(item)
        #expect(await AppTestSupport.wait { loading.isClosed }, "Close did nothing on a loading tab")
    }

    // MARK: - Structure edits

    @Test("BH-384: two whole-set edits in one turn both land")
    func structureEditsAreSerialised() async throws {
        let harness = try await Fix2Harness.make("BH384.pdf")
        defer { harness.tearDown() }
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Floor 1", kind: .floor, parentID: nil, pageID: nil,
            boundary: [], sortOrder: 0, isVisible: true, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1)
        )
        _ = try await harness.core.commands.perform(.setProjectZones([zone]))
        let shell = harness.shell
        shell.projectZones.onRenameZone?(zone.id.rawValue, "Level 1")
        shell.projectZones.onSetZoneVisible?(zone.id.rawValue, false)
        await harness.document.settleStructureEdits()
        let stored = await harness.core.session.projectZoneDefinitions
        // Old: both read the old set; the second write reverted the rename.
        #expect(stored.first?.name == "Level 1")
        #expect(stored.first?.isVisible == false)
    }

    @Test("BH-385 / BH-918: deleting a middle zone moves its children up; a new zone's order never collides")
    func zoneDeletionKeepsTheHierarchy() {
        func zone(_ name: String, parent: ZoneID?, order: Int) -> ProjectZoneDefinition {
            ProjectZoneDefinition(id: ZoneID(UUID()), name: name, kind: .room, parentID: parent,
                                  pageID: nil, boundary: [], sortOrder: order, isVisible: true, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1))
        }
        let building = zone("Building", parent: nil, order: 0)
        let floor = zone("Floor 2", parent: building.id, order: 1)
        let apartment = zone("Apt 201", parent: floor.id, order: 2)
        let after = ZenitPDFProjectDocument.deletingZone(floor.id.rawValue, from: [building, floor, apartment])
        // Old: nil — Apt 201 fell out of Building's roll-up.
        #expect(after.first { $0.id == apartment.id }?.parentID == building.id)
        #expect(ZenitPDFProjectDocument.nextZoneSortOrder([building, apartment]) == 3,
                "the count (2) collides with Apt 201's order")
    }

    @Test("BH-917: a drag reorder keeps a locked region's priority")
    func reorderKeepsLockedPriority() {
        func region(_ priority: Int, locked: Bool) -> ScaleRegionDefinition {
            ScaleRegionDefinition(
                id: ScaleRegionID(UUID()), pageID: PageID(UUID()), name: "R\(priority)",
                boundary: [], scaleID: ScaleID(UUID()), priority: priority, locked: locked,
                isVisible: true, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)
            )
        }
        let locked = region(7, locked: true)
        let free = region(1, locked: false)
        let result = ZenitPDFProjectDocument.reorderedRegions([locked, free], orderedIDs: [free.id.rawValue, locked.id.rawValue])
        // Old: rewritten to `top - index` = 1 — the lock's promise undone on the next refresh.
        #expect(result.first { $0.id == locked.id }?.priority == 7)
        #expect(result.first { $0.id == free.id }?.priority == 2)
    }

    // MARK: - Revision Overlay

    @Test("BH-387: a fit made over one baseline stays right when another sheet becomes the bottom")
    func fitFollowsItsBaseline() {
        let base = UUID(), moved = UUID()
        let fit = RevisionAlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 12, ty: -4)
        let usual = RevisionOverlayEngine.alignments(stackIDs: [base, moved], fit: fit, fitBaselineID: base)
        #expect(usual[0] == .identity && usual[1].tx == 12)
        let swapped = RevisionOverlayEngine.alignments(stackIDs: [moved, base], fit: fit, fitBaselineID: base)
        // Old: the fit applied to the baseline, now on top — misregistered by twice the fit.
        #expect(swapped[0] == .identity)
        #expect(swapped[1].tx == -12 && swapped[1].ty == 4)
    }

    final class FailingProducer: RevisionOverlayProducing {
        func registeredPageCount(among ids: [RevisionSummary.ID]) -> Int { 0 }
        func compose(_ request: RevisionOverlayCompositeRequest) async throws -> RevisionOverlayComposite {
            throw CancellationError()
        }
    }

    @Test("BH-906 / BH-920: a baseline that failed to register keeps its reason on the pane")
    func baselineFailureIsNotOverwritten() {
        let model = ZPDFUIWorkflows.RevisionOverlayModel(revisions: [])
        let compositor = RevisionOverlayCompositing(producer: FailingProducer(), model: model, requestedScale: { 2 })
        model.setCompositeStatus(.failed("The compare service could not open the drawing."))
        compositor.attach(composeNow: false)
        // Old: attach recomposed at once and replaced the reason with "there is 0 revisions".
        #expect(model.compositeStatus == .failed("The compare service could not open the drawing."))
        compositor.detach()
    }

    @Test("BH-386: turning the page moves every revision to the sheet on screen")
    func overlayFollowsThePage() async throws {
        let harness = try await Fix2Harness.make("BH386.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        #expect(await AppTestSupport.wait { harness.document.comparePresenter != nil })
        _ = try await harness.document.registerCurrentDrawingAsBaseline()
        harness.core.document.goToPage(index: 2)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.canvas.viewport.pageIndex == 2 })
        // Old: frozen at the page current when the baseline was registered.
        #expect(harness.document.overlayPages().values.allSatisfy { $0.pageIndex == 2 })
    }

    // MARK: - Snippets

    @Test("BH-389 / BH-390 / BH-922: snippet geometry keeps opacity, dash and text size, and every mark its own id")
    func snippetSceneKeepsStyleAndIdentity() {
        var shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [CanvasStroke(points: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)], closed: false, filled: false)],
            fill: nil,
            counts: (0..<40).map { PDFPointValue(x: Double($0) * 3, y: 10) },
            symbol: MarkupSymbol(builtInGlyph: "triangle", sizePoints: 12, rotationDegrees: 0),
            artwork: nil, stamp: nil,
            bounds: PDFRectValue(x: 0, y: 0, width: 120, height: 20), hidden: false, printable: true,
            caption: nil, kind: .measurement, text: "Demolish", textBox: PDFRectValue(x: 0, y: 30, width: 80, height: 20),
            leaderTarget: nil, lineWidth: 2, opacity: 0.4, fontSize: 24, lineStyle: .dashed, vertices: []
        )
        shape.isTemporary = false
        let out = SnippetSceneBuilder.renderables(from: [shape])
        let line = out.first { if case .polyline = $0.shape { return true }; return false }
        // Old: opacity 1 and solid — the 40 % dashed outline printed as a full solid line.
        #expect(line?.style.opacity == 0.4)
        #expect(line?.style.dash != .solid)
        let text = out.compactMap { markup -> RenderTextLabel? in
            if case let .textLabel(label) = markup.shape { return label }; return nil
        }.first
        #expect(text?.fontSize == 24, "the 24 pt note printed at 11 pt")
        // Old: every mark's first fragment shared one id.
        let ids = out.map(\.id)
        #expect(Set(ids).count == ids.count, "fragment ids collide")
    }

    // MARK: - Ledger JSON import

    @Test("BH-392: a file that repeats a markup row is never an exact match")
    func duplicateRowsAreReported() async throws {
        let harness = try await Fix2Harness.make("BH392.pdf")
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)])
        }, subject: "Wall")
        let ledger = try await ProjectWindowController.interchange(
            core: harness.core, documentName: "Dup", scaleDescription: nil, request: .flat
        )
        var json = try #require(try JSONSerialization.jsonObject(with: ZenitJSONExporter().encode(ledger)) as? [String: Any])
        var rows = try #require(json["rows"] as? [Any])
        let first = try #require(rows.first)
        rows.append(first)
        json["rows"] = rows
        let doctored = try JSONSerialization.data(withJSONObject: json)
        let document = try ZenitJSONImporter().document(from: doctored)
        #expect(ZenitJSONImport.duplicateMarkupIDs(in: document).count == 1)
        let summary = ZenitJSONImport.summary(of: ZenitLedgerReconciliation.compare(imported: document, against: ledger), duplicates: 1)
        // Old: "N row(s), every value identical" over a file that contradicts itself.
        #expect(!summary.contains("every value identical"))
    }

    // MARK: - More workflow regressions

    @Test("BH-369: leaving a canvas mode puts the page back, not only the zoom and scroll")
    func leavingAModeRestoresThePage() async throws {
        let harness = try await Fix2Harness.make("BH369.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        let token = CanvasReturnToken(documentID: harness.document.documentIdentity, viewport: harness.core.canvas.viewport)
        let startPage = harness.core.document.currentPageID
        harness.core.document.goToPage(index: 2)
        #expect(harness.core.document.currentPageID != startPage)
        harness.shell.onLeaveCanvasMode?(.splitCanvas, token)
        // Old: zoom and scroll restored onto page 3 — the page the pane had turned to.
        #expect(harness.core.document.currentPageID == startPage)
    }

    @Test("BH-366: a layered export through a symlinked folder is refused like the direct path")
    func layeredExportRefusesTheSourceByIdentity() async throws {
        let harness = try await Fix2Harness.make("BH366.pdf", calibrate: false)
        defer { harness.tearDown() }
        let source = try #require(harness.document.drawing?.url)
        let link = harness.directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
        let respelled = link.appendingPathComponent(source.lastPathComponent)
        let before = try Data(contentsOf: source)
        // Old: a naive URL `!=` let the write replace the drawing it promised to preserve.
        await #expect(throws: (any Error).self) {
            try await harness.controller.writeLayeredDrawing(for: harness.document, to: respelled)
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test("BH-388: the snippet caption lists every scale in the picture, never one picked")
    func snippetScaleDescriptionListsTheScales() {
        let page = ScaleSummary(id: UUID(), name: "Page", displayString: "1:100", isUniform: true, sx: 1, sy: 1, unit: .metre, version: 1, locked: false)
        let region = ScaleSummary(id: UUID(), name: "Detail", displayString: "1:50", isUniform: true, sx: 1, sy: 1, unit: .metre, version: 1, locked: false)
        #expect(SnippetExport.scaleDescription([region]) == "1:50")
        // Old: the page's ratio under a quantity measured in a 1:50 region.
        #expect(SnippetExport.scaleDescription([page, region]) == "1:100, 1:50")
        #expect(SnippetExport.calibrationDescription([region])?.contains("Detail") == true)
    }

    @Test("BH-923: a workflow sheet goes through the modal door and is never hung on a visible window in a test")
    func workflowSheetsAreRecorded() async throws {
        let harness = try await Fix2Harness.make("BH923.pdf", calibrate: false)
        defer { harness.tearDown() }
        let before = ZenitModalPresenter.recorded.count
        let sheet = try #require(harness.controller.presentToolLibrary(for: harness.document))
        // nl-ux: the Tool Library is a non-modal panel now; it is closed, not ended as a sheet.
        defer { harness.shell.perform(.toolLibrary) }
        _ = sheet
        // Old: parent.beginSheet directly — invisible to the presenter's ledger.
        #expect(ZenitModalPresenter.recorded.count == before + 1)
        #expect(ZenitModalPresenter.lastRecorded?.identifier.hasPrefix("workflow.") == true)
    }
}
