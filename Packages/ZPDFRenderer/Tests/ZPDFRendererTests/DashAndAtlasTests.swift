import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer

@Suite("Dash pattern")
struct DashPatternTests {

    @Test("An unusable pattern collapses to solid rather than looping or dividing by zero")
    func sanitization() {
        #expect(DashPattern(.pattern(runs: [], phase: 0)).isSolid)
        #expect(DashPattern(.pattern(runs: [0, 0], phase: 0)).isSolid)
        #expect(DashPattern(.pattern(runs: [.nan, 3], phase: 0)).isSolid == false)
        #expect(DashPattern(.pattern(runs: [-4, -2], phase: 0)).isSolid)
        #expect(DashPattern(.pattern(runs: [3], phase: .nan)).phase == 0)
        // An odd-length pattern repeats doubled, as PDF and Core Graphics define it.
        #expect(DashPattern(.pattern(runs: [3], phase: 0)).runArray == [3, 3])
    }

    @Test("The scale factor preserves the pattern's shape and floors its smallest run")
    func scalingRule() {
        let dotted = DashPattern(.pattern(runs: [1.2, 3.6], phase: 0))
        // At 100 % on Retina nothing is at risk: the scale is the plain pixel ratio.
        #expect(dotted.deviceScale(pixelsPerPagePoint: 2) == 2)
        // At 5 % the smallest run would be 0.06 px, so the whole pattern is scaled up together.
        let scale = dotted.deviceScale(pixelsPerPagePoint: 0.05)
        #expect(abs(scale - DashPattern.minimumRunPixels / 1.2) < 1e-12)
        let runs = dotted.devicePixelRuns(pixelsPerPagePoint: 0.05)
        #expect(abs(Double(runs[0]) - DashPattern.minimumRunPixels) < 1e-12)
        // The ratio between the runs is preserved exactly: the pattern still reads as dotted.
        #expect(abs(Double(runs[1]) / Double(runs[0]) - 3.0) < 1e-12)
    }

    @Test("Only four runs survive, so a pattern always fits one GPU instance")
    func runCap() {
        let many = DashPattern(.pattern(runs: [1, 2, 3, 4, 5, 6], phase: 0))
        #expect(many.runCount == 4)
        #expect(many.runArray == [1, 2, 3, 4])
    }

    @Test("Phase and per-segment arc length both enter the device phase")
    func phaseComposition() {
        let dashed = DashPattern(.pattern(runs: [9, 5], phase: 4))
        let phase = dashed.devicePixelPhase(pixelsPerPagePoint: 2, extraPagePoints: 10)
        #expect(abs(Double(phase) - 28) < 1e-12)
    }
}

@Suite("Atlases")
struct AtlasTests {

    @Test("Every count symbol has a tile with ink in it")
    func symbolAtlasHasInk() throws {
        let atlas = try #require(SymbolAtlas(tileSize: 32))
        for symbol in CountSymbol.allCases {
            let tile = try #require(atlas.tile(for: symbol))
            var ink = 0
            for y in tile.y..<(tile.y + tile.height) {
                for x in tile.x..<(tile.x + tile.width) where atlas.bitmap[x, y] > 8 {
                    ink += 1
                }
            }
            // Between one per cent and eighty: an empty tile and a solid block are both defects.
            let area = Double(tile.width * tile.height)
            let fraction = Double(ink) / area
            #expect(fraction > 0.01, "\(symbol) tile is empty")
            #expect(fraction < 0.80, "\(symbol) tile is a solid block")
        }
    }

    @Test("Symbol size buckets are fine enough that a tile is never badly resampled")
    func symbolBuckets() {
        for size in stride(from: 8.0, through: 256.0, by: 0.5) {
            let bucket = Double(SymbolAtlas.bucket(forDeviceSize: size))
            #expect(bucket >= 8)
            #expect(bucket <= 256)
            #expect(abs(bucket - size) / size < 0.12)
        }
        #expect(SymbolAtlas.bucket(forDeviceSize: .nan) == 16)
        // A non-positive size is a caller bug, not a size: it takes the default bucket.
        #expect(SymbolAtlas.bucket(forDeviceSize: -1) == 16)
        #expect(SymbolAtlas.bucket(forDeviceSize: 100_000) == 256)
    }

    @Test("The symbol atlas cache is bounded and reuses buckets")
    func symbolCacheBounded() {
        let cache = SymbolAtlasCache(capacity: 3)
        var seen: Set<Int> = []
        for size in stride(from: 8.0, through: 256.0, by: 4.0) {
            guard let atlas = cache.atlas(forDeviceSize: size) else { continue }
            seen.insert(atlas.tileSize)
        }
        #expect(cache.bucketCount <= 3)
        #expect(!seen.isEmpty)
        #expect(cache.residentByteCount > 0)
    }

