import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
@testable import ZenitPDFAppKit

/// NL-PDF-05 scope sheet and NL-PDF-06 print filters, scale bar, header and summary pages —
/// one predicate for paper and file. Headless: the print view draws into a PDF context.
@MainActor
@Suite("Print and export scope, scale bar, header, summary (NL-PDF-05/06)", .appTierSerialised)
struct NLPDFR2PrintScopeTests {

    static let walls = UUID(), floors = UUID()

    /// A 400 × 300 sheet with two markups: a "Walls" line (open) and a "Floors" line (accepted).
    static func sheet() -> (FlattenPage, [UUID: DrawingOutputScope.Facts]) {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 400, height: 300), crop: PDFRect(x: 0, y: 0, width: 400, height: 300)),
            rotation: .degrees0
        )
        func line(_ id: UUID, y: Double) -> RenderableMarkup {
            RenderableMarkup(id: MarkupID(id), shape: .polyline(RenderPolyline(points: [PDFPoint(x: 40, y: y), PDFPoint(x: 360, y: y)], isClosed: false)),
                             style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 1), lineWidth: 2))
        }
        let facts: [UUID: DrawingOutputScope.Facts] = [
            walls: .init(subject: "Walls", status: .open),
            floors: .init(subject: "Floors", status: .accepted)
        ]
        return (FlattenPage(page: page, sourcePageIndex: 0, markups: [line(walls, y: 100), line(floors, y: 200)]), facts)
    }

    @Test("Scale bar lengths, hand-derived: 1:200 → 10 m over 50 mm; 1:250 → 10 m over 40 mm; 1:96 imperial → 10 ft over 90 pt")
    func scaleBarMath() throws {
        // 50 mm of paper at 1:200 is 0.05 × 200 = 10 m: a round 10 m, 50 mm = 141.732 pt.
        let a = try #require(DocumentPrintLayout.scaleBar(printedRatio: 200, imperial: false))
        #expect(a.length == 10 && a.unit == "m")
        #expect(abs(a.paperLength - 50 / 25.4 * 72) < 1e-9)
        // At 1:250 the 50 mm stand for 12.5 m; the largest round length under it is 10 m = 40 mm.
        let b = try #require(DocumentPrintLayout.scaleBar(printedRatio: 250, imperial: false))
        #expect(b.length == 10)
        #expect(abs(b.paperLength - 40 / 25.4 * 72) < 1e-9)
        // 1/8 in = 1 ft is 1:96: 50 mm stand for 0.05 × 96 / 0.3048 = 15.75 ft → 10 ft,
        // which is 10 × 0.3048 / 96 m = 31.75 mm = 90 pt.
        let c = try #require(DocumentPrintLayout.scaleBar(printedRatio: 96, imperial: true))
        #expect(c.length == 10 && c.unit == "ft")
        #expect(abs(c.paperLength - 90) < 1e-9)
        #expect(DocumentPrintLayout.scaleBar(printedRatio: 0, imperial: false) == nil)
    }

    @Test("The scope keeps exactly the chosen subjects and statuses, on the chosen sheets, and says so")
    func scopePredicate() throws {
        let (page, facts) = Self.sheet()
        let bySubject = DrawingOutputScope(subjects: ["Walls"]).apply(to: [page], facts: facts)
        #expect(bySubject[0].markups.map(\.id.rawValue) == [Self.walls])
        let byStatus = DrawingOutputScope(statuses: [.accepted]).apply(to: [page], facts: facts)
        #expect(byStatus[0].markups.map(\.id.rawValue) == [Self.floors])
        let otherSheet = DrawingOutputScope(pageIDs: [UUID()]).apply(to: [page], facts: facts)
        #expect(otherSheet[0].markups.isEmpty, "markups only on another sheet: this one prints clean")
        #expect(DrawingOutputScope.everything.apply(to: [page], facts: facts)[0].markups.count == 2)
        let sentence = try #require(DrawingOutputScope(subjects: ["Walls"], statuses: [.open]).summary { _ in nil })
        #expect(sentence == "Only markups with subject Walls; with status Open are included.")

        // The controls: all ticked is "everything", unticking one narrows.
        let controls = DrawingScopeControls(subjects: ["Floors", "Walls"], statuses: [.open, .accepted], currentPageID: page.page.id.rawValue)
        #expect(controls.scope.isEverything)
        controls.subjectBoxes[0].box.state = .off
        #expect(controls.scope.subjects == ["Walls"])
        controls.sheetPopup.selectItem(at: 1)
        #expect(controls.scope.pageIDs == [page.page.id.rawValue])
    }

    @Test("On paper: the scope removes the other subject's ink, the scale bar appears only at an exact scale, the header names the sheet")
    func printViewHonoursTheOptions() throws {
        let (page, facts) = Self.sheet()
        let view = DocumentPrintView(sheets: [.init(flatten: page, drawnRatio: 100)], content: nil, slotSize: CGSize(width: 400, height: 300))
        view.facts = facts
        view.imperialScaleBar = false
        view.options = DocumentPrintLayout.Options(scaleMode: .actualSize, scaleBar: false)
        let all = FlattenedDrawingExportTests.pathPoints(in: try NLPDFPrintTests.draw(view, size: CGSize(width: 400, height: 300)), page: 1)
        view.scope = DrawingOutputScope(subjects: ["Walls"])
        let walls = FlattenedDrawingExportTests.pathPoints(in: try NLPDFPrintTests.draw(view, size: CGSize(width: 400, height: 300)), page: 1)
        // Old behaviour: markups were all or nothing on paper.
        #expect(walls.count < all.count, "scoped \(walls.count) vs all \(all.count)")
        #expect(walls.contains { abs($0.y - 200) < 1 } && !walls.contains { abs($0.y - 100) < 1 },
                "the Walls line (page y 100, flipped to 200) stays; the Floors line goes")

        view.scope = .everything
        view.options = DocumentPrintLayout.Options(scaleMode: .actualSize, scaleBar: true)
        let barred = PDFDocument(data: try NLPDFPrintTests.draw(view, size: CGSize(width: 400, height: 300)))?.string ?? ""
        // 1:100 at actual size: a 5 m bar (50 mm), captioned with the printed ratio.
        #expect(barred.contains("Scale bar 1:100") && barred.contains("5 m"), "\(barred)")
        // Fit to paper at 37.5 % is no drawing scale: no bar.
        let unscaled = DocumentPrintView(sheets: [.init(flatten: page, drawnRatio: 100)], content: nil, slotSize: CGSize(width: 150, height: 150))
        unscaled.options = DocumentPrintLayout.Options(scaleMode: .fitToPaper, scaleBar: true)
        let noBar = PDFDocument(data: try NLPDFPrintTests.draw(unscaled, size: CGSize(width: 150, height: 150)))?.string ?? ""
        #expect(!noBar.contains("Scale bar"))

        let date = Date(timeIntervalSince1970: 1_790_164_800)
        let header = DocumentPrintView.headerText(title: "Level 3 takeoff", sheetLabel: "A-101", date: date)
        #expect(header.hasPrefix("Level 3 takeoff — Sheet A-101 — "))
        view.headerTitle = "Level 3 takeoff"
        view.options = DocumentPrintLayout.Options(scaleMode: .actualSize, header: true)
        let text = PDFDocument(data: try NLPDFPrintTests.draw(view, size: CGSize(width: 400, height: 300)))?.string ?? ""
        #expect(text.contains("Sheet A-101"))
    }

    @Test("The quantity summary prints after the sheets only when asked")
    func summaryPagesAppend() throws {
        let (page, _) = Self.sheet()
        let view = DocumentPrintView(sheets: [.init(flatten: page)], content: nil, slotSize: CGSize(width: 400, height: 300))
        // A two-page stand-in for the ledger report.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.fill(CGRect(x: 50, y: 50, width: 100, height: 20)); context.endPDFPage() }
        context.closePDF()
        view.summary = CGPDFDocument(CGDataProvider(data: data as CFData)!)
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range.length == 1)
        view.options = DocumentPrintLayout.Options(scaleMode: .actualSize, includeSummary: true)
        #expect(view.knowsPageRange(&range) && range.length == 3)
        #expect(view.rectForPage(3) != .zero)

        let accessory = PrintOptionsAccessory(printView: view)
        _ = accessory.view
        #expect(accessory.summaryCheckbox.isEnabled)
        #expect(accessory.scaleBarCheckbox.state == .on)
        #expect(accessory.keyPathsForValuesAffectingPreview().isSuperset(of: ["scaleBar", "header", "includeSummary", "scopeRevision"]))
    }

    @Test("The Marked export writes only the scoped markups, and its report says which")
    func markedExportHonoursTheScope() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Scoped.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { Task { await document.drawing?.rasterSource.close(); document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)
        for (subject, y) in [("Walls", 300.0), ("Floors", 500.0)] {
            var record = MarkupRecord(
                id: MarkupID(UUID()), documentID: drawing.documentID, pageID: page.id, kind: .measurement, tool: .length,
                subject: subject,
                geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: y), PDFPoint(x: 400, y: y)]),
                createdAt: Date(), modifiedAt: Date()
            )
            record.label = subject
            _ = try await core.commands.perform(.addMarkup(record))
        }
        await core.commands.settle()
        await core.refresh()
        let controller = ProjectWindowController(document: document)
        let folder = url.deletingLastPathComponent()
        let everything = folder.appendingPathComponent("all.pdf"), scoped = folder.appendingPathComponent("walls.pdf")
        try await controller.writeDrawing(.flattened, for: document, to: everything)
        try await controller.writeDrawing(.flattened, for: document, to: scoped, scope: DrawingOutputScope(subjects: ["Walls"]))
        let allPoints = FlattenedDrawingExportTests.pathPoints(in: try Data(contentsOf: everything), page: 1)
        let wallPoints = FlattenedDrawingExportTests.pathPoints(in: try Data(contentsOf: scoped), page: 1)
        #expect(wallPoints.count < allPoints.count, "scoped \(wallPoints.count) vs all \(allPoints.count)")
        #expect(core.document.warnings.contains { $0.message.contains("Only markups with subject Walls are included.") })
    }
}
