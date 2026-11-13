import AppKit
import CoreText
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Select Text (1.1.0): the drawing's own text, selected on the canvas and copied.
///
/// The main fixture is a hand-written PDF whose first page carries two lines of Helvetica 24 pt —
/// `ROOM SCHEDULE` on the baseline y = 700 and `DOOR 101 OAK` on y = 650, both from x = 72 —
/// and whose second page carries linework only, the scanned-sheet case.
@MainActor
enum SelectTextFixture {

    static let firstLine = "ROOM SCHEDULE"
    static let secondLine = "DOOR 101 OAK"

    /// Inside the first line's glyphs, and inside the second's.
    static let onFirstLine = PDFPointValue(x: 100, y: 708)
    static let onSecondLine = PDFPointValue(x: 100, y: 658)
    /// Just before the first line's first glyph, and inside the second line's last glyph
    /// (`DOOR 101 OAK` is 180.9 pt wide in Helvetica 24, so it ends at x ≈ 252.9).
    static let dragStart = PDFPointValue(x: 71, y: 708)
    static let dragEnd = PDFPointValue(x: 250, y: 658)
    /// Paper with nothing on it.
    static let blank = PDFPointValue(x: 450, y: 400)
    /// The fixture's page, unrotated and uncropped.
    static let fullPage = CGRect(x: 0, y: 0, width: 595, height: 842)

    static func write() throws -> URL {
        try AutomationFixtures.writePages(
            named: "Select Text.pdf",
            contents: [
                "BT /F1 24 Tf 72 700 Td (\(firstLine)) Tj ET\nBT /F1 24 Tf 72 650 Td (\(secondLine)) Tj ET\n",
                "2 w 0 0 0 RG 72 72 m 300 300 l S\n"
            ]
        )
    }

    /// Two pages that are not plain: page 1 turned by `/Rotate 90`; page 2 an 842 × 1191 sheet
    /// whose crop box `[200 300 700 900]` shows `CROPPED NOTE` (baseline y = 600 from x = 250,
    /// 192 pt wide) and crops `HIDDEN NOTE` (x = 40, y = 100) off the sheet.
    static func writeTurnedAndCropped() throws -> URL {
        try AutomationFixtures.writePDF(
            named: "Turned and Cropped.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 90 /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
                "",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 1191] /CropBox [200 300 700 900] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
                "",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
            ],
            streams: [
                4: "BT /F1 24 Tf 72 700 Td (ROTATED NOTE) Tj ET\n",
                6: "BT /F1 24 Tf 250 600 Td (CROPPED NOTE) Tj ET\nBT /F1 24 Tf 40 100 Td (HIDDEN NOTE) Tj ET\n"
            ]
        )
    }

    /// One page of real text whose security settings forbid copying it: an owner password, no
    /// open password, copying off — what the protected-copy workflow writes.
    static func writeCopyProtected() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-selecttext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Protected.pdf")
        var mediaBox = fullPage
        let options: [CFString: Any] = [
            kCGPDFContextOwnerPassword: "owner-secret",
            kCGPDFContextAllowsCopying: false
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, options as CFDictionary) else {
            throw AppTestSupport.FixtureError(reason: "CoreGraphics refused to create a protected PDF")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "PROTECTED NOTE", attributes: [.font: font])
        )
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func cg(_ point: PDFPointValue) -> CGPoint { CGPoint(x: point.x, y: point.y) }

    static func trimmed(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func answer(_ text: String) -> ZPDFPDFKitBridge.TextSelection {
        ZPDFPDFKitBridge.TextSelection(
            pageIndex: 0, string: text, bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            lineRects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
        )
    }

    struct Failure: Error {}
}

// MARK: - The selection model

@MainActor
@Suite("Select Text: the selection model", .appTierSerialised, .serialized)
struct SelectTextModelTests {

    private func openSource() async throws -> (PageRasterSource, URL) {
        let url = try SelectTextFixture.write()
        let (source, pages) = try await PageRasterSource.open(url: url)
        #expect(pages.count == 2)
        return (source, url)
    }

