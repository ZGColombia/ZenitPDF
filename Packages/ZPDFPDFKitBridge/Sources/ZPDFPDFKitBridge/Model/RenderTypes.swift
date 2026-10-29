import CoreGraphics
import Foundation

/// A bitmap size in whole pixels.
///
/// It exists so a caller that must blit its raster to whole device pixels can say so as a
/// value rather than hoping `ceil` agrees with it. See ``PageRenderRequest/exactPixelSize``.
public struct RenderPixelSize: Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Pixels in the bitmap. Computed in a wider type by the caller when it matters.
    public var pixelCount: Int { width * height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    // MARK: - The render's sizing rule, in one place (T-069)

    /// One axis of the bitmap ``PDFDocumentProviding/renderPageRegion(_:)`` produces for a
    /// displayed extent of `points` at `scale`, when no ``PageRenderRequest/exactPixelSize`` is
    /// pinned: `ceil(points × scale)`, so an export never loses its last row.
    ///
    /// A `Double`, not an `Int`: a hostile page box reaches here intact and `Int(1e23)` traps.
    public static func renderedDimension(_ points: Double, scale: Double) -> Double {
        (points * scale).rounded(.up)
    }

    /// A scale, at most `requested`, whose bitmap — each axis rounded up by
    /// ``renderedDimension(_:scale:)`` — fits `pixelBudget`. `0` when no positive scale fits or
    /// an argument is unusable.
    ///
    /// `requested` when it fits, else the exact-area scale `sqrt(budget / area)` when it fits.
    /// That one can overshoot by up to `w + h + 1` pixels once each axis is rounded up (BH-645:
    /// an ARCH-D crop box at a 64 M budget came to 9 798 × 6 532 = 64 000 536). Because
    /// `ceil(x) < x + 1`, a scale with `(w·s + 1)(h·s + 1) <= budget` always fits, and that root
    /// is taken otherwise: never over the budget, and a fit is found whenever one exists — a
    /// strip sheet whose exact-area scale is ten times too large included. It can be a row or a
    /// column short of the very largest fit on an ordinary sheet; it is never over.
    ///
    /// The one implementation for Revision Compare's overlay plan and for OCR's page renders:
    /// before T-069 the overlay stepped the scale down by 0.1 % at most 64 times and threw past
    /// that, and its caller then fell back to the unfitted, over-budget scale.
    public static func fittedScale(width: Double, height: Double, requested: Double, pixelBudget: Int) -> Double {
        guard width > 0, height > 0, width.isFinite, height.isFinite,
              requested.isFinite, requested > 0, pixelBudget > 0
        else { return 0 }
        let budget = Double(pixelBudget)
        func pixels(_ scale: Double) -> Double {
            renderedDimension(width, scale: scale) * renderedDimension(height, scale: scale)
        }
        let exact = Swift.min(requested, (budget / (width * height)).squareRoot())
        if exact > 0, pixels(exact) <= budget { return exact }

        let a = width * height
        let b = width + height
        let c = 1 - budget
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return 0 }
        var scale = Swift.min(exact, (-b + discriminant.squareRoot()) / (2 * a))
        // Floating-point belt and braces: step down until the rounded bitmap fits.
        var steps = 0
        while scale > 0, pixels(scale) > budget, steps < 64 {
            scale = scale.nextDown * (1 - 1e-9)
            steps += 1
        }
        return scale > 0 && pixels(scale) <= budget ? scale : 0
    }
}

