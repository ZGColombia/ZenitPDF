import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// Bug hunt 2: the flatten path's sheet geometry.
@Suite(.sharedHeap)
struct Fix2E2FlattenGeometryTests {

    /// Pixels whose three channels are all under `limit` — the drawing's pure-black box, and
    /// nothing else in `LayeredSourceFixtures.drawingContent` (its line is 0.15 gray, 38/255).
    static func blackPixels(_ image: PageRaster.Image, limit: UInt8 = 20) -> Int {
        var count = 0
        for pixel in 0..<(image.width * image.height) {
            let offset = pixel * 4
            if image.pixels[offset] < limit, image.pixels[offset + 1] < limit,
               image.pixels[offset + 2] < limit {
                count += 1
            }
        }
        return count
    }

    @Test("BH-132: the underlay follows the page descriptor's geometry, so markups stay registered")
    func underlayAndMarkupsShareOneGeometry() throws {
        // The file says /Rotate 0; the project's descriptor says a quarter turn (a rotation held
        // in the project before the file is rewritten). A markup is traced exactly over the
        // drawing's black 80 x 40 box, with an opaque fill and a stroke that covers its edges.
        //
        // Old: the underlay was fitted from the file's own crop and /Rotate — unrotated, scaled
        // 0.75 and letterboxed into the 300 x 400 sheet — while the markup was rotated with the
        // descriptor, so the black box stood uncovered beside the red one (~1800 black pixels).
        let source = LayeredSourceFixtures.plain(rotate: 0)
        let url = try LayeredMarkupExportTests.write(source, named: "unrotated.pdf")
        let content = try #require(CGPDFPageContentSource(url: url))
        let red = RGBAColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let cover = RenderableMarkup(
            id: MarkupID(UUID()),
            shape: .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 200, y: 60),
                PDFPoint(x: 280, y: 60),
                PDFPoint(x: 280, y: 100),
                PDFPoint(x: 200, y: 100)
            ])),
            style: RenderStyle(stroke: red, fill: red, lineWidth: 3)
        )
        let job = FlattenPage(
            page: FlattenedPDFWriterTests.page(rotation: .degrees90),
            sourcePageIndex: 0,
            markups: [cover]
        )

        // Non-vacuity: without the markup the black box is really on the sheet.
        let clean = try FlattenedPDFWriter().data(shape: .clean, pages: [job], content: content)
        let cleanRaster = try #require(PageRaster.render(clean, pageIndex: 0))
        #expect(cleanRaster.width == 300 && cleanRaster.height == 400)
        #expect(Self.blackPixels(cleanRaster) > 2_500)

        let flattened = try FlattenedPDFWriter().data(shape: .flattened, pages: [job], content: content)
        let raster = try #require(PageRaster.render(flattened, pageIndex: 0))
        let uncovered = Self.blackPixels(raster)
        #expect(uncovered < 50, "\(uncovered) pixels of the drawing's black box are not under its markup")
    }

    @Test("BH-132: with descriptor and file in agreement the underlay is unchanged")
    func agreeingGeometryDrawsTheFittedPage() throws {
        let source = LayeredSourceFixtures.plain(rotate: 90)
        let url = try LayeredMarkupExportTests.write(source, named: "rotated.pdf")
        let content = try #require(CGPDFPageContentSource(url: url))
        let job = FlattenPage(
            page: FlattenedPDFWriterTests.page(rotation: .degrees90),
            sourcePageIndex: 0,
            markups: []
        )
        let clean = try FlattenedPDFWriter().data(shape: .clean, pages: [job], content: content)
        let produced = try #require(PageRaster.render(clean, pageIndex: 0))
        let original = try #require(PageRaster.render(source, pageIndex: 0))
        #expect(PageRaster.difference(produced, original) < 0.005)
    }

    @Test("BH-509: a /UserUnit 2 sheet is written at its physical size in points")
    func userUnitSheetsKeepTheirPhysicalSize() throws {
        // Old: the media box was the unit count (400 x 300) and no /UserUnit was written, so
        // the flattened sheet printed at half the size of the original.
        var page = FlattenedPDFWriterTests.page()
        page.userUnit = 2
        let job = FlattenPage(page: page, sourcePageIndex: 0, markups: [
            FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250))
        ])
        #expect(job.sheetSize == CGSize(width: 400, height: 300))
        #expect(job.paperSize == CGSize(width: 800, height: 600))

        let data = try FlattenedPDFWriter().data(shape: .flattened, pages: [job], content: nil)
        let document = try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        let written = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(written.width == 800)
        #expect(written.height == 600)
    }
}
