import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// ADR-0032 (unit r2-layers): markup layers in the application — the two dialogues (injected),
/// the Navigator rows, the canvas's hidden and locked rules, the context menu's Move to Layer,
/// the ledger filter, and print/export honouring the printable flag and the layer filter. A
/// window that is never shown; every modal answered by injection.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct MarkupLayersAppTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func open() async throws -> (ZenitPDFProjectDocument, ProjectWindowController, PDFCanvasViewController, URL) {
        let url = try AppTestSupport.writeFixturePDF(named: "Markup Layers.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let canvas = try #require(controller.canvasController(for: document))
        return (document, controller, canvas, url)
    }

    /// A 100 × 100 pt rectangle with a subject (so it has a ledger row) at `x`, on the first page.
    private func rectangle(_ core: AppCoreEnvironment, x: Double, layer: LayerID? = nil) throws -> MarkupRecord {
        let page = try #require(core.snapshot.pages.first)
        let pageID = PageID(page.id)
        return MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: pageID, kind: .rectangle,
            subject: "Wall", layerID: layer,
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 100), PDFPoint(x: x + 100, y: 100), PDFPoint(x: x + 100, y: 200), PDFPoint(x: x, y: 200)
            ], isClosed: true))]),
            createdAt: Self.now, modifiedAt: Self.now
        )
    }

    private func add(_ record: MarkupRecord, _ core: AppCoreEnvironment, _ canvas: PDFCanvasViewController) async throws {
        _ = try await core.commands.perform(.addMarkup(record))
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
    }

    private func settle(_ core: AppCoreEnvironment, _ canvas: PDFCanvasViewController) async {
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
    }

    /// Adds a layer named `name` directly (the dialogue has its own test) and returns its id.
    private func addLayer(_ name: String, _ core: AppCoreEnvironment) async throws -> LayerID {
        await MarkupLayerActions.addLayer(named: name, moving: [], core: core)
        return try #require(core.snapshot.markupLayers.first { $0.name == name }?.id)
    }

    @Test("New Layer asks for a name, adds it on top, makes it active and moves the selection onto it — one step")
    func newLayerDialogue() async throws {
        let (document, controller, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let a = try rectangle(core, x: 100)
        try await add(a, core, canvas)
        #expect(shell.markupLayers.isInstalled)
        #expect(shell.markupLayers.rows.map(\.name) == ["Default"])
        #expect(shell.markupLayers.rows.first?.markupCount == 1)

        MarkupLayerActions.typeNameForTesting = "Walls"
        defer { MarkupLayerActions.typeNameForTesting = nil }
        let requests = ZenitModalPresenter.answering({ _ in .button(0) }) {
            shell.markupLayers.newLayer(moving: [a.id.rawValue])
        }
        #expect(requests.map(\.identifier) == [MarkupLayerActions.newLayerIdentifier])
        // The whole step, not its first half: the batch lands the layer (and a refresh can show
        // it in the panel) before `setActiveMarkupLayer` and the closing refresh run. Waiting on
        // the rows alone asserted the active layer in between, which failed under a loaded full
        // suite run (K-15: MarkupLayersAppTests.newLayerDialogue, 3 issues; passes alone).
        #expect(await AppTestSupport.wait {
            guard let walls = core.snapshot.markupLayers.first(where: { $0.name == "Walls" }) else { return false }
            return shell.markupLayers.rows.map(\.name) == ["Walls", "Default"]
                && core.snapshot.activeMarkupLayerID == walls.id
                && shell.markupLayers.activeLayerID == walls.id.rawValue
        })
        let walls = try #require(core.snapshot.markupLayers.first { $0.name == "Walls" })
        #expect(core.snapshot.activeMarkupLayerID == walls.id)
        #expect(shell.markupLayers.activeLayerID == walls.id.rawValue)
        #expect(core.snapshot.markups.first { $0.id == a.id.rawValue }?.layerID == walls.id.rawValue)
        #expect(shell.markupLayers.rows.first?.markupCount == 1)
        #expect(document.undoManager?.undoActionName == "New Layer")

        // A new markup goes onto the active layer.
        let b = try rectangle(core, x: 300)
        try await add(b, core, canvas)
        #expect(core.snapshot.markups.first { $0.id == b.id.rawValue }?.layerID == walls.id.rawValue)

        _ = controller
    }

    @Test("A hidden layer is not drawn or hit; a locked one is drawn but never hit or selected")
    func hiddenAndLockedOnTheCanvas() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let walls = try await addLayer("Walls", core)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        let a = try rectangle(core, x: 100)
        let b = try rectangle(core, x: 300, layer: walls)
        try await add(a, core, canvas)
        try await add(b, core, canvas)
        let insideB = PDFPointValue(x: 350, y: 150)
        #expect(canvas.hitTest(insideB) == b.id.rawValue)

        await MarkupLayerActions.setVisible(false, layer: walls.rawValue, core: core)
        await settle(core, canvas)
        #expect(!canvas.pageViewForTesting.shapes.contains { $0.id == b.id.rawValue }, "a hidden layer is not drawn")
        #expect(canvas.hitTest(insideB) == nil, "nor hit")
        #expect(canvas.pageViewForTesting.shapes.contains { $0.id == a.id.rawValue })

        await MarkupLayerActions.setVisible(true, layer: walls.rawValue, core: core)
        core.canvas.select(markupIDs: [b.id.rawValue], additive: false)
        await MarkupLayerActions.setLocked(true, layer: walls.rawValue, core: core)
        await settle(core, canvas)
        #expect(canvas.pageViewForTesting.shapes.contains { $0.id == b.id.rawValue }, "a locked layer is drawn")
        #expect(canvas.hitTest(insideB) == nil, "and never hit")
        #expect(core.canvas.selectedMarkupIDs.isEmpty, "locking the layer took its markup out of the selection")
        core.canvas.select(markupIDs: [a.id.rawValue, b.id.rawValue], additive: false)
        #expect(core.canvas.selectedMarkupIDs == [a.id.rawValue], "nor selected")
        // The ledger still lists both rows: a layer's lock is not a quantity decision.
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 2 })
    }

    @Test("The context menu's Move to Layer lists the layers and moves the selection in one step")
    func contextMenuMoveToLayer() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let walls = try await addLayer("Walls", core)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        let a = try rectangle(core, x: 100)
        try await add(a, core, canvas)
        core.canvas.select(markupIDs: [a.id.rawValue], additive: false)
        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 150)))
        let move = try #require(menu.items.first { $0.title == "Move to Layer" }?.submenu)
        #expect(move.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Walls", "Default", "New Layer…"])
        #expect(move.items.first { $0.title == "Default" }?.state == .on)
        let target = try #require(move.items.first { $0.title == "Walls" } as? ContextMenuItem)
        #expect(NSApplication.shared.sendAction(try #require(target.action), to: target.target, from: target))
        #expect(await AppTestSupport.wait { core.snapshot.markups.first { $0.id == a.id.rawValue }?.layerID == walls.rawValue })
        #expect(document.undoManager?.undoActionName == "Move to Layer")
    }

    @Test("Delete Layer asks where the markups go and moves them there with the layer's deletion, one step")
    func deleteLayerDialogue() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let walls = try await addLayer("Walls", core)
        let doors = try await addLayer("Doors", core)
        let a = try rectangle(core, x: 100, layer: walls)
        let b = try rectangle(core, x: 300, layer: walls)
        try await add(a, core, canvas)
        try await add(b, core, canvas)

        MarkupLayerActions.chooseDeleteTargetForTesting = doors.rawValue
        defer { MarkupLayerActions.chooseDeleteTargetForTesting = nil }
        let requests = ZenitModalPresenter.answering({ _ in .button(0) }) {
            shell.markupLayers.delete(walls.rawValue)
        }
        #expect(requests.map(\.identifier) == [MarkupLayerActions.deleteLayerIdentifier])
        #expect(requests.first?.detail.contains("2 markups") == true)
        #expect(await AppTestSupport.wait { !core.snapshot.markupLayers.contains { $0.id == walls } })
        #expect(core.snapshot.markups.filter { $0.layerID == doors.rawValue }.count == 2)
        #expect(document.undoManager?.undoActionName == "Delete Layer")
        // The default layer offers no delete at all.
        let none = ZenitModalPresenter.answering({ _ in .button(0) }) {
            shell.markupLayers.delete(MarkupLayer.defaultID.rawValue)
        }
        #expect(none.isEmpty)
    }

    @Test("Show Only This Layer in Ledger narrows the rows; Show All brings them back")
    func ledgerFilter() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let walls = try await addLayer("Walls", core)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        try await add(try rectangle(core, x: 100), core, canvas)
        try await add(try rectangle(core, x: 300, layer: walls), core, canvas)
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 2 })
        shell.markupLayers.toggleLedgerFilter(walls.rawValue)
        #expect(shell.markupLayers.ledgerFilterLayerIDs == [walls.rawValue])
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 1 })
        shell.markupLayers.clearLedgerFilter()
        #expect(shell.markupLayers.ledgerFilterLayerIDs == nil)
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 2 })
    }

    @Test("Print and export leave a layer kept off paper out, and the scope's layer boxes narrow further")
    func outputsHonourLayers() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let walls = try await addLayer("Walls", core)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        let a = try rectangle(core, x: 100)
        let b = try rectangle(core, x: 300, layer: walls)
        try await add(a, core, canvas)
        try await add(b, core, canvas)

        // Everything printable: both on paper (one renderable per outline, at least).
        let both = try await FlattenedDrawingExport.job(for: document)
        let bothCount = both.pages.first?.markups.count ?? 0
        await MarkupLayerActions.setPrintable(false, layer: walls.rawValue, core: core)
        let one = try await FlattenedDrawingExport.job(for: document)
        let oneCount = one.pages.first?.markups.count ?? 0
        #expect(oneCount > 0 && oneCount < bothCount, "Walls kept off paper: \(oneCount) of \(bothCount)")

        // The scope's layer filter: Default only keeps A's renderables and none of B's.
        await MarkupLayerActions.setPrintable(true, layer: walls.rawValue, core: core)
        var job = try await FlattenedDrawingExport.job(for: document)
        let scope = DrawingOutputScope(layerIDs: [MarkupLayer.defaultID.rawValue])
        let sentence = await DrawingOutputScope.narrow(&job, scope: scope, document: document)
        #expect(job.pages.first?.markups.contains { $0.id == b.id } == false)
        #expect(job.pages.first?.markups.contains { $0.id == a.id } == true)
        #expect(sentence == "Only markups on layer Default are included.")

        // The controls offer one box per layer when there are two or more.
        let controls = DrawingScopeControls.make(records: await core.session.orderedMarkups, currentPageID: nil, layers: core.snapshot.markupLayers)
        #expect(controls.layerBoxes.map(\.box.title) == ["Walls", "Default"])
        #expect(controls.scope.layerIDs == nil, "all ticked is every layer")
        controls.layerBoxes[0].box.state = .off
        #expect(controls.scope.layerIDs == [MarkupLayer.defaultID.rawValue])
    }

    @Test("NL-UX-09: the pointer over a ledger row outlines its markup on the canvas; leaving clears it")
    func ledgerHoverOutlinesTheMarkup() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let a = try rectangle(core, x: 100)
        try await add(a, core, canvas)
        let hover = try #require(shell.onLedgerHover, "the window wires the ledger's hover to the canvas")
        hover(a.id.rawValue)
        #expect(canvas.pageViewForTesting.ledgerHoverMarkupID == a.id.rawValue)
        #expect(canvas.pageViewForTesting.ledgerHoverIsDrawnForTesting)
        hover(nil)
        #expect(canvas.pageViewForTesting.ledgerHoverMarkupID == nil)
        #expect(!canvas.pageViewForTesting.ledgerHoverIsDrawnForTesting)
    }
}
