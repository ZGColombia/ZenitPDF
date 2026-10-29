import CoreGraphics
import Foundation
import os
import ZPDFContracts

/// The reference markup renderer. Correct above all.
///
/// # Its two jobs
///
/// 1. **Oracle.** Every golden scene is rendered through this class and through
///    `MetalMarkupRenderer`, and the two rasters are compared. When they disagree, this one is
///    presumed right, because it is the one whose output can be reasoned about line by line: it
///    strokes one `CGPath` per segment with the caps and dash the compiler produced, fills one
///    triangle list, and blits one atlas tile per symbol and per glyph. There is no vertex
///    expansion, no shader, no `Float` truncation and no blend state to be wrong about. (A caller
///    with a vector destination can ask for ``AtlasImaging/outlines`` instead of that last blit;
///    the oracle role always runs on the default, so a golden still compares like with like.)
/// 2. **Fallback.** When there is no Metal device, or a shader will not compile,
///    `MarkupRendererFactory` returns this and logs why. The user gets a slower canvas, never a
///    blank one and never a crash.
///
/// # Pixel space, deliberately
///
/// The renderer transforms geometry to device pixels on the CPU and draws into a context whose
/// only transform is the y flip. Nothing is left for `CGContext` to scale. That means the line
/// width Core Graphics is given *is* the device width the Metal shader computes, the dash runs
/// are the same pixel runs, and the glyph tiles land on the same pixels. Letting Core Graphics
/// apply the page transform itself would have been shorter and would have made every golden
/// comparison a comparison of two different width and dash policies.
public final class CoreGraphicsMarkupRenderer: OffscreenMarkupRendering {

    public let backend: RendererBackend = .coreGraphics

    private let preparer = ScenePreparer()
    private var scene: PreparedScene?
    private var isDisposed = false
    private var lastStatistics = RenderStatistics.empty

    public init() {}

    // MARK: - Atlas imaging

    /// How the two things that come out of an atlas — glyphs and count symbols — are put into the
    /// destination context.
    ///
    /// Everything else this backend draws is already geometry: a stroke is `S`, a fill is `f`, an
    /// imported stamp's artwork is contours. Text and count markers were the exception, and on a
    /// bitmap destination that was invisible and free. On a **PDF** destination it was neither:
    /// `MarkupFlattener` compiles the sheet at `zoom: 1, backingScale: 1`, so one device pixel
    /// becomes one PDF point, and a 16 × 20-pixel tile blitted through a mask lands in the file
    /// as a 16 × 20-**point** image. A plotted A1 came out with vector linework and 72-dpi
    /// dimension values — the wrong way round for a construction document.
    public enum AtlasImaging: Sendable, Hashable {
        /// Blit the atlas's coverage tile through a `CGImage` mask.
        ///
        /// The right choice for a raster destination and the reason the two backends agree: the
        /// tile is rasterised once at the device size the frame needs, Core Graphics masks those
        /// bytes and Metal samples the same ones, so a golden comparison tests placement rather
        /// than two font rasterisers.
        case atlas
        /// Fill the glyph's outline and the symbol's own geometry as paths.
        ///
        /// The right choice for a vector destination. Same glyph, same font, same size, same
        /// placement — the outline is positioned in the tile's own frame — but resolution
        /// independent, so a dimension value is as sharp as the plotter instead of as sharp as
        /// one PDF point. Not the default, because on a bitmap it would replace a mask blit with
        /// a path fill for no gain and would make every golden a comparison of two rasterisers.
        case outlines
    }

    /// How glyphs and count symbols are imaged. ``AtlasImaging/atlas`` unless a caller with a
    /// vector destination says otherwise; ``MarkupFlattener`` is the caller that does.
    public var atlasImaging: AtlasImaging = .atlas

    // MARK: - MarkupPageRendering

    public var statistics: RenderStatistics { lastStatistics }

    /// See ``CullingPolicy``. Forwarded to the preparer; the next `update` uses it.
    public var cullingPolicy: CullingPolicy {
        get { preparer.cullingPolicy }
        set { preparer.cullingPolicy = newValue }
    }

