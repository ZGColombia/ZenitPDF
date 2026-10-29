import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MARKUP-02 (canvas context menu) and NL-MARKUP-05 (canvas clipboard) through the shipping
/// window, canvas and command bus (nl-markup). The clipboard is the window's injected scratch
/// one, so no test writes the user's clipboard.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLMarkupFeatureTests {

    private func open(pages: Int = 1) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, PDFCanvasViewController, URL) {
        let url = try AppTestSupport.writeFixturePDF(named: "Markup Menu.pdf", pageCount: pages)
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        controller.markupPasteboard = ScratchMarkupPasteboard()
        let canvas = try #require(controller.canvasController(for: document))
        return (document, controller, canvas, url)
    }

    private func addRectangle(_ core: AppCoreEnvironment) async throws -> MarkupID {
        let page = try #require(core.snapshot.pages.first)
        let id = MarkupID(UUID())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: id,
            documentID: DocumentID(core.snapshot.documentID),
            pageID: PageID(page.id),
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)],
                isClosed: true
            ))]),
            createdAt: now,
            modifiedAt: now
        )))
        await core.refresh()
        return id
    }

    /// The canvas scene the hit test reads, rebuilt after a command.
    private func settle(_ canvas: PDFCanvasViewController) async {
        canvas.refresh()
        await canvas.settleScene()
    }

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    @Test("Right-click on a markup selects it; its Colour submenu recolours it in one named undo step")
    func contextMenuRecolours() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let id = try await addRectangle(core)
        await settle(canvas)

        canvas.selectForContextMenu(at: PDFPointValue(x: 150, y: 150))
        #expect(core.canvas.selectedMarkupIDs == [id.rawValue])
        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 150)))
        for title in ["Cut", "Copy", "Paste", "Duplicate", "Colour", "Fill", "Line Width", "Line Style",
                      "Copy Style", "Paste Style", "Set as Default for Rectangle", "Status", "Delete"] {
            #expect(item(title, in: menu) != nil, "the markup menu has \(title)")
        }
        // A rectangle has no ends to decorate.
        #expect(item("Line End", in: menu) == nil)
        // Cloud is offered: a rectangle draws it.
        #expect(item("Line Style", in: menu)?.submenu?.items.contains { $0.title == "Cloud" } == true)

        let colours = try #require(item("Colour", in: menu)?.submenu)
        let red = try #require(colours.items.first { $0.title == "Red" } as? ContextMenuItem)
        #expect(NSApplication.shared.sendAction(try #require(red.action), to: red.target, from: red))
        #expect(await AppTestSupport.wait {
            core.snapshot.markups.first { $0.id == id.rawValue }.map { $0.colorRGBA.red > 0.7 && $0.colorRGBA.blue < 0.3 } == true
        })
        #expect(document.undoManager?.undoActionName == "Change Colour")
    }

    @Test("Right-click inside a multi-selection keeps it; on empty drawing the canvas menu offers Paste Here")
    func contextMenuSelectionRules() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let first = try await addRectangle(core)
        let second = try await addRectangle(core)
        await settle(canvas)
        core.canvas.select(markupIDs: [first.rawValue, second.rawValue], additive: false)
        canvas.selectForContextMenu(at: PDFPointValue(x: 150, y: 150))
        #expect(core.canvas.selectedMarkupIDs.count == 2)

        canvas.selectForContextMenu(at: PDFPointValue(x: 500, y: 500))
        #expect(core.canvas.selectedMarkupIDs.isEmpty)
        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 500, y: 500)))
        #expect(item("Paste Here", in: menu)?.isEnabled == false, "nothing copied yet")
        #expect(item("Select All on Page", in: menu) != nil)
        // While a markup tool is placing points, the secondary click is consumed first.
        core.markup.activate(kind: .polygon, style: .zenitInk)
        #expect(canvas.handleSecondaryClick())
        core.markup.deactivate()
    }

    @Test("Copy, Paste offsets 10 pt each time; Duplicate adds one; Cut removes; each is one undo step")
    func canvasClipboard() async throws {
        let (document, controller, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let id = try await addRectangle(core)
        core.canvas.select(markupIDs: [id.rawValue], additive: false)

        let payload = try #require(await canvas.copySelectedMarkups())
        #expect(payload.records.count == 1)
        let scratch = try #require(controller.markupPasteboard as? ScratchMarkupPasteboard)
        #expect(scratch.plainText?.contains("Rectangle") == true)

        let first = try #require(await canvas.pasteMarkups(placement: nil))
        let second = try #require(await canvas.pasteMarkups(placement: nil))
        let pastedFirst = try #require(first.pastedIDs.first)
        let a = try #require(await core.session.markup(MarkupID(pastedFirst)))
        let pastedSecond = try #require(second.pastedIDs.first)
        let b = try #require(await core.session.markup(MarkupID(pastedSecond)))
        // (100, 100) → (110, 90) on the first paste, (120, 80) on the second.
        #expect(a.geometry?.polygons.first?.outer.points.first == PDFPoint(x: 110, y: 90))
        #expect(b.geometry?.polygons.first?.outer.points.first == PDFPoint(x: 120, y: 80))
        #expect(document.undoManager?.undoActionName == "Paste Markup")

        let before = await core.session.orderedMarkups.count
        core.canvas.select(markupIDs: [id.rawValue], additive: false)
        _ = await canvas.duplicateSelectedMarkups()
        #expect(await core.session.orderedMarkups.count == before + 1)
        #expect(document.undoManager?.undoActionName == "Duplicate")

        core.canvas.select(markupIDs: [id.rawValue], additive: false)
        _ = await canvas.cutSelectedMarkups()
        #expect(await core.session.markup(id) == nil)
        document.undoManager?.undo()
        #expect(await AppTestSupport.wait { core.snapshot.markups.contains { $0.id == id.rawValue } })

        // The Edit menu's rows validate against the canvas.
        let paste = NSMenuItem(title: "Paste", action: #selector(PDFCanvasViewController.paste(_:)), keyEquivalent: "v")
        #expect(canvas.validateMenuItem(paste))
    }

    @Test("Paste to Selected Pages lands the clipboard on every page chosen in the Navigator, one step")
    func pasteToPages() async throws {
        let (document, _, canvas, url) = try await open(pages: 3)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let id = try await addRectangle(core)
        core.canvas.select(markupIDs: [id.rawValue], additive: false)
        _ = await canvas.copySelectedMarkups()
        let others = Array(core.snapshot.pages.dropFirst().map(\.id))
        core.document.selectPage(id: others[0], mode: .replace)
        core.document.selectPage(id: others[1], mode: .toggle)
        #expect(core.document.selectedPageIDs == others)
        let receipt = try #require(await canvas.pasteMarkupsToSelectedPages())
        #expect(receipt.pastedIDs.count == 2)
        #expect(document.undoManager?.undoActionName == "Paste to 2 Pages")
    }
}
