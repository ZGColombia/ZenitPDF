import CoreGraphics
import Foundation
import ZPDFContracts

/// The single-page view <-> page converter (spec 9.2, 9.3).
///
/// # The pipeline
///
/// `pageToView` composes four steps, in this order:
///
/// 1. **Crop translation.** Page coordinates are relative to the PDF's own origin, which may be
///    negative or far from zero. Subtracting ``PageDescriptor/visibleBox``'s minimum corner puts
///    the drawing surface at `(0, 0) ... (cropWidth, cropHeight)`.
/// 2. **`/Rotate`.** A clockwise quarter-turn map, in a bottom-left-origin frame, onto a
///    rectangle of ``PageDescriptor/rotatedVisibleSize``.
/// 3. **Zoom.** A uniform multiply. Nothing else in the engine is allowed to know this number.
/// 4. **View placement.** Translate to ``PageViewLayout/anchor``, mirroring y when the host view
///    is flipped.
///
/// `viewToPage` is the exact algebraic inverse, not a re-derivation, so a round trip is stable
/// to the last few ulps at any legal zoom.
///
/// # What is deliberately absent
///
/// No PDFKit, no AppKit, no scroll offset, no page-layout mode. A continuous or two-up layout is
/// expressed purely as a different ``PageViewLayout/anchor`` per page, which is why the same
/// twelve lines of arithmetic cover every layout case in spec 9.3.
///
/// `/UserUnit` is intentionally **not** applied here. It scales page points to physical size, not
/// page coordinates to view coordinates; it belongs to the scale layer, where the importer folds
/// it into the ``ScaleTransform`` matrix once, rather than being re-applied on every mouse move.
public struct PageCoordinateConverter: CoordinateConverting, Hashable, Sendable {
    /// The page being converted. Validated at construction.
    public let page: PageDescriptor
    /// Where and how it is drawn. Validated at construction.
    public let layout: PageViewLayout

    // Cached, so the hot path is pure arithmetic.
    private let cropMinX: Double
    private let cropMinY: Double
    private let cropWidth: Double
    private let cropHeight: Double

    /// - Throws: ``PageGeometryError`` for an invalid page, ``GeometryError`` for an invalid
    ///   layout.
    public init(page: PageDescriptor, layout: PageViewLayout) throws {
        try page.validate()
        try layout.validate()
        self.page = page
        self.layout = layout
        let box = page.visibleBox
        self.cropMinX = box.minX
        self.cropMinY = box.minY
        self.cropWidth = box.width
        self.cropHeight = box.height
    }

    // MARK: - Derived geometry

    /// The page's displayed size in view points: rotated crop size times zoom.
    public var displayedSize: CGSize {
        let size = page.rotatedVisibleSize
        return CGSize(width: size.width * layout.zoom, height: size.height * layout.zoom)
    }

    // MARK: - Rotation

    /// Crop-local (bottom-left origin, size `cropWidth` x `cropHeight`) to rotated-display-local
    /// (bottom-left origin, size ``PageDescriptor/rotatedVisibleSize``).
    ///
    /// `/Rotate` is defined as a **clockwise** rotation of the page content when displayed. In a
    /// y-up frame a clockwise quarter turn sends `(x, y)` to `(y, -x)`; the translation that
    /// follows brings the result back into the positive quadrant.
    private func rotateForward(_ x: Double, _ y: Double) -> (Double, Double) {
        switch page.rotation {
        case .degrees0: (x, y)
        case .degrees90: (y, cropWidth - x)
        case .degrees180: (cropWidth - x, cropHeight - y)
        case .degrees270: (cropHeight - y, x)
        }
    }

    /// The exact inverse of ``rotateForward(_:_:)``.
    private func rotateInverse(_ u: Double, _ v: Double) -> (Double, Double) {
        switch page.rotation {
        case .degrees0: (u, v)
        case .degrees90: (cropWidth - v, u)
        case .degrees180: (cropWidth - u, cropHeight - v)
        case .degrees270: (v, cropHeight - u)
        }
    }

    // MARK: - CoordinateConverting

    public func pageToView(_ point: PDFPoint) throws -> CGPoint {
        guard point.isFinite else { throw CoordinateError.nonFiniteCoordinate }
        let (u, v) = rotateForward(point.x - cropMinX, point.y - cropMinY)
        let sx = u * layout.zoom
        let sy = v * layout.zoom
        let x = layout.anchor.x + CGFloat(sx)
        let y: CGFloat = layout.isViewFlipped
            ? layout.anchor.y + CGFloat(Double(displayedSize.height) - sy)
            : layout.anchor.y + CGFloat(sy)
        return CGPoint(x: x, y: y)
    }

    public func viewToPage(_ point: CGPoint) throws -> PDFPoint {
        guard point.x.isFinite, point.y.isFinite else { throw CoordinateError.nonFiniteCoordinate }
        let sx = Double(point.x - layout.anchor.x)
        let rawY = Double(point.y - layout.anchor.y)
        let sy = layout.isViewFlipped ? Double(displayedSize.height) - rawY : rawY
        let u = sx / layout.zoom
        let v = sy / layout.zoom
        let (x, y) = rotateInverse(u, v)
        return PDFPoint(x: x + cropMinX, y: y + cropMinY)
    }

    /// Converts a tolerance in **logical view pixels** (points) to page points, per the contract
    /// in ``CoordinateConverting``.
    ///
    /// The conversion is a plain division by zoom: rotation is an isometry and the crop
    /// translation is rigid, so neither changes a distance. A 12-point snap radius is 240 page
    /// points at 5 % zoom and 0.1875 page points at 6400 % — which is exactly why spec 13.6
    /// requires the radius to be re-converted on every event rather than cached. The backing
    /// scale plays no part: a 12-point snap radius feels the same size on every display.
    public func screenToleranceToPage(pixels: CGFloat) throws -> CGFloat {
        let value = Double(pixels)
        guard value.isFinite, value >= 0 else { throw GeometryError.invalidTolerance(value) }
        return CGFloat(value / layout.zoom)
    }

    // MARK: - Aggregates

    /// Converts a page rectangle to view coordinates by converting two opposite corners.
    ///
    /// Corner-wise arithmetic on `origin` and `size` is wrong under rotation 90/270 and under a
    /// flipped view; converting corners and re-standardizing is correct in all eight combinations.
    public func pageToView(_ rect: PDFRect) throws -> CGRect {
        let a = try pageToView(PDFPoint(x: rect.minX, y: rect.minY))
        let b = try pageToView(PDFPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: Swift.min(a.x, b.x),
            y: Swift.min(a.y, b.y),
            width: Swift.abs(b.x - a.x),
            height: Swift.abs(b.y - a.y)
        )
    }

    /// Converts a view rectangle to page space by converting two opposite corners.
    public func viewToPage(_ rect: CGRect) throws -> PDFRect {
        let a = try viewToPage(CGPoint(x: rect.minX, y: rect.minY))
        let b = try viewToPage(CGPoint(x: rect.maxX, y: rect.maxY))
        return PDFRect(corner: a, opposite: b)
    }
}
