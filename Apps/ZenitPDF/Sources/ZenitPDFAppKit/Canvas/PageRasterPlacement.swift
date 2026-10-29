import CoreGraphics
import Foundation
import IOSurface
import ZPDFUIPresentation

/// A rasterised piece of a page, and the part of the page it is.
///
/// The region travels with the image because the canvas keeps showing the raster it has
/// while a new one is in flight: a zoom moves the page under the picture, and the only way
/// to know where the picture still belongs is to know which page rectangle it is.
struct PageRaster: Equatable, Sendable {

    /// How much of the page the image covers.
    enum Coverage: Equatable, Sendable {
        /// The whole page box. Print, export and the pre-viewport tests.
        case wholePage
        /// A page-space rectangle. What the canvas asks for.
        case region(PDFRectValue)
    }

    let image: CGImage
    let coverage: Coverage
    /// Device pixels per page point the image was produced at.
    let scale: CGFloat
    /// The same pixels as an `IOSurface`, when the image was made over one
    /// (``CanvasSurfaceImage``). A layer shows the surface without a copy; a `CGImage` given
    /// to a layer is copied into the render server on the main thread at the next commit —
    /// a megabyte per tile, which is what made a landing cost tens of milliseconds.
    var surface: IOSurface?

    init(image: CGImage, coverage: Coverage, scale: CGFloat, surface: IOSurface? = nil) {
        self.image = image
        self.coverage = coverage
        self.scale = scale
        self.surface = surface
    }

    /// The contents a Core Animation layer should show for this raster.
    var layerContents: Any { surface ?? image }

    static func == (lhs: PageRaster, rhs: PageRaster) -> Bool {
        lhs.image === rhs.image && lhs.coverage == rhs.coverage && lhs.scale == rhs.scale
    }
}

/// Where a raster goes this frame, and whether drawing it is a copy or a resample.
///
/// This is the value gates Z5 and Z6 are asserted on.
struct PageRasterPlacement: Equatable {
    /// The destination rectangle in the flipped page view's own coordinates.
    let destination: CGRect
    /// Destination pixels per source pixel. **1.0 means the page is as sharp as the raster
    /// is**; anything above 1.0 is an upscale the user sees as mush. Gate Z5 requires 1.00
    /// once the viewport has settled, at every zoom from 5 % to 800 %.
    let magnification: CGFloat
    /// Whether the destination is a whole number of device pixels in both origin and size,
    /// and the magnification is exactly 1. Gate Z6.
    let isPixelExact: Bool
}

extension PageRaster {

    /// How close to 1.0 a magnification has to be before the raster is treated as the one
    /// that belongs to this frame. A hair either side is float noise from the page-space
    /// round trip, not a zoom.
    static let settledMagnificationTolerance: CGFloat = 1e-3

    /// Places the raster under the current transform.
    ///
    /// Two cases, and the difference between them is what gate Z6 exists for:
    ///
    /// - **Settled** — the raster was produced for this zoom, so its natural destination is
    ///   already within a rounding error of the image's own pixel count. The destination is
    ///   snapped to whole device pixels and sized to exactly the image's pixels, which makes
    ///   the draw a 1:1 copy: 1.71 ms rather than 12.81 ms for the same picture on the
    ///   reference machine, a 7.5x main-thread saving bought by removing 0.04 of a pixel.
    /// - **Stale** — a zoom has moved on and the new raster has not landed yet. The image is
    ///   drawn at its true page position and resampled, which is the honest thing to show for
    ///   the few milliseconds it takes: a slightly soft page that is in the right place.
    ///   ``magnification`` says by how much, so a test can see it rather than infer it.
    func placement(in transform: PageDisplayTransform, backingScale: CGFloat) -> PageRasterPlacement {
        let natural: CGRect
        switch coverage {
        case .wholePage:
            natural = transform.pageFrame
        case let .region(region):
            natural = transform.viewRect(from: region)
        }
        let scale = max(backingScale, .leastNormalMagnitude)
        let deviceWidth = natural.width * scale
        guard image.width > 0, image.height > 0, deviceWidth > 0 else {
            return PageRasterPlacement(destination: natural, magnification: 1, isPixelExact: false)
        }
        let magnification = deviceWidth / CGFloat(image.width)
        guard abs(magnification - 1) <= Self.settledMagnificationTolerance else {
            return PageRasterPlacement(
                destination: natural,
                magnification: magnification,
                isPixelExact: false
            )
        }
        // Settled. The image's pixel count is the authority on the destination's size, so the
        // ratio is exactly 1 by construction rather than by luck; the origin is rounded to the
        // nearest whole device pixel, which moves the sheet by at most half a device pixel and
        // buys the fast path.
        let deviceRect = CGRect(
            x: (natural.minX * scale).rounded(),
            y: (natural.minY * scale).rounded(),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        return PageRasterPlacement(
            destination: CGRect(
                x: deviceRect.minX / scale,
                y: deviceRect.minY / scale,
                width: deviceRect.width / scale,
                height: deviceRect.height / scale
            ),
            magnification: 1,
            isPixelExact: true
        )
    }
}
