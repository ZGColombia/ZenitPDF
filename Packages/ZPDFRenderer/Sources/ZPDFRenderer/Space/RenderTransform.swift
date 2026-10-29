import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Page space to device-pixel space, and back, for one page in one viewport.
///
/// # Where the matrix comes from
///
/// It is **not** re-derived. `ZPDFGeometry.PageCoordinateConverter` is the coordinate contract,
/// and its `pageToView` is a composition of a crop translation, a quarter
/// turn, a uniform zoom and a translation — every one of them affine. So this type builds its
/// 2x3 matrix by probing the converter at three page points and solving, and a unit test asserts
/// the matrix agrees with `pageToView` to 1e-9 view points at random points and every rotation.
/// Deriving the matrix by probing rather than by re-implementing the pipeline means a change to
/// the coordinate contract cannot silently diverge from the renderer: the probe follows it.
///
/// # Pixel space
///
/// Top-left origin, y increasing downwards, one unit = one device pixel. That is what a Metal
/// render target uses and what a flipped `CGContext` uses, so both backends work in the same
/// numbers and the golden comparison is a straight pixel-for-pixel operation.
///
/// # Line widths
///
/// ``deviceWidth(forPageWidth:)`` applies two policies and neither of them touches geometry:
///
/// - **A minimum of ``minimumStrokeDevicePixels``.** At 5 % zoom a 0.5 pt stroke is 0.05 device
///   pixels and would be an invisible smear of 5 %-alpha grey. Flooring the *width* keeps the
///   line legible; the centreline, the endpoints and every measured length are unchanged, so the
///   drawing does not lie about geometry — it only refuses to disappear. This is the same
///   decision PDF's zero-width-line rule makes, and CAD viewers have made, for the same reason.
/// - **A maximum of ``maximumStrokeDevicePixels``.** At 6400 % a 100 pt stroke is 12 800 pixels;
///   past a few thousand the quad is larger than any drawable and the extra width is invisible
///   anyway. Clamping keeps the vertex expansion finite.
public struct RenderTransform: Sendable, Hashable {

    /// A 2x3 affine map, row major: `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
    public struct Affine: Sendable, Hashable {
        public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

        public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
            self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
        }

        public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        public var determinant: Double { a * d - b * c }

        public func apply(_ x: Double, _ y: Double) -> (Double, Double) {
            (a * x + c * y + tx, b * x + d * y + ty)
        }

