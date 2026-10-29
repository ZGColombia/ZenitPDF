import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZPDFContracts
@testable import ZPDFPDFKitBridge

/// NL-PDF-22: a photographed signature — blue ink on uneven, off-white paper — traced into sharp
/// outlines with the paper removed, holes kept, and specks dropped.
@Suite("Signature image tracing (NL-PDF-22)")
struct NLPDFSignatureImageTests {

    static let size = (width: 900, height: 300)

    /// Blue pen strokes, an "O" whose inside must stay paper, on a lit-from-one-side paper with
    /// grain and one stray speck.
    static func photographedSignature() -> (png: Data, ink: [Bool]) {
        let (width, height) = size
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Paper: a gradient from warm white to light grey, as a phone photo lights it.
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1), CGColor(red: 0.80, green: 0.80, blue: 0.78, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])
        // Grain.
        var seed: UInt32 = 99
        for _ in 0..<4000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let x = CGFloat(seed % UInt32(width)); seed = seed &* 1_664_525 &+ 1_013_904_223
            let y = CGFloat(seed % UInt32(height))
            context.setFillColor(CGColor(red: 0.72, green: 0.72, blue: 0.7, alpha: 0.5))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        // Ink.
        context.setStrokeColor(CGColor(red: 0.08, green: 0.15, blue: 0.55, alpha: 1))
        context.setLineWidth(9)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 80, y: 80))
        context.addCurve(to: CGPoint(x: 420, y: 150), control1: CGPoint(x: 160, y: 280), control2: CGPoint(x: 300, y: 0))
        context.addCurve(to: CGPoint(x: 620, y: 110), control1: CGPoint(x: 500, y: 250), control2: CGPoint(x: 560, y: 40))
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: 660, y: 70, width: 150, height: 130))
        // One speck of dirt far from the writing.
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 860, y: 270, width: 2, height: 2))
        let image = context.makeImage()!
        let out = NSMutableData()
        let writer = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, nil)
        _ = CGImageDestinationFinalize(writer)

        // The ink mask, rendered alone, for comparison (row 0 at the top, as the tracer reads it).
        let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        mask.setFillColor(gray: 1, alpha: 1); mask.fill(CGRect(x: 0, y: 0, width: width, height: height))
        mask.setStrokeColor(gray: 0, alpha: 1); mask.setLineWidth(9); mask.setLineCap(.round)
        mask.move(to: CGPoint(x: 80, y: 80))
        mask.addCurve(to: CGPoint(x: 420, y: 150), control1: CGPoint(x: 160, y: 280), control2: CGPoint(x: 300, y: 0))
        mask.addCurve(to: CGPoint(x: 620, y: 110), control1: CGPoint(x: 500, y: 250), control2: CGPoint(x: 560, y: 40))
        mask.strokePath()
        mask.strokeEllipse(in: CGRect(x: 660, y: 70, width: 150, height: 130))
        let pixels = mask.data!.assumingMemoryBound(to: UInt8.self)
        let ink = (0..<(width * height)).map { pixels[$0] < 128 }
        return (out as Data, ink)
    }

    @Test("The paper is removed, the O keeps its hole, the speck is gone, the ink colour is blue, and the outline matches the strokes")
    func tracesASignature() throws {
        let fixture = Self.photographedSignature()
        // Old behaviour: an image imported as a 96-cell colour mosaic, paper and all.
        let artwork = try SignatureImageTracer.trace(bytes: fixture.png, sourceName: "signature.png")
        let geometry = artwork.geometry
        #expect(geometry.kind.staysSharpWhenMagnified)
        #expect(geometry.limitViolation() == nil)
        #expect(!geometry.regions.isEmpty)
        #expect(geometry.regions.contains { !$0.holes.isEmpty }, "the O's inside is a hole, not ink")
        let ink = try #require(artwork.sourceInk)
        #expect(ink.blue > ink.red + 0.2 && ink.blue > ink.green + 0.15, "ink is the pen's blue: \(ink)")

        // Rasterise the traced regions back onto the ink's bounding box and compare with the mask.
        let (width, height) = Self.size
        var minX = width, minY = height, maxX = 0, maxY = 0
        for index in fixture.ink.indices where fixture.ink[index] {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        // The tracer's box is the ink's box plus one pixel of paper on each side.
        let boxX = Double(minX - 1), boxY = Double(minY - 1)
        let boxW = Double(maxX - minX + 3), boxH = Double(maxY - minY + 3)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        // Unit y is up; the bitmap context is y up too, and the mask's row 0 is the top.
        for region in geometry.regions {
            let path = CGMutablePath()
            for ring in [region.outer] + region.holes {
                let points = ring.map { CGPoint(x: boxX + $0.x * boxW, y: Double(height) - (boxY + (1 - $0.y) * boxH)) }
                path.addLines(between: points); path.closeSubpath()
            }
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        let traced = context.data!.assumingMemoryBound(to: UInt8.self)
        var both = 0, either = 0
        for index in 0..<(width * height) {
            let a = fixture.ink[index], b = traced[index] < 128
            if a && b { both += 1 }
            if a || b { either += 1 }
        }
        let iou = Double(both) / Double(either)
        #expect(iou >= 0.8, "traced outline vs pen strokes, intersection over union \(iou)")
    }

    @Test("A photograph that is mostly dark, an image with no ink, and an unreadable file are refused in words")
    func refusals() throws {
        let (width, height) = (200, 100)
        func png(_ gray: CGFloat, dark: Bool) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if dark { context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 150, height: 100)) }
            let out = NSMutableData()
            let writer = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, context.makeImage()!, nil)
            _ = CGImageDestinationFinalize(writer)
            return out as Data
        }
        #expect(throws: SignatureImageTracer.Refusal.notASignature) { try SignatureImageTracer.trace(bytes: png(0.9, dark: true), sourceName: "dark.png") }
        #expect(throws: SignatureImageTracer.Refusal.noInk) { try SignatureImageTracer.trace(bytes: png(1, dark: false), sourceName: "blank.png") }
        #expect(throws: SignatureImageTracer.Refusal.unreadable) { try SignatureImageTracer.trace(bytes: Data("not an image".utf8), sourceName: "x.png") }
    }
}
