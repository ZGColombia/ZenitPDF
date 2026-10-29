import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Iteration 1 re-fix: the items the independent review found still open
/// — K-11 (inline images and pattern cells), R-108 (object numbers near Int.max) and R-104 (sheet
/// names measured in code points). Each test says what the code before the re-fix did.
@Suite("Iteration 1 re-fix — PDF export", .sharedHeap, .serialized)
struct Iter1RExportPDFTests {

    // MARK: - K-11: an inline image in a form shared by a marked and a cropped unmarked sheet

    static let picture = Iter1RedactionFixTests.sharedPicture

    /// The review's fixture: one form holds the 32 × 32 picture as an ASCII-hex inline image;
    /// sheet 1 draws the form whole with the picture's left half under the box, sheet 2 shows only
    /// its right half through a clip.
    static func inlineImageFixture() -> Data {
        RedactionFixturePDF.assemble(pageCount: 2) { pdf, _ in
            let hex = picture.map { String(format: "%02X", $0) }.joined()
            let form = pdf.addStream("/Type /XObject /Subtype /Form /BBox [0 0 1 1]",
                                     "BI /W 32 /H 32 /BPC 8 /CS /RGB /F /AHx ID\n\(hex)>\nEI")
            let resources = "<< /XObject << /Fm1 \(form) 0 R >> >>"
            return ([
                HardeningPage("q 200 0 0 200 100 300 cm /Fm1 Do Q", resources: resources),
                HardeningPage("q 212 300 88 200 re W n 200 0 0 200 100 300 cm /Fm1 Do Q", resources: resources)
            ], "")
        }
    }

    static let box = CGRect(x: 95, y: 295, width: 110, height: 210)

    /// Sheet `index` of `source` drawn afresh through Core Graphics, as phase 1 draws an unmarked
    /// sheet: every picture it draws is written whole, whatever the clip.
    static func redrawnAfresh(_ source: Data, sheet index: Int) throws -> PDFPage {
        let document = try #require(PDFDocument(data: source))
        let page = try #require(document.page(at: index))
        let data = NSMutableData()
        var media = page.bounds(for: .mediaBox)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPage(mediaBox: &media)
        page.draw(with: .cropBox, to: context)
        context.endPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data)?.page(at: 0))
    }

    @Test("K-11: an inline image in a form under a box turns the unmarked sheet that crops it into a picture; no boxed row travels")
    func inlineImageInSharedForm() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("inline.pdf"), output = folder.appendingPathComponent("inline redacted.pdf")
        let data = Self.inlineImageFixture()
        try data.write(to: source)
        let document = try #require(PDFDocument(data: data))
        let marks = [0: [RedactionMark(pageIndex: 0, rect: Self.box)]]
        // Old: [] — no "EI" callback, so the inline image was never seen under the box.
        #expect(RasterSharedPictures.picturesUnderBoxes(document, marks: marks).count == 1)
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(document, marks: marks) == [1])

        let outcome = try RasterRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: Self.box)], to: output)
        // Old: the redaction succeeded with no such check, and sheet 2 carried a 3,072-byte image
        // holding all 32 rows of the boxed half.
        #expect(outcome.checks.contains { $0.contains("sheet 2 showed part of one and became a picture as well") }, "\(outcome.checks)")
        let images = try HardeningProof.decodedImages(output)
        for image in images {
            #expect(!Iter1RedactionFixTests.secretRuns().contains { HardeningProof.contains(Data(image), $0) }, "no row of the boxed half travels")
        }
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 1, boxes: [], delta: 48) <= 0.01,
                "sheet 2 still looks as it did")
    }

    @Test("K-11 proof step 5: the check sees a boxed picture that Core Graphics re-compressed into the copy, inline or XObject")
    func proofStepSeesRecompressedPictures() throws {
        let marks = [0: [RedactionMark(pageIndex: 0, rect: Self.box)]]
        for fixture in [Self.inlineImageFixture(), Iter1RedactionFixTests.sharedPictureFixture()] {
            let document = try #require(PDFDocument(data: fixture))
            let under = RasterSharedPictures.picturesUnderBoxes(document, marks: marks)
            #expect(under.count == 1)
            // Sheet 2 drawn afresh, as it was before K-11: the picture whole, re-written by Core
            // Graphics as a Flate-compressed image XObject.
            let leaked = try Self.redrawnAfresh(fixture, sheet: 1)
            // Old: empty for both — the inline image was never read, and the XObject's key held the
            // encoded stream length, which Core Graphics' re-compression changes.
            #expect(RasterSharedPictures.pictures(on: leaked, among: under) == under)
        }
    }

    @Test("K-11: a picture in a tiling pattern's cell counts; an inline image away from every box does not")
    func patternCellsAndInlineImagesAwayFromTheBox() throws {
        let hex = Self.picture.map { String(format: "%02X", $0) }.joined()
        let patterned = RedactionFixturePDF.assemble(pageCount: 2) { pdf, _ in
            let image = pdf.addStream(HardeningFixtures.imageDictionary(32, 32), Data(Self.picture))
            let pattern = pdf.addStream("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 200 200] /XStep 200 /YStep 200"
                                        + " /Matrix [1 0 0 1 100 300] /Resources << /XObject << /Im1 \(image) 0 R >> >>",
                                        "q 200 0 0 200 0 0 cm /Im1 Do Q")
            let resources = "<< /Pattern << /P1 \(pattern) 0 R >> >>"
            return ([
                HardeningPage("/Pattern cs /P1 scn 100 300 200 200 re f", resources: resources),
                HardeningPage("/Pattern cs /P1 scn 212 300 88 200 re f", resources: resources)
            ], "")
        }
        let marks = [0: [RedactionMark(pageIndex: 0, rect: Self.box)]]
        // Old: [] — the pattern cell was never read.
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(try #require(PDFDocument(data: patterned)), marks: marks) == [1])

        // The same inline image on both sheets, drawn at the top of sheet 1, far from the box.
        let away = RedactionFixturePDF.assemble(pageCount: 2) { _, _ in
            let inline = "BI /W 32 /H 32 /BPC 8 /CS /RGB /F /AHx ID\n\(hex)>\nEI"
            return ([
                HardeningPage("q 100 0 0 100 400 650 cm \(inline) Q", resources: "<< >>"),
                HardeningPage("q 450 650 50 100 re W n 100 0 0 100 400 650 cm \(inline) Q", resources: "<< >>")
            ], "")
        }
        let awayDocument = try #require(PDFDocument(data: away))
        #expect(RasterSharedPictures.picturesUnderBoxes(awayDocument, marks: marks).isEmpty)
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(awayDocument, marks: marks).isEmpty)
    }
}

