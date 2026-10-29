import CoreGraphics
import CoreText
import Foundation

/// One positioned glyph inside a laid-out label, in device pixels relative to the label origin.
public struct PositionedGlyph: Sendable, Hashable {
    public var tile: AtlasTile
    /// Which glyph of the font this is. Carried alongside the tile so a consumer that must not
    /// rasterise — the PDF flatten path — can ask the atlas for the same glyph's **outline**
    /// instead of its coverage tile. See ``GlyphAtlas/tileOutline(for:)``.
    public var glyph: CGGlyph
    /// Left edge of the glyph's ink, relative to the label origin, in device pixels.
    public var x: Double
    /// Top edge of the glyph's ink, relative to the label's **top**, in device pixels, y down.
    public var y: Double

    public init(tile: AtlasTile, glyph: CGGlyph = 0, x: Double, y: Double) {
        self.tile = tile; self.glyph = glyph; self.x = x; self.y = y
    }
}

/// A laid-out single-line label in device pixels.
public struct GlyphRun: Sendable, Hashable {
    public var glyphs: [PositionedGlyph]
    public var width: Double
    public var height: Double
    /// Distance from the label's top edge down to the baseline, in device pixels.
    public var ascent: Double

    public init(glyphs: [PositionedGlyph], width: Double, height: Double, ascent: Double) {
        self.glyphs = glyphs; self.width = width; self.height = height; self.ascent = ascent
    }

    public static let empty = GlyphRun(glyphs: [], width: 0, height: 0, ascent: 0)
}

/// A shelf-packed alpha atlas of rasterised glyphs, for one font at one device pixel size.
///
/// # Scope, stated plainly
///
/// Layout is advance-based over the UTF-16 code units of the string: one font, left to right, no
/// bidi reordering, no ligature or mark substitution, no fallback cascade for characters the font
/// lacks (those become the font's `.notdef` and are drawn as such rather than silently dropped).
/// That covers the entire label vocabulary of a takeoff — quantities, unit strings, subject names
/// — and it is written down here rather than discovered later. A label that needs shaping belongs
/// in a text markup, which is a different surface with a different renderer.
///
/// Both backends consume this same object, so a label lands on the same pixels either way.
public final class GlyphAtlas {

    /// Font size buckets in device pixels. Rounding to a bucket means a small zoom nudge does not
    /// re-rasterise every glyph on the page.
    public static func bucket(forDeviceSize size: Double) -> Int {
        guard size.isFinite, size > 0 else { return 11 }
        let clamped = Swift.min(256.0, Swift.max(4.0, size))
        // Half-integer buckets below 24 px, whole above: small text is where a one-pixel size
        // change is visible, large text is where the atlas cost matters.
        return clamped < 24 ? Int(clamped.rounded()) : Int((clamped / 2).rounded()) * 2
    }

    public let fontName: String
    public let pixelSize: Int
    public private(set) var bitmap: AlphaBitmap
    /// Bumped whenever ``bitmap`` grows or gains a tile, so a GPU texture knows to re-upload.
    public private(set) var generation: UInt64 = 0

    private let font: CTFont
    private let ascent: Double
    private let descent: Double
    private var tiles: [CGGlyph: AtlasTile] = [:]
    private var advances: [CGGlyph: Double] = [:]
    private var boundingBoxes: [CGGlyph: CGRect] = [:]
    private var outlines: [CGGlyph: CGPath?] = [:]
    /// Glyphs the atlas had no room for. Remembered, so a refused glyph is not rasterised again
    /// by every later layout only to be refused again (BH-619).
    private var refused: Set<CGGlyph> = []

    /// Distinct glyphs this atlas could not hold because it had reached
    /// ``RenderLimits/maximumTargetPixels``. Such a glyph is left out of its run — the pen still
    /// advances, so the rest of the label keeps its place — and is counted here rather than
    /// dropped silently.
    public var refusedGlyphCount: Int { refused.count }

    /// Clear pixels kept around a glyph's ink inside its tile, so an atlas neighbour can never
    /// bleed in under linear sampling. It is also the offset between the tile's corner and the
    /// ink's bounding box, which is why ``tileOutline(for:)`` needs the same number.
    private static let tilePadding = 1
    private var shelfX = 1
    private var shelfY = 1
    private var shelfHeight = 0
    private var atlasWidth: Int
    private var atlasHeight: Int

