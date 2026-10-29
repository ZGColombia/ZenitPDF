import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry

/// What the canvas is showing, in the terms the renderer needs.
///
/// This is the renderer's own viewport value rather than `ZPDFUIPresentation.ViewportSnapshot`,
/// for the same reason ``RenderSnapFeedback`` is: the dependency arrow runs UI -> renderer, never
/// the other way, and the renderer must build and test without a UI package present. The fields
/// are a strict subset of the UI snapshot's, so the adapter in the app layer is a memberwise copy.
///
/// # The one coordinate contract
///
/// ``layout`` is a `ZPDFGeometry.PageViewLayout`, and every page-to-pixel conversion in this
/// package goes through `PageCoordinateConverter` built from it (see ``RenderTransform``). There
/// is no second transform anywhere in the renderer, which is what makes "hit testing matches what
/// is drawn" a structural property rather than a promise.
public struct RenderViewport: Sendable, Hashable {
    /// Where the page is drawn, at what zoom, on what screen.
    public var layout: PageViewLayout
    /// Size of the drawable in **view points**.
    public var viewSize: CGSize
    /// The part of the page currently on screen, in page space. Used for coarse culling only;
    /// correctness never depends on it.
    public var visiblePageRect: PDFRect?

    public init(layout: PageViewLayout, viewSize: CGSize, visiblePageRect: PDFRect? = nil) {
        self.layout = layout
        self.viewSize = viewSize
        self.visiblePageRect = visiblePageRect
    }

    /// Zoom factor, 1.0 = 100 %.
    public var zoom: Double { layout.zoom }
    /// Device pixels per view point.
    public var backingScale: Double { layout.backingScale }

    /// The drawable size in device pixels, rounded up, clamped to ``RenderLimits/maximumTargetPixels``.
    public var pixelSize: PixelSize {
        let width = (Double(viewSize.width) * layout.backingScale).rounded(.up)
        let height = (Double(viewSize.height) * layout.backingScale).rounded(.up)
        return PixelSize(
            width: Int(Swift.min(Swift.max(width, 0), Double(RenderLimits.maximumTargetPixels))),
            height: Int(Swift.min(Swift.max(height, 0), Double(RenderLimits.maximumTargetPixels)))
        )
    }

    /// - Throws: ``GeometryError`` when the layout is unusable, ``RendererError/invalidViewport``
    ///   when the drawable size is not a positive finite number of pixels.
    public func validate() throws {
        try layout.validate()
        guard viewSize.width.isFinite, viewSize.height.isFinite else {
            throw RendererError.invalidViewport(reason: "non-finite view size")
        }
        let pixels = pixelSize
        guard pixels.width > 0, pixels.height > 0 else {
            throw RendererError.invalidViewport(reason: "empty drawable")
        }
    }

    /// Builds a viewport that shows the whole page, top-left anchored, at a given zoom.
    ///
    /// The renderer's pixel space is **top-left origin, y increasing downwards**, which is what
    /// both a Metal render target and a flipped `CGContext` use, so `isViewFlipped` is always
    /// `true` here and nothing downstream has to branch on it.
    public static func fittingWholePage(
        _ page: PageDescriptor,
        zoom: Double,
        backingScale: Double
    ) -> RenderViewport {
        let size = page.rotatedVisibleSize
        let layout = PageViewLayout(
            anchor: .zero,
            zoom: zoom,
            backingScale: backingScale,
            isViewFlipped: true
        )
        return RenderViewport(
            layout: layout,
            viewSize: CGSize(width: size.width * zoom, height: size.height * zoom),
            visiblePageRect: page.visibleBox
        )
    }

    /// A viewport showing only `pageRect`, which is how the canvas actually behaves once the user
    /// zooms past fit-to-page.
    ///
    /// The anchor is solved by mapping the region's corners through the coordinate contract and
    /// translating so the region's minimum view-space corner lands on the drawable's origin.
    /// Deriving it rather than assuming it is what keeps a windowed viewport correct on a rotated
    /// page, where "the top-left of the region" is not the corner one would guess.
    ///
    /// - Returns: `nil` when the page or the region is unusable.
    public static func window(
        _ page: PageDescriptor,
        zoom: Double,
        backingScale: Double,
        pageRect: PDFRect
    ) -> RenderViewport? {
        let base = PageViewLayout(
            anchor: .zero,
            zoom: zoom,
            backingScale: backingScale,
            isViewFlipped: true
        )
        guard let converter = try? PageCoordinateConverter(page: page, layout: base) else {
            return nil
        }
        let box = pageRect.standardized
        let corners = [
            PDFPoint(x: box.minX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.maxY),
            PDFPoint(x: box.minX, y: box.maxY)
        ]
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for corner in corners {
            guard let view = try? converter.pageToView(corner) else { return nil }
            minX = Swift.min(minX, Double(view.x)); maxX = Swift.max(maxX, Double(view.x))
            minY = Swift.min(minY, Double(view.y)); maxY = Swift.max(maxY, Double(view.y))
        }
        guard minX.isFinite, minY.isFinite, maxX > minX, maxY > minY else { return nil }
        var layout = base
        layout.anchor = CGPoint(x: -minX, y: -minY)
        return RenderViewport(
            layout: layout,
            viewSize: CGSize(width: maxX - minX, height: maxY - minY),
            visiblePageRect: box
        )
    }
}

/// A size in whole device pixels.
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}
