import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-15: the precision magnifier follows the pointer while placing points; its picture is
/// a crop of the raster the canvas already holds; it takes no clicks and is off unless turned on.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureLoupeTests {

    @Test("The loupe crops the drawn raster, follows a point tool, never takes a click")
    func loupe() async throws {
        // A thick black line along y = 1200, the middle of the A1 sheet's height.
        let harness = try await NLMeasureR2Harness.make("Loupe.pdf", content: "12 w 0 0 0 RG 200 1200 m 1400 1200 l S")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        for _ in 0..<5 {
            await canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(30))
        }
        let page = canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { page.pageRaster != nil || !page.tileRasters.isEmpty })
        let transform = try #require(page.transform)

        // The crop over the line is dark at its centre; over empty paper it is white.
        let onLine = try #require(page.loupeCrop(around: transform.viewPoint(from: PDFPointValue(x: 800, y: 1200)), magnification: 4, diameter: 132))
        let offLine = try #require(page.loupeCrop(around: transform.viewPoint(from: PDFPointValue(x: 800, y: 1240)), magnification: 4, diameter: 132))
        #expect(Self.centreBrightness(onLine.image) < 0.5)
        #expect(Self.centreBrightness(offLine.image) > 0.9)

        try ScratchDefaults.with(prefix: "zenit.r2measure.loupe") { defaults, _ in
            canvas.loupeDefaults = defaults
            harness.shell.toolbar.activateMeasurement(.length)
            // Off by default: nothing appears.
            canvas.handlePointerMove(PDFPointValue(x: 800, y: 1200))
            #expect(canvas.loupeHost == nil)
            CanvasLoupe.setEnabled(true, defaults)
            canvas.handlePointerMove(PDFPointValue(x: 800, y: 1200))
            let host = try #require(canvas.loupeHost)
            #expect(host.hitTest(NSPoint(x: host.bounds.midX, y: host.bounds.midY)) == nil, "the loupe never takes a click")
            #expect(host.frame.width >= CanvasLoupe.diameter)
            // Rendered off screen, the lens has ink.
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
            // The Select tool takes it away.
            harness.shell.toolbar.selectTool(.select)
            canvas.handlePointerMove(PDFPointValue(x: 800, y: 1200))
            #expect(canvas.loupeHost == nil)
            canvas.loupeDefaults = .standard
        }
    }

    static func centreBrightness(_ image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5, width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: rect)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
    }
}
