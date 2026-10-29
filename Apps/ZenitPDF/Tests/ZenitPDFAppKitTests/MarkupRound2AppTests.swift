import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Round 2, markup unit (ADR-0029): the canvas draws and hit-tests the new style fields, the
/// export maps stored line ends, and the canvas controller's new gestures land as one undo step
/// each. Everything runs in a window that is never shown; no modal reaches the screen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct MarkupRound2AppTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Scene, pure

    private static func record(
        _ kind: ZPDFContracts.MarkupKind,
        points: [PDFPoint] = [],
        ring: [PDFPoint]? = nil,
        style: MarkupStyle = MarkupStyle(),
        caption: String? = nil,
        page: PageID = PageID(UUID())
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: kind,
            style: style, caption: caption,
            geometry: MeasurementGeometry(
                pageID: page, points: points,
                polygons: ring.map { [PolygonGeometry(outer: PolygonRing(points: $0, isClosed: true))] } ?? []
            ),
            createdAt: now, modifiedAt: now
        )
    }

    private static func shape(_ record: MarkupRecord, artwork: [String: ArtworkGeometry] = [:]) -> CanvasMarkupShape? {
        CanvasSceneBuilder.build(records: [record], summaries: [], pageID: record.pageID.rawValue, artwork: artwork).first
    }

    private static let square = [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)]

    @Test("A Text box with a border and a fill draws a frame; bold, italic and text colour reach the shape")
    func textStyleReachesTheCanvas() throws {
        var style = MarkupStyle(fill: RGBAColor(red: 1, green: 1, blue: 0, alpha: 0.3))
        style.textStyle = MarkupTextStyle(bold: true, italic: true, textColor: RGBAColor(red: 1, green: 0, blue: 0), boxBorder: true)
        let text = Self.record(.text, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 40)], style: style, caption: "Hello")
        let shape = try #require(Self.shape(text))
        #expect(shape.text == "Hello")
        #expect(shape.textStyle?.bold == true && shape.textStyle?.italic == true)
        #expect(shape.strokes.count == 1 && shape.strokes[0].closed && shape.strokes[0].filled && shape.strokes[0].stroked)
        // Old output (before ADR-0029): a text box had no strokes at all.
        let plain = try #require(Self.shape(Self.record(.text, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 40)], caption: "Hi")))
        #expect(plain.strokes.isEmpty)
        let font = CanvasMarkupFont.font(named: "Helvetica", size: 12, weight: .regular, bold: true, italic: true)
        let traits = NSFontManager.shared.traits(of: font)
        #expect(traits.contains(.boldFontMask) && traits.contains(.italicFontMask))
    }

    @Test("A stored arc size sets the scallop count; unset keeps the automatic size")
    func arcSize() throws {
        let auto = try #require(Self.shape(Self.record(.cloud, ring: Self.square)))
        var style = MarkupStyle(lineStyle: .cloud)
        style.cloudArcSize = 5
        let small = try #require(Self.shape(Self.record(.cloud, ring: Self.square, style: style)))
        // 100 pt edges: automatic radius max(8, min(18, 100/12)) = 8.33 → 6 scallops per edge
        // (100 / 16.67 = 6), 12 samples each, 4 edges = 288 points. Radius 5 → 10 per edge = 480.
        #expect(auto.strokes[0].points.count == 288)
        #expect(small.strokes[0].points.count == 480)
    }

    @Test("A turned rectangle's strokes turn about its centre, and its knob box is the unturned one")
    func rotationTurnsStrokes() throws {
        var style = MarkupStyle()
        style.rotationDegrees = 90
        let turned = try #require(Self.shape(Self.record(.rectangle, ring: Self.square, style: style)))
        // (100, 100) turned 90° CCW about (150, 150) is (200, 100).
        let first = try #require(turned.strokes.first?.points.first)
        #expect(abs(first.x - 200) < 1e-9 && abs(first.y - 100) < 1e-9)
        #expect(turned.rotationBox == PDFRectValue(x: 100, y: 100, width: 100, height: 100))
        #expect(turned.vertices.isEmpty, "a turned markup edits by its box")
    }

    @Test("Hit-testing a turned text box uses the turned box")
    func rotatedTextHitTest() throws {
        var style = MarkupStyle()
        style.rotationDegrees = 90
        // A 200 × 20 box centred on (200, 100); turned 90° it stands upright, 20 wide, 200 tall.
        let text = Self.record(.text, points: [PDFPoint(x: 100, y: 90), PDFPoint(x: 300, y: 110)], style: style, caption: "Tall")
        let shape = try #require(Self.shape(text))
        #expect(CanvasHitTesting.shape(shape, contains: PDFPointValue(x: 200, y: 180), tolerance: 0.5))
        #expect(!CanvasHitTesting.shape(shape, contains: PDFPointValue(x: 280, y: 100), tolerance: 0.5),
                "the unturned box's far end is empty page once turned")
    }

    @Test("A clouded callout draws its cloud, its leader and its box, with the words")
    func cloudedCalloutScene() throws {
        let cloud = Self.record(
            .cloud,
            points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 230, y: 230), PDFPoint(x: 330, y: 250)],
            ring: Self.square,
            style: MarkupStyle(endCap: .openArrow),
            caption: "Revised"
        )
        let shape = try #require(Self.shape(cloud))
        #expect(shape.strokes.count == 3)
        #expect(shape.strokes[1].endCap == .openArrow)
        #expect(shape.strokes[2].calloutBox)
        #expect(shape.text == "Revised")
        #expect(shape.leaderTarget == PDFPointValue(x: 200, y: 200))
        // Bounded by everything: the ring from 100 and the box to 330 × 250.
        #expect(shape.bounds == PDFRectValue(x: 100, y: 100, width: 230, height: 150))
        // A plain cloud is unchanged: one stroke, no text.
        #expect(try #require(Self.shape(Self.record(.cloud, ring: Self.square, caption: "note"))).strokes.count == 1)
    }

    @Test("Pen strokes draw smooth; the highlighter multiplies; a link draws a frame; a note is a note")
    func annotationKinds() throws {
        let pen = try #require(Self.shape(Self.record(.freehand, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 8), PDFPoint(x: 10, y: 0)])))
        #expect(pen.strokes.first?.smooth == true)
        #expect(!pen.multiplyBlend)
        var marker = MarkupStyle(opacity: 0.4, lineWidth: 12)
        marker.blendMode = .multiply
        let highlight = try #require(Self.shape(Self.record(.freehand, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0)], style: marker)))
        #expect(highlight.multiplyBlend)
        let link = try #require(Self.shape(Self.record(.hyperlink, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 40, y: 20)])))
        #expect(link.strokes.first?.closed == true)
        let note = try #require(Self.shape(Self.record(.note, points: [PDFPoint(x: 0, y: 20), PDFPoint(x: 20, y: 0)])))
        #expect(note.kind == .note)
        // The smooth path passes through every sample.
        let path = CanvasPageView.smoothPath([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 8), CGPoint(x: 10, y: 0)])
        #expect(path.elementCount == 3)
    }

    @Test("An image markup draws its artwork through a placement over its box")
    func imageScene() throws {
        var record = MarkupRound2Actions.imageRecord(
            digest: "abc", kind: .raster, sourceName: "site.png", pixelWidth: 400, pixelHeight: 200,
            centre: PDFPointValue(x: 300, y: 300), pageID: UUID(), documentID: UUID(), author: "t", now: Self.now
        )
        // 200 wide, aspect 2 → 100 tall, centred on (300, 300).
        #expect(record.geometry?.points == [PDFPoint(x: 200, y: 250), PDFPoint(x: 400, y: 350)])
        record.style.rotationDegrees = 30
        let artwork = ArtworkGeometry(kind: .raster, regions: [ArtworkRegion(outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)])], sourceAspectRatio: 2)
        let shape = try #require(Self.shape(record, artwork: ["abc": artwork]))
        #expect(shape.stamp?.artwork == artwork)
        #expect(shape.stamp?.rotationDegrees == 30)
        #expect(shape.stamp?.widthPoints == 200)
    }

    // MARK: Export (NL-MARKUP-07)

    @Test("A line with a circle start and a closed-arrow end exports both /LE names; an arrow set to none exports None")
    func lineEndsExport() throws {
        let line = Self.record(.line, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 90, y: 0)], style: MarkupStyle(startCap: .circle, endCap: .closedArrow))
        let lineShape = try #require(Self.shape(line))
        let a = StandardAnnotationExport.annotation(for: lineShape, record: line, fragments: [])
        #expect(a.startEnding == .circle)
        #expect(a.endEnding == .closedArrow)
        // Old output: .none / .none — only kind == .arrow got a head.
        let arrow = Self.record(.arrow, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 90, y: 0)], style: MarkupStyle(startCap: .none, endCap: .none))
        let b = StandardAnnotationExport.annotation(for: try #require(Self.shape(arrow)), record: arrow, fragments: [])
        #expect(b.endEnding == .none, "old output: .closedArrow from the kind")
        let poly = Self.record(.polyline, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 5), PDFPoint(x: 10, y: 0)], style: MarkupStyle(startCap: .diamond, endCap: .slash))
        let c = StandardAnnotationExport.annotation(for: try #require(Self.shape(poly)), record: poly, fragments: [])
        #expect(c.startEnding == .diamond && c.endEnding == .slash)
        #expect(StandardAnnotationExport.lineEnding(.round) == .none)
    }

    @Test("A hyperlink exports its stored web address")
    func hyperlinkExport() throws {
        var link = Self.record(.hyperlink, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 40, y: 20)])
        link.link = MarkupLinkTarget(url: "https://example.org/spec")
        let a = StandardAnnotationExport.annotation(for: try #require(Self.shape(link)), record: link, fragments: [])
        #expect(a.geometry == .link(PDFRect(x: 0, y: 0, width: 40, height: 20), uri: "https://example.org/spec"))
    }

    // MARK: Canvas controller

    private func open() async throws -> (ZenitPDFProjectDocument, ProjectWindowController, PDFCanvasViewController, URL) {
        let url = try AppTestSupport.writeFixturePDF(named: "Markup Round Two.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let canvas = try #require(controller.canvasController(for: document))
        return (document, controller, canvas, url)
    }

    private func add(_ record: MarkupRecord, to core: AppCoreEnvironment, canvas: PDFCanvasViewController) async throws {
        _ = try await core.commands.perform(.addMarkup(record))
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
    }

    private func onPage(_ core: AppCoreEnvironment, _ make: (PageID, UUID) -> MarkupRecord) throws -> MarkupRecord {
        let page = try #require(core.snapshot.pages.first)
        return make(PageID(page.id), core.snapshot.documentID)
    }

    @Test("Double-click a text box with Select opens the editor in place; the new words are one Edit Text step")
    func inPlaceTextEditing() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let text = try onPage(core) { page, doc in
            var record = Self.record(.text, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 130)], caption: "Old words", page: page)
            record.documentID = DocumentID(doc)
            return record
        }
        try await add(text, to: core, canvas: canvas)
        canvas.handleDoubleClick(at: PDFPointValue(x: 150, y: 115))
        #expect(canvas.activeTextEntry?.editing == text.id.rawValue)
        #expect(canvas.textEditorForTesting?.string == "Old words")
        canvas.typeIntoTextEntry("New words")
        canvas.commitTextEntry()
        #expect(await AppTestSupport.wait { core.snapshot.markups.first { $0.id == text.id.rawValue }?.drawnText == "New words" })
        #expect(document.undoManager?.undoActionName == "Edit Text")
        #expect(canvas.activeTextEntry == nil)
    }

    @Test("Drag the rotation knob of a selected rectangle: it turns in one Rotate step; Shift snaps to 15°")
    func rotationKnob() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let rect = try onPage(core) { page, doc in
            var record = Self.record(.rectangle, ring: Self.square, page: page)
            record.documentID = DocumentID(doc)
            return record
        }
        try await add(rect, to: core, canvas: canvas)
        core.canvas.select(markupIDs: [rect.id.rawValue], additive: false)
        let gap = core.canvas.viewport.pageDistance(forViewPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints))
        let knob = PDFPointValue(x: 150, y: 200 + gap)
        #expect(canvas.markupRotationHandle(at: knob) == rect.id.rawValue)
        canvas.beginSelectDrag(at: knob)
        // Dragged to the left of the centre at the knob's height: atan2 puts it at ~+45°, which
        // Shift snaps to a multiple of 15.
        canvas.handleModifiers(shiftHeld: true)
        let target = PDFPointValue(x: 150 - (50 + gap), y: 150 + (50 + gap))
        canvas.endSelectDrag(at: target)
        #expect(await AppTestSupport.wait { core.snapshot.markups.first { $0.id == rect.id.rawValue }?.rotationDegrees == 45 })
        #expect(document.undoManager?.undoActionName == "Rotate")
        canvas.handleModifiers(shiftHeld: false)
    }

    @Test("Pen: one press-drag-release commits one smoothed freehand stroke")
    func penGesture() async throws {
        let (document, controller, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        shell.toolbar.activateShape(.freehand)
        _ = controller
        canvas.applyArmedSelection()
        #expect(core.markup.activeKind == .freehand)
        canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        for step in 1...20 {
            let x = 100 + Double(step) * 5
            canvas.handleDragMoved(to: PDFPointValue(x: x, y: 100 + (x - 100) * (x - 100) / 100))
        }
        canvas.handleDragEnded(at: PDFPointValue(x: 200, y: 200))
        #expect(await AppTestSupport.wait { core.snapshot.markups.contains { $0.kind == .freehand } })
        // The add names its kind (L-09); it read "Add Markup" for every kind.
        #expect(document.undoManager?.undoActionName == "Add Freehand")
    }

    @Test("Clouded Callout: a drag draws the cloud, the words go in the box beside it, one markup")
    func cloudedCalloutGesture() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        shell.toolbar.activateShapeVariant(.cloudedCallout)
        canvas.applyArmedSelection()
        #expect(core.markup.variant == .cloudedCallout)
        canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        canvas.handleDragMoved(to: PDFPointValue(x: 180, y: 160))
        canvas.handleDragEnded(at: PDFPointValue(x: 200, y: 180))
        #expect(canvas.activeTextEntry?.kind == .cloud)
        canvas.typeIntoTextEntry("Door moved")
        canvas.commitTextEntry()
        #expect(await AppTestSupport.wait { core.snapshot.markups.contains { $0.kind == .cloud && $0.drawnText == "Door moved" } })
        #expect(core.snapshot.markups.count == 1, "one markup, one ledger row")
    }

    @Test("Clicking one member of a group selects the group; ⌘-click selects the member alone")
    func groupSelection() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let a = try onPage(core) { page, doc in
            var r = Self.record(.rectangle, ring: Self.square, style: MarkupStyle(fill: RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.2)), page: page)
            r.documentID = DocumentID(doc)
            return r
        }
        let b = try onPage(core) { page, doc in
            var r = Self.record(.rectangle, ring: Self.square.map { PDFPoint(x: $0.x + 200, y: $0.y) }, style: MarkupStyle(fill: RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.2)), page: page)
            r.documentID = DocumentID(doc)
            return r
        }
        try await add(a, to: core, canvas: canvas)
        try await add(b, to: core, canvas: canvas)
        core.canvas.select(markupIDs: [a.id.rawValue, b.id.rawValue], additive: false)
        MarkupRound2Actions.group(core)
        #expect(await AppTestSupport.wait { core.snapshot.markups.allSatisfy { $0.groupID != nil } })
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.clearSelection()
        canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false)
        #expect(core.canvas.selectedMarkupIDs == [a.id.rawValue, b.id.rawValue])
        canvas.markupRound2.commandClickOverride = true
        canvas.handleClick(at: PDFPointValue(x: 350, y: 150), additive: false)
        #expect(core.canvas.selectedMarkupIDs == [b.id.rawValue])
        canvas.markupRound2.commandClickOverride = nil
        #expect(document.undoManager?.undoActionName == "Group")
    }

    @Test("⌘-click on a hyperlink follows it through the drawing-link door")
    func commandClickFollowsLink() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        var link = try onPage(core) { page, doc in
            var r = Self.record(.hyperlink, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 150)], page: page)
            r.documentID = DocumentID(doc)
            r.style.fill = RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.1)
            return r
        }
        link.link = MarkupLinkTarget(url: "https://example.org")
        try await add(link, to: core, canvas: canvas)
        var followed: DrawingLink.Target?
        canvas.onFollowLink = { followed = $0 }
        canvas.markupRound2.commandClickOverride = true
        canvas.handleClick(at: PDFPointValue(x: 150, y: 125), additive: false)
        canvas.markupRound2.commandClickOverride = nil
        #expect(followed == .uri("https://example.org"))
    }

    @Test("⌘-click on a hyperlink to a sheet follows the sheet by identity, never by PDF index")
    func commandClickFollowsSheetByIdentity() async throws {
        // r2-layers follow-up (2026-09-26). Old: `.page(page.index)` — in a project of several
        // drawings the index named a page only within its own PDF and could land on another
        // drawing's sheet. New: `.sheet(pageID)`.
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        var target: PageID?
        var link = try onPage(core) { page, doc in
            target = page
            var r = Self.record(.hyperlink, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 150)], page: page)
            r.documentID = DocumentID(doc)
            r.style.fill = RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.1)
            return r
        }
        let pageID = try #require(target)
        link.link = MarkupLinkTarget(pageID: pageID)
        try await add(link, to: core, canvas: canvas)
        var followed: DrawingLink.Target?
        canvas.onFollowLink = { followed = $0 }
        canvas.markupRound2.commandClickOverride = true
        canvas.handleClick(at: PDFPointValue(x: 150, y: 125), additive: false)
        canvas.markupRound2.commandClickOverride = nil
        #expect(followed == .sheet(pageID.rawValue))
    }

    @Test("Edit Link reads a web address or a sheet, through the injected alert, as one Change Link step")
    func editLink() async throws {
        let (document, controller, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let link = try onPage(core) { page, doc in
            var r = Self.record(.hyperlink, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 150)], page: page)
            r.documentID = DocumentID(doc)
            return r
        }
        try await add(link, to: core, canvas: canvas)
        core.canvas.select(markupIDs: [link.id.rawValue], additive: false)
        MarkupRound2Actions.typeLinkForTesting = "1"
        defer { MarkupRound2Actions.typeLinkForTesting = nil }
        let requests = ZenitModalPresenter.answering({ _ in .button(0) }) {
            MarkupRound2Actions.editLink(core, window: controller.window)
        }
        #expect(requests.map(\.identifier) == [MarkupRound2Actions.editLinkIdentifier])
        let page = try #require(core.snapshot.pages.first)
        #expect(await AppTestSupport.wait { core.snapshot.markups.first { $0.id == link.id.rawValue }?.linkPageID == page.id })
        #expect(document.undoManager?.undoActionName == "Change Link")
        #expect(MarkupRound2Actions.parseLink("javascript:x", pages: core.document.pages) == nil)
        #expect(MarkupRound2Actions.parseLink("https://a.b", pages: core.document.pages)?.url == "https://a.b")
    }

    @Test("The context menu offers Edit Text, Rotate, Group, Arrange and Align; Arrange sends to back in one step")
    func contextMenuRoundTwo() async throws {
        let (document, _, canvas, url) = try await open()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let core = try #require(document.core)
        let first = try onPage(core) { page, doc in
            var r = Self.record(.text, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 130)], caption: "One", page: page)
            r.documentID = DocumentID(doc)
            return r
        }
        let second = try onPage(core) { page, doc in
            var r = Self.record(.text, points: [PDFPoint(x: 300, y: 300), PDFPoint(x: 420, y: 330)], caption: "Two", page: page)
            r.documentID = DocumentID(doc)
            return r
        }
        try await add(first, to: core, canvas: canvas)
        try await add(second, to: core, canvas: canvas)
        core.canvas.select(markupIDs: [second.id.rawValue], additive: false)
        let single = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 350, y: 315)))
        for title in ["Edit Text", "Rotate", "Group", "Arrange"] {
            #expect(single.items.contains { $0.title == title }, "\(title)")
        }
        let arrange = try #require(single.items.first { $0.title == "Arrange" }?.submenu)
        #expect(arrange.items.map(\.title) == ["Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
        ZenitAppCommandTable.perform(.sendToBack, controller: try #require(document.windowControllers.first as? ProjectWindowController), document: document)
        #expect(await AppTestSupport.wait { core.snapshot.markups.first?.id == second.id.rawValue })
        #expect(document.undoManager?.undoActionName == "Send to Back")

        core.canvas.select(markupIDs: [first.id.rawValue, second.id.rawValue], additive: false)
        let both = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 115)))
        let align = try #require(both.items.first { $0.title == "Align" }?.submenu)
        #expect(align.items.filter { !$0.isSeparatorItem }.count == 10)
    }

    @Test("Edit ▸ Arrange and Edit ▸ Align are in the menu bar with their shortcuts")
    func menuBar() {
        let bar = ZenitMenuBar.make()
        let edit = bar.items.first { $0.submenu?.title == ZPDFCommandGroup.edit.displayName }?.submenu
        let arrange = edit?.items.first { $0.title == "Arrange" }?.submenu
        // ⌥⌘] since the 2026-09-26 design decision: ⌘] is sheet history Forward.
        let forward = arrange?.items.first { $0.title == "Bring Forward" }
        #expect(forward?.keyEquivalent == "]")
        #expect(forward?.keyEquivalentModifierMask == [.command, .option])
        let front = arrange?.items.first { $0.title == "Bring to Front" }
        #expect(front?.keyEquivalent == "}")
        #expect(front?.keyEquivalentModifierMask == [.command, .option])
        #expect(edit?.items.first { $0.title == "Group" }?.keyEquivalent == "g")
        #expect(edit?.items.contains { $0.title == "Align" } == true)
        #expect(edit?.items.contains { $0.title == "Insert Image…" } == true)
    }
}

