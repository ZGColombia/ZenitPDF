import CoreGraphics
import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// NL-DOCS-07: a sheet turned on screen renders turned — the bitmap is in the display space of
/// the page's own `/Rotate` plus the view rotation, exactly as a page carrying that `/Rotate`.
@Suite("View rotation rendering")
struct ViewRotationRenderingTests {

    /// A 200 × 100 pt page with a black 20 pt square in its top-left corner.
    private func page(rotate: Int, label: String) throws -> URL {
        try HandBuiltPDF.onePage(
            content: "0 0 0 rg 0 80 20 20 re f",
            mediaBox: "[0 0 200 100]",
            pageExtra: rotate == 0 ? "" : "/Rotate \(rotate)",
            label: label
        )
    }

    private func render(_ url: URL, viewRotation: Int) async throws -> CGImage {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        var request = PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: 1)
        request.viewRotation = viewRotation
        return try await provider.renderPageRegion(request).image
    }

    /// Grey value (0 black … 255 white) at a pixel counted from the image's top-left.
    private func grey(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: [UInt8] = [0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[0]
    }

    @Test("Turned 90°: 100 × 200 px, the top-left square lands top-right (hand-derived)")
    func quarterTurn() async throws {
        let url = try page(rotate: 0, label: "view-rotation-0")
        let turned = try await render(url, viewRotation: 90)
        #expect(turned.width == 100 && turned.height == 200)
        #expect(grey(turned, x: 95, y: 5) < 64, "the square's new place: top-right")
        #expect(grey(turned, x: 5, y: 5) > 192, "the old top-left corner is now paper")
        let plain = try await render(url, viewRotation: 0)
        #expect(plain.width == 200 && plain.height == 100)
        #expect(grey(plain, x: 5, y: 5) < 64, "untouched when the view is not turned")
    }

    @Test("A view turn equals a page that carries the same /Rotate")
    func sameAsOwnRotate() async throws {
        let flat = try page(rotate: 0, label: "view-rotation-flat")
        let rotated = try page(rotate: 90, label: "view-rotation-own90")
        let byView = try await render(flat, viewRotation: 90)
        let byPage = try await render(rotated, viewRotation: 0)
        #expect(byView.width == byPage.width && byView.height == byPage.height)
        for (x, y) in [(5, 5), (95, 5), (5, 195), (95, 195), (50, 100)] {
            #expect((grey(byView, x: x, y: y) < 128) == (grey(byPage, x: x, y: y) < 128), "pixel \(x),\(y)")
        }
        // And a /Rotate 90 page turned a further 270° stands upright again.
        let upright = try await render(rotated, viewRotation: 270)
        #expect(upright.width == 200 && upright.height == 100)
        #expect(grey(upright, x: 5, y: 5) < 64)
    }

    @Test("The affine map agrees with the rectangle map in every quarter")
    func affineMatchesRectangles() {
        let box = CGRect(x: 10, y: 20, width: 200, height: 100)
        let rect = CGRect(x: 30, y: 50, width: 40, height: 10)
        for rotation in [0, 90, 180, 270] {
            let mapped = rect.applying(PageDisplayGeometry.pageToDisplay(box: box, rotation: rotation))
            let expected = PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: rotation)
            #expect(abs(mapped.minX - expected.minX) < 1e-9 && abs(mapped.minY - expected.minY) < 1e-9, "\(rotation)")
            #expect(abs(mapped.width - expected.width) < 1e-9 && abs(mapped.height - expected.height) < 1e-9, "\(rotation)")
        }
    }
}
