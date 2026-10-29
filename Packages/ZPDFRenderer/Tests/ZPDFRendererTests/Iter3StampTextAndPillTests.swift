import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Iteration 3: a turned stamp's field text turns with the seal in
/// both backends (T-065), and an area pill never sits over a slot or a thin hole that crosses
/// its box between the corners (T-067).
@Suite("Iter3 stamp text rotation and area pills", .serialized)
struct Iter3StampTextAndPillTests {

    // MARK: T-065

    private static let page = SceneIdentity.page()
    private static let stampID = MarkupID(UUID(uuidString: "17E30650-0000-4000-8000-000000000001") ?? UUID())

    /// A 200 × 40 pt stamp at (300, 400) with one field filling the box, centred, 20 pt text.
    /// No artwork, so all the ink is the field's.
    private static func stamp(rotation: Double) -> [RenderableMarkup] {
        StampArtworkScene.markups(
            artwork: StampArtworkGeometry.empty,
            labels: [StampSceneLabel(
                text: "APPROVED ESTIMATE",
                normalizedFrame: PDFRect(x: 0, y: 0, width: 1, height: 1),
                fontSizeFraction: 0.5,
                anchor: .center
            )],
            center: PDFPoint(x: 300, y: 400),
            size: PDFSize(width: 200, height: 40),
            rotationDegrees: rotation,
            style: RenderStyle(stroke: .opaqueBlack, fill: .opaqueBlack, lineWidth: 1),
            baseID: stampID
        )
    }

