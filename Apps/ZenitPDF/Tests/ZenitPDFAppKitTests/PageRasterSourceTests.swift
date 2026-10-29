import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZenitPDFAppKit

/// End-to-end proof that "File ▸ Open renders a PDF": a real file on disk goes through the same
/// path the canvas uses and comes back as pixels with ink in them.
///
/// The fixture is written byte by byte rather than taken from a corpus, so the test states exactly
/// what is in the file it then asserts about: two pages, a stroked rectangle on page 1, a diagonal
/// on page 2.
@Suite(.appTierSerialised)
struct PageRasterSourceTests {

    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan.pdf")

        let page1 = Data("""
        4 w 0 0 0 RG
        72 72 m 372 72 l 372 272 l 72 272 l h S
        """.utf8)
        let page2 = Data("""
        4 w 0 0 0 RG
        100 100 m 480 700 l S
        """.utf8)

        var objects: [Data] = []
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>".utf8))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8))
        objects.append(stream(page1))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 90 /Contents 6 0 R >>".utf8))
        objects.append(stream(page2))

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    private func stream(_ content: Data) -> Data {
        var data = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        data.append(content)
        data.append(Data("\nendstream".utf8))
        return data
    }

    @Test("Opening a PDF yields page geometry and a raster with ink in it")
    func openAndRender() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let drawing = try await DocumentSessionLoader.load(pdfAt: url)
        #expect(drawing.pages.count == 2)
        #expect(drawing.digest.sha256.count == 64)
        #expect(drawing.pages[0].boxes.crop.size.width == 595)
        #expect(drawing.pages[0].rotation == .degrees0)
        #expect(drawing.pages[1].rotation == .degrees90)
        // A rotated page reads landscape even though its box is portrait.
        #expect(drawing.pages[1].rotatedVisibleSize.width == 842)

        let image = try await drawing.rasterSource.render(
            pageIndex: 0,
            displaySize: CGSize(width: 595, height: 842),
            requestedScale: 1
        )
        #expect(image.width == 595)
        #expect(image.height == 842)
        #expect(darkPixelCount(in: image) > 1_000, "the stroked rectangle must be in the raster")

        // The 90 degree page comes back transposed, because the rasteriser honours /Rotate.
        let rotated = try await drawing.rasterSource.render(
            pageIndex: 1,
            displaySize: CGSize(width: 842, height: 595),
            requestedScale: 1
        )
        #expect(rotated.width == 842)
        #expect(rotated.height == 595)

        await drawing.rasterSource.close()
    }

    @Test("A page thumbnail fits inside the requested bounding box")
    func thumbnail() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let drawing = try await DocumentSessionLoader.load(pdfAt: url)
        let image = try await drawing.rasterSource.thumbnail(pageIndex: 0, maximumPixelSize: 128)
        #expect(max(image.width, image.height) == 128)
        await drawing.rasterSource.close()
    }

    @Test("A file that is not a PDF is refused rather than half-opened")
    func refusesNonPDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.txt")
        try Data("this is not a drawing".utf8).write(to: url)

        await #expect(throws: (any Error).self) {
            _ = try await DocumentSessionLoader.load(pdfAt: url)
        }
    }

    /// Counts pixels darker than mid-grey. Enough to distinguish "the page drew" from "the page
    /// came back blank", which is the only thing this needs to tell apart.
    private func darkPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.reduce(into: 0) { count, value in if value < 128 { count += 1 } }
    }
}