    public init(fontName: String, pixelSize: Int) {
        let clampedSize = Swift.min(256, Swift.max(4, pixelSize))
        self.fontName = fontName
        self.pixelSize = clampedSize
        let created = CTFontCreateWithName(fontName as CFString, CGFloat(clampedSize), nil)
        self.font = created
        self.ascent = Double(CTFontGetAscent(created))
        self.descent = Double(CTFontGetDescent(created))
        // One row of a 128-wide atlas holds roughly sixteen 8 px glyphs; the shelf packer grows
        // the height as needed and never shrinks, which is what makes the generation counter a
        // sufficient invalidation signal.
        let initial = Swift.min(2048, Swift.max(128, clampedSize * 16))
        self.atlasWidth = initial
        self.atlasHeight = initial
        self.bitmap = AlphaBitmap(width: initial, height: initial)
    }

    public var lineHeight: Double { ascent + descent }
    public var atlasSize: PixelSize { PixelSize(width: atlasWidth, height: atlasHeight) }

    /// Lays out `text`, rasterising any glyph the atlas does not hold yet.
    ///
    /// The returned origins are quantised to whole device pixels, which is what lets the Core
    /// Graphics backend blit a tile with no resampling and the Metal backend draw a texel-aligned
    /// quad. Both then show the same pixels rather than two different subpixel phases of them.
    public func layout(_ text: String) -> GlyphRun {
        // Normalise to precomposed form (NFC) so a base+combining-mark sequence becomes the one
        // precomposed character the font has a glyph and an advance for, instead of two glyphs
        // rounded and advanced independently (CR-90).
        let normalized = text.precomposedStringWithCanonicalMapping
        let truncated = String(normalized.prefix(RenderLimits.maximumLabelCharacters))
        guard !truncated.isEmpty else { return .empty }

        let utf16 = Array(truncated.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let mapped = utf16.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { output -> Bool in
                guard let source = characters.baseAddress, let destination = output.baseAddress
                else { return false }
                return CTFontGetGlyphsForCharacters(font, source, destination, utf16.count)
            }
        }
        // `false` means at least one character has no glyph in this font; the rest still map, and
        // the unmapped ones come back as glyph 0, which is `.notdef` and is drawn as the box the
        // font defines. Nothing is silently dropped.
        _ = mapped

        var positioned: [PositionedGlyph] = []
        positioned.reserveCapacity(glyphs.count)
        var penX = 0.0
        var index = 0
        while index < glyphs.count {
            // A character outside the BMP is one surrogate PAIR in UTF-16. CTFont puts the pair's
            // glyph in the high-surrogate slot and 0 in the low-surrogate slot, so skipping the
            // trailing surrogate makes an emoji one glyph — its `.notdef` box for a font without
            // it — not two (CR-90).
            if UTF16.isTrailSurrogate(utf16[index]) {
                index += 1
                continue
            }
            let glyph = glyphs[index]
            let advance = advance(of: glyph)
            if let tile = tile(for: glyph), tile.width > 0, tile.height > 0 {
                positioned.append(PositionedGlyph(
                    tile: tile,
                    glyph: glyph,
                    x: (penX + tile.bearingX).rounded(),
                    y: (ascent - tile.bearingY).rounded()
                ))
            }
            penX += advance
            index += 1
        }
        return GlyphRun(
            glyphs: positioned,
            width: penX.rounded(.up),
            height: (ascent + descent).rounded(.up),
            ascent: ascent
        )
    }

