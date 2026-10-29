import CoreGraphics
import Foundation

/// One tile in an atlas: where it lives, and how its ink sits inside it.
public struct AtlasTile: Sendable, Hashable {
    /// Pixel rectangle of the tile inside the atlas bitmap.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Offset from the drawing origin to the tile's top-left corner, in device pixels.
    public var bearingX: Double
    public var bearingY: Double

    public init(x: Int, y: Int, width: Int, height: Int, bearingX: Double = 0, bearingY: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.bearingX = bearingX; self.bearingY = bearingY
    }

    /// Texel coordinates `(u0, v0, u1, v1)` of the tile's corners — what an unnormalised sampler
    /// takes. Independent of the atlas's size, so it survives the atlas growing (BH-200).
    public var texelUV: (Double, Double, Double, Double) {
        (Double(x), Double(y), Double(x + width), Double(y + height))
    }

    /// Normalised texture coordinates `(u0, v0, u1, v1)` inside an atlas of the given size.
    public func uv(inAtlasWidth atlasWidth: Int, height atlasHeight: Int) -> (Double, Double, Double, Double) {
        guard atlasWidth > 0, atlasHeight > 0 else { return (0, 0, 0, 0) }
        return (
            Double(x) / Double(atlasWidth),
            Double(y) / Double(atlasHeight),
            Double(x + width) / Double(atlasWidth),
            Double(y + height) / Double(atlasHeight)
        )
    }
}

/// The count-marker atlas: every ``CountSymbol`` rasterised at one tile size, in one bitmap.
///
/// Symbols are drawn from vector geometry defined here — nothing traced from another product —
/// with a 2-pixel margin so the antialiased edge of a tile can never bleed into its neighbour
/// when the GPU samples it with linear filtering.
public final class SymbolAtlas {

    /// Tile edge in device pixels. Symbols are drawn once per size bucket, so this is the bucket.
    public let tileSize: Int
    public let bitmap: AlphaBitmap
    /// Column count of the tile grid.
    public let columns: Int

    private let tiles: [CountSymbol: AtlasTile]

    /// Buckets a requested device size, finely enough that the drawn symbol is never resampled
    /// by more than a few percent, coarsely enough that a scene holds a handful of atlases.
    ///
    /// The step is one pixel below 32, four pixels below 64 and sixteen above, so the worst-case
    /// scale factor between a tile and the size it is drawn at is about 1.06. Both backends
    /// therefore resample by roughly nothing, and the small amount they do resample they do with
    /// comparable filters — Core Graphics at high interpolation quality, Metal with a mipmapped
    /// trilinear sampler.
    public static func bucket(forDeviceSize size: Double) -> Int {
        guard size.isFinite, size > 0 else { return 16 }
        let clamped = Swift.min(256.0, Swift.max(8.0, size))
        if clamped <= 32 { return Int(clamped.rounded()) }
        if clamped <= 64 { return Int((clamped / 4).rounded()) * 4 }
        return Swift.min(256, Int((clamped / 16).rounded()) * 16)
    }

    public init?(tileSize: Int) {
        let clamped = Swift.min(512, Swift.max(8, tileSize))
        let all = CountSymbol.allCases
        let columns = 4
        let rows = (all.count + columns - 1) / columns
        let width = columns * clamped
        let height = rows * clamped

        var tileMap: [CountSymbol: AtlasTile] = [:]
        guard let bitmap = AlphaBitmap.rasterize(width: width, height: height, { context in
            for (index, symbol) in all.enumerated() {
                let column = index % columns
                let row = index / columns
                let originX = CGFloat(column * clamped)
                // The grey context is bottom-left origin; tile row 0 is the top row of the atlas.
                let originY = CGFloat(height - (row + 1) * clamped)
                context.saveGState()
                context.translateBy(x: originX, y: originY)
                Self.draw(symbol, in: CGFloat(clamped), context: context)
                context.restoreGState()
            }
        }) else { return nil }

        for (index, symbol) in all.enumerated() {
            let column = index % columns
            let row = index / columns
            tileMap[symbol] = AtlasTile(
                x: column * clamped,
                y: row * clamped,
                width: clamped,
                height: clamped
            )
        }

        self.tileSize = clamped
        self.bitmap = bitmap
        self.columns = columns
        self.tiles = tileMap
    }

    public func tile(for symbol: CountSymbol) -> AtlasTile? { tiles[symbol] }

    // MARK: - Symbol geometry

