import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// Iteration 1: redaction findings R-098, R-099, R-103, R-107, R-114 and K-11.
/// Each test says what the code before the fix did.
@Suite("Iteration 1 — redaction fixes", .sharedHeap, .serialized)
struct Iter1RedactionFixTests {

    /// A title block drawn by Core Text: the lines a box is most often drawn over on a
    /// construction sheet, plus one that stays. Sheet 2 holds `secondSheet`.
    static func titleBlock(at url: URL, lines: [String], secondSheet: String = "General notes") throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        func text(_ string: String, at point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260), width: 1)
        for (index, line) in lines.enumerated() { text(line, at: CGPoint(x: 40, y: 240 - Double(index) * 40)) }
        text("Kept line outside every box", at: CGPoint(x: 40, y: 40))
        context.endPDFPage()
        context.beginPDFPage(nil)
        text(secondSheet, at: CGPoint(x: 40, y: 150))
        context.endPDFPage()
        context.closePDF()
    }

    /// A box around one line of the title block, from the line's own typographic bounds at the
    /// place `titleBlock` draws it (14-pt Helvetica, 40 pt apart, so neighbouring boxes do not meet).
    static func box(around text: String, lines: [String]) throws -> CGRect {
        let index = try #require(lines.firstIndex(of: text))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGRect(x: 36, y: 240 - Double(index) * 40 - 6, width: width + 8, height: 22)
    }

    // MARK: - R-098: the removed-word search looked in the raw bytes

    static let titleLines = ["Date: 2026-09-01", "Page 1 of 2", "Floor Plan Level 2"]

    @Test("R-098 phase 1: boxes over “Date:”, “Page 1 of 2” and a word of the output's file name are accepted")
    func rasterTitleBlock() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Floor Plan Level 2.pdf")
        // The app's default output name: "<drawing name> — Redacted".
        let output = folder.appendingPathComponent("Floor Plan Level 2 — Redacted.pdf")
        try Self.titleBlock(at: source, lines: Self.titleLines)
        let marks = try Self.titleLines.map { RedactionMark(pageIndex: 0, rect: try Self.box(around: $0, lines: Self.titleLines)) }

        // Old: RedactionRefusal.checkFailed("a removed word is still in the file") — "Date" is in
        // /CreationDate, "Page" in /Type /Page, "Floor" in the /Title written from the file name.
        let outcome = try RasterRedactor.redact(source: source, marks: marks, to: output)
        #expect(outcome.removedWordCount >= 5)
        let strings = RedactionWordSearch.fileStrings(try PDFDocumentScan(data: try Data(contentsOf: output)))
        for word in ["2026-09-01", "Floor", "Plan", "Level"] {
            #expect(!strings.contains { RedactionWordSearch.contains(word, in: $0) }, "\(word) is in no string of the copy")
        }
        let info = try #require(PDFDocument(url: output)).documentAttributes ?? [:]
        #expect(info[PDFDocumentAttribute.titleAttribute] == nil, "the output's file name is no longer written as its title")
        #expect(info[PDFDocumentAttribute.creatorAttribute] == nil)
    }

    @Test("R-098 phase 2: the same title-block boxes are accepted by the vector verifier")
    func vectorTitleBlock() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Floor Plan Level 2.pdf")
        let output = folder.appendingPathComponent("Floor Plan Level 2 — Redacted.pdf")
        try Self.titleBlock(at: source, lines: Self.titleLines)
        let marks = try Self.titleLines.map { RedactionMark(pageIndex: 0, rect: try Self.box(around: $0, lines: Self.titleLines)) }

        // Old: checkFailed("a removed word is still in the file") — "Page" stood only under the
        // boxes and the case-sensitive search ran over the raw bytes, which carry /Type /Page.
        let outcome = try VectorRedactor.redact(source: source, marks: marks, to: output)
        #expect(outcome.vectorPages == [0])
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(text.contains("Kept line outside every box"))
        #expect(!text.contains("2026-09-01") && !text.contains("Floor"))
    }

    @Test("Phase 2: two overlapping boxes are accepted — the black boxes' own edges are not a path under the other box")
    func overlappingBoxes() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sheet.pdf"), output = folder.appendingPathComponent("sheet redacted.pdf")
        try Self.titleBlock(at: source, lines: Self.titleLines)
        let first = try Self.box(around: "Date: 2026-09-01", lines: Self.titleLines)
        let second = try Self.box(around: "Page 1 of 2", lines: Self.titleLines).union(first.offsetBy(dx: 30, dy: -10))
        #expect(first.intersects(second))
        // Old: checkFailed("a path still runs inside a box on sheet 1") — the readback met the
        // edge of the first black box inside the second.
        let outcome = try VectorRedactor.redact(source: source, marks: [first, second].map { RedactionMark(pageIndex: 0, rect: $0) }, to: output)
        #expect(outcome.vectorPages == [0])
        let text = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        #expect(!text.contains("2026-09-01") && text.contains("Floor Plan Level 2"))
    }

    // MARK: - R-099: whole words only

    @Test("R-099: “and” under a box is not “Standard” on the next sheet — both methods accept; a real repeat still refuses")
    func wholeWordsOnOtherSheets() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("set.pdf")
        try Self.titleBlock(at: source, lines: ["Smith and Partners"], secondSheet: "Standard details")
        let mark = RedactionMark(pageIndex: 0, rect: try Self.box(around: "Smith and Partners", lines: ["Smith and Partners"]))

        // Old (phase 1): checkFailed("“and” is still readable on sheet 2; mark it there as well").
        _ = try RasterRedactor.redact(source: source, marks: [mark], to: folder.appendingPathComponent("raster.pdf"))
        // Old (phase 2): the same sentence, from the substring count in VectorRedactor.occurrences.
        _ = try VectorRedactor.redact(source: source, marks: [mark], to: folder.appendingPathComponent("vector.pdf"))

        let repeated = folder.appendingPathComponent("repeated.pdf")
        try Self.titleBlock(at: repeated, lines: ["Smith and Partners"], secondSheet: "Copy to Partners")
        let repeatedMark = RedactionMark(pageIndex: 0, rect: try Self.box(around: "Smith and Partners", lines: ["Smith and Partners"]))
        #expect(throws: RedactionRefusal.checkFailed("“Partners” is still readable on sheet 2; mark it there as well")) {
            try RasterRedactor.redact(source: repeated, marks: [repeatedMark], to: folder.appendingPathComponent("r2.pdf"))
        }
    }

    @Test("R-099: whole-word counting, by hand")
    func wholeWordCounting() {
        #expect(RedactionWordSearch.occurrences(of: "and", in: "Standard details and notes") == 1)
        #expect(RedactionWordSearch.occurrences(of: "and", in: "Standard sandbox") == 0)
        #expect(RedactionWordSearch.occurrences(of: "BIDAMOUNT", in: "BIDAMOUNT 4820000, again BIDAMOUNT.") == 2)
        #expect(RedactionWordSearch.occurrences(of: "BIDAMOUNT", in: "XBIDAMOUNT") == 0)
        #expect(RedactionWordSearch.occurrences(of: "falcon", in: "Project FALCON", caseInsensitive: true) == 1)
        #expect(RedactionWordSearch.occurrences(of: "$4,820", in: "Total$4,820 due") == 1, "a figure starting with a symbol needs no boundary before it")
        #expect(RedactionWordSearch.occurrences(of: "2026-09-01", in: "Date: 2026-09-01") == 1)
        #expect(RedactionWordSearch.occurrences(of: "aa", in: "aaa aa") == 1)
    }

    // MARK: - R-103 / R-114: the output is never the source, and no staging file is left behind

    @Test("R-103: a redaction whose output is the drawing itself — by path or through a symlink — is refused and the drawing untouched")
    func redactionRefusesItsSource() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tender.pdf")
        try RedactionFixturePDF.tender(at: source)
        let original = try Data(contentsOf: source)
        let link = folder.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let mark = RedactionMark(pageIndex: 0, rect: NLPDFR2RedactionTests.secretRect)
        for output in [source, link, URL(fileURLWithPath: folder.path + "/./tender.pdf")] {
            // Old: the drawing was replaced by its redacted picture copy.
            #expect(throws: RedactionRefusal.outputIsSource) { try RasterRedactor.redact(source: source, marks: [mark], to: output) }
            #expect(throws: RedactionRefusal.outputIsSource) { try VectorRedactor.redact(source: source, marks: [mark], to: output) }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("R-114: when the final move fails, phase 1 leaves no hidden staging file in the folder")
    func rasterCleansUpStaging() throws {
        let folder = try RedactionProof.folder()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.appendingPathComponent("locked.pdf").path)
            try? FileManager.default.removeItem(at: folder)
        }
        let source = folder.appendingPathComponent("tender.pdf")
        try RedactionFixturePDF.tender(at: source)
        let locked = folder.appendingPathComponent("locked.pdf")
        try Data("previous".utf8).write(to: locked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let mark = RedactionMark(pageIndex: 0, rect: NLPDFR2RedactionTests.secretRect)
        #expect(throws: (any Error).self) { try RasterRedactor.redact(source: source, marks: [mark], to: locked) }
        // Old: ".zpdf-redact-<UUID>.pdf" stayed in the folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".zpdf-") }
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    // MARK: - K-11: a picture under a box, shown cropped on an unmarked sheet

    /// 32 × 32 RGB picture; sheet 1 draws it whole with its left half under the box, sheet 2 shows
    /// only its right half through a clip.
    static let sharedPicture = HardeningFixtures.rgb(32, 32, seed: 11)

    static func sharedPictureFixture() -> Data {
        RedactionFixturePDF.assemble(pageCount: 2) { pdf, _ in
            let image = pdf.addStream(HardeningFixtures.imageDictionary(32, 32), Data(sharedPicture))
            let resources = "<< /XObject << /Im1 \(image) 0 R >> >>"
            return ([
                HardeningPage("q 200 0 0 200 100 300 cm /Im1 Do Q", resources: resources),
                HardeningPage("q 212 300 88 200 re W n 200 0 0 200 100 300 cm /Im1 Do Q", resources: resources)
            ], "")
        }
    }

    /// The rows of the picture's left half (columns 0-13), which lie under the box on sheet 1.
    static func secretRuns() -> [[UInt8]] {
        (0..<32).map { row in Array(sharedPicture[(row * 32 * 3)..<(row * 32 * 3 + 14 * 3)]) }
    }

    @Test("K-11: phase 1 turns an unmarked sheet that shows a boxed picture cropped into a picture of what it shows")
    func rasterSharedPicture() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("shared.pdf"), output = folder.appendingPathComponent("shared redacted.pdf")
        try Self.sharedPictureFixture().write(to: source)
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 95, y: 295, width: 110, height: 210))
        let sourceImages = try HardeningProof.decodedImages(source)
        #expect(sourceImages.contains { image in Self.secretRuns().allSatisfy { HardeningProof.contains(Data(image), $0) } },
                "the fixture's picture carries the secret half")

        let outcome = try RasterRedactor.redact(source: source, marks: [mark], to: output)
        // Old: sheet 2 was drawn afresh through Core Graphics, which wrote the 32 × 32 picture whole
        // — its left half, under the box on sheet 1, included.
        for image in try HardeningProof.decodedImages(output) {
            #expect(!Self.secretRuns().contains { HardeningProof.contains(Data(image), $0) }, "no row of the boxed half travels")
        }
        #expect(outcome.checks.contains { $0.contains("sheet 2 showed part of one and became a picture as well") }, "\(outcome.checks)")
        #expect((PDFDocument(url: output)?.page(at: 1)?.string ?? "").isEmpty)
        #expect(try RedactionProof.changedShareOutside(source: source, output: output, page: 1, boxes: [], delta: 48) <= 0.01,
                "sheet 2 still looks as it did")
    }

    @Test("K-11: the vector path's whole-document fallback (an encrypted drawing) does the same")
    func encryptedFallbackSharedPicture() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("locked.pdf"), output = folder.appendingPathComponent("locked redacted.pdf")
        // The same two sheets, written by Core Graphics with a password, so the object layer
        // cannot read it and the vector path hands the whole redaction to phase 1.
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(source as CFURL, mediaBox: &media, [
            kCGPDFContextUserPassword: "open", kCGPDFContextOwnerPassword: "owner"
        ] as CFDictionary))
        let provider = try #require(CGDataProvider(data: Data(Self.sharedPicture) as CFData))
        let picture = try #require(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 96,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        context.beginPDFPage(nil)
        context.draw(picture, in: CGRect(x: 100, y: 300, width: 200, height: 200))
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.clip(to: CGRect(x: 212, y: 300, width: 88, height: 200))
        context.draw(picture, in: CGRect(x: 100, y: 300, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()
        let mark = RedactionMark(pageIndex: 0, rect: CGRect(x: 95, y: 295, width: 110, height: 210))

        let outcome = try VectorRedactor.redact(source: source, password: "open", marks: [mark], to: output)
        #expect(outcome.rasterFallbacks.map(\.pageIndex) == [0], "the whole redaction ran as phase 1")
        // Old: sheet 2 carried the picture whole in the unencrypted copy.
        for image in try HardeningProof.decodedImages(output) {
            #expect(!Self.secretRuns().contains { HardeningProof.contains(Data(image), $0) })
        }
        #expect(outcome.checks.contains { $0.contains("sheet 2 showed part of one") }, "\(outcome.checks)")
    }

    @Test("K-11: a picture under a box that no other sheet draws turns no unmarked sheet into a picture")
    func unsharedPictureStaysVector() throws {
        let data = RedactionFixturePDF.assemble(pageCount: 2) { pdf, _ in
            let image = pdf.addStream(HardeningFixtures.imageDictionary(32, 32), Data(Self.sharedPicture))
            let other = pdf.addStream(HardeningFixtures.imageDictionary(32, 32), Data(HardeningFixtures.rgb(32, 32, seed: 12)))
            return ([
                HardeningPage("q 200 0 0 200 100 300 cm /Im1 Do Q", resources: "<< /XObject << /Im1 \(image) 0 R >> >>"),
                HardeningPage("q 200 0 0 200 100 300 cm /Im2 Do Q", resources: "<< /XObject << /Im2 \(other) 0 R >> >>")
            ], "")
        }
        let document = try #require(PDFDocument(data: data))
        let marks = [0: [RedactionMark(pageIndex: 0, rect: CGRect(x: 95, y: 295, width: 110, height: 210))]]
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(document, marks: marks).isEmpty)
        let shared = try #require(PDFDocument(data: Self.sharedPictureFixture()))
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(shared, marks: marks) == [1])
        // A box that misses the picture: nothing lies under it, nothing becomes a picture.
        let away = [0: [RedactionMark(pageIndex: 0, rect: CGRect(x: 400, y: 50, width: 40, height: 40))]]
        #expect(RasterSharedPictures.unmarkedSheetsSharingPictures(shared, marks: away).isEmpty)
    }
}

