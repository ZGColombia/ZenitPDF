import AppKit
import CoreGraphics
import ZPDFContracts
import ZPDFRenderer

/// Draws a count mark as the symbol it was placed with.
///
/// # What this replaces
///
/// `CanvasPageView` drew every count point as a hard-coded 8 × 8 filled oval, whatever the tool
/// said, from the first build to this one. A preset could carry a symbol, the schema could store
/// one and the renderer could draw ten of them; the canvas drew a dot.
///
/// # Why the atlas rather than a second set of paths
///
/// The glyph geometry belongs to `SymbolAtlas`, which is where both shipping backends get it.
/// Writing the ten shapes again here would be a mirror nothing forces into agreement — and the
/// one that drifted would be the canvas, because the canvas has no golden. So this asks the
/// renderer for the same rasterised tile the Core Graphics backend asks for, and paints the
/// markup's own colour through it as a mask. There is exactly one description of what a star is.
///
/// # Bounded
///
/// One atlas per device-size bucket, at most ``maximumCachedAtlases`` of them, evicted oldest
/// first. `SymbolAtlas.bucket(forDeviceSize:)` quantises the size, so a continuous pinch-zoom
/// walks a handful of buckets rather than allocating a bitmap per frame.
@MainActor
enum CanvasCountSymbolPainter {

    /// How many size buckets are kept. A canvas shows one zoom at a time; the spare entries are
    /// for the zoom the person just left and is about to come back to.
    static let maximumCachedAtlases = 6

    /// The edge, in PDF points, of a count mark whose record carries no symbol.
    ///
    /// Eight, which is the oval that was hard-coded here, so every count made before a symbol
    /// was a property of the mark keeps the size it has always had. A mark that *does* carry a
    /// symbol takes its own size, and an unusable one falls back to `ImportedArtworkScene`'s
    /// twelve rather than to this.
    /// `nonisolated` so the snippet exporter's scene builder, which runs off the main actor,
    /// reads the *same* number rather than restating it. A constant restated is a constant that
    /// drifts.
    nonisolated static let unsymbolledSizePoints: CGFloat = 8

    private static var atlases: [Int: SymbolAtlas] = [:]
    private static var atlasOrder: [Int] = []
    private static var masks: [MaskKey: CGImage] = [:]

    private struct MaskKey: Hashable {
        let bucket: Int
        let glyph: CountSymbol
        /// The keyline's reach in tile pixels; 0 for the glyph itself.
        var keyline: Int = 0
    }

    /// Draws one count mark.
    ///
    /// - Parameters:
    ///   - symbol: the mark's own symbol, or `nil` for a mark placed before symbols existed.
    ///   - viewPoint: where the mark sits, in the flipped view's coordinates.
    ///   - zoom: view points per page point, so a symbol keeps its size on the *sheet*.
    ///   - backingScale: device pixels per view point, which decides the atlas bucket.
    ///   - color: the markup's own ink.
    /// A symbol's size on the sheet, in page points. The renderer's own rule for an unusable
    /// size, stated in one place there and read here: a symbol whose box is absurd draws at a
    /// legible default instead of at zero. Hit testing reads the same number (BH-878).
    nonisolated static func symbolSize(for symbol: MarkupSymbol?) -> CGFloat {
        guard let symbol else { return unsymbolledSizePoints }
        return symbol.hasUsableSize ? CGFloat(symbol.sizePoints) : 12
    }

    /// The smallest a count mark is drawn on screen, in view points.
    ///
    /// A mark keeps its size on the sheet as the reader zooms in, but it does not shrink below
    /// this as the reader zooms out: at fit zoom an 8 pt mark on an A1 sheet was a 1.6-point
    /// speck, and on a hatched area a count of forty read as two faint dots (L-15).
    /// Twelve, because the glyph sits inside its box with the atlas's 2-pixel margin: a 12-point
    /// box draws an 8-point dot, which a person can find and click at any zoom.
    nonisolated static let minimumOnScreenSize: CGFloat = 12

    /// The contrasting keyline round every mark, in view points: paper-light round a dark ink,
    /// dark round a light one, so a mark separates from hatching and linework whatever its
    /// colour (L-15).
    nonisolated static let keylineWidth: CGFloat = 1.5