    public func update(
        page: PageDescriptor,
        markups: [RenderableMarkup],
        selection: SelectionSnapshot,
        snapFeedback: RenderSnapFeedback?,
        viewport: RenderViewport
    ) {
        guard !isDisposed else { return }
        do {
            let prepared = try preparer.prepare(
                page: page,
                markups: markups,
                selection: selection,
                snapFeedback: snapFeedback,
                viewport: viewport
            )
            var statistics = prepared.statistics
            statistics.dirtySlotCount = prepared.changedIndices.count
            // The Core Graphics backend has no upload step; the comparable number is the instance
            // bytes it had to rebuild, which is what the incremental benchmark reads.
            statistics.uploadedByteCount = prepared.changedIndices.reduce(0) { total, index in
                total + prepared.markups[index].instanceByteCount
            }
            statistics.residentByteCount = preparer.residentByteCount
            lastStatistics = statistics
            scene = prepared
        } catch {
            // An unusable page or viewport — a transient zoom 0 or zero drawable during a resize
            // — must leave the previous frame and its hit-testing in place, not blank the layer.
            // The old code set `scene = nil` here, which is exactly what the comment said it would
            // not do: the markup layer vanished and hit-testing returned nil until the next good
            // frame (CR-79). Keep the previous scene and statistics; the Metal backend already
            // returns on this path.
            RendererLog.logger.error(
                "scene preparation failed, keeping the previous frame: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func hitTest(pagePoint: CGPoint, toleranceInPagePoints: CGFloat) -> HitTestResult? {
        guard !isDisposed, let scene else { return nil }
        let point = PDFPoint(x: Double(pagePoint.x), y: Double(pagePoint.y))
        let tolerance = Double(toleranceInPagePoints)
        // The spatial index narrows the query to the markups near the point (IM-083).
        return SceneHitTester.hitTest(
            markups: scene.markups,
            candidates: preparer.hitCandidates(point: point, tolerance: tolerance, transform: scene.transform),
            overlay: scene.overlay,
            transform: scene.transform,
            point: point,
            tolerance: tolerance
        )
    }

    public func dispose() {
        isDisposed = true
        scene = nil
        preparer.removeAll()
        lastStatistics = .empty
    }

    // MARK: - OffscreenMarkupRendering

    public func renderOffscreen() throws -> RasterImage {
        guard !isDisposed else { throw RendererError.disposed }
        guard let scene else { throw RendererError.noSceneToRender }
        let size = scene.transform.viewport.pixelSize
        guard size.width > 0, size.height > 0 else {
            throw RendererError.invalidViewport(reason: "empty drawable")
        }
        guard size.width <= RenderLimits.maximumTargetPixels,
              size.height <= RenderLimits.maximumTargetPixels
        else { throw RendererError.targetTooLarge(size) }

        var storage = [UInt8](repeating: 0, count: size.width * size.height * 4)
        var created = false
        storage.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: size.width,
                    height: size.height,
                    bitsPerComponent: 8,
                    bytesPerRow: size.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else { return }
            created = true
            draw(scene, into: context, pixelHeight: size.height)
        }
        guard created else { throw RendererError.bitmapContextUnavailable }
        guard let image = RasterImage(width: size.width, height: size.height, pixels: storage) else {
            throw RendererError.bitmapContextUnavailable
        }
        return image
    }

    /// Draws the current scene — the one the last successful `update` produced — into an
    /// already-configured context, or does nothing and returns `false` when there is none.
    ///
    /// This is the vector path of ADR-0006's snippet export: the same instances the raster
    /// output paints, stroked and filled as paths into a PDF context instead of a bitmap.
    @discardableResult
    public func drawCurrentScene(into context: CGContext, pixelHeight: Int) -> Bool {
        guard !isDisposed, let scene else { return false }
        draw(scene, into: context, pixelHeight: pixelHeight)
        return true
    }

    /// Draws the prepared scene into an already-configured context.
    ///
    /// Exposed so an `NSView`'s `draw(_:)` can hand its own context over without a round trip
    /// through a bitmap.
    public func draw(_ scene: PreparedScene, into context: CGContext, pixelHeight: Int) {
        context.saveGState()
        // The only transform: pixel space is top-left origin, y down.
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(pixelHeight)))
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        context.setBlendMode(.normal)

        let transform = scene.transform

