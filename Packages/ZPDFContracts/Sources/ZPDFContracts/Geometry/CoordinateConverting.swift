import CoreGraphics
import Foundation

/// Converts between one page's view coordinates and its canonical PDF page space (spec 9.2).
///
/// The measurement engine may never see a screen pixel or a zoom value. Everything it receives
/// has already crossed this boundary. Implementations live in the viewer layer, are the only
/// place that knows about zoom, scroll offset, Retina backing scale, page layout mode and
/// `/Rotate`, and hand out nothing but ``PDFPoint``.
public protocol CoordinateConverting: Sendable {
    /// View point (AppKit coordinates, y-up in an `NSView` with a flipped:false geometry) to
    /// canonical page space.
    func viewToPage(_ point: CGPoint) throws -> PDFPoint

    /// Canonical page space to view point.
    func pageToView(_ point: PDFPoint) throws -> CGPoint

    /// Converts a screen tolerance in **logical pixels** to a tolerance in PDF points.
    ///
    /// Snap radii, hit-test slop and vertex grab boxes are all authored in pixels so they stay
    /// physically constant on screen; they must be re-converted on every event, because the user
    /// can zoom between events (spec 13.6).
    func screenToleranceToPage(pixels: CGFloat) throws -> CGFloat
}

/// The multi-page form of ``CoordinateConverting`` (spec 9.2, verbatim shape).
///
/// A continuous or two-up layout shows several pages at once, so the page must be named on every
/// call. Implementations throw ``CoordinateError/unknownPage(_:)`` rather than guessing.
public protocol PageCoordinateConverting: Sendable {
    func viewToPage(
        _ point: CGPoint,
        pageID: PageID
    ) throws -> PDFPoint

    func pageToView(
        _ point: PDFPoint,
        pageID: PageID
    ) throws -> CGPoint

    func screenToleranceToPage(
        pixels: CGFloat,
        pageID: PageID
    ) throws -> CGFloat
}

extension PageCoordinateConverting {
    /// Converts a rectangle by converting its two opposite corners, then re-standardizing.
    /// Correct under any rotation, which corner-wise `CGRect` arithmetic is not.
    public func viewToPage(_ rect: CGRect, pageID: PageID) throws -> PDFRect {
        let a = try viewToPage(CGPoint(x: rect.minX, y: rect.minY), pageID: pageID)
        let b = try viewToPage(CGPoint(x: rect.maxX, y: rect.maxY), pageID: pageID)
        return PDFRect(corner: a, opposite: b)
    }

    /// Binds this converter to a single page, yielding the single-page protocol.
    public func bound(to pageID: PageID) -> some CoordinateConverting {
        BoundPageCoordinateConverter(base: self, pageID: pageID)
    }
}

/// A ``PageCoordinateConverting`` narrowed to one page.
private struct BoundPageCoordinateConverter<Base: PageCoordinateConverting>: CoordinateConverting {
    let base: Base
    let pageID: PageID

    func viewToPage(_ point: CGPoint) throws -> PDFPoint {
        try base.viewToPage(point, pageID: pageID)
    }

    func pageToView(_ point: PDFPoint) throws -> CGPoint {
        try base.pageToView(point, pageID: pageID)
    }

    func screenToleranceToPage(pixels: CGFloat) throws -> CGFloat {
        try base.screenToleranceToPage(pixels: pixels, pageID: pageID)
    }
}
