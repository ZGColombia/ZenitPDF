import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// The exact mapping between one rendered bitmap and the page it came from.
///
/// Three coordinate systems meet here and confusing any two of them silently shifts
/// every reported difference region:
///
/// | Space | Origin | y | Units |
/// |---|---|---|---|
/// | **page** | the page box's lower-left corner, which may be negative | up | PDF points |
/// | **display** | the box's lower-left corner *after* `/Rotate` | up | PDF points |
/// | **pixel** | the bitmap's top-left corner | **down** | pixels |
///
/// `ZPDFPDFKitBridge` renders into display space, because that is what
/// `PDFPage.draw(with:to:)` does. This type composes the two hops so that a caller only
/// ever states page-space intent and reads page-space results.
public struct RasterFrame: Sendable, Hashable, Codable {
    /// The page box, in page space.
    public let boxRect: CGRect
    /// The page-space region that was actually drawn, after clamping to the box.
    public let renderedRegion: CGRect
    /// The page's `/Rotate`, normalised to 0, 90, 180 or 270.
    public let rotation: Int
    public let scale: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        boxRect: CGRect,
        renderedRegion: CGRect,
        rotation: Int,
        scale: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.boxRect = boxRect
        self.renderedRegion = renderedRegion
        self.rotation = ((rotation % 360) + 360) % 360
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Builds the frame that describes a bridge render.
    ///
    /// - Parameter boxRect: the page box in page space, from
    ///   ``PDFPageDescriptor/boxes``. `RenderedPageImage` carries the region it drew but
    ///   not the box that region sits in, and the rotation mapping needs the box.
    public init(rendered: RenderedPageImage, boxRect: CGRect) {
        self.init(
            boxRect: boxRect,
            renderedRegion: rendered.renderedRegion,
            rotation: rendered.rotation,
            scale: Double(rendered.scale),
            pixelWidth: rendered.pixelWidth,
            pixelHeight: rendered.pixelHeight
        )
    }

    /// The drawn region expressed in display space.
    public var displayRegion: CGRect {
        PageDisplayGeometry.displayRect(
            forPageRect: renderedRegion,
            box: boxRect,
            rotation: rotation
        )
    }

    /// Page space to display space. Exact for all four rotations: no trigonometry. The
    /// renderer's own mapping, so every compare region bound and every rendered pixel agree
    /// on where a page point lands (R-161: this used to be a case-for-case copy of it).
    public var pageToDisplay: AlignmentTransform {
        AlignmentTransform(PageDisplayGeometry.pageToDisplay(box: boxRect, rotation: rotation))
    }

    /// Display space to pixel space, including the y flip.
    public var displayToPixel: AlignmentTransform {
        let region = displayRegion
        return AlignmentTransform(
            a: scale,
            b: 0,
            c: 0,
            d: -scale,
            tx: -Double(region.minX) * scale,
            ty: Double(pixelHeight) + Double(region.minY) * scale
        )
    }

    /// Page space to pixel space.
    public var pageToPixel: AlignmentTransform {
        pageToDisplay.concatenating(displayToPixel)
    }

    /// Pixel space to page space.
    public func pixelToPage() throws -> AlignmentTransform {
        try pageToPixel.inverted()
    }

    /// The page-space bounding box of a pixel-space rectangle.
    ///
    /// Corner-mapped rather than origin-and-size mapped, so a rotated page comes out
    /// right instead of inside out.
    public func pageRect(fromPixelRect rect: CGRect) throws -> CGRect {
        try pixelToPage().transformedBounds(of: rect)
    }

    /// How many pixels one PDF point occupies. Equal to ``scale`` for an unrotated page
    /// and for every rotation, since rotation is rigid.
    public var pixelsPerPoint: Double { scale }

    public var pixelCount: Int { pixelWidth * pixelHeight }

    /// The dst-pixel to src-pixel map that warps a raster taken in `source` into this
    /// frame, given an alignment that maps `source` page space onto this frame's page
    /// space.
    ///
    /// Composed rather than approximated: destination pixel → this page space →
    /// (alignment⁻¹) → source page space → source pixel.
    public func inverseResamplingMap(
        from source: RasterFrame,
        alignment: AlignmentTransform
    ) throws -> AlignmentTransform {
        let inverseAlignment = try alignment.inverted()
        return try pixelToPage()
            .concatenating(inverseAlignment)
            .concatenating(source.pageToPixel)
    }
}
