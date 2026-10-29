import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Bug hunt 2: the glyph and symbol atlases, and the Metal renderer's use of them.
@Suite("Fix2 atlases", .serialized)
struct Fix2AtlasTests {

    private static func id(_ n: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (0xF2, 0xA7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
    }

    private static let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)

    /// Pixels whose red channel clearly dominates — the pill text in the BH-031 scene.
    private static func redInk(_ image: RasterImage) -> Int {
        var count = 0
        var offset = 0
        while offset < image.pixels.count {
            let r = Int(image.pixels[offset]), g = Int(image.pixels[offset + 1])
            if r > 120, r > g + 80 { count += 1 }
            offset += 4
        }
        return count
    }

    // MARK: BH-031 / IM-196

    @Test("BH-031: a measurement pill keeps its text while text labels walk through 20 atlas buckets")
    func pillSurvivesBucketChurn() throws {
        let page = SceneIdentity.page()
        let pill = RenderableMarkup(
            id: Self.id(1),
            shape: .labelPill(RenderLabelPill(anchorPoint: PDFPoint(x: 100, y: 700), text: "12,50 m")),
            style: RenderStyle(stroke: Self.red)
        )
        let label = RenderableMarkup(
            id: Self.id(2),
            shape: .textLabel(RenderTextLabel(anchorPoint: PDFPoint(x: 300, y: 400), text: "Wall", fontSize: 11)),
            style: RenderStyle(stroke: .opaqueBlack)
        )
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        let window = PDFRect(x: 40, y: 660, width: 120, height: 80)
        // Each step moves the label's device size by about one pixel — one new glyph bucket —
        // while the pill, sized in view points, stays on one bucket. Old output: FIFO eviction of
        // the pill's bucket once 16 newer buckets existed; the backend re-fetched it as a fresh
        // empty atlas and the pill text vanished (red ink 0) from step 16 on.
        for step in 0..<20 {
            let zoom = 0.5 + Double(step) * 0.1
            guard let viewport = RenderViewport.window(page, zoom: zoom, backingScale: 1, pageRect: window)
            else { Issue.record("no viewport"); return }
            renderer.update(page: page, markups: [pill, label], selection: .empty, snapFeedback: nil, viewport: viewport)
            let image = try renderer.renderOffscreen()
            #expect(Self.redInk(image) > 10, "pill text blank at step \(step) (zoom \(zoom))")
        }
    }

