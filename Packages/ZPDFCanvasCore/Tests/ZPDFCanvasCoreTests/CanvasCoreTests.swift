import CoreGraphics
import Foundation
import Testing
import ZPDFCanvasCore
import ZPDFUIPresentation

/// NL-PLAT-17: the canvas arithmetic, portable. Values hand-derived.
@Suite("Canvas core, portable")
struct CanvasCoreTests {

    @Test("Fitting a 100 × 50 pt rectangle into 400 × 400: padded 124 × 62, zoom 400/124, centred")
    func fitsARectangle() throws {
        let fit = try #require(ZoomMath.fit(target: PDFRectValue(x: 100, y: 100, width: 100, height: 50),
                                            in: CGSize(width: 400, height: 400)))
        // Padding 12 % a side: 100 × 1.24 = 124, 50 × 1.24 = 62; the tighter axis gives 400 / 124.
        #expect(abs(fit.zoom - 400.0 / 124.0) < 1e-12)
        // The visible rect is 124 pt wide and centred on x = 150.
        #expect(abs(fit.visiblePageRect.size.width - 124) < 1e-9)
        #expect(abs(fit.visiblePageRect.origin.x - (150 - 62)) < 1e-9)
    }

    @Test("On a sheet turned 90°, the page's width runs along the view's height")
    func pageAxesOnATurnedSheet() {
        #expect(ZoomMath.pageAxes(CGSize(width: 800, height: 600), rotation: 90) == CGSize(width: 600, height: 800))
        #expect(ZoomMath.pageAxes(CGSize(width: 800, height: 600), rotation: -180) == CGSize(width: 800, height: 600))
    }

    @Test("Page to view and back is the identity, on an unturned and a turned sheet")
    func displayTransformRoundTrips() {
        for rotation in [0, 90, 180, 270] {
            let transform = PageDisplayTransform(pageBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595), rotation: rotation,
                                                 zoom: 2, origin: CGPoint(x: 10, y: 20))
            let point = PDFPointValue(x: 123.5, y: 456.25)
            let back = transform.pagePoint(from: transform.viewPoint(from: point))
            #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9, "rotation \(rotation)")
        }
    }

    @Test("An area pill sits inside a square, on its centroid")
    func pillInsideASquare() throws {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let placement = try #require(AreaPillLayout.placement(polygon: square, pillHalfWidth: 20, pillHalfHeight: 8))
        #expect(placement.isInterior)
        #expect(placement.center == CGPoint(x: 50, y: 50))
    }
}
