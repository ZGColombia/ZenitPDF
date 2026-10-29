import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Iteration-3 app-canvas fixes (iteration-3 findings), against the shipping window
/// and canvas. No window is ordered front and every modal goes through `ZenitModalPresenter`.
@MainActor
@Suite(.appTierSerialised)
struct Iter3AppCanvasTests {

    private static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Helpers

    /// Polls an actor-side condition, as `AppTestSupport.wait` polls a main-actor one.
    private static func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// A 100 × 100 pt square area at (100, 100) on the harness's 100 pt = 1 m page: 1 m².
    /// `MarkupVertexEditing` order: 0 (100,100), 1 (200,100), 2 (200,200), 3 (100,200).
    private static func square(_ page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)
        ], isClosed: true))])
    }

    /// The shipping window with the square area selected and the Select tool armed.
    private static func selectedSquare(_ name: String) async throws -> (Fix2Harness, MarkupID) {
        let harness = try await Fix2Harness.make(name)
        let area = try await harness.addMarkup(tool: .area, geometry: square)
        harness.shell.perform(.selectTool)
        await harness.settle()
        harness.core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        harness.canvas.refresh()
        await harness.canvas.settleScene()
        return (harness, area.id)
    }

    private static func vertexCount(_ harness: Fix2Harness, _ id: MarkupID) async -> Int {
        await harness.core.session.markup(id)?.geometry?.polygons.first?.outer.points.count ?? 0
    }

    /// A plain white page raster, so every sampled pixel sits on paper whatever the backdrop.
    private static func whitePage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    // MARK: - T-001 Delete acts on the vertex the person focused, and on nothing stale

    /// Old output: the drag's `focusedVertex` (area, 2) survived the click on empty paper and the
    /// click on the body, so Delete removed vertex 2 — the area became the triangle (100,100),
    /// (200,100), (100,200) with 3 vertices — and the markup stayed.
    @Test("T-001: after a vertex drag, clicking the body and pressing Delete deletes the markup")
    func deleteAfterADragDeletesTheMarkup() async throws {
        let (harness, area) = try await Self.selectedSquare("Iter3 Focus Drag.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 200))
        #expect(canvas.focusedVertex?.index == 2, "a vertex drag focuses its handle")
        canvas.handleDragMoved(to: PDFPointValue(x: 220, y: 220))
        canvas.handleDragEnded(at: PDFPointValue(x: 220, y: 220))
        #expect(await Self.eventually {
            await harness.core.session.markup(area)?.geometry?.polygons.first?.outer.points[2] == PDFPoint(x: 220, y: 220)
        })
        await harness.settle()
        canvas.handleClick(at: PDFPointValue(x: 450, y: 600), additive: false)   // empty paper
        canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false)   // the area's body
        #expect(harness.core.canvas.selectedMarkupIDs == [area.rawValue])
        #expect(canvas.focusedVertex == nil, "a click on the body lets go of the drag's focus")
        #expect(canvas.pageViewForTesting.focusedVertex == nil)
        canvas.delete(nil)
        let deleted = await Self.eventually { await harness.core.session.markup(area) == nil }
        let vertices = await Self.vertexCount(harness, area)
        #expect(deleted, "Delete edited the geometry instead: \(vertices) vertices")
    }

    /// The selection changing off the canvas (the ledger, Select None) forgets the focus too, so
    /// re-selecting the markup does not bring a stale focus back.
    ///
    /// Old output: the focus slept through the empty selection; with the area selected again,
    /// Delete removed vertex 2 and the markup stayed.
    @Test("T-001: a selection change forgets the focus, so re-selecting the markup and Delete deletes it")
    func selectionChangeForgetsTheFocus() async throws {
        let (harness, area) = try await Self.selectedSquare("Iter3 Focus Selection.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 200))
        canvas.handleDragMoved(to: PDFPointValue(x: 220, y: 220))
        canvas.handleDragEnded(at: PDFPointValue(x: 220, y: 220))
        #expect(canvas.focusedVertex?.index == 2)
        await harness.settle()
        harness.core.canvas.clearSelection()
        // The canvas's own selection observation, as in the product.
        #expect(await AppTestSupport.wait { canvas.focusedVertex == nil }, "the observed selection change kept the focus")
        harness.core.canvas.select(markupIDs: [area.rawValue], additive: false)
        canvas.refresh()
        #expect(canvas.focusedVertex == nil)
        canvas.delete(nil)
        let deleted = await Self.eventually { await harness.core.session.markup(area) == nil }
        let vertices = await Self.vertexCount(harness, area)
        #expect(deleted, "Delete edited the geometry instead: \(vertices) vertices")
    }

    /// A press and release on vertex 1 (200, 100) with no movement, through the page view's own
    /// mouse handling, then Delete. The square (1 m²) loses vertex 1 and becomes the triangle
    /// (100,100), (200,200), (100,200): legs 1 m and 1 m, ½ · 1 · 1 = 0.5 m².
    ///
    /// Old output: the click went to `handleClick`, which never looked at handles, so nothing was
    /// focused and Delete removed the whole markup.
    @Test("T-001: click a handle (no drag), then Delete removes that vertex and keeps the markup")
    func clickAHandleThenDelete() async throws {
        let (harness, area) = try await Self.selectedSquare("Iter3 Focus Click.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        let transform = try #require(pageView.transform)
        let local = transform.viewPoint(from: PDFPointValue(x: 200, y: 100))
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local))
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: local))
        #expect(canvas.focusedVertex?.markupID == area.rawValue)
        #expect(canvas.focusedVertex?.index == 1)
        #expect(pageView.focusedVertex == CanvasPageView.FocusedVertex(markupID: area.rawValue, index: 1),
                "the focus is drawn")
        #expect(harness.core.canvas.selectedMarkupIDs == [area.rawValue])
        canvas.delete(nil)
        #expect(await Self.eventually { await Self.vertexCount(harness, area) == 3 })
        let record = try #require(await harness.core.session.markup(area), "Delete on a vertex removed the markup")
        let net = try #require(record.measurement?[.netArea]?.value)
        #expect(Swift.abs(NSDecimalNumber(decimal: net).doubleValue - 0.5) < 1e-9, "\(net) m²")
        #expect(canvas.focusedVertex == nil)
    }

    /// Old output: Escape and a tool switch kept the focus; the context menu's Delete removed
    /// vertex 1 instead of the markup.
    @Test("T-001: Escape and a tool change let go of the focus; the context menu's Delete deletes the markup")
    func escapeToolChangeAndContextMenuDelete() async throws {
        let (harness, area) = try await Self.selectedSquare("Iter3 Focus Menu.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let handle = PDFPointValue(x: 200, y: 100)

        canvas.handleClick(at: handle, additive: false)
        #expect(canvas.focusedVertex?.index == 1)
        _ = canvas.handle(key: .escape)
        #expect(canvas.focusedVertex == nil, "Escape kept the focus")

        canvas.handleClick(at: handle, additive: false)
        #expect(canvas.focusedVertex?.index == 1)
        harness.shell.perform(.measureArea)
        canvas.refresh()
        #expect(canvas.focusedVertex == nil, "a tool change kept the focus")
        harness.shell.perform(.selectTool)
        canvas.refresh()
        harness.core.canvas.select(markupIDs: [area.rawValue], additive: false)
        canvas.refresh()

        canvas.handleClick(at: handle, additive: false)
        #expect(canvas.focusedVertex?.index == 1)
        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 150)))
        let delete = try #require(menu.items.first { $0.title == "Delete" } as? ContextMenuItem)
        #expect(NSApplication.shared.sendAction(try #require(delete.action), to: delete.target, from: delete))
        let deleted = await Self.eventually { await harness.core.session.markup(area) == nil }
        let vertices = await Self.vertexCount(harness, area)
        #expect(deleted, "the menu's Delete edited the geometry instead: \(vertices) vertices")
    }

    /// The focused handle is filled with the selection ink; every other handle stays paper-filled.
    ///
    /// Old output: nothing drew the focus — every handle was paper-filled, so Delete acted on a
    /// vertex the screen did not single out.
    @Test("T-001: the focused handle is drawn filled, the others paper")
    func focusedHandleIsDrawnFilled() throws {
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 200, height: 100), rotation: 0, zoom: 1,
            origin: CGPoint(x: 20, y: 10)
        )
        let id = UUID()
        let ring = [
            PDFPointValue(x: 40, y: 20), PDFPointValue(x: 160, y: 20),
            PDFPointValue(x: 160, y: 80), PDFPointValue(x: 40, y: 80)
        ]
        var shape = CanvasMarkupShape(
            id: id, pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            strokes: [CanvasStroke(points: ring, closed: true, filled: false)],
            counts: [], bounds: PDFRectValue(x: 40, y: 20, width: 120, height: 60), hidden: false
        )
        shape.vertices = ring
        view.shapes = [shape]
        view.selection = [id]
        view.focusedVertex = CanvasPageView.FocusedVertex(markupID: id, index: 1)
        let size = CGSize(width: 240, height: 120)
        view.frame = CGRect(origin: .zero, size: size)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        func colour(_ page: PDFPointValue) -> NSColor {
            let p = view.transform!.viewPoint(from: page)
            return rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
        }
        let ink = CanvasMarkupStyle.selectionInk, paper = CanvasMarkupStyle.paper
        let focused = colour(ring[1])
        let plain = colour(ring[0])
        #expect(distance(focused, ink) < distance(focused, paper), "focused handle \(focused) is not ink-filled")
        #expect(distance(plain, paper) < distance(plain, ink), "unfocused handle \(plain) is not paper-filled")
    }

    // MARK: - T-001 (re-fix) a handle Delete cannot remove is a click on the markup

    /// A press and release at `page` with no movement, through the page view's own mouse handling.
    private static func click(_ harness: Fix2Harness, at page: PDFPointValue) throws {
        let pageView = harness.canvas.pageViewForTesting
        let local = try #require(pageView.transform).viewPoint(from: page)
        pageView.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local))
        pageView.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: local))
    }

    /// Arms Select, selects `id` alone and waits for the scene, so its handles are drawn.
    private static func select(_ harness: Fix2Harness, _ id: MarkupID) async {
        harness.shell.perform(.selectTool)
        await harness.settle()
        harness.core.canvas.select(markupIDs: [id.rawValue], additive: false)
        harness.canvas.refresh()
        await harness.canvas.settleScene()
    }

    /// Clicks the handle at `handle` on the selected `id` (no drag), then presses Delete.
    private static func clickHandleThenDelete(
        _ harness: Fix2Harness, _ id: MarkupID, at handle: PDFPointValue
    ) async throws -> (focused: Bool, deleted: Bool, note: String?) {
        #expect(harness.canvas.vertexHandle(at: handle)?.markupID == id.rawValue, "the click is on a drawn handle")
        try click(harness, at: handle)
        let focused = harness.canvas.focusedVertex != nil
        harness.canvas.delete(nil)
        let deleted = await eventually { await harness.core.session.markup(id) == nil }
        return (focused, deleted, harness.core.status.snapshot.activeToolNote)
    }

    /// A Length (100,100)–(300,100) is two points: its endpoint drags but can never be removed.
    ///
    /// Old output (first T-001 fix): the click focused vertex 1, Delete was spent on it, the
    /// status bar said "This vertex cannot be removed: the shape would no longer be a
    /// measurement of its kind." and the Length stayed.
    @Test("T-001 re-fix: click a selected Length's endpoint (no drag), then Delete deletes the Length")
    func clickALengthEndpointThenDelete() async throws {
        let harness = try await Fix2Harness.make("Iter3 Focus Length.pdf")
        defer { harness.tearDown() }
        let length = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        await Self.select(harness, length.id)
        let outcome = try await Self.clickHandleThenDelete(harness, length.id, at: PDFPointValue(x: 300, y: 100))
        #expect(!outcome.focused, "the Length's endpoint took the focus")
        #expect(outcome.deleted, "Delete left the Length; note: \(outcome.note ?? "none")")
        #expect(outcome.note?.contains("cannot be removed") != true, "\(outcome.note ?? "")")
    }

    /// Count marks at `positions`.
    private static func marks(_ positions: [(Double, Double)]) -> [CountPoint] {
        positions.map { CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: $0.0, y: $0.1)) }
    }

    /// A one-mark Count's only vertex is the mark itself: at its minimum, so a click on it is a
    /// click on the count. A three-mark Count still gives up a mark: its focus is kept.
    ///
    /// Old output (first T-001 fix): the click on the lone mark focused it, Delete posted
    /// "This vertex cannot be removed: …" and the count stayed.
    @Test("T-001 re-fix: click a one-mark Count's mark (no drag), then Delete deletes the count")
    func clickALoneCountMarkThenDelete() async throws {
        let harness = try await Fix2Harness.make("Iter3 Focus Count.pdf")
        defer { harness.tearDown() }
        let lone = try await harness.addMarkup(tool: .count) { page in
            MeasurementGeometry(pageID: page, countPoints: Self.marks([(300, 300)]))
        }
        let three = try await harness.addMarkup(tool: .count) { page in
            MeasurementGeometry(pageID: page, countPoints: Self.marks([(100, 500), (150, 500), (200, 500)]))
        }
        await Self.select(harness, lone.id)
        let outcome = try await Self.clickHandleThenDelete(harness, lone.id, at: PDFPointValue(x: 300, y: 300))
        #expect(!outcome.focused, "the lone count mark took the focus")
        #expect(outcome.deleted, "Delete left the count; note: \(outcome.note ?? "none")")
        #expect(outcome.note?.contains("cannot be removed") != true, "\(outcome.note ?? "")")

        // The control: a mark of a three-mark count is still a vertex Delete removes.
        await Self.select(harness, three.id)
        try Self.click(harness, at: PDFPointValue(x: 150, y: 500))
        #expect(harness.canvas.focusedVertex?.markupID == three.id.rawValue)
        harness.canvas.delete(nil)
        #expect(await Self.eventually { await harness.core.session.markup(three.id)?.geometry?.countPoints.count == 2 })
        #expect(await harness.core.session.markup(three.id)?.geometry?.countPoints.map(\.position)
                == [PDFPoint(x: 100, y: 500), PDFPoint(x: 200, y: 500)], "the middle mark is the one removed")
    }

    /// A stamp's geometry point is its centre, which is where a person clicks a stamp.
    ///
    /// Old output (first T-001 fix): the click focused the centre, Delete posted "This vertex
    /// cannot be removed: …" and the stamp stayed.
    @Test("T-001 re-fix: click a selected stamp at its centre (no drag), then Delete deletes the stamp")
    func clickAStampCentreThenDelete() async throws {
        let harness = try await Fix2Harness.make("Iter3 Focus Stamp.pdf")
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        let stampID = MarkupID(UUID())
        _ = try await harness.core.commands.perform(.addMarkup(MarkupRecord(
            id: stampID,
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .stamp,
            subject: "Review",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 300, y: 400)]),
            stamp: StampInstance(
                templateID: UUID(), templateName: "Approved", widthPoints: 120, heightPoints: 48,
                resolvedAt: Self.stamp
            ),
            createdAt: Self.stamp,
            modifiedAt: Self.stamp
        )))
        await Self.select(harness, stampID)
        let outcome = try await Self.clickHandleThenDelete(harness, stampID, at: PDFPointValue(x: 300, y: 400))
        #expect(!outcome.focused, "the stamp's centre took the focus")
        #expect(outcome.deleted, "Delete left the stamp; note: \(outcome.note ?? "none")")
        #expect(outcome.note?.contains("cannot be removed") != true, "\(outcome.note ?? "")")
    }

    /// A drag on a Length's endpoint still moves it (2 m → 2.2 m), but leaves no focus, and a
    /// focus that reaches a fixed-count markup anyway is refused by Delete at once, so Delete
    /// deletes the Length.
    ///
    /// Old output (first T-001 fix): the drag focused vertex 1, `removeFocusedVertex()` answered
    /// true before its task found the tool fixed, and Delete left the Length with the refusal note.
    @Test("T-001 re-fix: after dragging a Length's endpoint, Delete deletes the Length")
    func dragALengthEndpointThenDelete() async throws {
        let harness = try await Fix2Harness.make("Iter3 Focus Length Drag.pdf")
        defer { harness.tearDown() }
        let length = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        await Self.select(harness, length.id)
        let canvas = harness.canvas
        canvas.handleDragBegan(at: PDFPointValue(x: 300, y: 100))
        #expect(canvas.focusedVertex == nil, "a drag on a Length's endpoint focused it")
        canvas.handleDragMoved(to: PDFPointValue(x: 320, y: 100))
        canvas.handleDragEnded(at: PDFPointValue(x: 320, y: 100))
        #expect(await Self.eventually {
            await harness.core.session.markup(length.id)?.geometry?.points.last == PDFPoint(x: 320, y: 100)
        }, "the endpoint drag did not move the endpoint")
        await harness.settle()
        #expect(harness.core.canvas.selectedMarkupIDs == [length.id.rawValue])

        canvas.focusedVertex = (length.id.rawValue, 1)
        #expect(!canvas.removeFocusedVertex(), "Delete was spent on a vertex a Length cannot lose")
        #expect(canvas.focusedVertex == nil)

        canvas.delete(nil)
        let deleted = await Self.eventually { await harness.core.session.markup(length.id) == nil }
        let note = harness.core.status.snapshot.activeToolNote
        #expect(deleted, "Delete left the Length; note: \(note ?? "none")")
        #expect(note?.contains("cannot be removed") != true, "\(note ?? "")")
    }

    // MARK: - T-002 a turned text box is culled and outlined as drawn

    /// A borderless 200 × 20 text box at (100, 100), turned 90° about its centre (200, 110): as
    /// drawn it covers x 190…210, y 10…210.
    private static func turnedText() -> CanvasMarkupShape {
        let box = PDFRectValue(x: 100, y: 100, width: 200, height: 20)
        let centre = PDFPointValue(x: 200, y: 110)
        var shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            strokes: [], counts: [],
            bounds: CanvasSceneBuilder.turnedBounds(box, about: centre, degrees: 90), hidden: false
        )
        shape.kind = .text
        shape.text = "Turned note"
        shape.textBox = box
        shape.rotationDegrees = 90
        shape.rotationCentre = centre
        return shape
    }

    private static func close(_ a: PDFRectValue, _ b: PDFRectValue) -> Bool {
        Swift.abs(a.minX - b.minX) < 1e-9 && Swift.abs(a.minY - b.minY) < 1e-9
            && Swift.abs(a.size.width - b.size.width) < 1e-9 && Swift.abs(a.size.height - b.size.height) < 1e-9
    }

    /// At 400 % the turned box reaches 90 pt · 4 = 360 view pt past the unturned box's long
    /// edges, against a pad of 48.
    ///
    /// Old output: the cull rectangle was the unturned box ± 48 view pt (view y 1040…1216 for a
    /// turned extent of 760…1560), so a partial redraw culled the shape and clipped its words.
    @Test("T-002: a turned borderless text box's cull rectangle holds its turned extent")
    func turnedTextCullRectangle() {
        let shape = Self.turnedText()
        let turned = PDFRectValue(x: 190, y: 10, width: 20, height: 200)
        #expect(Self.close(shape.drawnBox, turned), "\(shape.drawnBox)")
        #expect(CanvasHitTesting.inkBounds(of: shape).map { Self.close($0, turned) } == true,
                "the hit test's ink bounds and the drawn box are one rule")
        var upright = shape
        upright.rotationDegrees = 0
        upright.rotationCentre = nil
        #expect(upright.drawnBox == PDFRectValue(x: 100, y: 100, width: 200, height: 20))

        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 4, origin: .zero
        )
        let padded = CanvasPageView.paddedViewBounds(of: shape, transform: transform)
        let extent = transform.viewRect(from: turned)
        #expect(padded.contains(extent), "cull \(padded) does not hold the turned words \(extent)")
    }

    /// The ledger hover outlines the turned box: its solid edge runs 5 pt outside x = 190, at
    /// view x 185, from view y 85 to 295 on a 400-pt-high page at 100 %.
    ///
    /// Old output: the outline framed the unturned box (view x 95…305, y 85…115), so at
    /// (185, 190) the sheet was blank paper.
    @Test("T-002: the ledger hover frames a turned text box as it is drawn")
    func ledgerHoverFramesTheTurnedBox() throws {
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 400, height: 300), rotation: 0, zoom: 1, origin: .zero
        )
        view.pageImage = try Self.whitePage(width: 400, height: 300)
        let shape = Self.turnedText()
        view.shapes = [shape]
        view.ledgerHoverMarkupID = shape.id
        let size = CGSize(width: 400, height: 300)
        view.frame = CGRect(origin: .zero, size: size)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        let ink = try #require(CanvasMarkupStyle.selectionInk.usingColorSpace(.sRGB))
        func inkNear(x: CGFloat, y: CGFloat) -> Bool {
            // The outline is antialiased: any pixel within 1.5 pt of the edge that reads as ink.
            var column = (x - 1.5) * scale
            while column <= (x + 1.5) * scale {
                if let c = rep.colorAt(x: Int(column), y: Int(y * scale))?.usingColorSpace(.sRGB),
                   abs(c.redComponent - ink.redComponent) + abs(c.greenComponent - ink.greenComponent)
                    + abs(c.blueComponent - ink.blueComponent) < 0.35 {
                    return true
                }
                column += 1
            }
            return false
        }
        #expect(inkNear(x: 185, y: 190), "no ledger-hover edge beside the turned box")
        #expect(inkNear(x: 215, y: 190), "no ledger-hover edge on the turned box's right side")
    }

    // MARK: - T-003 Split Canvas panes show the sheet's view

    /// A4 (595 × 842) turned 90° in the view and cropped to (10, 20, 200 × 100): the pane's box
    /// is the crop, it stands at 90°, and the crop rendered at 1 px/pt comes back turned,
    /// 100 × 200 px.
    ///
    /// Old output: pageBox (0, 0, 595 × 842), rotation 0, and the same region came back
    /// unturned, 200 × 100 px.
    @Test("T-003: a Split Canvas pane renders a sheet turned and cropped in the view as the canvas does")
    func splitPaneFollowsTheSheetView() async throws {
        let harness = try await Fix2Harness.make("Iter3 Split View.pdf", calibrate: false)
        defer { harness.tearDown() }
        let core = harness.core
        let first = try #require(await core.session.firstPageID)
        let rotate = try #require(harness.shell.onRotatePages, "the window wires Rotate")
        rotate([first.rawValue], 90)
        #expect(await AppTestSupport.wait { core.document.pages.first?.viewRotation == 90 })
        let crop = PDFRectValue(x: 10, y: 20, width: 200, height: 100)
        await harness.document.cropPage(first, to: crop)
        #expect(await AppTestSupport.wait { core.document.pages.first?.viewBox == crop })

        let pane = SplitCanvasPaneState(
            id: .first, documentID: harness.document.documentIdentity, pageID: first.rawValue
        )
        let source = try #require(harness.controller.splitPaneRenderSource(for: pane))
        #expect(source.pageBox == crop)
        #expect(source.rotation == 90)
        #expect(source.geometry.displayBox.size == PDFSizeValue(width: 100, height: 200))
        let image = try #require(await source.render(crop, 1))
        #expect(image.width == 100 && image.height == 200, "\(image.width) × \(image.height)")

        // The pane view places that picture where its geometry says: tall, not squashed.
        let paneView = SplitPaneCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        paneView.renderSource = source
        paneView.scheduleRender()
        await paneView.settleRenderForTesting()
        let rendered = try #require(paneView.lastRenderedImage)
        let display = try #require(paneView.lastRenderedDisplayRegion)
        let imageAspect = Double(rendered.width) / Double(rendered.height)
        let regionAspect = display.size.width / display.size.height
        #expect(Swift.abs(imageAspect - regionAspect) < 0.02, "image \(imageAspect) vs region \(regionAspect)")
    }

    // MARK: - T-004 Tint by Author does not rebuild its tables per drag frame

    private static func signed(_ author: String, x: Double, harness: Fix2Harness) throws -> MarkupRecord {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        return MarkupRecord(
            id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id,
            kind: .measurement, tool: .area, subject: "Floor", label: author, author: author,
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 100), PDFPoint(x: x + 100, y: 100), PDFPoint(x: x + 100, y: 200), PDFPoint(x: x, y: 200)
            ], isClosed: true))]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
    }

    /// Twenty move frames with Tint by Author on: the colour table and the author map are each
    /// built once for the scene, not once per frame, and the tint still follows the authors.
    ///
    /// Old output: `applyScene` ran `AuthorColors.assignments` over every project markup and
    /// rebuilt the author map on every frame — 20 builds of each for 20 frames.
    @Test("T-004: a Select drag with Tint by Author on builds the author tables once, not per frame")
    func authorTintIsNotRebuiltPerDragFrame() async throws {
        let harness = try await Fix2Harness.make("Iter3 Author Tint.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        let bo = try Self.signed("Bo", x: 100, harness: harness)
        let ada = try Self.signed("Ada", x: 300, harness: harness)
        _ = try await core.commands.perform(.addMarkup(bo))
        _ = try await core.commands.perform(.addMarkup(ada))
        harness.shell.perform(.selectTool)
        core.canvas.tintsByAuthor = true
        await harness.settle()
        let colours = AuthorColors.assignments(for: ["Bo", "Ada"])
        func drawnColour(_ record: MarkupRecord) -> ColorRGBA? {
            canvas.pageViewForTesting.shapes.first { $0.id == record.id.rawValue }?.color
        }
        #expect(drawnColour(bo) == colours["Bo"]?.color)
        #expect(drawnColour(ada) == colours["Ada"]?.color)

        core.canvas.select(markupIDs: [bo.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        // The press arms a move and redraws once; its scene lands before the frames are counted.
        // Inside Bo's area, clear of its caption pill at the centroid, which a press would drag.
        canvas.handleDragBegan(at: PDFPointValue(x: 110, y: 190))
        await canvas.settleScene()
        #expect(canvas.isSelectDragArmed)
        let colourBuildsBeforeFrames = canvas.authorTintColourComputationCountForTesting
        let authorBuildsBeforeFrames = canvas.sceneAuthorsComputationCountForTesting
        #expect(colourBuildsBeforeFrames >= 1 && authorBuildsBeforeFrames >= 1, "the tint was never computed")
        for step in 1...20 {
            canvas.handleDragMoved(to: PDFPointValue(x: 110 + Double(step), y: 190))
        }
        #expect(canvas.isSelectDragArmed)
        #expect(canvas.authorTintColourComputationCountForTesting == colourBuildsBeforeFrames,
                "colour table built \(canvas.authorTintColourComputationCountForTesting - colourBuildsBeforeFrames) times in 20 frames")
        #expect(canvas.sceneAuthorsComputationCountForTesting == authorBuildsBeforeFrames,
                "author map built \(canvas.sceneAuthorsComputationCountForTesting - authorBuildsBeforeFrames) times in 20 frames")
        #expect(drawnColour(bo) == colours["Bo"]?.color, "the dragged markup keeps its author's colour")
        canvas.cancelSelectDrag()
        let colourBuildsBeforeDrag = canvas.authorTintColourComputationCountForTesting

        // A new author re-assigns the table (sorted: Ada, Bo, Cy).
        let cy = try Self.signed("Cy", x: 500, harness: harness)
        _ = try await core.commands.perform(.addMarkup(cy))
        await harness.settle()
        let three = AuthorColors.assignments(for: ["Bo", "Ada", "Cy"])
        #expect(canvas.authorTintColourComputationCountForTesting > colourBuildsBeforeDrag)
        #expect(drawnColour(cy) == three["Cy"]?.color)
        #expect(drawnColour(bo) == three["Bo"]?.color)
    }
}