// MARK: - R-107, R-108, R-111

extension Iter1RedactionFixTests {

    @Test("R-107: RunLength and ASCII85 “z” stop at the size limit while decoding, not after")
    func expandingFiltersAreBounded() throws {
        // 2 input bytes → 128 output bytes, 64 times over: 8 KiB from 128 bytes.
        let bomb = Data((0..<64).flatMap { _ in [UInt8(129), 0x41] })
        #expect(try RedactionStreamFilters.runLength(bomb).count == 8_192)
        // Old: runLength(_:) had no limit; it produced every byte and decode() compared the size
        // only after the filter had finished (a limit-sized Flate stream behind it: ~16 GB).
        #expect(throws: RedactionUnsupported.self) { try RedactionStreamFilters.runLength(bomb, limit: 4_096) }
        let zeros = Data(("<~" + String(repeating: "z", count: 2_000) + "~>").utf8)
        #expect(try RedactionStreamFilters.ascii85(zeros).count == 8_000)
        #expect(throws: RedactionUnsupported.self) { try RedactionStreamFilters.ascii85(zeros, limit: 4_000) }
        // Through the chain, with the limit the redaction reads pages under.
        let dictionary: [String: PDFObject] = ["Filter": .array([.name("ASCIIHexDecode"), .name("RunLengthDecode")])]
        let hex = Data(bomb.map { String(format: "%02X", $0) }.joined().utf8)
        #expect(throws: RedactionUnsupported.self) { try RedactionStreamFilters.decode(dictionary: dictionary, data: hex, limit: 1_000) }
        #expect(try RedactionStreamFilters.decode(dictionary: dictionary, data: hex).data.count == 8_192)
    }