    /// Draws one count symbol's geometry into `context`, filling a `size × size` box anchored at
    /// the context's current origin, y up. The caller has already set the fill and stroke colour.
    ///
    /// # Why this is public
    ///
    /// It is the **single** definition of what a count marker looks like. The atlas calls it to
    /// rasterise a tile, which is what a screen and a PNG want. A vector destination — a printed
    /// or flattened sheet — calls it directly through `CoreGraphicsMarkupRenderer`, so the marker
    /// on paper is *this* geometry at the plotter's resolution rather than a 72-dpi photograph of
    /// it. Two drawings of a symbol would be two things to keep in agreement; there is one.
    public static func draw(_ symbol: CountSymbol, in size: CGFloat, context: CGContext) {
        guard size.isFinite, size > 0 else { return }
        // The margin and the stroke are floored for legibility at atlas sizes (8 px and up, where
        // the caps below change nothing) and capped so that a marker drawn at its exact size on
        // the outline path — which can be 1 to 6 pt — keeps a box of positive size. Unclamped,
        // `insetBy` produced `CGRect.null` below 6 px and the hollow triangle was stroked along
        // infinite coordinates (BH-197).
        let margin = Swift.min(Swift.max(2, size * 0.08), size * 0.25)
        let box = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let stroke = Swift.min(Swift.max(1.0, size * 0.12), box.width / 3)
        context.setLineWidth(stroke)
        context.setLineCap(.butt)
        context.setLineJoin(.miter)

        switch symbol {
        case .filledCircle:
            context.fillEllipse(in: box)
        case .hollowCircle:
            context.strokeEllipse(in: box.insetBy(dx: stroke / 2, dy: stroke / 2))
        case .filledSquare:
            context.fill(box)
        case .hollowSquare:
            context.stroke(box.insetBy(dx: stroke / 2, dy: stroke / 2))
        case .filledTriangle:
            context.addPath(trianglePath(in: box))
            context.fillPath()
        case .hollowTriangle:
            context.addPath(trianglePath(in: box.insetBy(dx: stroke, dy: stroke)))
            context.strokePath()
        case .filledDiamond:
            context.addPath(diamondPath(in: box))
            context.fillPath()
        case .cross:
            context.move(to: CGPoint(x: box.minX, y: box.minY))
            context.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            context.move(to: CGPoint(x: box.minX, y: box.maxY))
            context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            context.strokePath()
        case .plus:
            context.move(to: CGPoint(x: box.midX, y: box.minY))
            context.addLine(to: CGPoint(x: box.midX, y: box.maxY))
            context.move(to: CGPoint(x: box.minX, y: box.midY))
            context.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            context.strokePath()
        case .star:
            context.addPath(starPath(in: box))
            context.fillPath()
        }
    }

    private static func trianglePath(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        path.closeSubpath()
        return path
    }

    private static func diamondPath(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        path.addLine(to: CGPoint(x: box.midX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.midY))
        path.closeSubpath()
        return path
    }

    private static func starPath(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        let centerX = box.midX, centerY = box.midY
        let outer = Swift.min(box.width, box.height) / 2
        let inner = outer * 0.42
        for index in 0..<10 {
            let radius = index % 2 == 0 ? outer : inner
            let angle = CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let point = CGPoint(
                x: centerX + radius * Foundation.cos(angle),
                y: centerY + radius * Foundation.sin(angle)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}


/// Caches one ``SymbolAtlas`` per tile-size bucket, bounded so a pathological scene cannot make
/// the renderer allocate an atlas per markup.
public final class SymbolAtlasCache {
    private var atlases: [Int: SymbolAtlas] = [:]
    /// Buckets in least-recently-used order (oldest first). Actually maintained and used for
    /// eviction (CR-91): the previous version left it dead and, at capacity, returned the
    /// numerically nearest existing bucket via `Dictionary.keys.min`, which is non-deterministic
    /// on ties and hands back a wrong-sized atlas that resamples.
    private var order: [Int] = []
    private let capacity: Int

    public init(capacity: Int = 12) {
        self.capacity = Swift.max(1, capacity)
    }

    /// The atlas for a device size, creating it on first use and evicting the least recently used
    /// atlas when the cache is over capacity — so every caller gets the *exact* bucket for its
    /// size rather than a nearest-but-wrong one, and the choice is deterministic.
    ///
    /// Returns `nil` only when Core Graphics refuses to make the bitmap, which the callers treat
    /// as "draw no symbols this frame" rather than as a failure of the frame.
    public func atlas(forDeviceSize size: Double) -> SymbolAtlas? {
        let bucket = SymbolAtlas.bucket(forDeviceSize: size)
        if let existing = atlases[bucket] {
            touch(bucket)
            return existing
        }
        guard let created = SymbolAtlas(tileSize: bucket) else { return nil }
        atlases[bucket] = created
        order.append(bucket)
        evictIfNeeded()
        return created
    }

    /// Moves a just-used bucket to the most-recently-used end.
    private func touch(_ bucket: Int) {
        if let index = order.firstIndex(of: bucket) { order.remove(at: index) }
        order.append(bucket)
    }

    /// Evicts least-recently-used atlases until the cache is within capacity.
    private func evictIfNeeded() {
        // Bounded: each pass removes exactly one entry.
        while atlases.count > capacity, let leastRecentlyUsed = order.first {
            order.removeFirst()
            atlases.removeValue(forKey: leastRecentlyUsed)
        }
    }

    public var residentByteCount: Int {
        atlases.values.reduce(0) { $0 + $1.bitmap.byteCount }
    }

    public var bucketCount: Int { atlases.count }

    /// The tile-size buckets currently resident, for tests and diagnostics.
    public var residentBucketSizes: [Int] { Array(atlases.keys) }

    public func removeAll() {
        atlases.removeAll()
        order.removeAll()
    }
}
