import CoreGraphics
import CoreText
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// `CoreGraphicsMarkupRenderer.AtlasImaging.outlines` — the mode a vector destination asks for.
///
/// The export side proves the *consequence*: a flattened sheet has no image XObject in it
/// (`ZPDFExportTests.FlattenedVectorTextTests`). This side proves the thing that would make that
/// a hollow win — that the outline is the **same glyph in the same place**, not a second, quietly
/// disagreeing way of drawing text. Two implementations of one drawing is the failure mode
/// `MarkupFlattener` was written to avoid, and adding a mode is exactly how it would sneak back.
@Suite("Vector ink imaging")
struct VectorInkImagingTests {

    // MARK: - The outline sits in the tile's frame

    @Test("A glyph's outline occupies its atlas tile, inset by the tile's padding")
    func outlineFillsTheTile() throws {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 32)
        let run = atlas.layout("Hg8,2m²")
        #expect(run.glyphs.count == 7)
        var checked = 0
        for positioned in run.glyphs {
            let outline = try #require(
                atlas.tileOutline(for: positioned.glyph),
                "glyph \(positioned.glyph) has a tile but no outline"
            )
            let box = outline.boundingBox
            let tile = positioned.tile
            // The tile is the ink box grown by one pixel of padding on each side and rounded up,
            // so the outline starts at (1, 1) and ends within a pixel of the far corner.
            #expect(abs(Double(box.minX) - 1) < 0.001, "left edge: \(box.minX)")
            #expect(abs(Double(box.minY) - 1) < 0.001, "bottom edge: \(box.minY)")
            #expect(Double(box.maxX) <= Double(tile.width) - 1 + 0.001, "right edge: \(box.maxX)")
            #expect(Double(box.maxY) <= Double(tile.height) - 1 + 0.001, "top edge: \(box.maxY)")
            #expect(Double(box.maxX) >= Double(tile.width) - 2 - 0.001, "too narrow: \(box.maxX)")
            #expect(Double(box.maxY) >= Double(tile.height) - 2 - 0.001, "too short: \(box.maxY)")
            checked += 1
        }
        #expect(checked == run.glyphs.count)
    }

    @Test("A whitespace glyph has no outline, exactly as it has no tile")
    func whitespaceHasNoOutline() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 24)
        let run = atlas.layout("a b")
        // Two glyphs laid out; the space contributes an advance and no ink.
        #expect(run.glyphs.count == 2)
        var space: CGGlyph = 0
        var characters: [UniChar] = Array(" ".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1)
        space = glyphs[0]
        #expect(atlas.tileOutline(for: space) == nil)
    }

    // MARK: - The two modes draw the same picture

    private static func page() -> PageDescriptor {
        PageDescriptor(
            id: PageID(UUID()),
            documentID: DocumentID(UUID()),
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 240, height: 120),
                crop: PDFRect(x: 0, y: 0, width: 240, height: 120)
            ),
            rotation: .degrees0
        )
    }

    private static func scene() -> [RenderableMarkup] {
        [
            RenderableMarkup(
                id: MarkupID(UUID()),
                zIndex: 0,
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: PDFPoint(x: 12, y: 90),
                    text: "14,72 m",
                    fontName: "Helvetica",
                    fontSize: 14
                )),
                style: RenderStyle(
                    stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1
                )
            ),
            RenderableMarkup(
                id: MarkupID(UUID()),
                zIndex: 1,
                shape: .countSymbol(RenderCountSymbol(
                    center: PDFPoint(x: 180, y: 40), symbol: .filledDiamond, size: 24
                )),
                style: RenderStyle(
                    stroke: RGBAColor(red: 0.1, green: 0.4, blue: 0.1, alpha: 1),
                    fill: RGBAColor(red: 0.1, green: 0.4, blue: 0.1, alpha: 1),
                    lineWidth: 1
                )
            )
        ]
    }

    private static func raster(
        _ imaging: CoreGraphicsMarkupRenderer.AtlasImaging
    ) throws -> RasterImage {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.atlasImaging = imaging
        renderer.update(
            page: page(),
            markups: scene(),
            selection: .empty,
            snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page(), zoom: 3, backingScale: 1)
        )
        return try renderer.renderOffscreen()
    }

    /// The bounding box of everything with ink in it, in pixels.
    private static func inkBox(_ image: RasterImage) -> (Int, Int, Int, Int)? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<image.height {
            for x in 0..<image.width where image.alpha(x: x, y: y) > 0.05 {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return (minX, minY, maxX, maxY)
    }

    @Test("Outlines and atlas tiles put the same ink in the same place")
    func bothModesAgree() throws {
        let masked = try Self.raster(.atlas)
        let outlined = try Self.raster(.outlines)
        #expect(masked.width == outlined.width)
        #expect(masked.height == outlined.height)

        // **Placement** is the claim, and it is exact to the pixel: the outline is filled in its
        // tile's own frame, at the same whole-pixel origin the tile would have been blitted to.
        let a = try #require(Self.inkBox(masked))
        let b = try #require(Self.inkBox(outlined))
        #expect(abs(a.0 - b.0) <= 1, "left edge \(a.0) vs \(b.0)")
        #expect(abs(a.1 - b.1) <= 1, "top edge \(a.1) vs \(b.1)")
        #expect(abs(a.2 - b.2) <= 1, "right edge \(a.2) vs \(b.2)")
        #expect(abs(a.3 - b.3) <= 1, "bottom edge \(a.3) vs \(b.3)")

        let comparison = ImageComparator.compare(masked, outlined)
        // **Coverage** is close but deliberately not identical, and the honest number is recorded
        // here rather than hidden behind a widened tolerance. `CTFontDrawGlyphs` hints a glyph
        // onto the pixel grid when it rasterises the tile; a filled outline is unhinted, so stem
        // edges land a fraction of a pixel apart and one 16-pixel tile of a seven-glyph label
        // differs by about 6 % of its coverage. That is the whole reason this is not the default:
        // on a screen the hinted tile is the better picture, and a golden must keep comparing the
        // two backends rather than two rasterisers. On paper there is no pixel grid to hint to,
        // and the outline is the only one of the two that is not capped at 72 dpi.
        #expect(comparison.meanChannelDifference < 0.005, "\(comparison.summary)")
        #expect(comparison.differingPixelFraction < 0.02, "\(comparison.summary)")
        // Both actually drew something — two empty rasters would also "agree".
        #expect(comparison.inkRatio > 0.001, "no ink: \(comparison.summary)")
    }

    @Test("Outlines are the opt-in; the default is still the atlas")
    func defaultIsUnchanged() {
        #expect(CoreGraphicsMarkupRenderer().atlasImaging == .atlas)
    }
}
