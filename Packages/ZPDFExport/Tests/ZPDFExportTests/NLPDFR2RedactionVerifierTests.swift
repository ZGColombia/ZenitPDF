import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// The verifier catches each known class of leak on its own: every test here
/// hands it a copy built the leaky way (the old behaviour, reproduced by switching the fix off for
/// that one build) and expects the copy to be refused before anything is written.
@Suite("Redaction verifier catches each leak class (r2-redaction-fix)", .sharedHeap, .serialized)
struct NLPDFR2RedactionVerifierTests {

    func prepareSource(_ data: Data, boxes: [CGRect], page: Int = 0) throws -> (VectorRedactor.Prepared, URL) {
        let folder = try RedactionProof.folder()
        let source = folder.appendingPathComponent("source.pdf")
        try data.write(to: source)
        let prepared = try VectorRedactor.prepare(source: source, password: nil, marks: boxes.map { RedactionMark(pageIndex: page, rect: $0) })
        return (prepared, folder)
    }

    func expectRefused(_ built: VectorRedactor.Built, _ prepared: VectorRedactor.Prepared, mentioning phrase: String) {
        do {
            _ = try VectorRedactor.verify(built, prepared: prepared)
            Issue.record("the leaky copy was accepted")
        } catch let refusal as RedactionRefusal {
            #expect(refusal.description.contains(phrase), "\(refusal.description)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// Findings 4 and 8: an unmarked sheet kept with the shared dictionary (the old copy).
    @Test("Check 1b refuses a copy that carries the original of a picture cut under a box through a shared resource dictionary")
    func sharedDictionaryOriginal() throws {
        var (prepared, folder) = try prepareSource(HardeningFixtures.sharedResources(.twoSheets), boxes: [CGRect(x: 190, y: 290, width: 220, height: 220)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(prepared.context)
        context.dirty = []  // the unmarked sheet is not rewritten: its shared dictionary travels whole
        prepared.context = context
        let built = try VectorRedactor.build(prepared, scan: try #require(prepared.scan), entries: try #require(prepared.entries), dpi: 150)
        expectRefused(built, prepared, mentioning: "cut under a box is still in the file")
    }

    /// Finding 8: the cropped placement keeps the original (the old copy).
    @Test("Check 1b refuses a copy that keeps the whole original for a placement that shows only part of it")
    func croppedPlacementOriginal() throws {
        var (prepared, folder) = try prepareSource(HardeningFixtures.croppedImageFixture(), boxes: [CGRect(x: 190, y: 290, width: 220, height: 220)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(prepared.context), entries = try #require(prepared.entries)
        // Rewritten without examining other uses (as before the fix), still recording what was cut.
        context.surveying = true
        prepared.rewritten[0] = try VectorRedactor.rewritePage(entries[0], boxes: [CGRect(x: 190, y: 290, width: 220, height: 220)], context: context)
        context.surveying = false
        let built = try VectorRedactor.build(prepared, scan: try #require(prepared.scan), entries: entries, dpi: 150)
        expectRefused(built, prepared, mentioning: "cut under a box is still in the file")
    }

    /// Findings 1, 5, 15: the pattern cell copied unchanged (the old copy).
    @Test("The readback refuses a copy whose tiling-pattern cell still draws under a box")
    func patternCellUnderBox() throws {
        let boxes = [CGRect(x: 90, y: 490, width: 200, height: 30), CGRect(x: 300, y: 100, width: 100, height: 40)]
        var (prepared, folder) = try prepareSource(HardeningFixtures.wholeSheetPattern(), boxes: boxes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = try #require(prepared.scan), entries = try #require(prepared.entries), context = try #require(prepared.context)
        prepared.rewritten[0]?.operations = try RedactionContentLexer.parse(try VectorRedactor.pageContent(entries[0], context: context))
        prepared.rewritten[0]?.resources = scan.dictionary(entries[0].inheritedResources) ?? [:]
        var built = try VectorRedactor.build(prepared, scan: scan, entries: entries, dpi: 150)
        built.tainted = []  // leave only the readback to find it
        expectRefused(built, prepared, mentioning: "under a box")
    }

    /// Finding 6: the shading kept inside a clip to the box (the old copy).
    @Test("The readback refuses a copy that still paints a shading under a box")
    func shadingUnderBox() throws {
        var (prepared, folder) = try prepareSource(HardeningFixtures.sampledShading(), boxes: [CGRect(x: 200, y: 300, width: 200, height: 200)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = try #require(prepared.scan), entries = try #require(prepared.entries), context = try #require(prepared.context)
        prepared.rewritten[0]?.operations = try RedactionContentLexer.parse(try VectorRedactor.pageContent(entries[0], context: context))
        prepared.rewritten[0]?.resources = scan.dictionary(entries[0].inheritedResources) ?? [:]
        var built = try VectorRedactor.build(prepared, scan: scan, entries: entries, dpi: 150)
        built.tainted = []
        expectRefused(built, prepared, mentioning: "shading is painted under a box")
    }

    /// Finding 14: phase 1's picture drawn with the page transform applied twice (the old copy).
    @Test("Phase 1's proof refuses a picture whose drawing applied the page transform twice")
    func doubledTransform() throws {
        let data = HardeningFixtures.rotatedSheet(rotate: 90, crop: nil, standardFont: true)
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let mark = RedactionMark(pageIndex: 0, rect: HardeningFixtures.rotatedMark)
        // The old drawRaster: transform(for:) concatenated, then draw(with:to:) — which applies it again.
        let size = RasterRedactor.displayedSize(of: page)
        let scale = 300.0 / 72
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let raster = try #require(CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                            bytesPerRow: Int(pixels.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        raster.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        raster.fill(CGRect(origin: .zero, size: pixels))
        raster.scaleBy(x: pixels.width / size.width, y: pixels.height / size.height)
        raster.concatenate(page.transform(for: .cropBox))
        page.draw(with: .cropBox, to: raster)
        raster.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        raster.fill(mark.rect)
        let image = try #require(raster.makeImage())
        let bytes = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: bytes as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPage(mediaBox: &box)
        context.draw(image, in: box)
        context.endPage()
        context.closePDF()
        #expect(throws: RedactionRefusal.self) {
            try RasterRedactor.verify(bytes as Data, source: document, marks: [0: [mark]], words: [])
        }
    }

    /// Finding 12: a sheet taken from an earlier revision (the old reading of the trailer).
    @Test("Check 8 refuses a copy whose sheet without a box does not look like the drawing's")
    func unmarkedSheetFromAnotherRevision() throws {
        let data = HardeningFixtures.mixedCrossReferenceChain()
        let (prepared, folder) = try prepareSource(data, boxes: [CGRect(x: 60, y: 690, width: 300, height: 40)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let scan = try #require(prepared.scan)
        var entries = try #require(prepared.entries)
        // Revision 1's sheet 2 (object 4, with the photo) in place of revision 2's.
        let old = try #require(scan.dictionary(PDFObject.reference(number: 4, generation: 0)))
        entries[1] = PDFDocumentScan.PageEntry(
            number: 4, dictionary: old, inheritedResources: old["Resources"], inheritedVisibleBox: old["MediaBox"],
            inheritedRotation: nil, inheritedMediaBox: old["MediaBox"], inheritedCropBox: nil
        )
        let built = try VectorRedactor.build(prepared, scan: scan, entries: entries, dpi: 150)
        expectRefused(built, prepared, mentioning: "sheet 2 changed")
    }

    /// Finding 2: a value that showed only under the box, repeated in a hidden field elsewhere.
    @Test("Check 5b refuses a copy that still carries a form value that showed only under the box")
    func removedFieldValue() throws {
        let data = RedactionFixturePDF.assemble(pageCount: 1) { pdf, pages in
            let font = pdf.add(RedactionFixturePDF.helveticaWithWidths)
            let field = pdf.reserve(), copy = pdf.reserve()
            let visible = pdf.add("<< /Type /Annot /Subtype /Widget /Parent \(field) 0 R /Rect [100 695 320 725] /F 4 /P \(pages[0]) 0 R >>")
            let hidden = pdf.add("<< /Type /Annot /Subtype /Widget /Parent \(copy) 0 R /Rect [100 100 320 130] /F 2 /P \(pages[0]) 0 R >>")
            pdf.set(field, "<< /FT /Tx /T (codename) /V (FALCON-7731) /Kids [\(visible) 0 R] >>")
            pdf.set(copy, "<< /FT /Tx /T (archive) /V (FALCON-7731) /Kids [\(hidden) 0 R] >>")
            return ([HardeningPage("BT /F1 12 Tf 72 400 Td (Form sheet) Tj ET", resources: "<< /Font << /F1 \(font) 0 R >> >>",
                                   extras: "/Annots [\(visible) 0 R \(hidden) 0 R]")],
                    "/AcroForm << /Fields [\(field) 0 R \(copy) 0 R] >>")
        }
        let (prepared, folder) = try prepareSource(data, boxes: [CGRect(x: 90, y: 690, width: 240, height: 40)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = try VectorRedactor.build(prepared, scan: try #require(prepared.scan), entries: try #require(prepared.entries), dpi: 150)
        #expect(built.removedFieldValues.contains("FALCON-7731"))
        expectRefused(built, prepared, mentioning: "removed form value is still in the file")
    }

    /// Finding 3: the word under the box repeated, in another case, in a note kept elsewhere.
    @Test("Check 5 finds a removed word in any case in a string the copy carries")
    func removedWordInAnotherCase() throws {
        let data = RedactionFixturePDF.document(
            pages: [("BT /F1 24 Tf 100 700 Td (PROJECT FALCON) Tj ET BT /F1 12 Tf 72 400 Td (Body text here.) Tj ET", "[NOTE]")],
            resources: "<< /Font << /F1 HELV >> >>",
            mediaBox: "[0 0 612 792]",
            extraObjects: { pdf in
                let font = pdf.add(RedactionFixturePDF.helveticaWithWidths)
                let note = pdf.add("<< /Type /Annot /Subtype /Text /Rect [500 100 520 120] /Contents (the project falcon review) >>")
                return ["HELV": "\(font) 0 R", "NOTE": "\(note) 0 R"]
            }
        )
        let (prepared, folder) = try prepareSource(data, boxes: [CGRect(x: 90, y: 690, width: 340, height: 40)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let built = try VectorRedactor.build(prepared, scan: try #require(prepared.scan), entries: try #require(prepared.entries), dpi: 150)
        expectRefused(built, prepared, mentioning: "removed word is still in the file")
    }

    /// Findings 10, 13, 17: what check 1 refuses wherever it sits.
    @Test("Check 1 refuses an untyped embedded file, an associated file, a file-attachment note and a PostScript alternate")
    func carriedFiles() {
        let cases: [PDFObject] = [
            .dictionary(["Type": .name("Filespec"), "EF": .dictionary(["F": .reference(number: 3, generation: 0)])]),
            .dictionary(["Subtype": .name("Image"), "AF": .array([.reference(number: 4, generation: 0)])]),
            .dictionary(["Type": .name("Annot"), "Subtype": .name("FileAttachment")]),
            .dictionary(["Subtype": .name("Form"), "Subtype2": .name("PS"), "PS": .reference(number: 5, generation: 0)]),
            .array([.dictionary(["Kids": .array([.dictionary(["EF": .null])])])])
        ]
        for object in cases {
            #expect(throws: RedactionRefusal.self) { try VectorRedactor.refuseCarriedFiles(object, depth: 0) }
        }
        #expect(throws: Never.self) { try VectorRedactor.refuseCarriedFiles(.dictionary(["Type": .name("Filespec"), "F": .string(Array("a.pdf".utf8))]), depth: 0) }
    }
}