/// A request to rasterise part of a page.
///
/// `region` is in page space — PDF points, bottom-left origin, in the coordinate system
/// of `box`, so a crop box with a negative origin has a region with negative coordinates
/// — and `nil` means the whole box. It is clamped to the box before anything is drawn.
///
/// The page's `/Rotate` is always honoured, because that is what the estimator sees and
/// what PDFKit's own page drawing does. The returned image is therefore in *display*
/// space: for a 90 or 270 degree page the image's aspect is the page's transposed. The
/// image is `ceil(region.size * scale)` pixels, and the request is rejected before any
/// allocation when that product exceeds ``DocumentLimits/maximumRenderPixels``.
public struct PageRenderRequest: Sendable, Hashable {
    public var document: DocumentHandle
    public var pageIndex: Int
    public var box: PDFPageBox
    public var region: CGRect?
    public var scale: CGFloat
    /// Paint an opaque white ground first. Off for overlay compositing, on for export.
    public var opaqueBackground: Bool
    /// The exact bitmap size the caller needs, or `nil` for `ceil(region.size x scale)`.
    ///
    /// An export wants `ceil`. A canvas does not: it has to blit its raster to whole device
    /// pixels at exactly 1:1, and half a pixel of rounding is the difference between a copy
    /// and a resample -- measured at 7.1x to 7.5x by a historical viewer benchmark. Pinning the
    /// bitmap here removes the rounding from the round trip.
    ///
    /// The content is still drawn at ``scale`` and positioned by ``region``: an over- or
    /// under-sized value shows more or less of the ground, and never stretches the page.
    public var exactPixelSize: RenderPixelSize?
    /// Degrees clockwise the sheet is turned on screen on top of its own `/Rotate`
    /// (NL-DOCS-07): 0, 90, 180 or 270. The bitmap comes back in that turned display space.
    public var viewRotation: Int = 0

    public init(
        document: DocumentHandle,
        pageIndex: Int,
        box: PDFPageBox = .crop,
        region: CGRect? = nil,
        scale: CGFloat = 1,
        opaqueBackground: Bool = true,
        exactPixelSize: RenderPixelSize? = nil
    ) {
        self.document = document
        self.pageIndex = pageIndex
        self.box = box
        self.region = region
        self.scale = scale
        self.opaqueBackground = opaqueBackground
        self.exactPixelSize = exactPixelSize
    }
}

/// A rasterised page region.
///
/// `CGImage` is `Sendable`, so this crosses actor boundaries as a value.
public struct RenderedPageImage: Sendable {
    public let image: CGImage
    public let pageIndex: Int
    /// The page-space rectangle that was drawn, after clamping to the box.
    public let renderedRegion: CGRect
    public let box: PDFPageBox
    public let scale: CGFloat
    /// The page's `/Rotate`, which was applied when drawing.
    public let rotation: Int
    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }

    public init(
        image: CGImage,
        pageIndex: Int,
        renderedRegion: CGRect,
        box: PDFPageBox,
        scale: CGFloat,
        rotation: Int
    ) {
        self.image = image
        self.pageIndex = pageIndex
        self.renderedRegion = renderedRegion
        self.box = box
        self.scale = scale
        self.rotation = rotation
    }
}

/// A whole-page thumbnail at a bounded pixel size.
///
/// The requested size is a *bounding box*: the page is fitted into it preserving aspect
/// ratio, so a landscape ARCH-D sheet and a portrait A4 asked for 256 x 256 come back
/// with the same longest edge and different short edges.
public struct ThumbnailRequest: Sendable, Hashable {
    public var document: DocumentHandle
    public var pageIndex: Int
    public var box: PDFPageBox
    public var maximumPixelSize: Int

    public init(
        document: DocumentHandle,
        pageIndex: Int,
        box: PDFPageBox = .crop,
        maximumPixelSize: Int
    ) {
        self.document = document
        self.pageIndex = pageIndex
        self.box = box
        self.maximumPixelSize = maximumPixelSize
    }
}

/// A thumbnail, and whether it came out of the cache.
public struct ThumbnailResult: Sendable {
    public let image: CGImage
    public let pageIndex: Int
    public let wasCacheHit: Bool
    public let key: ThumbnailCache.Key

    public init(image: CGImage, pageIndex: Int, wasCacheHit: Bool, key: ThumbnailCache.Key) {
        self.image = image
        self.pageIndex = pageIndex
        self.wasCacheHit = wasCacheHit
        self.key = key
    }
}