// MARK: - R-108: an object header near Int.max

extension Iter1RExportPDFTests {

    /// A one-page drawing that also carries `number 0 obj << >> endobj`, as a top-level object
    /// and as a member of an object stream.
    static func drawingWithObject(_ number: Int) -> (topLevel: Data, inStream: Data) {
        var topLevel = RedactionFixturePDF.assemble(pageCount: 1) { _, _ in ([HardeningPage("0 0 10 10 re f", resources: "<< >>")], "") }
        topLevel.append(Data("\n\(number) 0 obj\n<< >>\nendobj\n".utf8))
        let header = "\(number) 0 "
        let inStream = RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            pdf.addStream("/Type /ObjStm /N 1 /First \(header.utf8.count)", header + "<< >>")
            return ([HardeningPage("0 0 10 10 re f", resources: "<< >>")], "")
        }
        return (topLevel, inStream)
    }

    @Test("R-108: an object numbered Int.max is not read, so every writer that allocates from nextObjectNumber runs")
    func objectHeaderAtIntMax() throws {
        let hostile = Self.drawingWithObject(Int.max)
        for data in [hostile.topLevel, hostile.inStream] {
            let scan = try PDFDocumentScan(data: data)
            #expect(scan.objects[Int.max] == nil)
            #expect(scan.nextObjectNumber <= PDFDocumentScan.maximumObjectNumber + 1)
            // Old: `max(highest, declared, 0) + 1` trapped (SIGTRAP, rc 133) with highest = Int.max,
            // so OCR's text layer, Sign, Save Markups into PDF and the annotated export all crashed.
            let empty = try SearchableTextLayerWriter().data(source: data, pages: [])
            #expect(PDFDocument(data: empty.data)?.pageCount == 1)
            let page = SearchableTextLayerWriter.Page(sourcePageIndex: 0, rotation: 0,
                                                      tokens: [.init(text: "Level", bounds: CGRect(x: 100, y: 100, width: 60, height: 12))])
            let written = try SearchableTextLayerWriter().data(source: data, pages: [page])
            let reopened = try #require(PDFDocument(data: written.data))
            #expect(reopened.page(at: 0)?.string?.contains("Level") == true)
        }
        // Just inside the bound the object is still read, as before.
        let inside = try PDFDocumentScan(data: Self.drawingWithObject(PDFDocumentScan.maximumObjectNumber).topLevel)
        #expect(inside.objects[PDFDocumentScan.maximumObjectNumber] != nil)
        #expect(inside.nextObjectNumber == PDFDocumentScan.maximumObjectNumber + 1)
    }
}