    /// A model armed on one page of the fixture, asking the real PDFKit through the source.
    private func engagedModel(
        source: PageRasterSource, pageIndex: Int = 0, pageID: UUID = UUID()
    ) -> CanvasTextSelection {
        let model = CanvasTextSelection()
        model.resolveTarget = { _ in
            CanvasTextSelection.Target(pageID: pageID, pageIndex: pageIndex, source: source, visibleBox: SelectTextFixture.fullPage)
        }
        model.engage()
        return model
    }

    @Test("A drag selects the text between two points in reading order, one highlight box per line")
    func dragSelectsBetweenTwoPoints() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pageID = UUID()
        let model = engagedModel(source: source, pageID: pageID)

        model.press(at: SelectTextFixture.dragStart, clickCount: 1)
        #expect(model.isTracking)
        model.drag(to: SelectTextFixture.onSecondLine)
        model.release(at: SelectTextFixture.dragEnd)
        await model.settle()

        let selected = try #require(model.selection)
        #expect(selected.pageID == pageID)
        #expect(selected.allowsCopying)
        #expect(selected.text.contains(SelectTextFixture.firstLine), "\(selected.text)")
        #expect(selected.text.contains(SelectTextFixture.secondLine), "\(selected.text)")
        // Reading order: the first line's words come first.
        let first = try #require(selected.text.range(of: SelectTextFixture.firstLine))
        let second = try #require(selected.text.range(of: SelectTextFixture.secondLine))
        #expect(first.lowerBound < second.lowerBound)
        // One box per line, each on its own line's words.
        #expect(selected.lineRects.count == 2)
        #expect(selected.lineRects.contains { $0.contains(SelectTextFixture.onFirstLine) })
        #expect(selected.lineRects.contains { $0.contains(SelectTextFixture.onSecondLine) })
    }

    @Test("A drag inside one line selects part of it, on one box")
    func dragWithinOneLine() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = engagedModel(source: source)

        model.press(at: SelectTextFixture.dragStart, clickCount: 1)
        // To the middle of the first line: past ROOM, before the end of SCHEDULE.
        model.release(at: PDFPointValue(x: 180, y: 708))
        await model.settle()

        let selected = try #require(model.selection)
        #expect(selected.text.hasPrefix("ROOM"), "\(selected.text)")
        #expect(!selected.text.contains(SelectTextFixture.secondLine))
        #expect(selected.lineRects.count == 1)
    }

    @Test("Double-click selects the word, triple-click the line, on empty paper nothing")
    func wordAndLine() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = engagedModel(source: source)

        model.press(at: SelectTextFixture.onFirstLine, clickCount: 2)
        #expect(!model.isTracking, "a double-click is not a drag")
        await model.settle()
        #expect(SelectTextFixture.trimmed(model.selection?.text) == "ROOM")
        #expect(model.selection?.lineRects.count == 1)

        model.press(at: SelectTextFixture.onSecondLine, clickCount: 3)
        await model.settle()
        #expect(SelectTextFixture.trimmed(model.selection?.text) == SelectTextFixture.secondLine)
        #expect(model.selection?.lineRects.count == 1)

        // PDFKit offers the nearest word for any point; a double-click on paper selects nothing.
        model.press(at: SelectTextFixture.blank, clickCount: 2)
        await model.settle()
        #expect(model.selection == nil)
    }

    @Test("A click lets go of the selection")
    func clickClears() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = engagedModel(source: source)
        model.press(at: SelectTextFixture.onFirstLine, clickCount: 2)
        await model.settle()
        #expect(model.selection != nil)

        model.press(at: SelectTextFixture.blank, clickCount: 1)
        model.release(at: SelectTextFixture.blank)
        await model.settle()
        #expect(model.selection == nil)
        #expect(!model.isTracking)
    }

    @Test("Select All selects every line on the page")
    func selectAll() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = engagedModel(source: source)
        model.selectAll()
        await model.settle()
        let selected = try #require(model.selection)
        #expect(selected.text.contains(SelectTextFixture.firstLine))
        #expect(selected.text.contains(SelectTextFixture.secondLine))
        #expect(selected.lineRects.count == 2)
    }

    @Test("A page with no text layer says so and selects nothing")
    func emptyPage() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try await source.hasTextLayer(pageIndex: 0))
        #expect(try await source.hasTextLayer(pageIndex: 1) == false)

        var known: [(UUID, Bool)] = []
        let pageID = UUID()
        let model = engagedModel(source: source, pageIndex: 1, pageID: pageID)
        model.onTextLayer = { known.append(($0, $1)) }
        let target = try #require(model.resolveTarget?(nil))
        model.probeTextLayer(for: target)
        await model.settle()
        #expect(known.count == 1)
        #expect(known.first?.0 == pageID)
        #expect(known.first?.1 == false)
        #expect(model.hasTextLayer(for: target) == false)

        model.press(at: PDFPointValue(x: 72, y: 300), clickCount: 1)
        model.release(at: PDFPointValue(x: 300, y: 72))
        model.selectAll()
        await model.settle()
        #expect(model.selection == nil)
        for gesture in [
            TextSelectionGesture.wholePage,
            .word(at: CGPoint(x: 150, y: 150)),
            .span(from: CGPoint(x: 0, y: 842), to: CGPoint(x: 595, y: 0))
        ] {
            #expect(try await source.textSelection(pageIndex: 1, gesture: gesture) == nil)
        }
    }

    @Test("Text outside the visible box is neither selected nor highlighted")
    func visibleBoxClips() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A box over the first line only, as a view crop would leave it.
        let box = CGRect(x: 0, y: 690, width: 595, height: 152)
        let all = try #require(try await source.textSelection(pageIndex: 0, gesture: .wholePage, within: box))
        #expect(all.string.contains(SelectTextFixture.firstLine))
        #expect(!all.string.contains(SelectTextFixture.secondLine))
        #expect(all.lineRects.allSatisfy { box.insetBy(dx: -0.5, dy: -0.5).contains($0) })
        let span = try #require(try await source.textSelection(
            pageIndex: 0,
            gesture: .span(from: SelectTextFixture.cg(SelectTextFixture.dragStart), to: SelectTextFixture.cg(SelectTextFixture.dragEnd)),
            within: box
        ))
        #expect(!span.string.contains(SelectTextFixture.secondLine))
        #expect(span.lineRects.count == 1)
        // A word clicked outside the box is not selected.
        #expect(try await source.textSelection(pageIndex: 0, gesture: .word(at: SelectTextFixture.cg(SelectTextFixture.onSecondLine)), within: box) == nil)
    }

    @Test("A drag keeps at most one query in flight; the newest point wins")
    func dragIsCoalesced() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        final class Log { var gestures: [TextSelectionGesture] = [] }
        let log = Log()
        let model = engagedModel(source: source)
        model.query = { _, gesture in
            log.gestures.append(gesture)
            await Task.yield()
            return SelectTextFixture.answer("x")
        }

        let start = PDFPointValue(x: 71, y: 708)
        model.press(at: start, clickCount: 1)
        // Fifty pointer events arrive before the first answer can land.
        for step in 0..<50 { model.drag(to: PDFPointValue(x: 80 + Double(step), y: 680)) }
        let last = PDFPointValue(x: 129, y: 680)
        // Released where the last drag event was: that question is already asked.
        model.release(at: last)
        await model.settle()

        #expect(model.queryCountForTesting == 2, "\(log.gestures)")
        #expect(log.gestures.first == .span(from: SelectTextFixture.cg(start), to: CGPoint(x: 80, y: 680)))
        #expect(log.gestures.last == .span(from: SelectTextFixture.cg(start), to: SelectTextFixture.cg(last)))
        #expect(model.selection?.text == "x")
    }

    @Test("A query given up on still runs to its end before the next one starts")
    func oneQueryAtATimeAcrossAClear() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        final class Load { var running = 0; var most = 0 }
        let load = Load()
        let model = engagedModel(source: source)
        model.query = { _, gesture in
            load.running += 1
            load.most = max(load.most, load.running)
            for _ in 0..<5 { await Task.yield() }
            load.running -= 1
            if case .word = gesture { return SelectTextFixture.answer("word") }
            return SelectTextFixture.answer("span")
        }
        model.press(at: SelectTextFixture.dragStart, clickCount: 1)
        model.drag(to: SelectTextFixture.dragEnd)
        // A new press gives the drag up while PDFKit is still on it.
        model.press(at: SelectTextFixture.onFirstLine, clickCount: 2)
        #expect(model.isAnswerOutstanding)
        await model.settle()
        #expect(load.most == 1, "two queries ran at once")
        #expect(model.queryCountForTesting == 2)
        #expect(model.selection?.text == "word", "the given-up answer was dropped")
    }

    @Test("A failed query keeps the selection; a failed probe is not remembered")
    func failuresAreNotAnswers() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        final class Calls { var count = 0 }
        let calls = Calls()
        var known: [Bool] = []
        let model = engagedModel(source: source)
        model.onTextLayer = { _, hasText in known.append(hasText) }
        model.query = { _, _ in
            calls.count += 1
            if calls.count > 1 { throw SelectTextFixture.Failure() }
            return SelectTextFixture.answer("first")
        }
        model.probe = { _ in throw SelectTextFixture.Failure() }

        model.press(at: SelectTextFixture.dragStart, clickCount: 1)
        model.drag(to: PDFPointValue(x: 150, y: 708))
        await model.settle()
        #expect(model.selection?.text == "first")
        model.drag(to: SelectTextFixture.dragEnd)
        await model.settle()
        #expect(calls.count == 2)
        #expect(model.selection?.text == "first", "PDFKit could not be asked: that is not 'nothing selected'")

        let target = try #require(model.resolveTarget?(nil))
        model.probeTextLayer(for: target)
        await model.settle()
        #expect(model.hasTextLayer(for: target) == nil)
        #expect(known.isEmpty, "no note from a probe that failed")
    }

    @Test("A drawing still behind its password reports no text layer answer, not a scanned sheet")
    func lockedDrawingIsNotAScan() async throws {
        let url = try AppTestSupport.writeLockedFixturePDF(password: "open-secret")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (source, _) = try await PageRasterSource.open(url: url)
        let locked = await source.isLocked
        #expect(locked)
        await #expect(throws: (any Error).self) { try await source.hasTextLayer(pageIndex: 0) }
        await #expect(throws: (any Error).self) { try await source.textSelection(pageIndex: 0, gesture: .wholePage) }
    }

    @Test("Nothing is asked unless the tool is engaged, and disengaging lets go")
    func idleUnlessEngaged() async throws {
        let (source, url) = try await openSource()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = CanvasTextSelection()
        let pageID = UUID()
        model.resolveTarget = { _ in
            CanvasTextSelection.Target(pageID: pageID, pageIndex: 0, source: source, visibleBox: SelectTextFixture.fullPage)
        }
        model.press(at: SelectTextFixture.dragStart, clickCount: 1)
        model.drag(to: SelectTextFixture.dragEnd)
        model.selectAll()
        await model.settle()
        #expect(model.queryCountForTesting == 0)
        #expect(model.selection == nil)

        model.engage()
        model.selectAll()
        await model.settle()
        #expect(model.selection != nil)
        model.disengage()
        #expect(model.selection == nil)
        #expect(!model.isEngaged)
    }

    @Test("The page rule: a change of current page lets go of a selection on another page")
    func pageRule() {
        let a = UUID(), b = UUID()
        #expect(PDFCanvasViewController.currentPageChangeClearsTextSelection(selectionPageID: a, currentPageID: b))
        #expect(PDFCanvasViewController.currentPageChangeClearsTextSelection(selectionPageID: a, currentPageID: nil))
        #expect(!PDFCanvasViewController.currentPageChangeClearsTextSelection(selectionPageID: a, currentPageID: a))
    }
}