    /// A 300 × 300 px window, page x 150…450 and y 250…550 at zoom 1, so the stamp's centre is
    /// pixel (150, 150).
    private static func render(_ renderer: any OffscreenMarkupRendering, rotation: Double) throws -> RasterImage {
        let viewport = try #require(RenderViewport.window(
            page, zoom: 1, backingScale: 1, pageRect: PDFRect(x: 150, y: 250, width: 300, height: 300)
        ))
        renderer.update(page: page, markups: stamp(rotation: rotation), selection: .empty,
                        snapFeedback: nil, viewport: viewport)
        return try renderer.renderOffscreen()
    }

    /// The bounding box of every pixel with ink, as (minX, minY, maxX, maxY).
    private static func inkBox(_ image: RasterImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).3 > 32 {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return box
    }

    /// One render on a fresh renderer: a renderer keeps a compiled slot while the markup's id
    /// and revision are unchanged, so re-rendering the same ids at another angle on one renderer
    /// would show the first angle again.
    private static func inkBox(metal: Bool, rotation: Double) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let renderer: any OffscreenMarkupRendering = metal ? try MetalMarkupRenderer() : CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        return inkBox(try render(renderer, rotation: rotation))
    }

    @Test("T-065: a 90° stamp's field text runs up the stamp, in Core Graphics and in Metal alike")
    func turnedStampTextTurns() throws {
        let upright = try #require(try Self.inkBox(metal: false, rotation: 0))
        let turned = try #require(try Self.inkBox(metal: false, rotation: 90))
        let uprightSize = (width: upright.maxX - upright.minX, height: upright.maxY - upright.minY)
        let turnedSize = (width: turned.maxX - turned.minX, height: turned.maxY - turned.minY)
        // Unturned: a line of text, far wider than tall.
        #expect(uprightSize.width > 3 * uprightSize.height, "\(upright)")
        // Old output: the same wide, short box at 90° (the anchor turned, the text did not), so
        // the text ran across a 40 pt wide, 200 pt tall stamp.
        #expect(turnedSize.height > 3 * turnedSize.width, "\(turned)")
        // The text's extents swap, and it stays centred on the stamp.
        #expect(abs(turnedSize.height - uprightSize.width) <= 3 && abs(turnedSize.width - uprightSize.height) <= 3,
                "upright \(uprightSize), turned \(turnedSize)")
        #expect(abs((turned.minX + turned.maxX) / 2 - 150) <= 2 && abs((turned.minY + turned.maxY) / 2 - 150) <= 2, "\(turned)")

        // The GPU draws the same turn, and the same upright text.
        let gpu = try #require(try Self.inkBox(metal: true, rotation: 90))
        #expect(abs(gpu.minX - turned.minX) <= 2 && abs(gpu.maxX - turned.maxX) <= 2
                && abs(gpu.minY - turned.minY) <= 2 && abs(gpu.maxY - turned.maxY) <= 2,
                "metal \(gpu), core graphics \(turned)")
        let gpuUpright = try #require(try Self.inkBox(metal: true, rotation: 0))
        #expect(abs(gpuUpright.minX - upright.minX) <= 1 && abs(gpuUpright.maxX - upright.maxX) <= 1
                && abs(gpuUpright.minY - upright.minY) <= 1 && abs(gpuUpright.maxY - upright.maxY) <= 1,
                "an unturned label draws alike: metal \(gpuUpright), core graphics \(upright)")
    }

    @Test("T-065: the compiled glyphs read bottom to top at 90° and carry the turn; an upright label carries none")
    func compiledGlyphsCarryTheTurn() throws {
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        let label = try #require(Self.stamp(rotation: 90).first)
        let compiled = try #require(compiler.compile(label))
        // Page 90° counter-clockwise is straight up on screen: −90° in y-down pixels, 3/4 turn.
        #expect(compiled.glyphs.allSatisfy { $0.rotationSteps == 49_152 })
        let ys = compiled.glyphs.map(\.offsetY)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0.0 > $0.1 }, "each glyph above the last: \(ys)")
        // Its selection bounds are tall too: about 20 pt wide, about 170 pt tall.
        let bounds = try #require(compiled.bounds)
        #expect(bounds.size.height > 3 * bounds.size.width, "\(bounds)")

        // A stamp at 0° and a plain label: no turn at all.
        let flatLabel = try #require(Self.stamp(rotation: 0).first)
        let flat = try #require(compiler.compile(flatLabel))
        #expect(flat.glyphs.allSatisfy { $0.rotationSteps == 0 })
        let plain = RenderableMarkup(id: Self.stampID, shape: .textLabel(RenderTextLabel(
            anchorPoint: PDFPoint(x: 300, y: 400), text: "APPROVED ESTIMATE", fontSize: 20, anchor: .center
        )), style: RenderStyle(stroke: .opaqueBlack, lineWidth: 1))
        let plainCompiled = try #require(compiler.compile(plain))
        #expect(plainCompiled.glyphs.map(\.offsetX) == flat.glyphs.map(\.offsetX))
        #expect(plainCompiled.glyphs.allSatisfy { $0.rotationSteps == 0 })
    }

    @Test("T-065: the turn is read off the frame — a page shown turned 90° clockwise turns a 0° stamp's text down the screen")
    func turnFollowsTheFrame() {
        // Page +x to pixel +y and page +y to pixel +x: its own inverse.
        let turnedView = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1,
                                        pixelToPage: RenderTransform.Affine(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        #expect(turnedView.pixelRotationSteps(pageDegrees: 0) == 16_384, "a quarter turn clockwise on screen")
        let flippedView = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 2)
        #expect(flippedView.pixelRotationSteps(pageDegrees: 0) == 0)
        #expect(flippedView.pixelRotationSteps(pageDegrees: 180) == 32_768)
        #expect(flippedView.pixelRotationSteps(pageDegrees: -90) == 16_384)
        #expect(flippedView.pixelRotationSteps(pageDegrees: .nan) == 0)
    }

    @Test("T-065: a turned glyph is hit where it is drawn, not where the upright text would be")
    func turnedTextHitTestsWhereDrawn() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        _ = try Self.render(renderer, rotation: 90)
        // 60 pt above the centre, on the turned text; 60 pt to the right, where upright text sat.
        #expect(renderer.hitTest(pagePoint: CGPoint(x: 300, y: 460), toleranceInPagePoints: 2) != nil)
        #expect(renderer.hitTest(pagePoint: CGPoint(x: 360, y: 400), toleranceInPagePoints: 0) == nil)
    }

    // MARK: T-067

    /// 200 × 100 with a 5 pt slot at x 110…115 from y 30 up to the top edge. Area
    /// 20 000 − 350 = 19 650; centroid ((2 000 000 − 350 · 112.5) / 19 650,
    /// (1 000 000 − 350 · 65) / 19 650) = (99.78, 49.73). A 60 × 16 pill there spans
    /// x 69.78…129.78, y 41.73…57.73: centre and all four corners in the fill, the slot through
    /// its middle, and none of the slot's vertices (at y 30 and 100) inside it.
    static let slotted = [
        PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 100), PDFPoint(x: 115, y: 100),
        PDFPoint(x: 115, y: 30), PDFPoint(x: 110, y: 30), PDFPoint(x: 110, y: 100), PDFPoint(x: 0, y: 100),
    ]

    @Test("T-067: a slot crossing the pill box between its corners sends the pill to the leader")
    func slotBetweenCornersFallsBack() throws {
        let centroid = try #require(AreaPillPlacement.centroid(of: Self.slotted))
        #expect(abs(centroid.x - 1_960_625.0 / 19_650) < 1e-9 && abs(centroid.y - 977_250.0 / 19_650) < 1e-9)
        let placement = try #require(AreaPillPlacement.placement(polygon: Self.slotted, pillHalfWidth: 30, pillHalfHeight: 8))
        // Old output: interior at the centroid, the number printed across the slot.
        #expect(!placement.isInterior)
        #expect(placement.leaderStart == PDFPoint(x: 0, y: 0))
        // A pill narrow enough to sit left of the slot stays inside.
        let narrow = try #require(AreaPillPlacement.placement(polygon: Self.slotted, pillHalfWidth: 8, pillHalfHeight: 8))
        #expect(narrow.isInterior)
    }

    @Test("T-067: a long thin hole through the pill box with no vertex inside it sends the pill to the leader")
    func thinHoleThroughTheBoxFallsBack() throws {
        let outer = [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 100), PDFPoint(x: 0, y: 100)]
        // A 1 pt shaft at y 53…54 from x 20 to 180: the pill box (70…130 × 42…58) straddles it,
        // its corners (y 42 and 58) and centre (y 50) miss it, and its vertices are outside.
        let shaft = [PDFPoint(x: 20, y: 53), PDFPoint(x: 180, y: 53), PDFPoint(x: 180, y: 54), PDFPoint(x: 20, y: 54)]
        let placement = try #require(AreaPillPlacement.placement(polygon: outer, holes: [shaft], pillHalfWidth: 30, pillHalfHeight: 8))
        // Old output: interior at (100, 50).
        #expect(!placement.isInterior)
        // Moved clear of the box, it no longer matters.
        let clear = shaft.map { PDFPoint(x: $0.x, y: $0.y + 20) }
        let clearPlacement = try #require(AreaPillPlacement.placement(polygon: outer, holes: [clear], pillHalfWidth: 30, pillHalfHeight: 8))
        #expect(clearPlacement.isInterior)
    }

    @Test("T-067: segment against box — crossing, inside, touching and missing")
    func segmentMeetsBox() {
        func meets(_ a: (Double, Double), _ b: (Double, Double)) -> Bool {
            AreaPillPlacement.segmentMeetsBox(PDFPoint(x: a.0, y: a.1), PDFPoint(x: b.0, y: b.1),
                                              minX: 0, minY: 0, maxX: 10, maxY: 10)
        }
        #expect(meets((-5, 5), (15, 5)), "straight through")
        #expect(meets((2, 2), (3, 3)), "wholly inside")
        #expect(meets((10, -5), (10, 15)), "along an edge")
        #expect(meets((-1, 11), (11, -1)), "across a corner region")
        #expect(!meets((-5, 11), (15, 11)), "above")
        #expect(!meets((11, 15), (15, 11)), "beside a corner")
        #expect(!meets((12, 5), (12, 5)), "a point outside")
    }
}
