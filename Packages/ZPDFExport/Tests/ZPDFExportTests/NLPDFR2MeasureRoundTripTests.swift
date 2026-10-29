import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFMeasureDictionary
import PDFKit
import ZPDFRenderer
@testable import ZPDFExport

/// NL-PLAT-06 write half / NL-PDF-02: the scale the annotated export writes is the scale another
/// program — and Zenit's own drawing-file scale reader — reads back.
@Suite("Annotated export measure round trip (NL-PLAT-06 write half)", .sharedHeap)
struct NLPDFR2MeasureRoundTripTests {

    @Test("A page with a 1:100 sheet scale and a 1:20 region reads back as 1:100 and 1:20 with their boxes")
    func viewportsReadBack() throws {
        let page = FlattenedPDFWriterTests.page()
        let plan = MeasureScale(ratioLabel: "1:100", metresPerPoint: 100 * 0.0254 / 72)
        let detail = MeasureScale(ratioLabel: "1:20", metresPerPoint: 20 * 0.0254 / 72)
        let start = PDFPoint(x: 40, y: 60), end = PDFPoint(x: 193.0709, y: 60)
        let id = UUID()
        var length = StandardAnnotation(
            id: id,
            geometry: .polyLine([start, end]),
            stroke: StandardAnnotationWriterTests.blue,
            intent: .polyLineDimension,
            appearance: [RenderableMarkup(
                id: MarkupID(id),
                shape: .polyline(RenderPolyline(points: [start, end], isClosed: false)),
                style: RenderStyle(stroke: StandardAnnotationWriterTests.blue, lineWidth: 1)
            )]
        )
        length.measure = plan
        let produced = try StandardAnnotationWriter().data(
            source: LayeredSourceFixtures.plain(),
            pages: [StandardAnnotationPage(
                page: page, sourcePageIndex: 0, annotations: [length],
                viewports: [
                    MeasureViewport(bounds: PDFRect(x: 0, y: 0, width: 400, height: 300), name: "Sheet", measure: plan),
                    MeasureViewport(bounds: PDFRect(x: 210, y: 20, width: 150, height: 100), name: "Detail", measure: detail)
                ]
            )]
        )
        let document = try #require(CGPDFDocument(CGDataProvider(data: produced.data as CFData)!))
        let read = PDFMeasureReader.viewports(in: document)
        // Before the reader was corrected it preferred /D (m per *mm*, 0.001) and read 1:2.835.
        #expect(read.map(\.ratioDenominator).sorted() == [20, 100])
        let region = try #require(read.first { $0.ratioDenominator == 20 })
        #expect(region.bbox == CGRect(x: 210, y: 20, width: 150, height: 100))
        #expect(region.ratioText == "1:20")
        // Hand-derived: 1:100 is 100 × 0.0254 / 72 = 0.035277… m per point.
        let sheet = try #require(read.first { $0.ratioDenominator == 100 })
        #expect(abs(sheet.metresPerPoint - 0.0352777777778) < 1e-9)

        // The measured annotation's own /Measure parses with the same reader's rules.
        let written = try #require(StandardAnnotationWriterTests.named(id, in: try StandardAnnotationWriterTests.annotations(in: produced.data)))
        #expect(written["IT"]?.nameValue == "PolyLineDimension")
        let x = try #require(written["Measure"]?.dictionaryValue?["X"]?.arrayValue?.first?.dictionaryValue)
        let unit = try #require(StandardAnnotationWriter.text(x["U"]))
        let factor = try #require(x["C"]?.doubleValue)
        let metres = try #require(PDFMeasureReader.metres(perUnit: unit))
        #expect(abs(factor * metres - 0.0352777777778) < 1e-9)
    }
}

/// NL-PDF-03 restore: the session archive rides beside the overlay and is superseded with it.
@Suite("Embedded takeoff companions (NL-PDF-03 restore)", .sharedHeap)
struct NLPDFR2EmbeddedCompanionTests {