// MARK: - The canvas

@MainActor
@Suite("Select Text: the canvas", .appTierSerialised, .serialized)
struct SelectTextCanvasTests {

    /// `pageLayout` pins the canvas's page layout; the tests that turn the page pass
    /// `.singlePage`, because the rule they assert — a page change lets go — is single-page mode's.
    private func makeHarness(
        fixture: URL? = nil, pageLayout: ZenitCanvasPreferences.PageLayout? = nil
    ) async throws -> (Fix2Harness, ScratchMarkupPasteboard) {
        let harness = try await Fix2Harness.make(
            "Select Text", calibrate: false, fixture: try fixture ?? SelectTextFixture.write(), pageLayout: pageLayout
        )
        let scratch = ScratchMarkupPasteboard()
        harness.controller.markupPasteboard = scratch
        return (harness, scratch)
    }

    private func arm(_ harness: Fix2Harness) {
        harness.shell.perform(.selectTextTool)
        harness.canvas.applyArmedTool()
    }

    /// A press-drag-release on the page view, as the window delivers it, without waiting for
    /// the answer.
    private func dragEvents(
        _ harness: Fix2Harness, from a: PDFPointValue, through middle: PDFPointValue, to b: PDFPointValue
    ) throws {
        let page = harness.canvas.pageViewForTesting
        let transform = try #require(page.transform)
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: transform.viewPoint(from: a)))
        page.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: transform.viewPoint(from: middle)))
        page.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: transform.viewPoint(from: b)))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: transform.viewPoint(from: b)))
    }

    private func drag(
        _ harness: Fix2Harness, from a: PDFPointValue, through middle: PDFPointValue, to b: PDFPointValue
    ) async throws {
        try dragEvents(harness, from: a, through: middle, to: b)
        await harness.canvas.settleTextSelection()
    }

    private func click(_ harness: Fix2Harness, at point: PDFPointValue, clickCount: Int) async throws {
        let page = harness.canvas.pageViewForTesting
        let local = try #require(page.transform).viewPoint(from: point)
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local, clickCount: clickCount))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: local, clickCount: clickCount))
        await harness.canvas.settleTextSelection()
    }

    private func selectBothLines(_ harness: Fix2Harness) async throws {
        try await drag(
            harness,
            from: SelectTextFixture.dragStart,
            through: SelectTextFixture.onSecondLine,
            to: SelectTextFixture.dragEnd
        )
    }

    private func addRectangle(_ harness: Fix2Harness) async throws -> MarkupID {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        let id = MarkupID(UUID())
        _ = try await harness.core.commands.perform(.addMarkup(MarkupRecord(
            id: id,
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)],
                isClosed: true
            ))]),
            createdAt: Date(),
            modifiedAt: Date()
        )))
        await harness.settle()
        return id
    }

    private static let copyItem = NSMenuItem(
        title: "Copy", action: #selector(PDFCanvasViewController.copy(_:)), keyEquivalent: "c"
    )
    private static let cutItem = NSMenuItem(
        title: "Cut", action: #selector(PDFCanvasViewController.cut(_:)), keyEquivalent: "x"
    )
    private static let deleteItem = NSMenuItem(
        title: "Delete", action: #selector(PDFCanvasViewController.delete(_:)), keyEquivalent: ""
    )
    private static let selectAllItem = NSMenuItem(
        title: "Select All", action: #selector(PDFCanvasViewController.selectAll(_:)), keyEquivalent: "a"
    )

    @Test("Arming Select Text routes the page's presses to it and wears the I-beam; Select does not")
    func arming() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        let page = harness.canvas.pageViewForTesting
        #expect(page.textSelection == nil, "nothing is routed to text selection under Select")
        #expect(harness.canvas.drawingLinkHoverApplies)

        arm(harness)
        #expect(harness.shell.toolbar.activeTool == .selectText)
        #expect(harness.canvas.armedMode == .selectText)
        #expect(page.textSelection != nil)
        #expect(page.cursorKind == .selectText)
        #expect(harness.canvas.armedToolName == "Select Text")
        // A click selects text here, so a drawing's link shows no pointing hand.
        #expect(!harness.canvas.drawingLinkHoverApplies)
    }

    @Test("A drag selects the page's text, highlights each line, and ⌘C copies it as plain text")
    func dragAndCopy() async throws {
        let (harness, scratch) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        #expect(!harness.canvas.validateMenuItem(Self.copyItem), "nothing to copy yet")

        try await selectBothLines(harness)
        let selected = try #require(harness.canvas.textSelectionForTesting)
        #expect(selected.text.contains(SelectTextFixture.firstLine))
        #expect(selected.text.contains(SelectTextFixture.secondLine))
        // The overlay draws exactly the selection's line boxes, in page space, so a zoom or a
        // pan moves them with the words.
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights == selected.lineRects)
        #expect(selected.lineRects.count == 2)

        #expect(harness.canvas.validateMenuItem(Self.copyItem))
        harness.canvas.copy(nil)
        #expect(scratch.plainText == selected.text)
        #expect(scratch.payload == nil, "plain text only: no markup payload rides along")
        #expect(!harness.canvas.validateMenuItem(Self.cutItem))
    }

    @Test("⌘C straight after the release copies the final answer, not an earlier one")
    func copyWaitsForTheAnswer() async throws {
        let (harness, scratch) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        try dragEvents(
            harness,
            from: SelectTextFixture.dragStart,
            through: PDFPointValue(x: 120, y: 708),
            to: SelectTextFixture.dragEnd
        )
        #expect(harness.textSelectionOutstanding)
        #expect(harness.canvas.validateMenuItem(Self.copyItem), "Copy is live while the answer is on its way")
        harness.canvas.copy(nil)
        #expect(await AppTestSupport.wait { scratch.plainText != nil })
        let copied = try #require(scratch.plainText)
        #expect(copied.contains(SelectTextFixture.firstLine), "\(copied)")
        #expect(copied.contains(SelectTextFixture.secondLine), "\(copied)")
        await harness.canvas.settleTextSelection()
        #expect(copied == harness.canvas.textSelectionForTesting?.text)
    }

    @Test("Double-click selects a word and triple-click a line on the canvas")
    func wordAndLineClicks() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        try await click(harness, at: SelectTextFixture.onFirstLine, clickCount: 2)
        #expect(SelectTextFixture.trimmed(harness.canvas.textSelectionForTesting?.text) == "ROOM")
        try await click(harness, at: SelectTextFixture.onSecondLine, clickCount: 3)
        #expect(SelectTextFixture.trimmed(harness.canvas.textSelectionForTesting?.text) == SelectTextFixture.secondLine)
        try await click(harness, at: SelectTextFixture.blank, clickCount: 1)
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty)
    }

    @Test("With no text selected, Copy copies the selected markups as before")
    func copyFallsBackToMarkups() async throws {
        let (harness, scratch) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        let id = try await addRectangle(harness)
        // Selected from elsewhere — the ledger — while the tool is armed.
        harness.core.canvas.select(markupIDs: [id.rawValue], additive: false)
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.validateMenuItem(Self.copyItem))

        harness.canvas.copy(nil)
        #expect(await AppTestSupport.wait { scratch.payload != nil })
        #expect(scratch.plainText?.contains("Rectangle") == true)
    }

    @Test("A markup selected before arming is let go, and Cut, Delete and the arrows never reach one")
    func markupsStayStill() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        let id = try await addRectangle(harness)
        harness.core.canvas.select(markupIDs: [id.rawValue], additive: false)
        let before = await harness.core.session.markup(id)

        arm(harness)
        #expect(harness.core.canvas.selectedMarkupIDs.isEmpty, "arming lets the markup go")

        // Even selected again from elsewhere, nothing here edits it.
        harness.core.canvas.select(markupIDs: [id.rawValue], additive: false)
        try await selectBothLines(harness)
        #expect(!harness.canvas.validateMenuItem(Self.cutItem))
        #expect(!harness.canvas.validateMenuItem(Self.deleteItem))
        let nudges = harness.canvas.nudgeCommitCountForTesting
        harness.canvas.cut(nil)
        harness.canvas.delete(nil)
        #expect(!harness.canvas.handle(key: .removeLastVertex))
        _ = harness.canvas.handle(key: .nudge(dx: 1, dy: 0, large: true, isRepeat: false))
        await harness.settle()
        #expect(harness.canvas.nudgeCommitCountForTesting == nudges)
        let after = await harness.core.session.markup(id)
        #expect(after != nil, "the markup is still there")
        #expect(after?.geometry == before?.geometry, "and where it was")
    }

    @Test("A drawing that forbids copying its text: selectable, Copy refused with a note")
    func copyingForbidden() async throws {
        let (harness, scratch) = try await makeHarness(fixture: SelectTextFixture.writeCopyProtected())
        defer { harness.tearDown() }
        arm(harness)
        harness.canvas.selectAll(nil)
        await harness.canvas.settleTextSelection()
        let selected = try #require(harness.canvas.textSelectionForTesting)
        #expect(selected.text.contains("PROTECTED NOTE"))
        #expect(!selected.allowsCopying)
        #expect(!harness.canvas.validateMenuItem(Self.copyItem))
        harness.canvas.copy(nil)
        #expect(scratch.plainText == nil)
        #expect(harness.core.status.snapshot.activeToolNote == PDFCanvasViewController.copyingNotAllowedNote)
    }

    /// Pinned to single-page mode: it asserts that a page change lets go of the selection, which
    /// is single-page mode's rule; continuous scrolling keeps a selection while its sheet is on
    /// screen (`CanvasContinuousScrollTests`).
    @Test("A turned page and a cropped page select the right words and highlight them")
    func turnedAndCroppedPages() async throws {
        let (harness, _) = try await makeHarness(fixture: SelectTextFixture.writeTurnedAndCropped(), pageLayout: .singlePage)
        defer { harness.tearDown() }
        arm(harness)

        // Page 1, turned 90°: page-space points still name the words.
        let onTurned = PDFPointValue(x: 150, y: 708)
        try await drag(harness, from: PDFPointValue(x: 71, y: 708), through: onTurned, to: PDFPointValue(x: 265, y: 708))
        let turned = try #require(harness.canvas.textSelectionForTesting)
        #expect(SelectTextFixture.trimmed(turned.text) == "ROTATED NOTE")
        let turnedTransform = try #require(harness.canvas.pageViewForTesting.transform)
        #expect(turnedTransform.rotation == 90)
        #expect(turned.lineRects.contains { turnedTransform.viewRect(from: $0).contains(turnedTransform.viewPoint(from: onTurned)) },
                "the highlight sits on the words on screen")

        // Page 2, cropped with its origin at (200, 300).
        harness.core.document.goToNextPage()
        harness.canvas.refresh()
        #expect(harness.canvas.textSelectionForTesting == nil)
        let onCropped = PDFPointValue(x: 300, y: 608)
        try await drag(harness, from: PDFPointValue(x: 249, y: 608), through: onCropped, to: PDFPointValue(x: 438, y: 608))
        let cropped = try #require(harness.canvas.textSelectionForTesting)
        #expect(SelectTextFixture.trimmed(cropped.text) == "CROPPED NOTE")
        let croppedTransform = try #require(harness.canvas.pageViewForTesting.transform)
        #expect(cropped.lineRects.contains { croppedTransform.viewRect(from: $0).contains(croppedTransform.viewPoint(from: onCropped)) })

        // Select All takes what the sheet shows, never what the crop box cuts off.
        harness.canvas.selectAll(nil)
        await harness.canvas.settleTextSelection()
        let all = try #require(harness.canvas.textSelectionForTesting)
        #expect(all.text.contains("CROPPED NOTE"))
        #expect(!all.text.contains("HIDDEN NOTE"), "\(all.text)")
        let box = croppedTransform.pageBox
        #expect(all.lineRects.allSatisfy {
            $0.minX >= box.minX - 0.5 && $0.minY >= box.minY - 0.5 && $0.maxX <= box.maxX + 0.5 && $0.maxY <= box.maxY + 0.5
        })
    }

    @Test("Select All selects the page's text while Select Text is armed")
    func selectAllSelectsText() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        await harness.canvas.settleTextSelection()
        #expect(harness.canvas.validateMenuItem(Self.selectAllItem))
        harness.canvas.selectAll(nil)
        await harness.canvas.settleTextSelection()
        let selected = try #require(harness.canvas.textSelectionForTesting)
        #expect(selected.text.contains(SelectTextFixture.firstLine))
        #expect(selected.text.contains(SelectTextFixture.secondLine))
    }

    @Test("The right-click menu over selected text offers Copy, and it copies")
    func contextMenuCopy() async throws {
        let (harness, scratch) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        await harness.canvas.settleTextSelection()
        // No selection: the canvas's own menu, its Select All on Page decided by the text rule.
        let plain = try #require(harness.canvas.markupContextMenu(at: SelectTextFixture.blank))
        #expect(plain.items.contains { $0.title == "Paste Here" })
        #expect(plain.items.first { $0.title == "Select All on Page" }?.isEnabled == true)

        try await selectBothLines(harness)
        harness.canvas.selectForContextMenu(at: SelectTextFixture.onFirstLine)
        let menu = try #require(harness.canvas.markupContextMenu(at: SelectTextFixture.onFirstLine))
        let copy = try #require(menu.items.first { $0.title == "Copy" } as? ContextMenuItem)
        #expect(copy.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(copy.action), to: copy.target, from: copy))
        #expect(scratch.plainText?.contains(SelectTextFixture.firstLine) == true)
    }

    @Test("Escape lets go of the selection and keeps the tool")
    func escapeClears() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        try await selectBothLines(harness)
        #expect(harness.canvas.textSelectionForTesting != nil)

        #expect(harness.canvas.handle(key: .escape))
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty)
        #expect(harness.canvas.armedMode == .selectText)
    }

    @Test("Arming another tool lets go of the selection and stops routing presses to it")
    func toolChangeClears() async throws {
        let (harness, _) = try await makeHarness()
        defer { harness.tearDown() }
        arm(harness)
        try await selectBothLines(harness)
        #expect(harness.canvas.textSelectionForTesting != nil)

        harness.shell.perform(.selectTool)
        harness.canvas.applyArmedTool()
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty)
        #expect(harness.canvas.pageViewForTesting.textSelection == nil)
        #expect(!harness.canvas.validateMenuItem(Self.copyItem), "Copy is back to markups, and none is selected")
    }

    /// Pinned to single-page mode: it asserts that a page change lets go of the selection, which
    /// is single-page mode's rule; continuous scrolling keeps a selection while its sheet is on
    /// screen (`CanvasContinuousScrollTests`).
    @Test("An answer for a page the canvas has left is dropped")
    func staleAnswerIsDropped() async throws {
        let (harness, _) = try await makeHarness(pageLayout: .singlePage)
        defer { harness.tearDown() }
        arm(harness)
        await harness.canvas.settleTextSelection()
        try dragEvents(
            harness,
            from: SelectTextFixture.dragStart,
            through: SelectTextFixture.onSecondLine,
            to: SelectTextFixture.dragEnd
        )
        #expect(harness.textSelectionOutstanding)
        harness.core.document.goToNextPage()
        harness.canvas.applyArmedTool()
        await harness.canvas.settleTextSelection()
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty)
    }

    /// Pinned to single-page mode: it asserts that a page change lets go of the selection, which
    /// is single-page mode's rule; continuous scrolling keeps a selection while its sheet is on
    /// screen (`CanvasContinuousScrollTests`).
    @Test("Turning the page lets go; a page without text says so in the status bar, pointing at Read Text")
    func pageChangeClearsAndNotes() async throws {
        let (harness, _) = try await makeHarness(pageLayout: .singlePage)
        defer { harness.tearDown() }
        arm(harness)
        await harness.canvas.settleTextSelection()
        #expect(harness.core.status.snapshot.activeToolNote == nil)
        try await selectBothLines(harness)
        #expect(harness.canvas.textSelectionForTesting != nil)

        harness.core.document.goToNextPage()
        harness.canvas.applyArmedTool()
        #expect(harness.canvas.textSelectionForTesting == nil)
        #expect(harness.canvas.pageViewForTesting.textSelectionHighlights.isEmpty)
        await harness.canvas.settleTextSelection()
        #expect(harness.core.status.snapshot.activeToolNote == PDFCanvasViewController.noTextLayerNote)
        #expect(PDFCanvasViewController.noTextLayerNote.contains("Read Text from Scanned Pages"))
        #expect(!harness.canvas.validateMenuItem(Self.selectAllItem), "nothing on this page to select")
        let menu = try #require(harness.canvas.markupContextMenu(at: SelectTextFixture.blank))
        #expect(menu.items.first { $0.title == "Select All on Page" }?.isEnabled == false)

        // Back on a page with text, the note is taken back.
        harness.core.document.goToPreviousPage()
        harness.canvas.applyArmedTool()
        await harness.canvas.settleTextSelection()
        #expect(harness.core.status.snapshot.activeToolNote == nil)
    }
}

extension Fix2Harness {
    /// Whether the canvas's text selection is still waiting for an answer.
    @MainActor
    var textSelectionOutstanding: Bool { canvas.textSelection.isAnswerOutstanding }
}
