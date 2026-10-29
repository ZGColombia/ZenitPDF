import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// NL-PDF-14: a redaction that truly removes — text, annotations and metadata under the boxes
/// gone, the rest of the sheet unchanged, and a copy that fails any check never kept.
@Suite("Redaction, phase 1 (NL-PDF-14)", .sharedHeap, .serialized)
struct NLPDFR2RedactionTests {

    static let secretRect = CGRect(x: 60, y: 180, width: 300, height: 40)

    /// Two 420 × 300 sheets. Sheet 1: a bid figure inside `secretRect`, a title outside it, a
    /// reviewer's note annotation on the figure, drawing linework. Sheet 2: other text. The file
    /// carries an author in its metadata.
    static func fixture(at url: URL, secretOnSheetTwo: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextAuthor: "Estimator Name"] as CFDictionary))
        func text(_ string: String, at point: CGPoint, size: CGFloat = 18) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260), width: 2)
        text("Tender summary", at: CGPoint(x: 60, y: 250))
        text("BIDAMOUNT 4820000 SEK", at: CGPoint(x: 70, y: 192))
        context.endPDFPage()
        context.beginPDFPage(nil)
        text(secretOnSheetTwo ? "Repeat BIDAMOUNT here" : "Level 3 plan notes", at: CGPoint(x: 60, y: 150))
        context.endPDFPage()
        context.closePDF()
        // A reviewer's note on the figure, written by PDFKit.
        let document = try #require(PDFDocument(url: url))
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 185, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "privatenote about the bid"
        document.page(at: 0)?.addAnnotation(note)
        #expect(document.write(to: url))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Under the box: no text, no word in the decompressed file, no annotation, no metadata; outside it: unchanged")
    func redactsTruly() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tender.pdf"), output = folder.appendingPathComponent("tender redacted.pdf")
        try Self.fixture(at: source)
        let original = try Data(contentsOf: source)
        let before = try #require(PDFDocument(url: source))
        #expect(before.page(at: 0)?.selection(for: Self.secretRect)?.string?.contains("4820000") == true, "the fixture's secret is really there")

        // Old behaviour: no redaction existed; a box drawn over the figure left the text under it.
        let outcome = try RasterRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: Self.secretRect)], to: output)
        #expect(outcome.redactedPages == [0])
        #expect(outcome.removedWordCount >= 2)
        #expect(outcome.checks.count == 4)
        #expect(try Data(contentsOf: source) == original, "the drawing itself is untouched")

        let after = try #require(PDFDocument(url: output))
        #expect((after.page(at: 0)?.string ?? "").isEmpty, "nothing extractable on the redacted sheet")
        #expect(after.page(at: 0)?.selection(for: Self.secretRect)?.string?.isEmpty ?? true)
        #expect(after.page(at: 0)?.annotations.isEmpty == true)
        #expect(after.page(at: 1)?.string?.contains("Level 3 plan notes") == true, "an unmarked sheet keeps its text")
        let bytes = try Data(contentsOf: output)
        #expect(bytes.range(of: Data("4820000".utf8)) == nil)
        #expect(bytes.range(of: Data("privatenote".utf8)) == nil)
        #expect(bytes.range(of: Data("Estimator Name".utf8)) == nil, "the original's metadata is not carried")
        #expect((after.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) == nil)
    }

    @Test("A removed word still readable on another sheet refuses the whole copy, and nothing is written")
    func leakRefuses() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tender.pdf"), output = folder.appendingPathComponent("leaky.pdf")
        try Self.fixture(at: source, secretOnSheetTwo: true)
        #expect(throws: RedactionRefusal.checkFailed("“BIDAMOUNT” is still readable on sheet 2; mark it there as well")) {
            try RasterRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: Self.secretRect)], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".zpdf-redact") }
        #expect(leftovers.isEmpty)
        #expect(throws: RedactionRefusal.noMarks) { try RasterRedactor.redact(source: source, marks: [], to: output) }
        #expect(throws: RedactionRefusal.markOutsidePage(0)) {
            try RasterRedactor.redact(source: source, marks: [RedactionMark(pageIndex: 0, rect: CGRect(x: 900, y: 900, width: 10, height: 10))], to: output)
        }
    }
}
