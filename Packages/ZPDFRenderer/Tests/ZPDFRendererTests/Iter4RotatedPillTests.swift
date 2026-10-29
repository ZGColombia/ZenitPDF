import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Iteration 4, U-077: an exported value pill on a `/Rotate 90` or
/// `270` sheet is as wide as its screen-upright text, not a quarter turn off from it.
@Suite("Iter4 pills on rotated sheets", .serialized)
struct Iter4RotatedPillTests {

    private static let pillID = MarkupID(UUID(uuidString: "17E40770-0000-4000-8000-000000000001") ?? UUID())

    /// A red pill with blue text "12.50 m2" centred at page (300, 400).
    private static let pill = RenderableMarkup(
        id: pillID,
        shape: .labelPill(RenderLabelPill(
            anchorPoint: PDFPoint(x: 300, y: 400),
            text: "12.50 m2",
            fontSizeViewPoints: 12,
            pillFill: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        )),
        style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
                           fill: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), lineWidth: 1)
    )

    typealias Box = (minX: Int, minY: Int, maxX: Int, maxY: Int)

    /// The pixel box of every pixel `predicate` admits.
    private static func box(_ image: RasterImage, _ predicate: ((UInt8, UInt8, UInt8, UInt8)) -> Bool) -> Box? {
        var box: Box?
        for y in 0..<image.height {
            for x in 0..<image.width where predicate(image.pixel(x: x, y: y)) {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return box
    }

    /// The pill rendered by Core Graphics in a 200 × 200 px window around it, zoom 1.
    private static func render(rotation: PageRotation) throws -> RasterImage {
        let page = SceneIdentity.page(rotation: rotation)
        let viewport = try #require(RenderViewport.window(
            page, zoom: 1, backingScale: 1, pageRect: PDFRect(x: 200, y: 300, width: 200, height: 200)
        ))
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: [pill], selection: .empty, snapFeedback: nil, viewport: viewport)
        return try renderer.renderOffscreen()
    }

    @Test("U-077: on a /Rotate 90 and 270 sheet the pill's fill is wider than tall and holds its text, as on an upright one")
    func pillFollowsItsTextOnRotatedSheets() throws {
        for rotation in [PageRotation.degrees0, .degrees90, .degrees180, .degrees270] {
            let image = try Self.render(rotation: rotation)
            // The fill is the red: the pixels where red dominates.
            let ink = try #require(Self.box(image) { Int($0.0) > 128 && Int($0.2) < 96 }, "\(rotation)")
            // The text is blue over the red fill: the pixels where blue dominates.
            let text = try #require(Self.box(image) { Int($0.2) > 128 && Int($0.0) < 96 }, "\(rotation)")
            let inkSize = (width: ink.maxX - ink.minX, height: ink.maxY - ink.minY)
            let textSize = (width: text.maxX - text.minX, height: text.maxY - text.minY)
            // The text is screen-upright at every rotation: a line wider than tall.
            #expect(textSize.width > 2 * textSize.height, "\(rotation): text \(text)")
            // Old output at 90° and 270°, verified by restoring the page-axis contour: the fill
            // tall and narrow (its page-axis box turned on screen), the text spilling out of it
            // at both ends — both checks below failed at both rotations.
            #expect(inkSize.width > inkSize.height, "\(rotation): fill \(ink)")
            #expect(ink.minX <= text.minX && ink.maxX >= text.maxX && ink.minY <= text.minY && ink.maxY >= text.maxY,
                    "\(rotation): fill \(ink) holds text \(text)")
            // Centred on the anchor: page (300, 400) is the window's centre pixel (100, 100).
            #expect(abs((ink.minX + ink.maxX) / 2 - 100) <= 2 && abs((ink.minY + ink.maxY) / 2 - 100) <= 2, "\(rotation): \(ink)")
        }
    }

    @Test("U-077: the compiled pill's page box turns with the sheet; on an upright page it is the page-axis box it was")
    func compiledBoxTurns() throws {
        let upright = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 2)
        let flatCompiled = try #require(upright.compile(Self.pill))
        let flat = try #require(flatCompiled.bounds)
        // Screen right is page +y and screen up is page −x on a /Rotate 90 frame (y-down pixels).
        let quarter = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 2,
                                     pixelToPage: RenderTransform.Affine(a: 0, b: 0.5, c: 0.5, d: 0, tx: 0, ty: 0))
        let turnedCompiled = try #require(quarter.compile(Self.pill))
        let turned = try #require(turnedCompiled.bounds)
        #expect(flat.size.width > flat.size.height, "\(flat)")
        // Old output: the same wide page-axis box, which reads tall and narrow on screen.
        #expect(turned.size.height > turned.size.width, "\(turned)")
        #expect(abs(turned.size.height - flat.size.width) < 1e-6 && abs(turned.size.width - flat.size.height) < 1e-6,
                "flat \(flat), turned \(turned)")
        #expect(abs(turned.midX - 300) < 1e-6 && abs(turned.midY - 400) < 1e-6)
    }
}