    @Test("Glyph layout is deterministic, advances forward, and quantises to whole pixels")
    func glyphLayout() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 14)
        let first = atlas.layout("A-101 1 284,75 m2")
        let second = atlas.layout("A-101 1 284,75 m2")
        #expect(first == second)
        #expect(first.width > 0)
        #expect(first.height > 0)
        #expect(first.glyphs.count >= 12)
        var lastX = -Double.infinity
        for glyph in first.glyphs {
            #expect(glyph.x == glyph.x.rounded())
            #expect(glyph.y == glyph.y.rounded())
            #expect(glyph.x >= lastX - Double(atlas.pixelSize))
            lastX = glyph.x
        }
    }

    @Test("A label longer than the bound is truncated rather than allowed to allocate freely")
    func glyphLayoutIsBounded() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 8)
        let run = atlas.layout(String(repeating: "M", count: 5_000))
        #expect(run.glyphs.count <= RenderLimits.maximumLabelCharacters)
    }

    @Test("An empty string and a whitespace string lay out without producing ink")
    func emptyLabels() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 12)
        #expect(atlas.layout("").glyphs.isEmpty)
        #expect(atlas.layout("   ").glyphs.isEmpty)
        #expect(atlas.layout("   ").width > 0)
    }

    @Test("The glyph atlas grows and reports a new generation when it does")
    func atlasGrowth() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 64)
        let before = atlas.generation
        _ = atlas.layout("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        #expect(atlas.generation > before)
        #expect(atlas.bitmap.byteCount > 0)
    }

    @Test("The glyph atlas cache is bounded")
    func glyphCacheBounded() {
        let cache = GlyphAtlasCache(capacity: 2)
        for size in [8.0, 12.0, 24.0, 48.0] {
            _ = cache.atlas(fontName: "Helvetica", deviceSize: size).layout("1")
        }
        #expect(cache.residentByteCount > 0)
        cache.removeAll()
        #expect(cache.residentByteCount == 0)
    }

    @Test("An emoji is one glyph slot, and NFD normalises before layout (CR-90)")
    func glyphAtlasHandlesSurrogatesAndNormalization() {
        let atlas = GlyphAtlas(fontName: "Helvetica", pixelSize: 24)
        // 😀 (U+1F600) is one surrogate PAIR — two UTF-16 units. Old output: two `.notdef` boxes
        // for the one emoji, so "A😀B" laid out as four glyph slots. Now the trailing surrogate
        // is skipped and the pair is one slot, so at most three.
        let emoji = atlas.layout("A😀B")
        #expect(emoji.glyphs.count <= 3, "emoji laid out as \(emoji.glyphs.count) glyph slots")

        // NFD 'e' + combining acute normalises to the precomposed 'é', so it lays out to the same
        // glyph count and width. Old output: two glyphs (base + mark advanced independently).
        let precomposed = atlas.layout("\u{00E9}")
        let decomposed = atlas.layout("e\u{0301}")
        #expect(decomposed.glyphs.count == precomposed.glyphs.count,
                "NFD laid out \(decomposed.glyphs.count) glyphs, NFC \(precomposed.glyphs.count)")
        #expect(abs(decomposed.width - precomposed.width) < 0.5,
                "NFD width \(decomposed.width) != NFC width \(precomposed.width)")
    }

    @Test("The symbol atlas cache evicts the least recently used bucket deterministically (CR-91)")
    func symbolCacheEvictsLRU() {
        let cache = SymbolAtlasCache(capacity: 2)
        let bucketA = SymbolAtlas.bucket(forDeviceSize: 8)
        let bucketB = SymbolAtlas.bucket(forDeviceSize: 64)
        let bucketC = SymbolAtlas.bucket(forDeviceSize: 200)
        #expect(Set([bucketA, bucketB, bucketC]).count == 3, "sizes must map to distinct buckets")

        _ = cache.atlas(forDeviceSize: 8)
        _ = cache.atlas(forDeviceSize: 64)
        // Touch A so B becomes the least recently used.
        _ = cache.atlas(forDeviceSize: 8)
        // A third distinct bucket must evict the LRU (B) and create C. Old output: at capacity the
        // cache returned the numerically nearest existing bucket and never created C or evicted —
        // so C was absent and B stayed.
        _ = cache.atlas(forDeviceSize: 200)
        #expect(cache.bucketCount == 2)
        #expect(cache.residentBucketSizes.contains(bucketA), "the touched bucket A was evicted")
        #expect(cache.residentBucketSizes.contains(bucketC), "the new bucket C was never created")
        #expect(!cache.residentBucketSizes.contains(bucketB), "the least-recently-used bucket B was not evicted")
    }
}
