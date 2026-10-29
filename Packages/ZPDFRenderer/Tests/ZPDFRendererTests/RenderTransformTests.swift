import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFRenderer
import ZPDFRendererScenario

/// The renderer's pixel space, against the coordinate contract it is derived from.
@Suite("Render transform (coordinate contract)")
struct RenderTransformTests {

    private func layouts() -> [(PageRotation, Double, Double, Double)] {
        var cases: [(PageRotation, Double, Double, Double)] = []
        for rotation in PageRotation.allCases {
            for zoom in [0.05, 0.25, 1.0, 4.0, 16.0, 64.0] {
                for scale in [1.0, 2.0] {
                    cases.append((rotation, zoom, scale, 0))
                }
            }
        }
        return cases
    }

    @Test("The 2x3 matrix reproduces PageCoordinateConverter exactly at every rotation and zoom")
    func matrixAgreesWithCoordinateContract() throws {
        var random = DeterministicRandom(seed: 0xC0FFEE)
        for (rotation, zoom, scale, _) in layouts() {
            let page = SceneIdentity.page(rotation: rotation, cropInset: 12)
            let viewport = RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: scale)
            let transform = try RenderTransform(page: page, viewport: viewport)
            let converter = try PageCoordinateConverter(page: page, layout: viewport.layout)
            for _ in 0..<64 {
                let point = PDFPoint(
                    x: random.double(-500, 1500),
                    y: random.double(-500, 1500)
                )
                let view = try converter.pageToView(point)
                let expected = PixelPoint(
                    x: Double(view.x) * scale,
                    y: Double(view.y) * scale
                )
                let actual = transform.pixel(from: point)
                // 1e-9 device pixels: the matrix is built by probing the converter, so the only
                // difference is the rounding of three multiply-adds.
                #expect(abs(actual.x - expected.x) < 1e-9)
                #expect(abs(actual.y - expected.y) < 1e-9)
            }
        }
    }

    @Test("Pixel to page is the algebraic inverse, stable at 5 % and 6400 %")
    func inverseRoundTrip() throws {
        var random = DeterministicRandom(seed: 0xBEEF)
        for zoom in [RenderViewport.fittingWholePage(SceneIdentity.page(), zoom: 0.05, backingScale: 1).zoom, 1.0, 64.0] {
            for scale in [1.0, 2.0] {
                let page = SceneIdentity.page(rotation: .degrees270, cropInset: 7)
                let viewport = RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: scale)
                let transform = try RenderTransform(page: page, viewport: viewport)
                for _ in 0..<128 {
                    let point = PDFPoint(x: random.double(0, 612), y: random.double(0, 792))
                    let back = transform.pagePoint(from: transform.pixel(from: point))
                    #expect(abs(back.x - point.x) < 1e-9 * Swift.max(1, abs(point.x)) + 1e-9)
                    #expect(abs(back.y - point.y) < 1e-9 * Swift.max(1, abs(point.y)) + 1e-9)
                }
            }
        }
    }

    @Test("Line width is floored at one device pixel and the floor is honest about geometry")
    func lineWidthFloor() throws {
        let page = SceneIdentity.page()
        let viewport = RenderViewport.fittingWholePage(page, zoom: 0.05, backingScale: 1.0)
        let transform = try RenderTransform(page: page, viewport: viewport)
        // 0.25 pt at 5 % zoom is 0.0125 device pixels; it is painted at one.
        #expect(transform.deviceWidth(forPageWidth: 0.25) == 1.0)
        // The centreline is untouched: page-space geometry maps the same either way.
        let a = transform.pixel(from: PDFPoint(x: 100, y: 100))
        let b = transform.pixel(from: PDFPoint(x: 100, y: 100))
        #expect(a == b)
        // And the hit tester is told the drawn half width, which at this zoom is 10 page points.
        #expect(abs(transform.drawnHalfWidthInPagePoints(forPageWidth: 0.25) - 10.0) < 1e-12)
    }

    @Test("Line width is clamped above, so 6400 % cannot produce an unbounded quad")
    func lineWidthCeiling() throws {
        let page = SceneIdentity.page()
        let viewport = RenderViewport.fittingWholePage(page, zoom: 64.0, backingScale: 2.0)
        let transform = try RenderTransform(page: page, viewport: viewport)
        #expect(transform.deviceWidth(forPageWidth: 1000) == RenderTransform.maximumStrokeDevicePixels)
        #expect(transform.deviceWidth(forPageWidth: .nan) == RenderTransform.minimumStrokeDevicePixels)
        #expect(transform.deviceWidth(forPageWidth: -4) == RenderTransform.minimumStrokeDevicePixels)
    }

    @Test("A one-pixel stroke is drawn with no cap, matching Core Graphics' thin-line path")
    func thinStrokesLoseTheirCaps() throws {
        let page = SceneIdentity.page()
        let thin = try RenderTransform(
            page: page,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        #expect(thin.effectiveCap(.round, forPageWidth: 0.5) == .butt)
        #expect(thin.effectiveCap(.square, forPageWidth: 1.0) == .butt)
        #expect(thin.effectiveCap(.round, forPageWidth: 2.0) == .round)
    }

    @Test("Backing scale changes pixels and never view points")
    func retinaInvariance() throws {
        let page = SceneIdentity.page(rotation: .degrees90)
        let one = try RenderTransform(
            page: page,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        let two = try RenderTransform(
            page: page,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        )
        let point = PDFPoint(x: 217, y: 433)
        let a = one.pixel(from: point)
        let b = two.pixel(from: point)
        #expect(abs(b.x - a.x * 2) < 1e-9)
        #expect(abs(b.y - a.y * 2) < 1e-9)
        // A seven-view-point handle is seven points at either scale, and seven or fourteen pixels.
        #expect(one.devicePixels(fromViewPoints: 7) == 7)
        #expect(two.devicePixels(fromViewPoints: 7) == 14)
        #expect(one.pagePoints(fromViewPoints: 7) == two.pagePoints(fromViewPoints: 7))
    }

    @Test("An unusable viewport or page is a typed error, never a trap")
    func invalidInputsThrow() {
        let page = SceneIdentity.page()
        var broken = RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        broken.viewSize = CGSize(width: 0, height: 0)
        #expect(throws: (any Error).self) { try RenderTransform(page: page, viewport: broken) }

        var badZoom = RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        badZoom.layout.zoom = 1000
        #expect(throws: (any Error).self) { try RenderTransform(page: page, viewport: badZoom) }

        var huge = RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        huge.viewSize = CGSize(width: CGFloat.nan, height: 10)
        #expect(throws: (any Error).self) { try RenderTransform(page: page, viewport: huge) }
    }

    @Test("A windowed viewport places the requested page region at the drawable's origin")
    func windowedViewport() throws {
        for rotation in PageRotation.allCases {
            let page = SceneIdentity.page(rotation: rotation, cropInset: 9)
            let region = PDFRect(x: 120, y: 240, width: 200, height: 160)
            let viewport = try #require(
                RenderViewport.window(page, zoom: 2.0, backingScale: 2.0, pageRect: region)
            )
            let transform = try RenderTransform(page: page, viewport: viewport)
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for corner in [
                PDFPoint(x: region.minX, y: region.minY),
                PDFPoint(x: region.maxX, y: region.minY),
                PDFPoint(x: region.maxX, y: region.maxY),
                PDFPoint(x: region.minX, y: region.maxY)
            ] {
                let pixel = transform.pixel(from: corner)
                minX = Swift.min(minX, pixel.x); maxX = Swift.max(maxX, pixel.x)
                minY = Swift.min(minY, pixel.y); maxY = Swift.max(maxY, pixel.y)
            }
            #expect(abs(minX) < 1e-9)
            #expect(abs(minY) < 1e-9)
            #expect(abs(maxX - Double(viewport.pixelSize.width)) < 1e-6)
            #expect(abs(maxY - Double(viewport.pixelSize.height)) < 1e-6)
        }
    }
}