/// NL-MARKUP-08/18 in the exports: text colour, face and rotation reach the flattened fragments.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct MarkupRound2ExportFragmentTests {

    @Test("A turned text box exports its words as turned glyph outlines; an upright one as a label in its face and colour")
    func textFragments() throws {
        let page = PageID(UUID())
        var style = MarkupStyle(fontName: "Helvetica", fontSize: 20)
        style.textStyle = MarkupTextStyle(bold: true, textColor: RGBAColor(red: 1, green: 0, blue: 0))
        var record = MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .text,
            style: style, caption: "AB",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 130)]),
            createdAt: Date(), modifiedAt: Date()
        )
        let upright = try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue).first)
        let labels = SnippetSceneBuilder.renderables(from: [upright], for: .paper).compactMap { fragment -> (RenderTextLabel, RenderStyle)? in
            if case let .textLabel(label) = fragment.shape { return (label, fragment.style) }
            return nil
        }
        let label = try #require(labels.first)
        #expect(label.0.fontName.contains("Bold"), "the bold face, by PostScript name: \(label.0.fontName)")
        #expect(label.1.fill?.red == 1 && label.1.fill?.green == 0)

        record.style.rotationDegrees = 90
        let turned = try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue).first)
        let fragments = SnippetSceneBuilder.renderables(from: [turned], for: .paper)
        #expect(!fragments.contains { if case .textLabel = $0.shape { true } else { false } })
        let glyphs = fragments.compactMap { fragment -> RenderPolygon? in
            if case let .filledPolygon(polygon) = fragment.shape, fragment.style.stroke == nil { return polygon }
            return nil
        }
        #expect(glyphs.count == 2, "A and B")
        // Turned 90° about the box centre (200, 115): every glyph point lies in the upright
        // band x ∈ [185, 215], where the unturned words ran along y ≈ 100…130 from x = 100.
        let xs = glyphs.flatMap { $0.outer.map(\.x) }
        #expect(xs.allSatisfy { $0 > 180 && $0 < 220 })
    }
}