    @Test("BH-031: a pinned atlas is never evicted, and trim returns the cache to its bound")
    func pinnedAtlasIsNotEvicted() {
        let cache = GlyphAtlasCache(capacity: 2)
        let pinned = cache.atlas(fontName: "Helvetica", deviceSize: 10)
        _ = pinned.layout("12")
        cache.pin(fontName: "Helvetica", bucket: 10)
        for size in [12.0, 14.0, 16.0, 18.0] {
            _ = cache.atlas(fontName: "Helvetica", deviceSize: size)
        }
        #expect(cache.isResident(fontName: "Helvetica", bucket: 10))
        #expect(cache.atlas(fontName: "Helvetica", deviceSize: 10) === pinned, "a live atlas was replaced")
        #expect(cache.atlasCount == 2)
        cache.unpin(fontName: "Helvetica", bucket: 10)
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 20)
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 22)
        cache.trim()
        #expect(!cache.isResident(fontName: "Helvetica", bucket: 10))
        #expect(cache.atlasCount == 2)
    }

    @Test("IM-196: the glyph atlas cache is least-recently-used")
    func glyphCacheIsLRU() {
        let cache = GlyphAtlasCache(capacity: 2)
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 10)
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 12)
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 10) // touch
        _ = cache.atlas(fontName: "Helvetica", deviceSize: 14)
        // Old output: FIFO evicted 10 (first inserted) although it had just been used.
        #expect(cache.isResident(fontName: "Helvetica", bucket: 10))
        #expect(!cache.isResident(fontName: "Helvetica", bucket: 12))
        #expect(cache.isResident(fontName: "Helvetica", bucket: 14))
    }

    // MARK: BH-619

    @Test("BH-619: a full atlas counts the glyphs it refuses and does not re-rasterise them")
    func fullAtlasRefusesOnce() {
        let atlas = GlyphAtlas(fontName: "PingFang SC", pixelSize: 256)
        // 700 distinct CJK ideographs at 256 px cannot fit under the 16 384-px height cap.
        let scalars = (0x4E00..<0x4E00 + 700).compactMap(Unicode.Scalar.init)
        let text = String(String.UnicodeScalarView(scalars))
        var laidOut = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            laidOut += atlas.layout(String(text[start..<end])).glyphs.count
            start = end
        }
        #expect(atlas.refusedGlyphCount > 0, "the atlas never filled; the test did not exercise the cap")
        #expect(laidOut + atlas.refusedGlyphCount <= 700)
        let generation = atlas.generation
        let refused = atlas.refusedGlyphCount
        _ = atlas.layout(String(text.suffix(50)))
        // Old output: the refused glyph was rasterised again on every layout and not remembered.
        #expect(atlas.generation == generation)
        #expect(atlas.refusedGlyphCount == refused)
    }

    // MARK: Metal atlas bookkeeping

    private func labelScene(_ texts: [String], fontSize: Double = 11) -> [RenderableMarkup] {
        texts.enumerated().map { index, text in
            RenderableMarkup(
                id: Self.id(UInt8(10 + index)),
                revision: 1,
                zIndex: index,
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: PDFPoint(x: 40, y: 740 - Double(index) * 40),
                    text: text,
                    fontSize: fontSize
                )),
                style: RenderStyle(stroke: .opaqueBlack)
            )
        }
    }

    private static let manyGlyphs: String = {
        var scalars: [Unicode.Scalar] = []
        for value in 0x00C0...0x017F { if let s = Unicode.Scalar(value) { scalars.append(s) } }
        for value in 0x0021...0x007E { if let s = Unicode.Scalar(value) { scalars.append(s) } }
        return String(String.UnicodeScalarView(scalars))
    }()

    @Test("BH-200: a glyph atlas doubling its height does not garble the labels already uploaded")
    func atlasGrowthKeepsOtherLabels() throws {
        // Precondition: the long label really does make an 11 px atlas grow.
        let probe = GlyphAtlas(fontName: "Helvetica", pixelSize: 11)
        let initialHeight = probe.atlasSize.height
        _ = probe.layout("Room 101")
        _ = probe.layout(Self.manyGlyphs)
        #expect(probe.atlasSize.height > initialHeight)

        let page = SceneIdentity.page()
        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let before = labelScene(["Room 101", "x"])
        var after = before
        after[1].revision = 2
        if case var .textLabel(label) = after[1].shape {
            label.text = Self.manyGlyphs
            after[1].shape = .textLabel(label)
        }

        let evolved = try MetalMarkupRenderer()
        defer { evolved.dispose() }
        evolved.update(page: page, markups: before, selection: .empty, snapFeedback: nil, viewport: viewport)
        let first = try evolved.renderOffscreen()
        evolved.update(page: page, markups: after, selection: .empty, snapFeedback: nil, viewport: viewport)
        let second = try evolved.renderOffscreen()

        // The unchanged label's rows must be byte-identical across the edit. Old output: its
        // instances kept v normalised to the old height and sampled row 2y after the doubling.
        let rows = 30..<75
        for y in rows {
            for x in 0..<300 {
                if first.pixel(x: x, y: y) != second.pixel(x: x, y: y) {
                    Issue.record("unchanged label changed at (\(x), \(y))")
                    return
                }
            }
        }
    }

    @Test("BH-201: a re-created glyph atlas with the stored generation still re-uploads its texture")
    func recreatedAtlasReuploads() throws {
        let page = SceneIdentity.page()
        let home = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        var markups = labelScene(["AB"], fontSize: 30)
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: home)
        // Walk the label through enough other buckets that its home bucket is evicted.
        for step in 1...24 {
            let zoom = 1 + Double(step) * 0.07
            renderer.update(
                page: page,
                markups: markups,
                selection: .empty,
                snapFeedback: nil,
                viewport: RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 1)
            )
        }
        // Back home with the glyphs in the opposite order: the fresh atlas packs B first, and
        // reaches generation 2 exactly as the old one did.
        markups[0].revision = 2
        markups[0].shape = .textLabel(RenderTextLabel(anchorPoint: PDFPoint(x: 40, y: 740), text: "BA", fontSize: 30))
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: home)
        let evolved = try renderer.renderOffscreen()

        let fresh = try MetalMarkupRenderer()
        defer { fresh.dispose() }
        fresh.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: home)
        let reference = try fresh.renderOffscreen()
        // Old output: the stale texture (A at B's tile) was kept and the label read "AB".
        #expect(evolved == reference)
    }

    @Test("BH-199: a zoom step re-buckets count symbols on a reused Metal renderer")
    func zoomRebucketsSymbols() throws {
        let page = SceneIdentity.page()
        let symbol = RenderableMarkup(
            id: Self.id(3),
            shape: .countSymbol(RenderCountSymbol(center: PDFPoint(x: 300, y: 400), symbol: .star, size: 16)),
            style: RenderStyle(stroke: .opaqueBlack, fill: .opaqueBlack)
        )
        let window = PDFRect(x: 280, y: 380, width: 40, height: 40)
        guard let near = RenderViewport.window(page, zoom: 1, backingScale: 1, pageRect: window),
              let far = RenderViewport.window(page, zoom: 8, backingScale: 1, pageRect: window)
        else { Issue.record("no viewport"); return }

        let reused = try MetalMarkupRenderer()
        defer { reused.dispose() }
        reused.update(page: page, markups: [symbol], selection: .empty, snapFeedback: nil, viewport: near)
        reused.update(page: page, markups: [symbol], selection: .empty, snapFeedback: nil, viewport: far)
        let zoomed = try reused.renderOffscreen()

        let fresh = try MetalMarkupRenderer()
        defer { fresh.dispose() }
        fresh.update(page: page, markups: [symbol], selection: .empty, snapFeedback: nil, viewport: far)
        let reference = try fresh.renderOffscreen()
        // Old output: the reused renderer kept the 16-px tile stretched to 128 px (blurred edges).
        #expect(zoomed == reference)
    }

    @Test("BH-630: deleted markups leave no bucket or font entry behind")
    func removedMarkupsArePruned() throws {
        let page = SceneIdentity.page()
        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let keep = labelScene(["kept"])
        var all = keep
        for n in 0..<20 {
            all.append(RenderableMarkup(
                id: MarkupID(UUID()),
                shape: .countSymbol(RenderCountSymbol(center: PDFPoint(x: 20 + Double(n) * 10, y: 100), symbol: .filledCircle, size: 6))
            ))
        }
        renderer.update(page: page, markups: all, selection: .empty, snapFeedback: nil, viewport: viewport)
        #expect(renderer.trackedAtlasMarkupCount == 21)
        renderer.update(page: page, markups: keep, selection: .empty, snapFeedback: nil, viewport: viewport)
        // Old output: 21 — the twenty deleted count markups stayed in the map forever.
        #expect(renderer.trackedAtlasMarkupCount == 1)
    }
}
