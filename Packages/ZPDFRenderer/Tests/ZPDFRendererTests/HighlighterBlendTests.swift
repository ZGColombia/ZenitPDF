import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// r2-layers follow-up: a highlighter (ADR-0029 `MarkupStyle.blendMode = multiply`) paints
/// multiplied through the renderer's CoreGraphics backend — the backend every PDF export draws
/// markups with. Old output: `RenderStyle` had no blend, so an exported highlighter covered the
/// linework under it with 40 %-opaque yellow instead of darkening it.
@Suite("Highlighter blend", .serialized)
struct HighlighterBlendTests {

    private static let page = SceneIdentity.page()

    private static func yellowSquare(multiply: Bool) -> RenderableMarkup {
        var style = RenderStyle(stroke: nil, fill: RGBAColor(red: 1, green: 1, blue: 0, alpha: 1))
        if multiply { style.blendMode = .multiply }
        return RenderableMarkup(
            id: MarkupID(UUID(uuid: (0xB1, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, multiply ? 1 : 0))),
            shape: .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 0, y: 692), PDFPoint(x: 100, y: 692), PDFPoint(x: 100, y: 792), PDFPoint(x: 0, y: 792)
            ])),
            style: style
        )
    }

    /// The pixel at the centre of a 100 × 100 px render of `markup` over mid-grey paper.
    private static func centrePixel(_ markup: RenderableMarkup) throws -> (red: Int, green: Int, blue: Int) {
        let viewport = try #require(RenderViewport.window(
            page, zoom: 1, backingScale: 1, pageRect: PDFRect(x: 0, y: 692, width: 100, height: 100)
        ))
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: [markup], selection: .empty, snapFeedback: nil, viewport: viewport)
        let width = viewport.pixelSize.width
        let height = viewport.pixelSize.height
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Mid-grey paper: 128 in every channel.
        context.setFillColor(CGColor(srgbRed: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        #expect(renderer.drawCurrentScene(into: context, pixelHeight: height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (height / 2) * width * 4 + (width / 2) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    @Test("Multiply keeps the grey under yellow ink (128, 128, 0); normal painting covers it (255, 255, 0)")
    func multiplyDarkensInsteadOfCovering() throws {
        // By hand: multiply is source × destination per channel. Yellow (1, 1, 0) over grey
        // (0.502, 0.502, 0.502) gives (0.502, 0.502, 0) = (128, 128, 0). Source-over with an
        // opaque source gives the source, (255, 255, 0).
        let multiplied = try Self.centrePixel(Self.yellowSquare(multiply: true))
        #expect(abs(multiplied.red - 128) <= 2 && abs(multiplied.green - 128) <= 2 && multiplied.blue <= 2, "\(multiplied)")
        let normal = try Self.centrePixel(Self.yellowSquare(multiply: false))
        #expect(normal.red >= 253 && normal.green >= 253 && normal.blue <= 2, "\(normal)")
    }

    @Test("Into a PDF context the multiply is written as the graphics state's /BM /Multiply")
    func pdfCarriesTheBlendMode() throws {
        let viewport = try #require(RenderViewport.window(
            Self.page, zoom: 1, backingScale: 1, pageRect: PDFRect(x: 0, y: 692, width: 100, height: 100)
        ))
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: Self.page, markups: [Self.yellowSquare(multiply: true)], selection: .empty, snapFeedback: nil, viewport: viewport)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator as String: "test"] as CFDictionary))
        pdf.beginPDFPage(nil)
        #expect(renderer.drawCurrentScene(into: pdf, pixelHeight: 100))
        pdf.endPDFPage()
        pdf.closePDF()
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try #require(document.page(at: 1))
        let resources = try #require(page.dictionary.flatMap { dictionary -> CGPDFDictionaryRef? in
            var value: CGPDFDictionaryRef?
            return CGPDFDictionaryGetDictionary(dictionary, "Resources", &value) ? value : nil
        })
        var states: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(resources, "ExtGState", &states))
        var found = false
        if let states {
            CGPDFDictionaryApplyBlock(states, { _, object, context in
                var state: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &state), let state else { return true }
                var name: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(state, "BM", &name), let name, String(cString: name) == "Multiply" {
                    context?.assumingMemoryBound(to: Bool.self).pointee = true
                }
                return true
            }, &found)
        }
        #expect(found, "a /BM /Multiply graphics state")
    }

    @Test("A style without a blend encodes exactly as before; a multiply style round-trips")
    func codingIsAdditive() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try String(decoding: encoder.encode(RenderStyle()), as: UTF8.self)
        #expect(!plain.contains("blendMode"))
        var multiply = RenderStyle()
        multiply.blendMode = .multiply
        let decoded = try JSONDecoder().decode(RenderStyle.self, from: encoder.encode(multiply))
        #expect(decoded.blendMode == .multiply)
    }
}