    @Test("R-108: an xref subsection or /Index starting near Int.max is ignored, not an overflow trap")
    func hostileCrossReferenceStart() throws {
        var pdf = Data(RedactionFixturePDF.assemble(pageCount: 1) { _, _ in ([HardeningPage("0 0 10 10 re f", resources: "<< >>")], "") })
        // An appended revision whose table starts at 9223372036854775806 with three entries.
        let table = "xref\n9223372036854775806 3\n0000000000 65535 f \n0000000000 65535 f \n0000000000 65535 f \n"
            + "trailer\n<< /Size 5 /Root 1 0 R /Prev 0 >>\nstartxref\n\(pdf.count)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        // Old: `start + index` overflowed at index 2 and trapped (only with free entries honoured —
        // the redaction path).
        let scan = try PDFDocumentScan(data: pdf, honoringFreeEntries: true)
        #expect(try scan.pages().count == 1)

        var stream = Data(RedactionFixturePDF.assemble(pageCount: 1) { pdf, _ in
            pdf.addStream("/Type /XRef /W [1 1 1] /Index [9223372036854775806 3] /Size 5", Data([0, 0, 0, 0, 0, 0, 0, 0, 0]))
            return ([HardeningPage("0 0 10 10 re f", resources: "<< >>")], "")
        })
        stream.append(Data("% end\n".utf8))
        let streamScan = try PDFDocumentScan(data: stream, honoringFreeEntries: true)
        #expect(try streamScan.pages().count == 1)
        // /Size at Int.min no longer underflows the next free object number.
        let sized = Data(String(decoding: RedactionFixturePDF.assemble(pageCount: 1) { _, _ in ([HardeningPage("", resources: "<< >>")], "") }, as: UTF8.self)
            .replacingOccurrences(of: "/Size 5", with: "/Size -9223372036854775808").utf8)
        #expect(try PDFDocumentScan(data: sized).nextObjectNumber >= 1)
    }

    @Test("R-111: a thick stroke whose centreline runs just outside a box is cut where it inks inside it")
    func thickStrokeBesideABox() throws {
        let folder = try RedactionProof.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("wall.pdf"), output = folder.appendingPathComponent("wall redacted.pdf")
        // A 20-pt wall line along x = 195; the box starts at x = 200, so 5 pt of ink lie inside it.
        let data = RedactionFixturePDF.assemble(pageCount: 1) { _, _ in
            ([HardeningPage("q 20 w 0 0 0 RG 195 100 m 195 700 l S Q", resources: "<< >>")], "")
        }
        try data.write(to: source)
        let box = CGRect(x: 200, y: 300, width: 100, height: 100)
        // Old: checkFailed("something is still painted under a box on sheet 1") — the centreline
        // hull did not meet the box, so the stroke was copied uncut.
        let outcome = try VectorRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: box)], to: output)
        #expect(outcome.vectorPages == [0])
        let render = try HardeningProof.coreGraphicsRender(output, page: 0)
        let wallOutside = CGRect(x: 187, y: 500, width: 6, height: 100).applying(render.transform).standardized
        #expect(HardeningProof.brightestMean(render.bitmap, inside: wallOutside) < 60, "the wall is still drawn outside the box")
    }
}