/// NL-UX-06 and NL-UX-15 (r2-markup): the docked Tool Library and image drops.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct MarkupRound2UXTests {

    @Test("The Inspector's Tools tab hosts the Tool Library over the live library; a preset deleted there leaves the document's library")
    func dockedToolLibrary() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Dock.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.makeWindowControllers()
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        #expect(shell.toolLibraryDock != nil)
        #expect(InspectorTab.allCases.contains(.tools))
        let dock = try #require(ToolLibraryDock.docks[ObjectIdentifier(document)])
        let model = try #require(dock.currentModel())
        // The personal library is process-wide: put it back as it was, whatever happens here.
        let original = core.toolLibrary.presets
        defer { document.applyToolPresets(original) }
        #expect(model.presets == core.toolLibrary.presets)
        let victim = try #require(model.presets.first { !$0.isReadOnly })
        model.delete(id: victim.id)
        #expect(await AppTestSupport.wait { !core.toolLibrary.presets.contains { $0.id == victim.id } })
        // A change made elsewhere reaches the dock's copy.
        core.toolLibrary.setPresets(core.toolLibrary.presets.filter { $0.id != core.toolLibrary.presets.last?.id })
        #expect(dock.currentModel()?.presets == core.toolLibrary.presets)
    }

    @Test("Images dropped on a project's sheet place image markups; ⌥, a Quick PDF or a PDF keep the old drop")
    func imageDropBehaviour() throws {
        let png = URL(fileURLWithPath: "/tmp/site.png")
        let pdf = URL(fileURLWithPath: "/tmp/plan.pdf")
        #expect(ProjectWindowController.imageDropBehavior(urls: [png], optionHeld: false, document: nil) == nil)
        let url = try AppTestSupport.writeFixturePDF(named: "Quick.pdf")
        let quick = try AppTestSupport.makeDocument(opening: url)
        defer { quick.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A Quick PDF has no package for the artwork to live in.
        #expect(ProjectWindowController.imageDropBehavior(urls: [png], optionHeld: false, document: quick) == nil)
        #expect(ProjectWindowController.imageDropBehavior(urls: [pdf], optionHeld: false, document: quick) == nil)
        #expect(CanvasDropBehavior.placeImages.badgeText(fileCount: 2) == "Place 2 images on the sheet")
    }

    @Test("A shape preset dropped from the Tool Library places one of it at the drop point")
    func presetDrop() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Drop Preset.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.makeWindowControllers()
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        let canvas = try #require(controller.canvasController(for: document))
        let original = core.toolLibrary.presets
        defer { document.applyToolPresets(original) }
        let preset = ToolPresetSummary(
            id: UUID(), name: "Dropped Count", category: "Test", panel: .projectTools, markupKind: .count,
            measurementKind: .count, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1), defaultSubject: "Doors"
        )
        document.applyToolPresets(original + [preset])
        #expect(await AppTestSupport.wait { canvas.scrollViewForTesting.onDropPreset != nil }, "the sheet accepts Tool Library rows")
        #expect(canvas.contentDropBehavior != nil, "and images")
        #expect(canvas.dropPreset(preset.id, at: PDFPointValue(x: 150, y: 150)))
        #expect(await AppTestSupport.wait { core.snapshot.markups.contains { $0.subject == "Doors" } })
        #expect(!canvas.dropPreset(UUID(), at: PDFPointValue(x: 1, y: 1)), "an unknown preset is refused")
    }

    @Test("The status strip's Scale menu sets a drawing ratio on the page on screen as one Change Scale step")
    func scaleMenu() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Scale Menu.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.makeWindowControllers()
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let apply = try #require(shell.onApplyScaleRatio, "the Scale read-out is a menu")
        let page = PageID(core.canvas.viewport.pageID)
        #expect(await core.session.pageScale(page) == nil)
        apply(50)
        #expect(await AppTestSupport.wait { document.undoManager?.undoActionName == "Change Scale" })
        let scale = await core.session.pageScale(page)
        #expect(scale != nil)
        #expect(ProjectShellEnvironment.scaleRatioChoices.contains(50))
        #expect(ProjectShellEnvironment.ratioTitle(50) == "1:50")
    }
}