    static func archive(for source: Data, payload: String) -> EmbeddedTakeoff {
        let base = StandardAnnotationWriterTests.takeoff(for: source, payload: payload)
        return EmbeddedTakeoff(fileName: "zenit-session.json", payload: Data(payload.utf8),
                               sourceByteCount: base.sourceByteCount, sourceSHA256: base.sourceSHA256)
    }

    @Test("Overlay and archive are both carried, read back by name, and a second save replaces both")
    func companionsTravelAndSupersede() throws {
        let fixture = StandardAnnotationWriterTests.fixture()
        let source = StandardAnnotationWriterTests.sourceWithAttachment()
        let pages = [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)]
        let first = try StandardAnnotationWriter().data(
            source: source, pages: pages,
            takeoff: StandardAnnotationWriterTests.takeoff(for: source, payload: "overlay-1"),
            attachments: [Self.archive(for: source, payload: "archive-1")]
        )
        let all = EmbeddedTakeoffReader.entries(in: first.data)
        #expect(all.map(\.takeoff.fileName) == [EmbeddedTakeoff.defaultFileName, "zenit-session.json"])
        let verified = all.filter(\.prefixVerified).count
        #expect(verified == 2)
        #expect(EmbeddedTakeoffReader.read(first.data)?.takeoff.fileName == EmbeddedTakeoff.defaultFileName,
                "the single-file reader still answers with the overlay")

        let second = try StandardAnnotationWriter().data(
            source: first.data, pages: pages,
            takeoff: StandardAnnotationWriterTests.takeoff(for: source, payload: "overlay-2"),
            attachments: [Self.archive(for: source, payload: "archive-2")]
        )
        let archive = try #require(EmbeddedTakeoffReader.read(second.data, named: "zenit-session.json"))
        #expect(String(decoding: archive.takeoff.payload, as: UTF8.self) == "archive-2")
        #expect(archive.prefixVerified)
        let scan = try PDFDocumentScan(data: second.data)
        let catalog = try #require(scan.dictionary(scan.rootReference))
        let tree = try #require(scan.dictionary(scan.dictionary(catalog["Names"])?["EmbeddedFiles"]))
        // The reviewer's notes.txt, the overlay and the archive: three pairs, never five.
        let names = try #require(scan.object(tree["Names"])?.arrayValue)
        #expect(names.count == 6)
        let associated = try #require(scan.object(catalog["AF"])?.arrayValue)
        #expect(associated.count == 2)
    }
}

/// A sheet link of the project is a `/Link` GoTo in the file written.
@Suite("Sheet links as /Link GoTo", .sharedHeap)
struct NLPDFR2PageLinkTests {

    @Test("A page link lands on its page (PDFKit follows it); one to a page the file lacks is left out and counted")
    func pageLinksGoTo() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.stroke(CGRect(x: 20, y: 20, width: 100, height: 50)); context.endPDFPage() }
        context.closePDF()
        let page = FlattenedPDFWriterTests.page()
        let good = StandardAnnotation(id: UUID(), geometry: .pageLink(PDFRect(x: 30, y: 30, width: 60, height: 20), pageIndex: 1), contents: "See S-201")
        let bad = StandardAnnotation(id: UUID(), geometry: .pageLink(PDFRect(x: 30, y: 80, width: 60, height: 20), pageIndex: 7))
        let produced = try StandardAnnotationWriter().data(
            source: data as Data,
            pages: [StandardAnnotationPage(page: page, sourcePageIndex: 0, annotations: [good, bad])]
        )
        #expect(produced.outcome.writtenAnnotationCount == 1)
        #expect(produced.outcome.rejectedMarkupCount == 1)
        let document = try #require(PDFDocument(data: produced.data))
        let link = try #require(document.page(at: 0)?.annotations.first { $0.type == "Link" })
        let destination = try #require(link.destination?.page)
        #expect(document.index(for: destination) == 1)
    }
}
