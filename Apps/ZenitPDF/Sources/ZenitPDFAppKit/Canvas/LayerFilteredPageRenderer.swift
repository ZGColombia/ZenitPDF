import CoreGraphics
import Foundation
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// The content-stream render path of gap 10.
///
/// PDFKit and `CGContextDrawPDFPage` both honour only the file's *default* layer
/// configuration; neither can render a per-project override (see the honesty notes in
/// `ZPDFPDFKitBridge.LayerTypes`). When the effective visibility differs from the document
/// default, the canvas therefore rasterises the page from the content-stream scan instead:
/// the extraction (taken with `includesHiddenOptionalContent`, so *every* layer's geometry
/// is present once) filtered through the effective hidden set.
///
/// What this path is, stated honestly: a vector-geometry render. It draws exactly the
/// painted paths the `CGPDFScanner` walk produced, in scan order, with their stroke widths —
/// but the extraction does not carry paint colour, text or image content, so the sheet
/// renders as monochrome linework. That is the truthful trade: the alternative, a native
/// render, would silently show layers the user has hidden. The moment overrides return to
/// the document default, the canvas switches back to the native raster.
enum LayerFilteredPageRenderer {

    /// The filtering state the canvas renders under.
    struct Filtering: Sendable {
        /// The page's extraction, taken with hidden optional content included.
        let extraction: VectorPageExtraction
        /// Marked-content property names whose layer is effectively hidden.
        let hiddenLayerIDs: Set<String>
        /// The zero-based page the extraction and the hidden names belong to. The canvas uses
        /// the filter for this page only (nl-ux: it used to draw page 0's linework on every page).
        let pageIndex: Int

        init(extraction: VectorPageExtraction, hiddenLayerIDs: Set<String>, pageIndex: Int = 0) {
            self.extraction = extraction
            self.hiddenLayerIDs = hiddenLayerIDs
            self.pageIndex = pageIndex
        }

        /// Whether this filter describes the page at `index`.
        func applies(toPageIndex index: Int) -> Bool { index == pageIndex }
    }

    /// Rasterises the planned viewport region of one page's visible-layer linework.
    ///
    /// The plan carries the bitmap size in whole device pixels and the region's offset from
    /// the page's top-left corner, so this path produces exactly the same geometry as the
    /// native one and lands on exactly the same whole device pixels (gates Z5 and Z6). It
    /// renders the viewport rather than the sheet for the same reason the native path does:
    /// at 400 % the sheet is 256.9 megapixels and the window is 6.4.
    ///
    /// - Parameters:
    ///   - filtering: the extraction and the effective hidden set.
    ///   - page: the page being drawn, for its box and `/Rotate`.
    ///   - plan: what to draw and at what pixel size.
    static func render(
        filtering: Filtering,
        page: ZPDFUIPresentation.PageDescriptor,
        plan: ViewportRasterPlan,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CGImage? {
        let pixelWidth = plan.pixelSize.width
        let pixelHeight = plan.pixelSize.height
        let scale = plan.scale
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Paper first, so a page whose every layer is hidden is honestly blank.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Reuse the canvas's own page-to-view mapping so rotation and the flip are decided
        // in exactly one place; the bitmap context's y-up space is flipped to match it.
        let transform = PageDisplayTransform(
            // The sheet's view (NL-DOCS-07/16): turned and cropped as on screen.
            pageBox: page.viewBox,
            rotation: page.displayRotation,
            zoom: scale,
            origin: CGPoint(
                x: -plan.originInPageDevicePixels.x,
                y: -plan.originInPageDevicePixels.y
            )
        )
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        let filter = VectorLayerVisibilityFilter(hiddenLayerIDs: filtering.hiddenLayerIDs)
        let ink = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let fill = CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.12)

        // Only primitives whose bounds meet the planned region, grown by the widest stroke:
        // zoomed in with a layer hidden, a pan costs the visible linework, not the sheet (IM-171).
        let region = plan.pageRegion
        var visited = 0
        for primitive in filtering.extraction.primitives where filter.admits(primitive) {
            visited += 1
            if visited % 1000 == 0, isCancelled() { return nil }
            // A path that only set the clip was never ink (BH-883).
            if primitive.paint.contains(.clipDerived), !primitive.paint.contains(.stroked),
               !primitive.paint.contains(.filled) { continue }
            let pad = max(primitive.strokeWidth, 0.5) + 1
            let bounds = primitive.bounds
            guard bounds.maxX + pad >= region.minX, bounds.minX - pad <= region.maxX,
                  bounds.maxY + pad >= region.minY, bounds.minY - pad <= region.maxY else { continue }
            // Parents carry whole subpaths; orphan segments carry open polylines and lone
            // curves. Children of a parent are skipped so no edge is stroked twice.
            switch primitive.kind {
            case .rectangle, .closedSubpath:
                break
            case .lineSegment, .cubicCurve:
                guard primitive.parentID == nil else { continue }
            }
            guard let path = path(for: primitive.geometry, transform: transform) else { continue }
            if primitive.paint.contains(.filled) {
                context.setFillColor(fill)
                context.addPath(path)
                context.fillPath()
            }
            if primitive.paint.contains(.stroked) || !primitive.paint.contains(.filled) {
                context.setStrokeColor(ink)
                context.setLineWidth(max(CGFloat(primitive.strokeWidth) * scale, 0.5))
                context.addPath(path)
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    private static func path(
        for geometry: VectorGeometry,
        transform: PageDisplayTransform
    ) -> CGPath? {
        func view(_ point: CGPoint) -> CGPoint {
            transform.viewPoint(from: PDFPointValue(x: point.x, y: point.y))
        }
        let path = CGMutablePath()
        switch geometry {
        case .line(let line):
            path.move(to: view(line.start))
            path.addLine(to: view(line.end))
        case .cubic(let cubic):
            path.move(to: view(cubic.p0))
            path.addCurve(to: view(cubic.p3), control1: view(cubic.p1), control2: view(cubic.p2))
        case .rectangle(let quad):
            path.addLines(between: quad.corners.map(view))
            path.closeSubpath()
        case .ring(let ring):
            guard ring.vertices.count >= 2 else { return nil }
            path.addLines(between: ring.vertices.map(view))
            if ring.isClosed { path.closeSubpath() }
        }
        return path
    }
}