    /// The horizontal advance of one glyph in device pixels.
    private func advance(of glyph: CGGlyph) -> Double {
        if let cached = advances[glyph] { return cached }
        var single = glyph
        var rect = CGSize.zero
        withUnsafeMutablePointer(to: &single) { glyphPointer in
            withUnsafeMutablePointer(to: &rect) { sizePointer in
                _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphPointer, sizePointer, 1)
            }
        }
        let value = Double(rect.width)
        advances[glyph] = value
        return value
    }

    /// The ink bounding box of one glyph at this atlas's pixel size, y-up from the baseline.
    private func boundingBox(of glyph: CGGlyph) -> CGRect {
        if let cached = boundingBoxes[glyph] { return cached }
        var single = glyph
        var box = CGRect.zero
        withUnsafeMutablePointer(to: &single) { glyphPointer in
            withUnsafeMutablePointer(to: &box) { boxPointer in
                _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphPointer, boxPointer, 1)
            }
        }
        boundingBoxes[glyph] = box
        return box
    }

    /// The glyph's filled **outline**, in the exact coordinate frame of its atlas tile: origin at
    /// the tile's bottom-left corner, y up, one unit per device pixel at this atlas's
    /// ``pixelSize``.
    ///
    /// # Why this exists next to the tile and not instead of it
    ///
    /// The tile is a coverage bitmap and is the right currency for a screen and for a PNG: it is
    /// rasterised once at the size it is drawn at, both backends sample the same bytes, and a
    /// golden comparison therefore tests placement rather than two font rasterisers.
    ///
    /// It is the wrong currency for **paper**. A flattened or printed sheet is drawn at
    /// `zoom: 1, backingScale: 1`, so one device pixel becomes one PDF point, and a tile blitted
    /// through a mask lands in the file as an 8-bit image at 72 dpi — crisp linework beside blocky
    /// dimension values, on the one artefact whose whole purpose is the numbers. The outline is
    /// resolution-independent: it leaves as `m`/`l`/`c`/`f` operators and is as sharp as the
    /// plotter.
    ///
    /// It is the same glyph, at the same size, placed by the same `padding - minimum` offset the
    /// tile's rasterisation uses, so filling this path inside the tile's rectangle covers the
    /// pixels the tile's coverage describes. `nil` for a glyph with no ink — whitespace — and for
    /// a font that has no outline for it.
    public func tileOutline(for glyph: CGGlyph) -> CGPath? {
        if let cached = outlines[glyph] { return cached }
        let box = boundingBox(of: glyph)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            outlines[glyph] = CGPath?.none
            return nil
        }
        let padding = CGFloat(Self.tilePadding)
        var placement = CGAffineTransform(
            translationX: padding - box.minX,
            y: padding - box.minY
        )
        let path = CTFontCreatePathForGlyph(font, glyph, &placement)
        outlines[glyph] = path
        return path
    }

    /// The atlas tile for one glyph, rasterising it on first use.
    private func tile(for glyph: CGGlyph) -> AtlasTile? {
        if let cached = tiles[glyph] { return cached }
        if refused.contains(glyph) { return nil }

        let boundingBox = self.boundingBox(of: glyph)
        guard boundingBox.width.isFinite, boundingBox.height.isFinite else { return nil }
        // A whitespace glyph has an empty box: record it so it is never re-measured, and draw
        // nothing for it.
        guard boundingBox.width > 0, boundingBox.height > 0 else {
            let empty = AtlasTile(x: 0, y: 0, width: 0, height: 0)
            tiles[glyph] = empty
            return empty
        }

        let padding = Self.tilePadding
        let inkWidth = Int(boundingBox.width.rounded(.up)) + 2 * padding
        let inkHeight = Int(boundingBox.height.rounded(.up)) + 2 * padding
        // The glyph is drawn into its own small bitmap and blitted, so a growing atlas never has
        // to re-run Core Text.
        let drawX = CGFloat(padding) - boundingBox.minX
        let drawY = CGFloat(padding) - boundingBox.minY
        // Room first, Core Text second: a full atlas must cost a lookup, not a rasterisation
        // whose result is then thrown away (BH-619).
        guard let placement = reserve(width: inkWidth, height: inkHeight) else {
            refused.insert(glyph)
            RendererLog.logger.error(
                "glyph atlas \(self.fontName, privacy: .public) @ \(self.pixelSize) px is full; glyph \(glyph) left out"
            )
            return nil
        }
        guard let patch = AlphaBitmap.rasterize(width: inkWidth, height: inkHeight, { context in
            var position = CGPoint(x: drawX, y: drawY)
            var drawGlyph = glyph
            withUnsafePointer(to: &drawGlyph) { glyphPointer in
                withUnsafePointer(to: &position) { positionPointer in
                    CTFontDrawGlyphs(self.font, glyphPointer, positionPointer, 1, context)
                }
            }
        }) else { return nil }

        bitmap.blit(patch, atX: placement.0, y: placement.1)
        generation &+= 1

        let tile = AtlasTile(
            x: placement.0,
            y: placement.1,
            width: inkWidth,
            height: inkHeight,
            // Core Text's box is y-up from the baseline; the renderer works y-down from the top.
            bearingX: Double(boundingBox.minX) - Double(padding),
            bearingY: Double(boundingBox.maxY) + Double(padding)
        )
        tiles[glyph] = tile
        return tile
    }

    /// Shelf allocation, growing the atlas by doubling its height when a shelf will not fit.
    private func reserve(width: Int, height: Int) -> (Int, Int)? {
        guard width > 0, height > 0, width <= RenderLimits.maximumTargetPixels else { return nil }
        if width > atlasWidth - 2 { return nil }
        if shelfX + width + 1 > atlasWidth {
            shelfY += shelfHeight + 1
            shelfX = 1
            shelfHeight = 0
        }
        while shelfY + height + 1 > atlasHeight {
            let grown = atlasHeight * 2
            guard grown <= RenderLimits.maximumTargetPixels else { return nil }
            var larger = AlphaBitmap(width: atlasWidth, height: grown)
            larger.blit(bitmap, atX: 0, y: 0)
            bitmap = larger
            atlasHeight = grown
            generation &+= 1
        }
        let placement = (shelfX, shelfY)
        shelfX += width + 1
        shelfHeight = Swift.max(shelfHeight, height)
        return placement
    }
}

