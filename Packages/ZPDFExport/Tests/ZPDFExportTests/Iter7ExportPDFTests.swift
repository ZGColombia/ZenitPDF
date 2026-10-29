import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// Iteration 7: X-026 (an incremental update with no new object numbered its
/// cross-reference stream after the highest object it superseded, which is an object the source
/// already has). Each test says what the code before the fix did.
@Suite("Iteration 7 — PDF export", .sharedHeap, .serialized)
struct Iter7ExportPDFTests {

    // MARK: - X-026

    /// `LayeredSourceFixtures.modern()`: the page is object 4, its content stream object 5, the
    /// source's cross-reference stream object 7, `/Size 8`.
    static let contentStreamNumber = 5

    static let sheet = MeasureViewport(
        bounds: PDFRect(x: 10, y: 20, width: 400, height: 300),
        name: "Sheet 1:100",
        measure: Iter5ExportPDFTests.scale(100),
        coverage: .sheet
    )

    /// The page's `/Contents` as Core Graphics resolves it through the newest cross-reference
    /// section — an independent reader, not this package's own scan.
    static func pageContentAsCoreGraphicsReadsIt(_ data: Data) throws -> Data {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: 1))
        let dictionary = try #require(page.dictionary)
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(dictionary, "Contents", &stream))
        let contents = try #require(stream)
        var format = CGPDFDataFormat.raw
        let bytes = try #require(CGPDFStreamCopyData(contents, &format))
        return bytes as Data
    }

    /// The object number the file's last `startxref` points at — the newest cross-reference
    /// stream.
    static func crossReferenceStreamNumber(_ data: Data) throws -> Int {
        let scan = try PDFDocumentScan(data: data)
        let offset = try #require(scan.previousStartXref)
        let header = String(decoding: data[offset..<min(offset + 24, data.count)], as: UTF8.self)
        return try #require(Int(String(header.prefix { $0.isNumber })))
    }

    /// Everything an update that superseded only the page must leave as it was: the drawing's
    /// bytes as the prefix, object 5 still the drawing's content stream for both readers, and the
    /// new cross-reference stream numbered past every object the source defined.
    static func expectDrawingIntact(_ produced: Data, from source: Data) throws {
        #expect(produced.prefix(source.count) == source, "the drawing's bytes are the prefix")
        let expected = Data(LayeredSourceFixtures.drawingContent.utf8)

        let scan = try PDFDocumentScan(data: produced)
        let entry = try #require(scan.objects[contentStreamNumber])
        guard case let .stream(dictionary, data) = entry.object else {
            Issue.record("object 5 is no longer a stream: \(entry.object)")
            return
        }
        #expect(dictionary["Type"]?.nameValue != "XRef", "object 5 was replaced by a cross-reference stream")
        #expect(data == expected)

        #expect(try pageContentAsCoreGraphicsReadsIt(produced) == expected)

        let before = try PDFDocumentScan(data: source).nextObjectNumber
        #expect(try crossReferenceStreamNumber(produced) >= before)
    }

    @Test("X-026: a viewport-only export of a cross-reference-stream drawing keeps the page's content stream")
    func viewportOnlyExportKeepsObjects() throws {
        let source = LayeredSourceFixtures.modern()
        let first = try Iter5ExportPDFTests.export(source, annotations: [], viewports: [Self.sheet])
        // Old: the update held only object 4 (the page), so its cross-reference stream was
        // written as `5 0 obj` and mapped object 5 — the page's content stream — to itself;
        // every reader then drew binary xref rows as the sheet.
        try Self.expectDrawingIntact(first.data, from: source)
        #expect(try Self.crossReferenceStreamNumber(first.data) == 8)
        #expect(try Iter5ExportPDFTests.viewports(in: first.data).map(\.name) == ["Sheet 1:100"])
        #expect(first.outcome.viewportCount == 1)

        // Clearing the viewports again supersedes only the page too. Old: `5 0 obj` once more.
        let cleared = try Iter5ExportPDFTests.export(first.data, annotations: [], viewports: [])
        try Self.expectDrawingIntact(cleared.data, from: first.data)
        #expect(try Self.crossReferenceStreamNumber(cleared.data) == 9)
        #expect(try Iter5ExportPDFTests.viewports(in: cleared.data).isEmpty)
    }

    @Test("X-026: an export that only removes Zenit's earlier annotations keeps the page's content stream")
    func supersedeOnlyExportKeepsObjects() throws {
        let source = LayeredSourceFixtures.modern()
        let first = try Iter5ExportPDFTests.export(source, annotations: [Iter5ExportPDFTests.line(UUID())], viewports: [])
        #expect(try StandardAnnotationWriterTests.annotations(in: first.data).count == 1)
        try Self.expectDrawingIntact(first.data, from: source)

        let removed = try Iter5ExportPDFTests.export(first.data, annotations: [], viewports: [])
        // Old: the second update held only the page, so its cross-reference stream was again
        // `5 0 obj`, replacing the drawing's content stream.
        #expect(removed.outcome.supersededAnnotationCount == 1)
        #expect(try StandardAnnotationWriterTests.annotations(in: removed.data).isEmpty)
        try Self.expectDrawingIntact(removed.data, from: first.data)
        try Self.expectDrawingIntact(removed.data, from: source)
    }

    @Test("X-026: a classic-table drawing's /Size is unchanged when the update adds no object")
    func classicTableSizeIsUnchanged() throws {
        let source = LayeredSourceFixtures.plain()
        let before = try PDFDocumentScan(data: source)
        let produced = try Iter5ExportPDFTests.export(source, annotations: [], viewports: [Self.sheet])
        let after = try PDFDocumentScan(data: produced.data)
        // The table branch writes no object of its own: one past the highest number, as before.
        #expect(after.trailer["Size"]?.integerValue == before.nextObjectNumber)
        #expect(produced.data.prefix(source.count) == source)
    }
}
