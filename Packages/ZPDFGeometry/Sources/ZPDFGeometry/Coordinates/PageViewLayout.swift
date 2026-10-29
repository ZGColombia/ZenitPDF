import CoreGraphics
import Foundation
import ZPDFContracts

/// Everything the viewer knows and the measurement engine must never see: where one page is
/// drawn, at what zoom, on what kind of screen (spec 9.2).
///
/// This is a plain value, not a view. `PDFKit`, `NSView` and `NSScrollView` are all absent from
/// this package on purpose — the viewer layer measures its own geometry and hands the numbers
/// over, which is what makes every golden coordinate case in spec 9.3 runnable headless.
///
/// # Anchor convention
///
/// ``anchor`` is the corner of the page's *displayed* rectangle in the view's own coordinate
/// system:
///
/// - `isViewFlipped == false` (AppKit default, y up): the **bottom-left** corner.
/// - `isViewFlipped == true` (y down from the top-left, what most scroll-view document views
///   use): the **top-left** corner.
///
/// The displayed rectangle's size is always ``PageDescriptor/rotatedVisibleSize`` multiplied by
/// ``zoom``, so it is derived rather than passed in: a caller cannot hand over a frame that
/// disagrees with the rotation it also handed over.
public struct PageViewLayout: Hashable, Sendable {
    /// Bottom-left (unflipped) or top-left (flipped) corner of the displayed page, in view points.
    public var anchor: CGPoint

    /// View points per page point. 1.0 means 100 %.
    public var zoom: Double

    /// Device pixels per view point: 1 on a non-Retina display, 2 on Retina (spec 9.3).
    /// It never affects ``PageCoordinateConverter/pageToView(_:)`` — view points are already
    /// resolution independent — it only enters the device-pixel tolerance conversion.
    public var backingScale: Double

    /// True when the hosting view's geometry is flipped (y increases downwards).
    public var isViewFlipped: Bool

    /// 5 % (spec 9.3).
    public static let minimumZoom = 0.05
    /// 6400 % (spec 9.3).
    public static let maximumZoom = 64.0
    /// The zoom range the product supports.
    public static let supportedZoomRange: ClosedRange<Double> = minimumZoom...maximumZoom

    public init(
        anchor: CGPoint = .zero,
        zoom: Double = 1.0,
        backingScale: Double = 1.0,
        isViewFlipped: Bool = false
    ) {
        self.anchor = anchor
        self.zoom = zoom
        self.backingScale = backingScale
        self.isViewFlipped = isViewFlipped
    }

    /// - Throws: ``GeometryError/zoomOutOfRange(_:)``,
    ///   ``GeometryError/invalidBackingScale(_:)`` or
    ///   ``GeometryError/nonFiniteCoordinate`` for an unusable anchor.
    public func validate() throws {
        guard anchor.x.isFinite, anchor.y.isFinite else {
            throw GeometryError.nonFiniteCoordinate
        }
        guard zoom.isFinite, Self.supportedZoomRange.contains(zoom) else {
            throw GeometryError.zoomOutOfRange(zoom)
        }
        guard backingScale.isFinite, backingScale > 0 else {
            throw GeometryError.invalidBackingScale(backingScale)
        }
    }

    /// The same layout at a different zoom, keeping the anchor.
    public func withZoom(_ newZoom: Double) -> PageViewLayout {
        var copy = self
        copy.zoom = newZoom
        return copy
    }
}