        // Four category passes, in this order: fills, strokes, symbols, labels. Within a category
        // the order is painter's order by z. Across categories it is the category order.
        //
        // This is the same order `MetalMarkupRenderer.encode(into:)` uses, and it has to be, or
        // every golden scene with overlapping markups of different kinds would disagree. It is
        // also the order a takeoff overlay reads in: area shading behind, outlines on top of it,
        // count markers and labels above both. On the GPU it is what makes one draw call per
        // category possible instead of one per markup.
        // Viewport culling and the sub-pixel cutoff, exactly as the Metal backend applies
        // them: the visible set was decided once, in `ScenePreparer`, for both. `nil` means
        // everything, and the loops below iterate the storage array directly in that case so
        // the uncculled path costs what it always did.
        let visible = scene.visibility.visibleIndices
        // A highlighter's ink multiplies with the page under it; into a PDF context that is the
        // graphics state's `/BM /Multiply`, so an export matches the canvas.
        forEachVisible(scene, visible) { markup in
            blending(markup, context) {
                // A markup with a curve form (ADR-0030 §5.6) fills its curves, not its triangles.
                if !markup.vectorFill.isEmpty, let color = markup.triangles.first?.color {
                    fillCurves(markup.vectorFill, color: color, transform: transform, into: context)
                } else {
                    fill(markup.triangles, transform: transform, into: context)
                }
                // A placed picture is area ink: painted in the fill pass, in painter's order with
                // the fills, where its mosaic used to paint (ADR-0043).
                drawImages(markup.images, transform: transform, into: context)
            }
        }
        forEachVisible(scene, visible) { markup in
            blending(markup, context) {
                if !markup.vectorStroke.isEmpty, strokeCurves(markup.vectorStroke, like: markup.segments, transform: transform, into: context) {
                    return
                }
                stroke(markup.segments, transform: transform, into: context)
            }
        }
        forEachVisible(scene, visible) { markup in
            blending(markup, context) { drawSymbols(markup.symbols, transform: transform, into: context) }
        }
        forEachVisible(scene, visible) { markup in
            blending(markup, context) {
                drawGlyphs(
                    markup.glyphs,
                    fontName: markup.glyphFontName,
                    bucket: markup.glyphBucket,
                    transform: transform,
                    into: context
                )
            }
        }

        // The overlay pass. Same context, drawn last, and built from its own instance list, so it
        // never touches the geometry above.
        stroke(scene.overlay.segments, transform: transform, into: context)
        drawSymbols(scene.overlay.symbols, transform: transform, into: context)