    /// A mark's drawn size on screen, in view points: its size on the sheet at this zoom, never
    /// below ``minimumOnScreenSize``. The one rule the painter, the hit test and the culling
    /// read, so the mark a person sees is the mark a click takes (BH-878).
    nonisolated static func drawnSizeInView(for symbol: MarkupSymbol?, zoom: CGFloat) -> CGFloat {
        let onSheet = symbolSize(for: symbol) * zoom
        guard onSheet.isFinite else { return minimumOnScreenSize }
        return Swift.max(onSheet, minimumOnScreenSize)
    }

    /// The keyline colour for a mark drawn in `color`: whichever of light and dark contrasts
    /// with it more, the rule a pill's text follows on the same fill.
    static func keylineColor(for color: NSColor) -> NSColor {
        switch CanvasMarkupStyle.pillTone(onFill: color.withAlphaComponent(1)) {
        case .light: return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: color.alphaComponent)
        case .dark: return NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: color.alphaComponent)
        }
    }

    /// The rotation to apply in the **flipped** canvas view, in degrees.
    ///
    /// `MarkupSymbol.rotationDegrees` is counter-clockwise, as the contract, the stamp path and
    /// the snippet renderer all read it in y-up page space. In a y-down view a positive
    /// `rotate(by:)` turns clockwise, so the same stored 30° turned the other way on the canvas
    /// from everywhere else (BH-338). Negated here, once.
    nonisolated static func viewRotationDegrees(for symbol: MarkupSymbol?) -> CGFloat {
        guard let degrees = symbol?.rotationDegrees, degrees.isFinite else { return 0 }
        return -CGFloat(degrees)
    }

    static func draw(
        symbol: MarkupSymbol?,
        artwork: ArtworkGeometry?,
        at viewPoint: CGPoint,
        zoom: CGFloat,
        backingScale: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        let sizeInView = drawnSizeInView(for: symbol, zoom: zoom)
        guard sizeInView.isFinite, sizeInView > 0.5 else { return }

        let glyph = symbol?.builtInGlyph.flatMap(CountSymbol.init(name:)) ?? .filledCircle
        let rotation = viewRotationDegrees(for: symbol)
        let box = CGRect(
            x: -sizeInView / 2,
            y: -sizeInView / 2,
            width: sizeInView,
            height: sizeInView
        )
        // The keyline is the mark itself, grown by the keyline on every side and painted in the
        // contrasting colour under the mark (L-15).
        let keyline = keylineColor(for: color)
        let keylineBox = box.insetBy(dx: -keylineWidth, dy: -keylineWidth)

        // Imported artwork, when the mark names some and the project still has it. The
        // condition is `ImportedArtworkScene.markups(symbol:artwork:…)`'s, stated the same way
        // here: artwork that is present and not empty, on a symbol that actually references it.
        // Everything else falls through to the glyph, visibly.
        if let symbol, symbol.usesImportedArtwork, let artwork, !artwork.isEmpty {
            // The keyline pass paints the artwork's silhouette, grown, in one colour.
            drawArtwork(artwork, at: viewPoint, box: keylineBox, rotation: rotation, color: keyline, silhouette: true, in: context)
            drawArtwork(
                artwork,
                at: viewPoint,
                box: box,
                rotation: rotation,
                color: color,
                in: context
            )
            return
        }

        guard let masks = masks(for: glyph, sizeInView: sizeInView, backingScale: backingScale) else {
            // No atlas — a machine that could not allocate the bitmap. A count mark must still
            // be visible, because a count of forty that draws thirty-nine marks is a wrong
            // quantity nobody notices. The dot is the fallback, and it is deliberate.
            context.setFillColor(keyline.cgColor)
            context.fillEllipse(in: keylineBox.offsetBy(dx: viewPoint.x, dy: viewPoint.y))
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: box.offsetBy(dx: viewPoint.x, dy: viewPoint.y))
            return
        }

        // The keyline mask is the glyph dilated by the keyline, so the outline follows a star or
        // a triangle rather than boxing it; it is drawn first, and grown by what it reaches.
        paint(masks.keyline, in: box.insetBy(dx: -masks.grow, dy: -masks.grow), at: viewPoint, rotation: rotation, color: keyline, context: context)
        paint(masks.glyph, in: box, at: viewPoint, rotation: rotation, color: color, context: context)
    }

    /// Paints `color` through a glyph mask filling `box` (centred on the mark) at `viewPoint`.
    private static func paint(
        _ mask: CGImage, in box: CGRect, at viewPoint: CGPoint, rotation: CGFloat, color: NSColor, context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: viewPoint.x, y: viewPoint.y)
        if rotation != 0, rotation.isFinite {
            context.rotate(by: rotation * .pi / 180)
        }
        // The view is flipped and a mask image is not, so the box is flipped back for the blit.
        // Getting this wrong turns a triangle upside down, which is the sort of thing that is
        // invisible on a circle and obvious on a count of roof vents.
        context.translateBy(x: 0, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        let target = CGRect(x: box.minX, y: 0, width: box.width, height: box.height)
        context.clip(to: target, mask: mask)
        context.setFillColor(color.cgColor)
        context.fill(target)
        context.restoreGState()
    }

    /// Draws compiled artwork into the mark's box, aspect preserved.
    ///
    /// Unit space in, view space out, with the same fit `ImportedArtworkScene.fittedSize` makes:
    /// a picture that is not square is letterboxed inside the square box rather than stretched,
    /// because a stretched seal is a different seal. Vector artwork carries no ink of its own
    /// (`VectorExtractor` records paint role and stroke width, not colour), so it takes the
    /// markup's style colour; a raster mosaic's cells carry their own and keep it.
    ///
    /// `silhouette` paints every region and stroke in `color`, ignoring a raster cell's own
    /// colour: the keyline pass under the mark (L-15).
    private static func drawArtwork(
        _ artwork: ArtworkGeometry,
        at viewPoint: CGPoint,
        box: CGRect,
        rotation: CGFloat,
        color: NSColor,
        silhouette: Bool = false,
        in context: CGContext
    ) {
        let aspect = artwork.sourceAspectRatio
        let fitted: CGSize
        if aspect.isFinite, aspect > 0 {
            fitted = aspect >= 1
                ? CGSize(width: box.width, height: box.width / CGFloat(aspect))
                : CGSize(width: box.height * CGFloat(aspect), height: box.height)
        } else {
            fitted = box.size
        }
        let frame = CGRect(
            x: -fitted.width / 2,
            y: -fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )

        context.saveGState()
        context.translateBy(x: viewPoint.x, y: viewPoint.y)
        if rotation != 0, rotation.isFinite {
            context.rotate(by: rotation * .pi / 180)
        }

        // Unit space has its origin at the lower left; the canvas view is flipped. Getting this
        // backwards turns every imported seal upside down, which is why the flip is here and
        // not folded into the point conversion where it would be easy to lose.
        func place(_ point: PDFPoint) -> CGPoint {
            CGPoint(
                x: frame.minX + CGFloat(point.x) * frame.width,
                y: frame.maxY - CGFloat(point.y) * frame.height
            )
        }

        for region in artwork.regions where region.outer.count >= 3 {
            let path = CGMutablePath()
            path.addLines(between: region.outer.map(place))
            path.closeSubpath()
            for hole in region.holes where hole.count >= 3 {
                path.addLines(between: hole.map(place))
                path.closeSubpath()
            }
            context.addPath(path)
            if let own = region.color, !silhouette {
                context.setFillColor(CGColor(
                    srgbRed: CGFloat(own.red),
                    green: CGFloat(own.green),
                    blue: CGFloat(own.blue),
                    alpha: CGFloat(own.alpha)
                ))
            } else {
                context.setFillColor(color.cgColor)
            }
            // Even-odd, as everywhere else in Zenit, which is what makes a hole a hole.
            context.fillPath(using: .evenOdd)
        }

        let minimumEdge = Swift.min(frame.width, frame.height)
        context.setStrokeColor(color.cgColor)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for stroke in artwork.strokes where stroke.points.count >= 2 {
            let width = stroke.widthFraction > 0
                ? CGFloat(stroke.widthFraction) * minimumEdge
                : Swift.max(0.5, minimumEdge * 0.02)
            context.setLineWidth(width)
            let path = CGMutablePath()
            path.addLines(between: stroke.points.map(place))
            if stroke.isClosed { path.closeSubpath() }
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The alpha tile for one glyph at one on-screen size as a Core Graphics image mask, with its
    /// keyline mask (the tile dilated by ``keylineWidth``) and how far, in view points, the
    /// keyline mask reaches past the glyph's box. Both cached per size bucket.
    private static func masks(
        for glyph: CountSymbol,
        sizeInView: CGFloat,
        backingScale: CGFloat
    ) -> (glyph: CGImage, keyline: CGImage, grow: CGFloat)? {
        let devicePixels = Double(sizeInView * max(backingScale, 1))
        let bucket = SymbolAtlas.bucket(forDeviceSize: devicePixels)
        let pixelsPerPoint = CGFloat(bucket) / sizeInView
        let reach = Swift.max(1, Int((keylineWidth * pixelsPerPoint).rounded()))
        let glyphKey = MaskKey(bucket: bucket, glyph: glyph)
        let keylineKey = MaskKey(bucket: bucket, glyph: glyph, keyline: reach)
        let grow = CGFloat(reach) / pixelsPerPoint
        if let cachedGlyph = masks[glyphKey], let cachedKeyline = masks[keylineKey] {
            return (cachedGlyph, cachedKeyline, grow)
        }
        guard let atlas = atlas(bucket: bucket), let tile = atlas.tile(for: glyph),
              tile.width > 0, tile.height > 0 else {
            return nil
        }
        let coverage = tileCoverage(bitmap: atlas.bitmap, tile: tile)
        guard let glyphImage = maskImage(coverage: coverage, width: tile.width, height: tile.height),
              let keylineImage = maskImage(
                coverage: dilated(coverage, width: tile.width, height: tile.height, reach: reach),
                width: tile.width + 2 * reach, height: tile.height + 2 * reach
              ) else { return nil }
        masks[glyphKey] = glyphImage
        masks[keylineKey] = keylineImage
        return (glyphImage, keylineImage, grow)
    }

    /// One tile's coverage bytes out of the atlas, row-major.
    private static func tileCoverage(bitmap: AlphaBitmap, tile: AtlasTile) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: tile.width * tile.height)
        for row in 0..<tile.height {
            let sourceRow = tile.y + row
            guard sourceRow >= 0, sourceRow < bitmap.height else { continue }
            for column in 0..<tile.width {
                let sourceColumn = tile.x + column
                guard sourceColumn >= 0, sourceColumn < bitmap.width else { continue }
                coverage[row * tile.width + column] = bitmap.coverage[sourceRow * bitmap.width + sourceColumn]
            }
        }
        return coverage
    }

    /// `coverage` grown by a disc of `reach` pixels (a maximum filter), on a canvas `reach`
    /// pixels larger on every side. Run once per glyph and size bucket, then cached.
    static func dilated(_ coverage: [UInt8], width: Int, height: Int, reach: Int) -> [UInt8] {
        let outWidth = width + 2 * reach, outHeight = height + 2 * reach
        var out = [UInt8](repeating: 0, count: outWidth * outHeight)
        var offsets: [(Int, Int)] = []
        for dy in -reach...reach {
            for dx in -reach...reach where dx * dx + dy * dy <= reach * reach { offsets.append((dx, dy)) }
        }
        for row in 0..<outHeight {
            for column in 0..<outWidth {
                var best: UInt8 = 0
                for (dx, dy) in offsets {
                    let x = column - reach + dx, y = row - reach + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let value = coverage[y * width + x]
                    if value > best {
                        best = value
                        if best == 255 { break }
                    }
                }
                out[row * outWidth + column] = best
            }
        }
        return out
    }

    private static func atlas(bucket: Int) -> SymbolAtlas? {
        if let cached = atlases[bucket] {
            // Least recently used, not first created: a hit moves the bucket to the back, so a
            // zoom level in use is never the one evicted (IM-196).
            if let position = atlasOrder.firstIndex(of: bucket), position != atlasOrder.count - 1 {
                atlasOrder.remove(at: position)
                atlasOrder.append(bucket)
            }
            return cached
        }
        guard let created = SymbolAtlas(tileSize: bucket) else { return nil }
        atlases[bucket] = created
        atlasOrder.append(bucket)
        while atlasOrder.count > maximumCachedAtlases {
            let evicted = atlasOrder.removeFirst()
            atlases.removeValue(forKey: evicted)
            masks = masks.filter { $0.key.bucket != evicted }
        }
        return created
    }

    /// An alpha tile as a Core Graphics image mask.
    ///
    /// A mask's samples are *inverse* coverage — 0 paints, 255 does not — so the bytes are
    /// inverted. The same inversion `CoreGraphicsMarkupRenderer` does for the same tiles; doing
    /// it in one place per tier rather than at every call site is the difference between symbols
    /// that render and symbols that render as squares.
    private static func maskImage(coverage: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        let inverted = coverage.map { 255 &- $0 }
        guard let provider = CGDataProvider(data: Data(inverted) as CFData) else { return nil }
        return CGImage(
            maskWidth: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            provider: provider,
            decode: nil,
            shouldInterpolate: true
        )
    }
}
