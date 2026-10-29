import CoreGraphics
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The canvas mapping is the one place in the application where a coordinate error becomes a wrong
/// number rather than a cosmetic problem: a vertex placed 3 points off is measured 3 points off.
@Suite(.appTierSerialised)
struct CanvasGeometryTests {

    private func box(x: Double = 12, y: Double = 30) -> PDFRectValue {
        PDFRectValue(x: x, y: y, width: 595, height: 842)
    }

    @Test("Page and view space round-trip at every rotation", arguments: [0, 90, 180, 270])
    func roundTrip(rotation: Int) {
        let transform = PageDisplayTransform(
            pageBox: box(),
            rotation: rotation,
            zoom: 1.7,
            origin: CGPoint(x: 24, y: 24)
        )
        let samples = [
            PDFPointValue(x: 12, y: 30),
            PDFPointValue(x: 607, y: 872),
            PDFPointValue(x: 300, y: 400),
            PDFPointValue(x: 12.5, y: 871.25)
        ]
        for page in samples {
            let back = transform.pagePoint(from: transform.viewPoint(from: page))
            #expect(abs(back.x - page.x) < 1e-9, "x drifted at \(rotation)°")
            #expect(abs(back.y - page.y) < 1e-9, "y drifted at \(rotation)°")
        }
    }

    @Test("A 90 degree page displays transposed")
    func rotationSwapsAxes() {
        let upright = PageDisplayTransform(pageBox: box(), rotation: 0, zoom: 1, origin: .zero)
        let turned = PageDisplayTransform(pageBox: box(), rotation: 90, zoom: 1, origin: .zero)
        #expect(upright.displaySize == CGSize(width: 595, height: 842))
        #expect(turned.displaySize == CGSize(width: 842, height: 595))
    }

    @Test("The page's bottom-left corner is at the view's bottom-left, unrotated")
    func originConvention() {
        let transform = PageDisplayTransform(
            pageBox: box(x: 0, y: 0),
            rotation: 0,
            zoom: 2,
            origin: CGPoint(x: 10, y: 20)
        )
        let bottomLeft = transform.viewPoint(from: PDFPointValue(x: 0, y: 0))
        // The view is flipped, so page y=0 is the *bottom* of the sheet and therefore the largest
        // view y.
        let expectedY: CGFloat = 20 + 842 * 2
        #expect(bottomLeft.x == CGFloat(10))
        #expect(bottomLeft.y == expectedY)
    }

    @Test("A page rectangle maps to a positive-extent view rectangle at every rotation",
          arguments: [0, 90, 180, 270])
    func rectangleExtents(rotation: Int) {
        let transform = PageDisplayTransform(pageBox: box(), rotation: rotation, zoom: 1.25, origin: .zero)
        let rect = PDFRectValue(x: 100, y: 200, width: 50, height: 80)
        let view = transform.viewRect(from: rect)
        #expect(view.width > 0)
        #expect(view.height > 0)
        let expected = rotation == 90 || rotation == 270
            ? CGSize(width: 80 * 1.25, height: 50 * 1.25)
            : CGSize(width: 50 * 1.25, height: 80 * 1.25)
        #expect(abs(view.width - expected.width) < 1e-9)
        #expect(abs(view.height - expected.height) < 1e-9)
    }

    @Test("The visible page rectangle is clamped to the page box")
    func visibleRectIsClamped() {
        let transform = PageDisplayTransform(pageBox: box(), rotation: 0, zoom: 1, origin: CGPoint(x: 24, y: 24))
        let covered = transform.pageRect(covering: CGRect(x: -500, y: -500, width: 4000, height: 4000))
        #expect(covered.minX >= 12)
        #expect(covered.minY >= 30)
        #expect(covered.maxX <= 12 + 595 + 1e-9)
        #expect(covered.maxY <= 30 + 842 + 1e-9)
    }

    @Test("A whole-page raster above the pixel budget is refused, not quietly shrunk")
    func wholePageRasterIsRefusedNotClamped() {
        // This test used to assert the opposite. `PageRasterSource.clampedScale` lowered the
        // scale until the sheet fitted 24 megapixels, which on an ARCH-E at 6400 % meant a
        // x52 upscale on screen with nothing to say so. Gate Z8: refuse.
        let sheet = CGSize(width: 2_384, height: 1_684)   // ARCH-E
        #expect(!PageRasterSource.allowsWholePageRaster(displaySize: sheet, scale: 64 * 2))
        #expect(
            PageRasterSource.wholePagePixelCount(displaySize: sheet, scale: 64 * 2)
                > PageRasterSource.maximumRasterPixels
        )
    }

    @Test("A whole-page raster inside the budget is allowed at the scale that was asked for")
    func wholePageRasterInsideTheBudget() {
        let sheet = CGSize(width: 595, height: 842)
        #expect(PageRasterSource.allowsWholePageRaster(displaySize: sheet, scale: 2))
        #expect(PageRasterSource.wholePagePixelCount(displaySize: sheet, scale: 2) == 1190 * 1684)
    }
}