        /// The inverse, or `nil` for a singular matrix. A singular page transform means a zero
        /// zoom, which `PageViewLayout.validate()` has already rejected.
        public var inverted: Affine? {
            let det = determinant
            guard det.isFinite, det != 0 else { return nil }
            let ia = d / det
            let ib = -b / det
            let ic = -c / det
            let id = a / det
            return Affine(
                a: ia, b: ib, c: ic, d: id,
                tx: -(ia * tx + ic * ty),
                ty: -(ib * tx + id * ty)
            )
        }
    }

    /// Thinnest stroke the renderer will paint, in device pixels. One pixel: below it a stroke is
    /// partial coverage and reads as a grey smudge rather than a line.
    public static let minimumStrokeDevicePixels: Double = 1.0
    /// Widest stroke the renderer will paint, in device pixels.
    public static let maximumStrokeDevicePixels: Double = 4096.0

    /// Page space to device pixels.
    public let pageToPixel: Affine
    /// Device pixels to page space. The algebraic inverse of ``pageToPixel``, not a re-derivation.
    public let pixelToPage: Affine
    /// Device pixels per page point along either axis. Rotation is a rigid quarter turn and zoom
    /// is uniform, so the two axes always agree and one scalar is enough.
    public let pixelsPerPagePoint: Double
    public let viewport: RenderViewport
    public let page: PageDescriptor

    /// - Throws: ``RendererError/invalidPage(reason:)``, ``RendererError/invalidViewport(reason:)``
    ///   or a `ZPDFGeometry` error for an unusable page or layout.
    public init(page: PageDescriptor, viewport: RenderViewport) throws {
        try viewport.validate()
        do {
            try page.validate()
        } catch {
            throw RendererError.invalidPage(reason: String(describing: error))
        }

        // Probe the coordinate contract rather than re-implementing it.
        let converter = try PageCoordinateConverter(page: page, layout: viewport.layout)
        let scale = viewport.layout.backingScale
        func probe(_ x: Double, _ y: Double) throws -> (Double, Double) {
            let view = try converter.pageToView(PDFPoint(x: x, y: y))
            return (Double(view.x) * scale, Double(view.y) * scale)
        }
        let box = page.visibleBox
        let origin = try probe(box.minX, box.minY)
        // Unit probes are taken one page point away from the crop origin, so the differences are
        // the matrix columns exactly, with no division by a large number.
        let unitX = try probe(box.minX + 1, box.minY)
        let unitY = try probe(box.minX, box.minY + 1)

        let a = unitX.0 - origin.0
        let b = unitX.1 - origin.1
        let c = unitY.0 - origin.0
        let d = unitY.1 - origin.1
        // Solve for the translation from the origin probe: origin = M * (box.minX, box.minY) + t.
        let tx = origin.0 - (a * box.minX + c * box.minY)
        let ty = origin.1 - (b * box.minX + d * box.minY)

        let forward = Affine(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        guard forward.determinant.isFinite, forward.determinant != 0,
              let inverse = forward.inverted
        else {
            throw RendererError.invalidViewport(reason: "singular page transform")
        }

        self.page = page
        self.viewport = viewport
        self.pageToPixel = forward
        self.pixelToPage = inverse
        self.pixelsPerPagePoint = viewport.layout.zoom * scale
    }

    // MARK: - Point mapping

    public func pixel(from point: PDFPoint) -> PixelPoint {
        let (x, y) = pageToPixel.apply(point.x, point.y)
        return PixelPoint(x: x, y: y)
    }

    public func pagePoint(from pixel: PixelPoint) -> PDFPoint {
        let (x, y) = pixelToPage.apply(pixel.x, pixel.y)
        return PDFPoint(x: x, y: y)
    }

    // MARK: - Widths and tolerances

    /// The width, in device pixels, that a stroke of `pageWidth` page points is actually painted
    /// at, after the legibility floor and the sanity ceiling.
    public func deviceWidth(forPageWidth pageWidth: Double) -> Double {
        guard pageWidth.isFinite, pageWidth > 0 else { return Self.minimumStrokeDevicePixels }
        let natural = pageWidth * pixelsPerPagePoint
        guard natural.isFinite else { return Self.minimumStrokeDevicePixels }
        return Swift.min(
            Self.maximumStrokeDevicePixels,
            Swift.max(Self.minimumStrokeDevicePixels, natural)
        )
    }

    /// Half of ``deviceWidth(forPageWidth:)``, expressed back in page points.
    ///
    /// This is the number the hit tester adds to the caller's tolerance, and it is the whole
    /// mechanism behind "hit testing matches what is drawn": at 5 % zoom a hairline is painted
    /// one pixel wide, which is 10 page points, and the user can hit it anywhere in that band.
    public func drawnHalfWidthInPagePoints(forPageWidth pageWidth: Double) -> Double {
        guard pixelsPerPagePoint > 0 else { return 0 }
        return deviceWidth(forPageWidth: pageWidth) / 2 / pixelsPerPagePoint
    }

    /// The cap a stroke of `pageWidth` is actually drawn with.
    ///
    /// Core Graphics takes a thin-line path for a stroke of one device pixel or narrower and
    /// draws **no cap** on it, whatever the caller asked for. That is measurable: a dotted 1 px
    /// line with round caps produces byte-for-byte the same raster as one with butt caps, and at
    /// 1.1 px the caps appear. So the rule is adopted as the renderer's own, applied in the Metal
    /// shader, in the reference rasteriser and here, rather than left as a per-backend difference
    /// the golden suite would have to be loosened to tolerate. At one pixel a cap is at most a
    /// quarter of a pixel of ink; the geometry it decorates is unchanged either way.
    public func effectiveCap(_ cap: RenderCap, forPageWidth pageWidth: Double) -> RenderCap {
        deviceWidth(forPageWidth: pageWidth) <= 1.0 ? .butt : cap
    }

    /// Converts a length in view points to device pixels. Handles and snap glyphs are sized this
    /// way so they are the same physical size at every zoom.
    public func devicePixels(fromViewPoints viewPoints: Double) -> Double {
        viewPoints * viewport.layout.backingScale
    }

    /// Converts a length in view points to page points at the current zoom.
    public func pagePoints(fromViewPoints viewPoints: Double) -> Double {
        guard viewport.layout.zoom > 0 else { return 0 }
        return viewPoints / viewport.layout.zoom
    }
}

/// A point in device-pixel space: top-left origin, y down.
public struct PixelPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func distance(to other: PixelPoint) -> Double {
        let dx = other.x - x, dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    public var asCGPoint: CGPoint { CGPoint(x: x, y: y) }
}