// MARK: - R-104: sheet names are measured in code points

extension Iter1RExportPDFTests {

    /// 31 characters and 32 code points: "ö" as "o" + U+0308, as a name pasted from a Finder file
    /// name arrives.
    static let decomposed = String(repeating: "x", count: 24) + "Fo\u{0308}nster"
    /// 32 characters, 38 code points: a family emoji is one character of seven code points.
    static let family = "Team \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} " + String(repeating: "z", count: 25)

    @Test("R-104: a name is cut to 31 code points, never inside a character, then stripped at both ends")
    func sheetNamesCountCodePoints() {
        #expect(Self.decomposed.count == 31 && Self.decomposed.unicodeScalars.count == 32)
        // Old: returned unchanged (31 characters), and libxlsxwriter refused its 32 code points.
        let accent = XLSXExporter.SheetNames.sanitised(Self.decomposed)
        #expect(accent == String(repeating: "x", count: 24) + "Fo\u{0308}nste")
        #expect(accent.unicodeScalars.count == 31)
        let emoji = XLSXExporter.SheetNames.sanitised(Self.family)
        #expect(emoji.unicodeScalars.count == 31)
        #expect(emoji == "Team \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} " + String(repeating: "z", count: 18))
        // A cut that would end in the middle of the family drops the whole character, then the
        // space before it.
        let tail = String(repeating: "y", count: 29) + " \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        #expect(XLSXExporter.SheetNames.sanitised(tail) == String(repeating: "y", count: 29))
        // One character of more than 31 code points leaves nothing: "Sheet".
        #expect(XLSXExporter.SheetNames.sanitised("e" + String(repeating: "\u{0301}", count: 40)) == "Sheet")
        // The suffix of a repeated name is counted the same way: "(2)" fits beside a whole "ö".
        var names = XLSXExporter.SheetNames()
        #expect(names.claim(Self.decomposed) == accent)
        let second = names.claim(Self.decomposed)
        #expect(second == String(repeating: "x", count: 24) + "Fo\u{0308} (2)", "\(second)")
        #expect(second.unicodeScalars.count <= 31)
        #expect(names.claim(Self.family).unicodeScalars.count <= 31)
        #expect(names.claim(Self.family).unicodeScalars.count <= 31)
    }

    /// The golden ledger with its subjects renamed: even rows `even`, odd rows `odd`.
    static func report(subjects even: String, _ odd: String) throws -> LedgerReport {
        let golden = try ExportFixture.goldenStore()
        let markups = (0..<golden.rowCount).map { index -> MarkupRecord in
            var record = golden.record(at: index)
            record.subject = index % 2 == 0 ? even : odd
            return record
        }
        let store = try LedgerStore(markups: markups, columns: golden.columns)
        let spec = LedgerViewSpec(grouping: [LedgerGroupingField(column: ExportFixture.standardID(.subject))], aggregation: ExportFixture.plan)
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch)).makeReport(store.makeView(spec), title: "Groups")
    }

    @Test("R-104: an XLSX export with group sheets named by a decomposed accent and an emoji sequence is written")
    func groupSheetsWithLongUnicodeLabels() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = XLSXExportOptions(includeUnitColumns: false)
        options.includeGroupSheets = true
        // Old: ExportError.xlsx(worksheetCreationFailed) — "exceeds Excel's limit of 31
        // characters" for the 32-code-point group label, and the whole export failed.
        try XLSXExporter().export(try ExportFixture.projection(try Self.report(subjects: Self.decomposed, Self.family)), to: url, options: options)
        let workbook = try XLSXInspector.entry("xl/workbook.xml", of: url)
        for name in [XLSXExporter.SheetNames.sanitised(Self.decomposed), XLSXExporter.SheetNames.sanitised(Self.family)] {
            #expect(workbook.contains("name=\"\(name)\""), "\(name) in \(workbook)")
        }
    }
}
