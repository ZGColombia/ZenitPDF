import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// NL-PDF-05: the marked export appended to the drawing instead of rebuilding it, so the sheet
/// bookmarks, callout links and page labels a drawing set carries are still there.
@Suite(.sharedHeap)
struct StructurePreservingFlattenTests {

    /// `LayeredSourceFixtures.plain()`'s sheet with an outline entry, page labels and one link.
    static func structuredSource() -> Data {
        let content = LayeredSourceFixtures.drawingContent
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 340] /CropBox [10 20 410 320]"
                + " /Contents 4 0 R /Resources << /ProcSet [/PDF] >> /Annots [7 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>",
            "<< /Title (Ground floor plan) /Parent 5 0 R /Dest [3 0 R /Fit] >>",
            "<< /Type /Annot /Subtype /Link /Rect [300 250 380 280] /Border [0 0 0] /Dest [3 0 R /Fit] >>"
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    @Test("The marked ink is appended with no layer, and the outline, page labels and link survive")
    func structureSurvives() throws {
        let source = Self.structuredSource()
        let produced = try LayeredMarkupExporter().data(
            source: source,
            pages: [LayeredMarkupExportTests.job()],
            options: .init(asSwitchableLayer: false)
        )
        #expect(produced.data.prefix(source.count) == source)
        #expect(produced.outcome.markupSpanCount == 3)
        // No optional content anywhere: the ink is simply on the page.
        #expect(!LayeredMarkupExportTests.contains(produced.data.dropFirst(source.count), "/OCProperties"))
        #expect(!LayeredMarkupExportTests.contains(produced.data.dropFirst(source.count), "BDC"))

        let document = try #require(PDFDocument(data: produced.data))
        #expect(document.outlineRoot?.numberOfChildren == 1)
        #expect(document.outlineRoot?.child(at: 0)?.label == "Ground floor plan")
        #expect(document.page(at: 0)?.label == "A-101")
        #expect(document.page(at: 0)?.annotations.contains { $0.type == "Link" } == true)
        // The ink is really there: the page renders differently from the bare drawing.
        let bare = try #require(PageRaster.render(source, pageIndex: 0))
        let marked = try #require(PageRaster.render(produced.data, pageIndex: 0))
        #expect(PageRaster.difference(bare, marked) > 0.001)
    }
}
