import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
@testable import ZenitPDFAppKit

/// NL-PDF-06 (print scale, stated) and NL-PDF-07 (tiling), headless: the layout is a value, and
/// the print view draws into a PDF context standing in for the printer's.
@MainActor
@Suite(.appTierSerialised)
struct NLPDFPrintTests {

    static func mm(_ value: Double) -> Double { value / 25.4 * 72 }
    static let a0 = CGSize(width: mm(841), height: mm(1189))
    static let a1 = CGSize(width: mm(594), height: mm(841))
    static let a3 = CGSize(width: mm(297), height: mm(420))
    static let a4 = CGSize(width: mm(210), height: mm(297))

    // MARK: - Scale, stated (bug: "not to scale" on an exact half-size print)

    @Test("An A1 1:100 sheet on A3 at Half size prints at exactly 50 % and says 1:200")
    func halfSizeIsAnExactScale() {
        var options = DocumentPrintLayout.Options()
        options.scaleMode = .halfSize
        let layout = DocumentPrintLayout(
            sheets: [.init(size: Self.a1, drawnRatio: 100)], slot: Self.a3, options: options
        )
        #expect(layout.pages.count == 1, "half an A1 is an A3 (within half a millimetre): no tiling")
        #expect(layout.pages[0].factor == 0.5)
        #expect(layout.pages[0].tile == nil)
        let note = DocumentPrintLayout.scaleNote(drawnRatio: 100, factor: 0.5)
        // Old output: "Printed at 50 % to fit the paper — not to scale".
        #expect(note == "Printed scale 1:200 (drawn 1:100 at 50 %)")
    }

    @Test("Fit to paper at a factor that is no drawing scale says not to scale")
    func fitAtANonStandardFactorIsNotToScale() {
        let layout = DocumentPrintLayout(
            sheets: [.init(size: Self.a1, drawnRatio: 100)], slot: Self.a3, options: .init(scaleMode: .fitToPaper)
        )
        let factor = layout.pages[0].factor
        #expect(abs(factor - 0.4994) < 0.001, "A1 onto A3 fits at 49.94 %, which is not 50 %")
        #expect(DocumentPrintLayout.printedRatio(drawn: 100, factor: factor) == nil)
        #expect(DocumentPrintLayout.scaleNote(drawnRatio: 100, factor: factor) == "Printed at 50 % — not to scale")
        // An A1 onto A2-proportioned paper at 1/√2 is 1:141.42…, no scale at all.
        #expect(DocumentPrintLayout.scaleNote(drawnRatio: 100, factor: 1 / 2.0.squareRoot()) == "Printed at 71 % — not to scale")
    }

    @Test("A calibrated sheet at its own size states its scale; an uncalibrated one says nothing")
    func actualSizeNotes() {
        #expect(DocumentPrintLayout.scaleNote(drawnRatio: 50, factor: 1) == "Printed scale 1:50 (actual size)")
        #expect(DocumentPrintLayout.scaleNote(drawnRatio: nil, factor: 1) == nil)
        #expect(DocumentPrintLayout.scaleNote(drawnRatio: nil, factor: 0.5) == "Printed at 50 % — not to scale")
        // 1:50 at 25 % is 1:200; 1:20 at 40 % is 1:50.
        #expect(DocumentPrintLayout.printedRatio(drawn: 50, factor: 0.25) == 200)
        #expect(DocumentPrintLayout.printedRatio(drawn: 20, factor: 0.4) == 50)
    }

    @Test("The drawn ratio comes from the calibration: 1:100 is 100 × 0.0254 / 72 metres per point")
    func drawnRatioFromCalibration() {
        #expect(DocumentPrintLayout.drawnRatio(metresPerPoint: 100 * 0.0254 / 72, userUnit: 1) == 100)
        // The same nominal 1:100 on a /UserUnit 2 sheet carries twice the metres per unit.
        #expect(DocumentPrintLayout.drawnRatio(metresPerPoint: 2 * 100 * 0.0254 / 72, userUnit: 2) == 100)
        #expect(DocumentPrintLayout.drawnRatio(metresPerPoint: 0, userUnit: 1) == nil)
    }

