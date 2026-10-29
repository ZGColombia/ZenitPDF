import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
@testable import ZPDFRenderer

/// L-81 (live test 8, re-fix): an image placed with Edit ▸ Insert Image reaches paper and every
/// file export from its own pixels (ADR-0043 §3, as amended).
///
/// Old output: the renderer had no image shape, so print, the flattened and annotated exports and
/// the snippet painted the picture as its 96-cell mosaic — a 2 400 × 1 700 px sketch printed as
/// 96 × 68 blocks while the canvas showed it sharp.
@Suite("L-81 — an inserted picture is painted from its own pixels")
struct L8InsertedImageRenderTests {

    /// A 100 × 100 pt sheet.
    static func page() -> PageDescriptor {
        PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 100, height: 100),
                             crop: PDFRect(x: 0, y: 0, width: 100, height: 100)),
            rotation: .degrees0
        )
    }

    /// `side` × `side` px of 2-px black and white vertical bars, with a solid red block over the
    /// picture's top-left eighth, so orientation can be read off the result.
    static func barsPNG(side: Int = 400) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: side, by: 4) { context.fill(CGRect(x: x, y: 0, width: 2, height: side)) }
        // Core Graphics bitmap space is y-up: the top-left block is at the high y.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: side - side / 8, width: side / 8, height: side / 8))
        return try encode(try #require(context.makeImage()), as: .png)
    }

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        return data as Data
    }

    /// The picture over the whole sheet: unit (0,0) at the page's bottom-left.
    static func picture(_ data: Data, opacity: Double = 1) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID()),
            zIndex: 0,
            shape: .image(RenderImage(
                origin: PDFPoint(x: 0, y: 0), xEnd: PDFPoint(x: 100, y: 0), yEnd: PDFPoint(x: 0, y: 100),
                source: data, opacity: opacity
            )),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1)
        )
    }

    static func render(_ markups: [RenderableMarkup], zoom: Double) throws -> (RasterImage, RenderStatistics) {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page(), markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page(), zoom: zoom, backingScale: 1)
        )
        return (try renderer.renderOffscreen(), renderer.statistics)
    }

    @Test("At 4× a 400-px picture keeps every bar, upright, where its 96-cell mosaic resolves none")
    func picturesKeepTheirResolution() throws {
        let (image, statistics) = try Self.render([Self.picture(try Self.barsPNG())], zoom: 4)
        #expect(statistics.markupCount == 1)
        #expect(statistics.rejectedMarkupCount == 0)
        #expect(image.width == 400 && image.height == 400)
        // Count the dark/light transitions across a row below the red block: 2-px bars at one
        // image pixel per device pixel give ~200 transitions; a 96-cell mosaic gives none it
        // could resolve (2-px bars average to grey in 4-px cells).
        var transitions = 0
        var previous = false
        let row = 300
        for x in 0..<image.width {
            let (r, _, _, _) = image.pixel(x: x, y: row)
            let dark = r < 80
            if dark != previous { transitions += 1 }
            previous = dark
        }
        #expect(transitions > 150, "\(transitions)")
        // Upright and not mirrored: the red block is at the sheet's top-left.
        let (r, g, b, _) = image.pixel(x: 10, y: 10)
        #expect(r > 200 && g < 60 && b < 60, "top-left \(r) \(g) \(b)")
        let (r2, g2, _, _) = image.pixel(x: 10, y: 390)
        #expect(!(r2 > 200 && g2 < 60), "the block must not be at the bottom-left")
        let (r3, g3, _, _) = image.pixel(x: 390, y: 10)
        #expect(!(r3 > 200 && g3 < 60), "the block must not be at the top-right")
    }

    @Test("A turned placement turns the picture with its box")
    func turnedPlacement() throws {
        // A quarter turn counter-clockwise: the picture's bottom edge runs up the sheet's right
        // side, so its top-left block lands at the sheet's bottom-left.
        var markup = Self.picture(try Self.barsPNG())
        markup.shape = .image(RenderImage(
            origin: PDFPoint(x: 100, y: 0), xEnd: PDFPoint(x: 100, y: 100), yEnd: PDFPoint(x: 0, y: 0),
            source: try Self.barsPNG()
        ))
        let (image, _) = try Self.render([markup], zoom: 4)
        let (r, g, _, _) = image.pixel(x: 10, y: 390)
        #expect(r > 200 && g < 60, "bottom-left after a quarter turn: \(r) \(g)")
    }

    @Test("A placed picture is hit anywhere on the area it covers")
    func hitTesting() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        let markup = Self.picture(try Self.barsPNG(side: 40))
        renderer.update(
            page: Self.page(), markups: [markup], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page(), zoom: 1, backingScale: 1)
        )
        let hit = renderer.hitTest(pagePoint: CGPoint(x: 50, y: 50), toleranceInPagePoints: 0)
        #expect(hit?.markupID == markup.id)
        #expect(hit?.kind == .fill)
    }

    @Test("Bytes that do not decode draw the placement's frame and are counted, never silently nothing")
    func undecodableBytes() {
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        let compiled = compiler.compile(Self.picture(Data("not an image".utf8)))
        #expect(compiled?.images.isEmpty == true)
        #expect(compiled?.fillRejected == true)
        #expect(compiled?.segments.count == 4)
    }

    @Test("A picture declaring more than the import's 40 MP is refused from its header, undecoded")
    func overTheImportBound() throws {
        // 7 000 × 6 000 = 42 MP, 8-bit grey: a real, readable PNG past the bound.
        let width = 7_000, height = 6_000
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = try Self.encode(try #require(context.makeImage()), as: .png)
        let declared = try #require(RenderImagePixels.declaredPixelSize(data), "the header is readable")
        #expect(declared.width == width && declared.height == height)
        #expect(width * height > ArtworkLimits.maximumRasterPixels)
        #expect(RenderImagePixels.decode(data) == nil)
        // A picture inside the bound decodes, its long edge held to the decode limit.
        let strip = try #require(context.makeImage()?.cropping(to: CGRect(x: 0, y: 0, width: 6_000, height: 1_000)))
        let inside = try RenderImagePixels.decode(Self.encode(strip, as: .png))
        #expect(inside?.width == RenderImagePixels.maximumDecodedEdge)
    }

    @Test("The Metal backend accepts a picture — bounds and hit area — and paints it no pixels")
    func metalAcceptsThePicture() throws {
        let made = MarkupRendererFactory.make(preference: .metal)
        guard made.selection.backend == .metal else { return }
        let renderer = made.renderer
        defer { renderer.dispose() }
        let markup = Self.picture(try Self.barsPNG(side: 40))
        renderer.update(
            page: Self.page(), markups: [markup], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page(), zoom: 1, backingScale: 1)
        )
        #expect(renderer.statistics.markupCount == 1)
        #expect(renderer.statistics.rejectedMarkupCount == 0)
        #expect(renderer.hitTest(pagePoint: CGPoint(x: 50, y: 50), toleranceInPagePoints: 0)?.markupID == markup.id)
        _ = try renderer.renderOffscreen()
    }
}
