import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// U-005 (iteration 4, re-fix): the loupe's per-move cost came down without moving its picture.
///
/// The crop is now taken at the view's backing resolution and magnified by the lens, and the
/// lens is measured only when its caption changes shape. These tests hold the two things that
/// change could break: the page point under the pointer must still sit exactly under the
/// crosshair, four times magnified, and the cached size must be the size SwiftUI would measure.
@MainActor
@Suite(.appTierSerialised)
struct Iter4RLoupeTests {

    /// A 12 pt black line along y = 1200 on the A1 fixture, rasters settled.
    static func lineHarness(_ name: String) async throws -> (NLMeasureR2Harness.Harness, PDFCanvasViewController) {
        let harness = try await NLMeasureR2Harness.make(name, content: "12 w 0 0 0 RG 200 1200 m 1400 1200 l S")
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        harness.core.canvas.zoomToFit()
        canvas.refresh()
        for _ in 0..<5 {
            await canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(30))
        }
        let page = canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { !page.tileRasters.isEmpty || page.pageRaster != nil })
        return (harness, canvas)
    }

    /// The darkness-weighted centre of the lens column `dx` lens points right of the lens centre,
    /// in lens points below the centre, over the rows within `reach` of it. The host is drawn by
    /// AppKit's own off-screen path (`cacheDisplay`), which composites the picture layer the way
    /// the window does — `CALayer.render(in:)` would not: the picture's layer is geometry-flipped
    /// and that call draws it mirrored. The column misses the crosshair (its arms reach 18 % of
    /// the diameter) and the rim.
    static func bandOffset(in host: LoupeHostingView, dx: CGFloat = 35, reach: CGFloat = 45) throws -> Double {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let radius = CanvasLoupe.diameter / 2
        let column = Int(((host.bounds.width / 2 + dx) * scale).rounded(.down))
        var weight = 0.0, moment = 0.0
        for row in Int((radius - reach) * scale)..<Int((radius + reach) * scale) {
            guard let colour = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
            let darkness = 1 - (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
            guard darkness > 0.02 else { continue }
            // The row's centre, in lens points below the lens centre (row 0 is the top).
            moment += darkness * ((CGFloat(row) + 0.5) / scale - radius)
            weight += darkness
        }
        try #require(weight > 1, "no band in the lens column")
        return moment / weight
    }

    /// The darkness-weighted centre of the crop's column at view `x`, in view points: where the
    /// canvas drew the band, placement rounding included.
    static func bandCentre(in crop: LoupeCrop, atViewX x: CGFloat, scale: CGFloat) throws -> CGFloat {
        let width = crop.image.width, height = crop.image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let column = Int(((x - crop.viewRect.minX) * scale).rounded(.down))
        try #require((0..<width).contains(column))
        var weight = 0.0, moment = 0.0
        for row in 0..<height {
            let index = (row * width + column) * 4
            let darkness = 1 - (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / (3 * 255)
            guard darkness > 0.02 else { continue }
            // Row 0 is the top of the image: view `minY` (view space is flipped).
            moment += darkness * (Double(crop.viewRect.minY) + (Double(row) + 0.5) / Double(scale))
            weight += darkness
        }
        try #require(weight > 0.5, "no band in the crop column")
        return CGFloat(moment / weight)
    }

    @Test("The lens puts the pointer's page point under its crosshair, four times magnified, to the sub-pixel")
    func lensCentresThePointer() async throws {
        let (harness, canvas) = try await Self.lineHarness("LoupeCentre.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let page = canvas.pageViewForTesting
        let transform = try #require(page.transform)
        let scale = page.effectiveBackingScale
        let onLine = transform.viewPoint(from: PDFPointValue(x: 800, y: 1200))
        let lineY = onLine.y, pointerX = onLine.x + 0.3

        // The crop: pixel-aligned, the source square inside it, one image pixel per device pixel.
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let viewPoint = CGPoint(x: pointerX, y: (lineY * scale).rounded(.down) / scale + fraction / scale)
            let crop = try #require(page.loupeCrop(around: viewPoint, magnification: 4, diameter: 132))
            let half = 132.0 / 4 / 2
            #expect(crop.viewRect.minX * scale == (crop.viewRect.minX * scale).rounded())
            #expect(crop.viewRect.minY * scale == (crop.viewRect.minY * scale).rounded())
            #expect(crop.viewRect.contains(CGRect(x: viewPoint.x - half, y: viewPoint.y - half, width: 2 * half, height: 2 * half)))
            #expect(CGFloat(crop.image.width) == (crop.viewRect.width * scale).rounded())
            #expect(CGFloat(crop.image.height) == (crop.viewRect.height * scale).rounded())
            // The placement puts the pointer at the lens centre, whatever its pixel fraction.
            let placement = PDFCanvasViewController.loupePlacement(crop: crop.viewRect, viewPoint: viewPoint, magnification: 4)
            let pointerInContent = CGPoint(x: (viewPoint.x - crop.viewRect.minX) * 4, y: (viewPoint.y - crop.viewRect.minY) * 4)
            #expect(abs(pointerInContent.x + placement.offset.width - placement.size.width / 2) < 1e-9)
            #expect(abs(pointerInContent.y + placement.offset.height - placement.size.height / 2) < 1e-9)
        }

        // The rendered lens: the line's band sits where the pointer's distance from it says, at
        // four times, with the pointer half a device pixel off the grid — so a lens that centred
        // the crop's pixels instead of the pointer would be a whole lens point out.
        try ScratchDefaults.with(prefix: "zenit.it4r.loupe.centre") { defaults, _ in
            canvas.loupeDefaults = defaults
            defer { canvas.loupeDefaults = .standard }
            CanvasLoupe.setEnabled(true, defaults)
            harness.shell.toolbar.activateMeasurement(.length)
            for lensPoints in [0.0, 18.0, -22.0] {
                let viewY = (lineY * scale).rounded(.down) / scale + 0.5 / scale - lensPoints / 4
                let pointer = transform.pagePoint(from: CGPoint(x: pointerX, y: viewY))
                canvas.handlePointerMove(pointer)
                let host = try #require(canvas.loupeHost as? LoupeHostingView)
                host.layoutSubtreeIfNeeded()
                // SwiftUI put the picture where the lens is: the circle at the top, centred.
                let picture = host.picture
                #expect(picture.isDescendant(of: host), "the picture is not in the lens")
                let inHost = picture.convert(picture.bounds, to: host)
                #expect(abs(inHost.width - CanvasLoupe.diameter) < 0.5 && abs(inHost.height - CanvasLoupe.diameter) < 0.5)
                #expect(abs(inHost.midX - host.bounds.midX) < 0.5)
                #expect(host.isFlipped ? inHost.minY < 0.5 : host.bounds.maxY - inHost.maxY < 0.5, "the picture is not the lens at the top: \(inHost) in \(host.bounds)")
                // Where the canvas drew the band under the lens's sample column, and so where the
                // lens must show it: its distance below the pointer, times four.
                let viewPointer = transform.viewPoint(from: pointer)
                let crop = try #require(page.loupeCrop(around: viewPointer, magnification: 4, diameter: 132))
                let drawn = try Self.bandCentre(in: crop, atViewX: viewPointer.x + 35 / 4, scale: scale)
                let expected = Double((drawn - viewPointer.y) * 4)
                let measured = try Self.bandOffset(in: host)
                print(String(format: "  lens band %.3f lens pt, drawn band %.3f lens pt (pointer %.3f lens pt off the line)", measured, expected, Double((lineY - viewPointer.y) * 4)))
                #expect(abs(measured - expected) < 0.5, "band at \(measured) lens pt, expected \(expected)")
            }
        }
    }

    @Test("The lens is measured once per caption shape, and the kept size is the measured one")
    func lensMeasuresOnlyOnShapeChange() async throws {
        let (harness, canvas) = try await Self.lineHarness("LoupeSize.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        try ScratchDefaults.with(prefix: "zenit.it4r.loupe.size") { defaults, _ in
            canvas.loupeDefaults = defaults
            defer { canvas.loupeDefaults = .standard }
            CanvasLoupe.setEnabled(true, defaults)
            harness.shell.toolbar.activateMeasurement(.length)
            // Empty paper, away from the line: no snap chip, and "5xx.xx, 1500.25 pt" throughout.
            var host: LoupeHostingView?
            for step in 0..<12 {
                canvas.handlePointerMove(PDFPointValue(x: 500.13 + Double(step) * 8.31, y: 1500.25))
                host = try #require(canvas.loupeHost as? LoupeHostingView)
                #expect(harness.core.canvas.snapFeedback == nil)
                #expect(host?.frame.size == host?.fittingSize, "the kept size is not the measured size at step \(step)")
            }
            #expect(host?.measureCountForTesting == 1, "the lens was measured on moves that kept the caption's shape")
            // A fourth integer digit widens the caption: measured again, and right.
            canvas.handlePointerMove(PDFPointValue(x: 1000.5, y: 1500.25))
            #expect(host?.measureCountForTesting == 2)
            #expect(host?.frame.size == host?.fittingSize)
            #expect(host?.frame.width ?? 0 >= CanvasLoupe.diameter)
            // Back to the first shape: its size is already known, and still right.
            canvas.handlePointerMove(PDFPointValue(x: 550, y: 1500.25))
            #expect(host?.measureCountForTesting == 2)
            #expect(host?.frame.size == host?.fittingSize)
        }
    }

    @Test("The size key keeps what moves the caption's width and nothing else")
    func sizeKeyIsTheCaptionShape() {
        let a = LoupeSizeKey(readout: "512.34, 1700.25 pt", snap: nil)
        let b = LoupeSizeKey(readout: "598.07, 1799.99 pt", snap: nil)
        let c = LoupeSizeKey(readout: "1000.50, 1700.25 pt", snap: nil)
        let d = LoupeSizeKey(readout: "-12.34, 1700.25 pt", snap: nil)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.captionShape == "000.00, 0000.00 pt")
    }
}