    // MARK: - Tiling (never a silent shrink)

    @Test("An A0 sheet on A4 at Actual size tiles at 100 % with the configured overlap")
    func actualSizeTiles() {
        var options = DocumentPrintLayout.Options(scaleMode: .actualSize)
        options.tileOverlap = Self.mm(10)
        let layout = DocumentPrintLayout(sheets: [.init(size: Self.a0, drawnRatio: 100)], slot: Self.a4, options: options)
        // Columns: ceil((841 − 10) / (210 − 10)) = ceil(4.155) = 5; rows: ceil((1189 − 10) / (297 − 10)) = ceil(4.108) = 5.
        #expect(layout.pages.count == 25)
        #expect(layout.pages.allSatisfy { $0.factor == 1 }, "a tiled sheet is never shrunk")
        let last = try? #require(layout.pages.last?.tile)
        #expect(last?.cell == "E5")
        #expect(last?.lastCell == "E5")
        #expect(layout.pages.first?.tile?.cell == "A1")
    }

    @Test("Reassembled tiles cover the whole sheet, each step one page minus the overlap")
    func tilesCoverTheSheet() {
        var options = DocumentPrintLayout.Options(scaleMode: .actualSize)
        options.tileOverlap = Self.mm(10)
        let layout = DocumentPrintLayout(sheets: [.init(size: Self.a0, drawnRatio: nil)], slot: Self.a4, options: options)
        let union = layout.pages.reduce(CGRect.null) { $0.union($1.region) }
        #expect(union.minX <= 0.0001 && union.minY <= 0.0001)
        #expect(union.maxX >= Self.a0.width - 1 && union.maxY >= Self.a0.height - 1)
        // Neighbours overlap by exactly the overlap.
        let first = layout.pages[0].region, second = layout.pages[1].region
        #expect(abs((first.maxX - second.minX) - Self.mm(10)) < 0.001)
    }

    // MARK: - The print view draws what the options say

    static func sheet() -> FlattenPage {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 400, height: 300), crop: PDFRect(x: 0, y: 0, width: 400, height: 300)),
            rotation: .degrees0
        )
        let markup = RenderableMarkup(
            id: MarkupID(UUID()),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 60, y: 80), PDFPoint(x: 300, y: 250)], isClosed: false)),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 1), lineWidth: 2)
        )
        return FlattenPage(page: page, sourcePageIndex: 0, markups: [markup])
    }

    static func draw(_ view: DocumentPrintView, size: CGSize) throws -> Data {
        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer as CFMutableData))
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(NSRect(origin: .zero, size: view.frame.size))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return buffer as Data
    }

    @Test("The markups toggle changes the printed content")
    func markupsToggle() throws {
        let view = DocumentPrintView(sheets: [.init(flatten: Self.sheet())], content: nil)
        let on = FlattenedDrawingExportTests.pathPoints(in: try Self.draw(view, size: CGSize(width: 400, height: 300)), page: 1)
        view.options = DocumentPrintLayout.Options(scaleMode: .actualSize, includeMarkups: false)
        let off = FlattenedDrawingExportTests.pathPoints(in: try Self.draw(view, size: CGSize(width: 400, height: 300)), page: 1)
        #expect(on.count > off.count, "markups on: \(on.count) path points, off: \(off.count)")
    }

    @Test("Half size lays the sheet out at half its size, and the page count follows the options")
    func viewFollowsOptions() {
        let view = DocumentPrintView(sheets: [.init(flatten: Self.sheet(), drawnRatio: 100)], content: nil, slotSize: CGSize(width: 150, height: 150))
        view.options = DocumentPrintLayout.Options(scaleMode: .halfSize)
        var range = NSRange(location: 0, length: 0)
        #expect(view.knowsPageRange(&range))
        // Half of 400 × 300 is 200 × 150 on a 150 × 150 slot: tiled 2 × 1.
        #expect(range.length == 2)
        view.options = DocumentPrintLayout.Options(scaleMode: .fitToPaper)
        #expect(view.knowsPageRange(&range))
        #expect(range.length == 1)
        #expect(view.layout.pages[0].factor == 0.375)
    }
}
