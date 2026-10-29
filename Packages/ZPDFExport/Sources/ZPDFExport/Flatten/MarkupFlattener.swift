import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer

/// **The flatten path.** One function paints a page's markups into a `CGContext`, and every
/// consumer that puts markups on a page goes through it: the flattened PDF, the print operation, and the
/// vector snippet's markup layer.
///
/// # Why there is exactly one of these
///
/// The renderer already knows how to draw every markup type — dimension grammar, value pills,
/// count symbols, stamps, imported artwork — because the canvas and the golden suite both make
/// it do so. Printing used to know how to draw none of them: `printDocument(_:)` rasterised the
/// page and stopped, so an estimator printed a measured drawing and received a blank drawing.
/// The obvious repair is a second drawing implementation for paper, and it is the wrong one: a
/// second implementation is how the canvas and the paper start disagreeing, one markup type at a
/// time, silently, on the one artefact nobody re-opens to check.
///
/// So this type owns no drawing code at all. It builds the same `RenderViewport` the canvas
/// builds, prepares the scene through `CoreGraphicsMarkupRenderer` — the renderer's reference
/// backend, the oracle every Metal golden is compared against — and asks it to paint into the
/// caller's context through the vector entry point it already had.
///
/// # Why the Core Graphics backend and not Metal
///
/// The same reason `SnippetExporter` chose it: an export must be reproducible on a machine with
/// no GPU, and its output is paths rather than a texture. That second point is what keeps a
/// flattened markup **vector** — `stroke` and `fill` end up as `S` and `f` operators in the
/// destination's content stream, at the printer's resolution, not as an image sampled at
/// whatever scale someone picked.
///
/// # Text is text — and how that was learned the hard way
///
/// The paragraph above was true of strokes and fills and, for a while, false of everything with
/// ink in it that came from an atlas. Reading a printed A1's decompressed content
/// stream and found **46 image XObjects** in it: every glyph and every count symbol arriving as a
/// 4 × 5-to-19 × 21-pixel 8-bit bitmap behind a soft mask, because the scale rule below makes one
/// atlas pixel one PDF point. Crisp linework, blocky dimension values — exactly backwards for the
/// artefact an estimator prints *for* the numbers.
///
/// So this function asks the renderer for `atlasImaging = .outlines`. The glyph is filled from
/// `CTFontCreatePathForGlyph`, positioned in its atlas tile's own frame, and the count symbol is
/// filled from `SymbolAtlas`'s own geometry — the same single definition the tile was rasterised
/// from, not a second drawing of it. Nothing about placement, size or colour changes; only whether
/// the ink is a path or a photograph of one.
///
/// `FlattenedPDFWriterTests.flattenedSheetContainsNoImageXObject` is what stops this coming back.
/// The allow-list beside it (`FlattenedVectorTextTests.imageAllowance`) has one entry: the picture
/// placed with Edit ▸ Insert Image (`RenderShape.image`, ADR-0043, L-81), a raster by nature,
/// which the renderer paints from its own decoded pixels as one image at its own resolution — it
/// used to reach paper as its 96-cell mosaic. Everything else is geometry: imported stamp artwork
/// is compiled to contours by `StampArtworkGeometry`, and the only other image in a flattened file
/// is the underlay page, which is the source document's own content and is copied rather than
/// painted through here.
///
/// # Scale, and why the sheet is drawn at zoom 1
///
/// The viewport is built at `zoom: 1, backingScale: 1`, so one renderer "device pixel" is one
/// PDF point and the view-point decorations of the measurement grammar — arrowheads, extension
/// ticks, pill text — come out at their nominal physical size on paper. Any scaling the caller
/// wants (fit-to-paper, a snippet's 3x) is applied by the `rect` argument, uniformly, after the
/// scene is compiled. Compiling at the output scale instead would change the decoration sizes
/// and the one-pixel stroke floor with the paper size, which is exactly the kind of quiet
/// disagreement this file exists to prevent.
public enum MarkupFlattener {

    /// What one call painted. Returned rather than logged so a caller can assert on it — and so
    /// `printable == false` can be *proved* absent rather than assumed absent.
    public struct Outcome: Sendable, Hashable {
        /// Markups the renderer accepted into the scene and submitted.
        public var paintedMarkupCount: Int
        /// Markups the renderer refused: non-finite coordinates, coordinates past
        /// `RenderLimits.coordinateMagnitudeBound`, contours past its vertex bound.
        public var rejectedMarkupCount: Int

        public init(paintedMarkupCount: Int, rejectedMarkupCount: Int) {
            self.paintedMarkupCount = paintedMarkupCount
            self.rejectedMarkupCount = rejectedMarkupCount
        }

        public static let nothing = Outcome(paintedMarkupCount: 0, rejectedMarkupCount: 0)
    }