/// Caches one ``GlyphAtlas`` per `(font, pixel size bucket)`, so a scene with a thousand labels in
/// two fonts holds two atlases and rasterises each glyph once.
///
/// # Eviction, and why an atlas in use is never a candidate
///
/// A ``CompiledGlyph`` holds pixel coordinates into one particular atlas *instance*, and both
/// backends re-resolve that atlas by `(font, bucket)` when they draw or upload. Evicting an atlas
/// that a compiled markup still points into therefore does not free anything useful — it hands
/// the next lookup a freshly created, empty atlas, and every label of that bucket goes blank until
/// the next zoom step (BH-031). The previous version evicted in strict first-inserted order and
/// never refreshed a key on a hit, so a zoom-independent bucket (the measurement pills') was the
/// first to go once sixteen text buckets had been visited.
///
/// Two rules now:
///
/// - **Least recently used**, not first inserted: a hit moves the key to the young end (IM-196),
///   exactly as ``SymbolAtlasCache`` does.
/// - **Pinned atlases are never evicted.** ``ScenePreparer`` pins the `(font, bucket)` of every
///   compiled markup it holds and unpins it when that markup is recompiled or removed. The
///   capacity is therefore a bound on *unreferenced* atlases; when every atlas is referenced the
///   cache holds more than `capacity` rather than breaking a live label, and ``trim()`` returns
///   it to the bound once the references move on.
public final class GlyphAtlasCache {
    private struct Key: Hashable {
        let font: String
        let size: Int
    }

    private var atlases: [Key: GlyphAtlas] = [:]
    /// Hard cap on distinct *unreferenced* atlases, so a document with a thousand fonts cannot
    /// exhaust memory.
    private let capacity: Int
    /// Keys in least-recently-used order, oldest first.
    private var order: [Key] = []
    /// How many compiled markups reference each key. A key with a count is never evicted.
    private var pins: [Key: Int] = [:]

    public init(capacity: Int = 16) {
        self.capacity = Swift.max(1, capacity)
    }

    public func atlas(fontName: String, deviceSize: Double) -> GlyphAtlas {
        let key = Key(font: fontName, size: GlyphAtlas.bucket(forDeviceSize: deviceSize))
        if let existing = atlases[key] {
            touch(key)
            return existing
        }
        let created = GlyphAtlas(fontName: key.font, pixelSize: key.size)
        atlases[key] = created
        order.append(key)
        evictIfNeeded(sparing: key)
        return created
    }

    /// Records that one more compiled markup draws from `(fontName, bucket)`.
    public func pin(fontName: String, bucket: Int) {
        pins[Key(font: fontName, size: bucket), default: 0] += 1
    }

    /// Drops one reference recorded by ``pin(fontName:bucket:)``. Does not evict by itself — the
    /// atlas may be about to be referenced again in the same frame — see ``trim()``.
    public func unpin(fontName: String, bucket: Int) {
        let key = Key(font: fontName, size: bucket)
        guard let count = pins[key] else { return }
        if count <= 1 { pins.removeValue(forKey: key) } else { pins[key] = count - 1 }
    }

    /// Drops every reference, for a caller that is about to re-pin its whole scene.
    public func unpinAll() {
        pins.removeAll(keepingCapacity: true)
    }

    /// Evicts least-recently-used unreferenced atlases until the cache is within capacity.
    public func trim() {
        evictIfNeeded(sparing: nil)
    }

    /// Whether the atlas for `(fontName, bucket)` is resident. For tests and diagnostics.
    public func isResident(fontName: String, bucket: Int) -> Bool {
        atlases[Key(font: fontName, size: bucket)] != nil
    }

    /// How many atlases are resident.
    public var atlasCount: Int { atlases.count }

    /// Moves a just-used key to the most-recently-used end.
    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func evictIfNeeded(sparing spared: Key?) {
        guard atlases.count > capacity else { return }
        var index = 0
        // Bounded: each step either removes an entry or advances past a pinned one.
        while atlases.count > capacity, index < order.count {
            let candidate = order[index]
            if candidate == spared || pins[candidate] != nil {
                index += 1
                continue
            }
            order.remove(at: index)
            atlases.removeValue(forKey: candidate)
        }
    }

    /// Total bytes held by every live atlas.
    public var residentByteCount: Int {
        atlases.values.reduce(0) { $0 + $1.bitmap.byteCount }
    }

    public func removeAll() {
        atlases.removeAll()
        order.removeAll()
        pins.removeAll()
    }
}
