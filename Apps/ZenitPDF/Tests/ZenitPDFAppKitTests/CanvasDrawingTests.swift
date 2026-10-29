import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Draws the canvas offscreen and reads the pixels back.
///
/// The window this view lives in cannot be screenshotted from a test process, so the drawing is
/// verified where it is actually produced: `CanvasPageView.draw(_:)` into a bitmap context. That
/// catches the failures a screenshot would — a page that never appears, an overlay drawn at the
/// wrong place, a measurement in the wrong colour — without needing a display.
@MainActor
@Suite(.appTierSerialised)
struct CanvasDrawingTests {

    private let pageBox = PDFRectValue(x: 0, y: 0, width: 200, height: 100)

    /// A page raster with a distinctive mid-grey block in its lower-left quadrant, in *display*
    /// space, so where it lands on screen can be asserted.
    private func pageRaster() -> CGImage {
        let width = 200
        let height = 100
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        // CGContext is y-up; this block is the bottom-left of the page.
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return context.makeImage()!
    }

    /// One rendered canvas, plus the pixels-per-point the rep was cached at.
    ///
    /// `bitmapImageRepForCachingDisplay` allocates at the display's backing scale, so on a Retina
    /// machine the rep is twice the view's size in points. Sampling has to go through that factor
    /// or every assertion silently reads a point a quarter of the way into the image.
    private struct Rendered {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        /// The colour at a point in the *view's* coordinates.
        func color(atViewX x: CGFloat, y: CGFloat) -> NSColor {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }
    }

    private func render(_ view: CanvasPageView, size: CGSize) -> Rendered {
        view.frame = CGRect(origin: .zero, size: size)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return Rendered(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width)
    }

    @Test("The page raster is drawn into the page's rectangle, right way up")
    func drawsThePage() {
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: pageBox,
            rotation: 0,
            zoom: 1,
            origin: CGPoint(x: 20, y: 10)
        )
        view.pageImage = pageRaster()
        let rep = render(view, size: CGSize(width: 240, height: 120))

        // The sheet is white where the raster is white.
        let sheet = rep.color(atViewX: 120, y: 40)
        #expect(sheet.brightnessComponent > 0.9, "the page should be white here, got \(sheet)")

        // The grey block sits at the *bottom* of the page, which in this flipped view is the
        // largest y: page origin 10 + page height 100 - block height 20 = 90…110.
        let block = rep.color(atViewX: 30, y: 100)
        #expect(abs(block.brightnessComponent - 0.5) < 0.15, "the grey block should be here, got \(block)")

        // Outside the sheet is the dark canvas backdrop, not white.
        let backdrop = rep.color(atViewX: 5, y: 5)
        #expect(backdrop.brightnessComponent < 0.5, "the backdrop should be dark, got \(backdrop)")
    }

    @Test("A markup is stroked in its own colour at its own coordinates")
    func drawsAMarkup() {
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: pageBox,
            rotation: 0,
            zoom: 1,
            origin: CGPoint(x: 20, y: 10)
        )
        view.pageImage = pageRaster()
        // A pure-red horizontal line across the middle of the page, page y = 50.
        view.shapes = [
            CanvasMarkupShape(
                id: UUID(),
                pageID: UUID(),
                color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
                strokes: [
                    CanvasStroke(
                        points: [PDFPointValue(x: 20, y: 50), PDFPointValue(x: 180, y: 50)],
                        closed: false,
                        filled: false
                    )
                ],
                counts: [],
                bounds: PDFRectValue(x: 20, y: 50, width: 160, height: 0),
                hidden: false,
                caption: nil
            )
        ]
        let rep = render(view, size: CGSize(width: 240, height: 120))

        // Page y = 50 is view y = 10 + (100 - 50) = 60.
        let onTheLine = rep.color(atViewX: 100, y: 60)
        #expect(onTheLine.redComponent > 0.6, "the stroke should be red here, got \(onTheLine)")
        #expect(onTheLine.greenComponent < 0.4)

        // A few points above it is still white paper.
        let offTheLine = rep.color(atViewX: 100, y: 40)
        #expect(offTheLine.redComponent > 0.85 && offTheLine.greenComponent > 0.85)
    }

    @Test("A measurement in progress is drawn in the measurement accent")
    func drawsLiveMeasurement() {
        let view = CanvasPageView()
        view.transform = PageDisplayTransform(
            pageBox: pageBox,
            rotation: 0,
            zoom: 1,
            origin: CGPoint(x: 20, y: 10)
        )
        view.pageImage = pageRaster()
        view.livePoints = [PDFPointValue(x: 20, y: 80), PDFPointValue(x: 180, y: 80)]
        let rep = render(view, size: CGSize(width: 240, height: 120))

        // Page y = 80 is view y = 10 + 20 = 30. Cyan: blue and green high, red low.
        let ink = rep.color(atViewX: 100, y: 30)
        #expect(ink.blueComponent > 0.5, "the live measurement should be cyan, got \(ink)")
        #expect(ink.redComponent < ink.blueComponent)
    }

    @Test("Nothing is drawn outside the page when there is no page")
    func emptyState() {
        let view = CanvasPageView()
        view.transform = nil
        let rep = render(view, size: CGSize(width: 120, height: 80))
        let anywhere = rep.color(atViewX: 60, y: 40)
        #expect(anywhere.brightnessComponent < 0.5, "an empty canvas is backdrop, got \(anywhere)")
    }
}