    /// Paints `markups` into `context`, filling `rect`.
    ///
    /// - Parameters:
    ///   - page: the page's geometry. Its `/Rotate`-applied crop box is what maps onto `rect`,
    ///     so a landscape `/Rotate 90` sheet lands the right way up without the caller rotating
    ///     anything.
    ///   - markups: painter-ordered renderer geometry. The caller has already applied the
    ///     `printable` and `hidden` rules — see ``PDFFlattenPolicy``.
    ///   - context: any context. A `CGPDFContext` keeps the result vector; a bitmap context
    ///     rasterises it; `NSPrintOperation`'s context is a PDF context and therefore keeps it
    ///     vector too.
    ///   - rect: where the sheet goes, in the context's current user space, origin bottom-left.
    ///
    /// - Returns: what was painted. Nothing is thrown for an empty markup list: a page with no
    ///   markups is a page, and a clean export is the whole point of one of the four shapes.
    /// - Throws: ``PDFFlattenError/unusablePage(index:reason:)`` when the page's boxes or the
    ///   derived viewport cannot describe a sheet.
    @discardableResult
    public static func paint(
        page: PageDescriptor,
        markups: [RenderableMarkup],
        into context: CGContext,
        rect: CGRect
    ) throws -> Outcome {
        guard !markups.isEmpty else { return .nothing }
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else {
            throw PDFFlattenError.unusablePage(
                index: page.index,
                reason: "the destination rectangle is empty or non-finite"
            )
        }

        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        let transform: RenderTransform
        do {
            transform = try RenderTransform(page: page, viewport: viewport)
        } catch {
            throw PDFFlattenError.unusablePage(
                index: page.index,
                reason: String(describing: error)
            )
        }
        let pixelSize = viewport.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw PDFFlattenError.unusablePage(index: page.index, reason: "empty sheet")
        }

        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        // Paper is a vector destination, so the two things that would otherwise arrive as
        // pictures do not. See the "Text is text" section above.
        renderer.atlasImaging = .outlines
        renderer.update(
            page: page,
            markups: markups,
            // Interface state never reaches paper. A selection ring printed on a tender
            // drawing is a defect in the drawing, not a reminder of what was selected.
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        let statistics = renderer.statistics
        guard statistics.markupCount > 0 else {
            return Outcome(
                paintedMarkupCount: 0,
                rejectedMarkupCount: statistics.rejectedMarkupCount
            )
        }

        // The renderer paints in **pixel space**: top-left origin, y down, one unit per device
        // pixel, and `drawCurrentScene` applies the single y flip `(1,0,0,-1,0,pixelHeight)`
        // itself. So the job here is one affine that carries pixel space onto `rect`.
        //
        // The mapping is *measured* rather than assumed: the crop box's four corners are pushed
        // through the renderer's own transform and their bounding box is what lands on `rect`.
        // Assuming pixel space starts at (0, 0) and is exactly `rotatedVisibleSize` tall would
        // be right today and wrong the first time `RenderViewport.fittingWholePage` changes its
        // anchor convention — and wrong by a fraction of a point every time `pixelSize` rounds
        // a non-integral sheet up, which is most A-series sheets in millimetres.
        let box = page.visibleBox
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [
            PDFPoint(x: box.minX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.maxY),
            PDFPoint(x: box.minX, y: box.maxY)
        ] {
            let pixel = transform.pixel(from: corner)
            minX = Swift.min(minX, pixel.x); maxX = Swift.max(maxX, pixel.x)
            minY = Swift.min(minY, pixel.y); maxY = Swift.max(maxY, pixel.y)
        }
        let spanX = maxX - minX
        let spanY = maxY - minY
        guard spanX.isFinite, spanY.isFinite, spanX > 0, spanY > 0 else {
            throw PDFFlattenError.unusablePage(
                index: page.index,
                reason: "the page's crop box does not project to a sheet"
            )
        }

        let scaleX = Double(rect.width) / spanX
        let scaleY = Double(rect.height) / spanY
        // `drawCurrentScene` will map a pixel point `p` to `(p.x, pixelHeight - p.y)` before this
        // transform sees it, so the translation is solved against that flipped coordinate.
        let flippedHeight = Double(pixelSize.height)
        let translateX = Double(rect.minX) - minX * scaleX
        let translateY = Double(rect.maxY) - (flippedHeight - minY) * scaleY

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: CGFloat(translateX), y: CGFloat(translateY))
        context.scaleBy(x: CGFloat(scaleX), y: CGFloat(scaleY))
        renderer.drawCurrentScene(into: context, pixelHeight: pixelSize.height)
        context.restoreGState()

        return Outcome(
            paintedMarkupCount: statistics.markupCount,
            rejectedMarkupCount: statistics.rejectedMarkupCount
        )
    }
}