        context.restoreGState()
    }

    /// Runs `body` with the markup's blend mode in force, and normal painting after it.
    private func blending(_ markup: CompiledMarkup, _ context: CGContext, _ body: () -> Void) {
        guard markup.multiplies else { body(); return }
        context.saveGState()
        context.setBlendMode(.multiply)
        body()
        context.restoreGState()
    }

    private func forEachVisible(
        _ scene: PreparedScene,
        _ visible: [Int]?,
        _ body: (CompiledMarkup) -> Void
    ) {
        if let visible {
            for index in visible where index < scene.markups.count {
                body(scene.markups[index])
            }
        } else {
            for markup in scene.markups {
                body(markup)
            }
        }
    }

    // MARK: - Primitives

    private func setFill(_ color: RGBAColor, in context: CGContext) {
        context.setFillColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }

    private func fill(
        _ triangles: [CompiledTriangle],
        transform: RenderTransform,
        into context: CGContext
    ) {
        guard !triangles.isEmpty else { return }
        // Triangles of one markup share a colour, so they batch into one path. Filling the whole
        // list at once with the non-zero rule is correct precisely because the triangulator has
        // already resolved the even-odd question: the triangles tile the filled region and do not
        // overlap, so either rule gives the same coverage. Doing it in one fill also means the
        // shared edges between adjacent triangles are not antialiased twice into a visible seam.
        var currentColor = triangles[0].color
        var path = CGMutablePath()
        func flush() {
            guard !path.isEmpty else { return }
            setFill(currentColor, in: context)
            context.addPath(path)
            context.fillPath()
            path = CGMutablePath()
        }
        for triangle in triangles {
            if triangle.color != currentColor {
                flush()
                currentColor = triangle.color
            }
            let a = transform.pixel(from: triangle.a)
            let b = transform.pixel(from: triangle.b)
            let c = transform.pixel(from: triangle.c)
            guard a.isFinite, b.isFinite, c.isFinite else { continue }
            path.move(to: a.asCGPoint)
            path.addLine(to: b.asCGPoint)
            path.addLine(to: c.asCGPoint)
            path.closeSubpath()
        }
        flush()
    }

    /// Draws a markup's raster pictures (ADR-0043, L-81) from their own pixels.
    ///
    /// The page → pixel map is affine, so the picture's unit square maps to pixel space through
    /// the one affine its three corners span there, and Core Graphics resamples the decoded pixels
    /// at the destination's own resolution — a plotter's, a printer's, or a bitmap's. Into a PDF
    /// context the picture lands as one image XObject at its decoded size, the single raster
    /// the flatten path's "no image XObject" guard allows.
    private func drawImages(_ images: [CompiledImage], transform: RenderTransform, into context: CGContext) {
        for image in images {
            let origin = transform.pixel(from: image.origin)
            let right = transform.pixel(from: image.xEnd)
            let up = transform.pixel(from: image.yEnd)
            guard origin.isFinite, right.isFinite, up.isFinite else { continue }
            let unitToPixel = CGAffineTransform(
                a: CGFloat(right.x - origin.x), b: CGFloat(right.y - origin.y),
                c: CGFloat(up.x - origin.x), d: CGFloat(up.y - origin.y),
                tx: CGFloat(origin.x), ty: CGFloat(origin.y)
            )
            context.saveGState()
            context.concatenate(unitToPixel)
            context.setAlpha(CGFloat(image.opacity))
            context.interpolationQuality = .high
            context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        }
    }

    /// The curve form of a contour in pixel space. The page → pixel map is affine, so a Bézier's
    /// control points map with it and the curve is the same curve.
    private func curvePath(_ curves: [RenderCurvePath], transform: RenderTransform) -> CGMutablePath? {
        let path = CGMutablePath()
        for curve in curves {
            let start = transform.pixel(from: curve.start)
            guard start.isFinite else { return nil }
            path.move(to: start.asCGPoint)
            for element in curve.elements {
                switch element {
                case let .line(to):
                    let point = transform.pixel(from: to)
                    guard point.isFinite else { return nil }
                    path.addLine(to: point.asCGPoint)
                case let .cubic(control1, control2, to):
                    let c1 = transform.pixel(from: control1), c2 = transform.pixel(from: control2), end = transform.pixel(from: to)
                    guard c1.isFinite, c2.isFinite, end.isFinite else { return nil }
                    path.addCurve(to: end.asCGPoint, control1: c1.asCGPoint, control2: c2.asCGPoint)
                }
            }
            if curve.isClosed { path.closeSubpath() }
        }
        return path
    }

    /// Fills a curved region even-odd (holes are clear whatever their winding, as the
    /// triangulator's fill is).
    private func fillCurves(_ curves: [RenderCurvePath], color: RGBAColor, transform: RenderTransform, into context: CGContext) {
        guard let path = curvePath(curves, transform: transform) else { return }
        setFill(color, in: context)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
    }

    /// Strokes curved contours with the style of the markup's own segments — width, colour, dash
    /// and caps are one per markup — and returns `false`, leaving the segments to be stroked as
    /// before, when that style is not uniform (two different end caps, say) or nothing is there.
    private func strokeCurves(
        _ curves: [RenderCurvePath],
        like segments: [CompiledSegment],
        transform: RenderTransform,
        into context: CGContext
    ) -> Bool {
        guard let first = segments.first, let last = segments.last,
              first.startCap == last.endCap,
              segments.allSatisfy({ $0.color == first.color && $0.widthPagePoints == first.widthPagePoints && $0.dash == first.dash }),
              let path = curvePath(curves, transform: transform) else { return false }
        context.setLineWidth(CGFloat(transform.deviceWidth(forPageWidth: first.widthPagePoints)))
        context.setStrokeColor(
            red: CGFloat(first.color.red),
            green: CGFloat(first.color.green),
            blue: CGFloat(first.color.blue),
            alpha: CGFloat(first.color.alpha)
        )
        context.setLineCap(Self.cgCap(first.startCap))
        context.setLineJoin(.round)
        var dashed = first
        dashed.dashOffsetPagePoints = 0
        applyDash(dashed, transform: transform, into: context)
        context.addPath(path)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        return true
    }

    private func stroke(
        _ segments: [CompiledSegment],
        transform: RenderTransform,
        into context: CGContext
    ) {
        guard !segments.isEmpty else { return }
        for segment in segments {
            let start = transform.pixel(from: segment.start)
            let end = transform.pixel(from: segment.end)
            guard start.isFinite, end.isFinite else { continue }
            let width = transform.deviceWidth(forPageWidth: segment.widthPagePoints)
            context.setLineWidth(CGFloat(width))
            context.setStrokeColor(
                red: CGFloat(segment.color.red),
                green: CGFloat(segment.color.green),
                blue: CGFloat(segment.color.blue),
                alpha: CGFloat(segment.color.alpha)
            )
            // A segment carries two caps, and Core Graphics has one per path, so a segment whose
            // ends differ is stroked twice under a clip. That is rare — it happens only at the
            // ends of an open polyline whose author asked for two different decorations — and it
            // is the price of matching the Metal path exactly.
            if segment.startCap == segment.endCap {
                context.setLineCap(Self.cgCap(segment.startCap))
                applyDash(segment, transform: transform, into: context)
                context.beginPath()
                context.move(to: start.asCGPoint)
                context.addLine(to: end.asCGPoint)
                context.strokePath()
            } else {
                strokeSplitCaps(segment, start: start, end: end, transform: transform, into: context)
            }
        }
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Strokes a segment whose two caps differ.
    ///
    /// Each half of the segment takes its own cap: the (dashed) line is outlined once per cap,
    /// each outline is cut to its half-plane through the midpoint, and the **union** of the two
    /// pieces is filled once. The previous version stroked twice under two abutting antialiased
    /// clips, so where the midline fell on a fractional pixel the two passes composited to
    /// `1 - c(1 - c)` — 0.75 at c = 0.5 — and an opaque line showed a light hairline across its
    /// middle that the Metal path, which draws the segment once, does not have (BH-620). The cut
    /// here is exact geometry, not coverage, so the seam has nothing to leak through.
    ///
    /// At a device width of one pixel or less Core Graphics draws no caps at all, and neither
    /// does the shader, so such a segment is simply stroked once with butt caps.
    private func strokeSplitCaps(
        _ segment: CompiledSegment,
        start: PixelPoint,
        end: PixelPoint,
        transform: RenderTransform,
        into context: CGContext
    ) {
        let width = transform.deviceWidth(forPageWidth: segment.widthPagePoints)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return }
        if width <= 1 {
            context.setLineCap(.butt)
            applyDash(segment, transform: transform, into: context)
            context.beginPath()
            context.move(to: start.asCGPoint)
            context.addLine(to: end.asCGPoint)
            context.strokePath()
            return
        }
        let ux = dx / length, uy = dy / length
        let reach = width + length
        let midX = (start.x + end.x) / 2, midY = (start.y + end.y) / 2

        let line = CGMutablePath()
        line.move(to: start.asCGPoint)
        line.addLine(to: end.asCGPoint)
        var dashed: CGPath = line
        if !segment.dash.isSolid {
            let runs = segment.dash.devicePixelRuns(pixelsPerPagePoint: transform.pixelsPerPagePoint)
            if !runs.isEmpty {
                let phase = segment.dash.devicePixelPhase(
                    pixelsPerPagePoint: transform.pixelsPerPagePoint,
                    extraPagePoints: segment.dashOffsetPagePoints
                )
                dashed = line.copy(dashingWithPhase: phase, lengths: runs)
            }
        }

        var ink: CGPath?
        for half in 0..<2 {
            let sign: Double = half == 0 ? -1 : 1
            let cap = half == 0 ? segment.startCap : segment.endCap
            // A generous quad covering the chosen half, extended sideways past any cap.
            let nx = -uy, ny = ux
            let side = CGMutablePath()
            side.move(to: CGPoint(x: midX + nx * reach, y: midY + ny * reach))
            side.addLine(to: CGPoint(x: midX - nx * reach, y: midY - ny * reach))
            side.addLine(to: CGPoint(
                x: midX - nx * reach + sign * ux * reach,
                y: midY - ny * reach + sign * uy * reach
            ))
            side.addLine(to: CGPoint(
                x: midX + nx * reach + sign * ux * reach,
                y: midY + ny * reach + sign * uy * reach
            ))
            side.closeSubpath()
            let outline = dashed.copy(
                strokingWithWidth: CGFloat(width),
                lineCap: Self.cgCap(cap),
                lineJoin: .miter,
                miterLimit: 10
            )
            let piece = outline.intersection(side, using: .winding)
            ink = ink.map { $0.union(piece, using: .winding) } ?? piece
        }
        guard let ink, !ink.isEmpty else { return }
        setFill(segment.color, in: context)
        context.addPath(ink)
        context.fillPath(using: .winding)
    }

    private func applyDash(
        _ segment: CompiledSegment,
        transform: RenderTransform,
        into context: CGContext
    ) {
        guard !segment.dash.isSolid else {
            context.setLineDash(phase: 0, lengths: [])
            return
        }
        let runs = segment.dash.devicePixelRuns(pixelsPerPagePoint: transform.pixelsPerPagePoint)
        guard !runs.isEmpty else {
            context.setLineDash(phase: 0, lengths: [])
            return
        }
        let phase = segment.dash.devicePixelPhase(
            pixelsPerPagePoint: transform.pixelsPerPagePoint,
            extraPagePoints: segment.dashOffsetPagePoints
        )
        context.setLineDash(phase: phase, lengths: runs)
    }

    private func drawSymbols(
        _ symbols: [CompiledSymbol],
        transform: RenderTransform,
        into context: CGContext
    ) {
        guard !symbols.isEmpty else { return }
        for symbol in symbols {
            let center = transform.pixel(from: symbol.center)
            guard center.isFinite else { continue }
            let devicePixels = symbol.sizePagePoints > 0
                ? symbol.sizePagePoints * transform.pixelsPerPagePoint
                : transform.devicePixels(fromViewPoints: symbol.sizeViewPoints)
            guard devicePixels.isFinite, devicePixels >= 1 else { continue }
            let rect = CGRect(
                x: center.x - devicePixels / 2,
                y: center.y - devicePixels / 2,
                width: devicePixels,
                height: devicePixels
            )
            let box = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            // A turned count mark (BH-634) turns about its centre, counter-clockwise on the page.
            let turn = CGFloat(symbol.pixelRotationRadians(pageToPixel: transform.pageToPixel))
            func applyTurn() {
                guard turn != 0 else { return }
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: turn)
                context.translateBy(x: -center.x, y: -center.y)
            }

            if atlasImaging == .outlines {
                context.saveGState()
                applyTurn()
                // The same frame the mask path establishes: origin at the tile's bottom-left
                // corner in the flipped context, y up — which is the frame `SymbolAtlas` draws
                // its geometry in when it rasterises a tile. So this is the tile's content,
                // un-rasterised, at the exact requested size rather than at a bucket's.
                context.translateBy(x: rect.minX, y: rect.minY + rect.height)
                context.scaleBy(x: 1, y: -1)
                setFill(symbol.color, in: context)
                context.setStrokeColor(
                    red: CGFloat(symbol.color.red),
                    green: CGFloat(symbol.color.green),
                    blue: CGFloat(symbol.color.blue),
                    alpha: CGFloat(symbol.color.alpha)
                )
                SymbolAtlas.draw(symbol.symbol, in: CGFloat(devicePixels), context: context)
                context.restoreGState()
                continue
            }

            guard let atlas = preparer.symbolAtlases.atlas(forDeviceSize: devicePixels),
                  let tile = atlas.tile(for: symbol.symbol),
                  let mask = Self.maskImage(atlas: atlas, tile: tile)
            else { continue }
            context.saveGState()
            applyTurn()
            // The mask is y-down like the atlas; the context is y-flipped, so the mask is drawn
            // into a rectangle that is itself flipped back.
            context.translateBy(x: rect.minX, y: rect.minY + rect.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: box, mask: mask)
            setFill(symbol.color, in: context)
            context.fill(box)
            context.restoreGState()
        }
    }

    private func drawGlyphs(
        _ glyphs: [CompiledGlyph],
        fontName: String?,
        bucket: Int?,
        transform: RenderTransform,
        into context: CGContext
    ) {
        guard !glyphs.isEmpty, let fontName, let bucket else { return }
        let atlas = preparer.glyphAtlases.atlas(fontName: fontName, deviceSize: Double(bucket))
        for glyph in glyphs {
            guard glyph.widthPixels > 0, glyph.heightPixels > 0 else { continue }
            let anchor = transform.pixel(from: glyph.anchor)
            guard anchor.isFinite else { continue }
            // Whole-pixel placement: the glyph was rasterised at this exact size, so landing it
            // on the pixel grid means no resampling at all.
            let originX = (anchor.x + glyph.offsetX).rounded()
            let originY = (anchor.y + glyph.offsetY).rounded()
            // Into the quad's own frame: its top-left corner, turned by the glyph's pixel-space
            // rotation (zero, and so no transform at all, for every screen-upright label; a
            // stamp's field text turns with the seal, T-065), then y flipped up from its bottom
            // edge, which is the frame both the outline and the mask are drawn in.
            func enterQuad() {
                if glyph.rotationSteps == 0 {
                    context.translateBy(x: originX, y: originY + glyph.heightPixels)
                } else {
                    context.translateBy(x: originX, y: originY)
                    context.rotate(by: CGFloat(glyph.rotationRadians))
                    context.translateBy(x: 0, y: glyph.heightPixels)
                }
                context.scaleBy(x: 1, y: -1)
            }

            if atlasImaging == .outlines {
                // `tileOutline` is expressed in the tile's own frame — origin at the tile's
                // bottom-left corner, y up, one unit per device pixel at this bucket — which is
                // precisely the frame the transforms below establish. So the outline lands on
                // the same pixels the tile would have covered, without being a picture of them.
                guard let outline = atlas.tileOutline(for: glyph.glyph) else { continue }
                context.saveGState()
                enterQuad()
                setFill(glyph.color, in: context)
                context.addPath(outline)
                // Non-zero, which is what a TrueType or CFF outline's counters assume.
                context.fillPath(using: .winding)
                context.restoreGState()
                continue
            }

            guard let mask = Self.maskImage(bitmap: atlas.bitmap, tile: glyph.tile) else {
                continue
            }
            context.saveGState()
            enterQuad()
            let box = CGRect(x: 0, y: 0, width: glyph.widthPixels, height: glyph.heightPixels)
            context.clip(to: box, mask: mask)
            setFill(glyph.color, in: context)
            context.fill(box)
            context.restoreGState()
        }
    }

    // MARK: - Mask images

    /// An alpha tile as a Core Graphics image mask.
    ///
    /// A mask's samples are *inverse* coverage — 0 paints, 255 does not — so the bytes are
    /// inverted here. Doing it in one place rather than at every call site is the difference
    /// between symbols that render and symbols that render as squares.
    private static func maskImage(bitmap: AlphaBitmap, tile: AtlasTile) -> CGImage? {
        guard tile.width > 0, tile.height > 0 else { return nil }
        var inverted = [UInt8](repeating: 255, count: tile.width * tile.height)
        for row in 0..<tile.height {
            let sourceRow = tile.y + row
            guard sourceRow >= 0, sourceRow < bitmap.height else { continue }
            for column in 0..<tile.width {
                let sourceColumn = tile.x + column
                guard sourceColumn >= 0, sourceColumn < bitmap.width else { continue }
                inverted[row * tile.width + column] =
                    255 &- bitmap.coverage[sourceRow * bitmap.width + sourceColumn]
            }
        }
        guard let provider = CGDataProvider(data: Data(inverted) as CFData) else { return nil }
        return CGImage(
            maskWidth: tile.width,
            height: tile.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: tile.width,
            provider: provider,
            decode: nil,
            shouldInterpolate: true
        )
    }

    private static func maskImage(atlas: SymbolAtlas, tile: AtlasTile) -> CGImage? {
        maskImage(bitmap: atlas.bitmap, tile: tile)
    }

    private static func cgCap(_ cap: RenderCap) -> CGLineCap {
        switch cap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}
