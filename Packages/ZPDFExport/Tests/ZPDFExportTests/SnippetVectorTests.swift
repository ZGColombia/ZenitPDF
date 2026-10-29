import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// NL-PDF-21: the snippet PDF's drawing layer is the drawing's own vector content, clipped to the
/// region at 1:1, instead of a raster underlay.
@Suite(.sharedHeap)
struct SnippetVectorTests {

    /// A 612 × 792 drawing with a heavy black line across the snippet's region.
    static func drawing() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-vector-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(6)
        context.strokeLineSegments(between: [CGPoint(x: 60, y: 300), CGPoint(x: 560, y: 300)])
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func imageCount(_ data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "/Subtype /Image").count - 1
            + text.components(separatedBy: "/Subtype/Image").count - 1
    }

    @Test("A vector sheet's snippet PDF carries no image, is the region at 1:1, and shows the drawing's line")
    func vectorSnippetHasNoRaster() async throws {
        let url = try Self.drawing()
        defer { try? FileManager.default.removeItem(at: url) }
        let markups = SnippetExportTests.markups()
        let spec = SnippetExportTests.spec(region: .markups([markups[0].id, markups[1].id], padding: 20), caption: .none)
        let vector = try #require(CGPDFPageContentSource(url: url))
        let data = try await SnippetExporter().renderPDF(
            spec: spec,
            page: SnippetExportTests.page(),
            markups: markups,
            vectorPage: vector
        )
        // Old output: the page layer was the bridge's raster — one image XObject per snippet.
        #expect(Self.imageCount(data) == 0)
        let page = try #require(PDFContentStreamInspector(data: data)?.pages.first)
        #expect(abs(page.mediaBox.width - 140) < 2, "the region is 140 pt wide at 1:1, got \(page.mediaBox.width)")
        // The line at page y = 300 crosses the region (y 255…425): it is drawn, dark, inside it.
        let raster = try #require(PageRaster.render(data, pageIndex: 0))
        // Region minY is 255, so page y 300 is 45 pt up from the bottom of the region.
        let row = raster.height - 1 - 45
        let dark = (0..<raster.width).filter { raster.pixels[(row * raster.width + $0) * 4] < 64 }.count
        #expect(dark > raster.width / 2, "the drawing's line crosses the snippet: \(dark) of \(raster.width) dark")
    }
}
