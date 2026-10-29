import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// The mapping between PDF page space and the flipped view the canvas draws in.
///
/// Two conversions are folded into one value, and both have to agree or a measurement lands where
/// the user did not click:
///
/// 1. **Origin.** Page space is bottom-left with y increasing upwards; the canvas document view is
///    flipped, so y increases downwards.
/// 2. **`/Rotate`.** The rasteriser honours the page's rotation, so the image it returns is in
///    *display* space. Markups are stored in page space, unrotated. The rotation therefore has to
///    be applied here rather than by drawing the overlay into a rotated context, because hit
///    testing needs the inverse and a `CGContext` rotation has no inverse the hit tester can read.
public struct PageDisplayTransform: Hashable, Sendable {

    /// The page's crop box, standardized.
    public let pageBox: PDFRectValue
    /// The page's `/Rotate`, normalised to 0, 90, 180 or 270.
    public let rotation: Int
    /// View points per page point.
    public let zoom: CGFloat
    /// Where the page's displayed rectangle starts, in the flipped view's coordinates.
    public let origin: CGPoint

    public init(pageBox: PDFRectValue, rotation: Int, zoom: CGFloat, origin: CGPoint) {
        self.pageBox = pageBox
        self.rotation = ((rotation % 360) + 360) % 360
        self.zoom = zoom
        self.origin = origin
    }

    /// The page's size in points after `/Rotate`.
    public var displaySize: CGSize {
        let width = CGFloat(pageBox.size.width)
        let height = CGFloat(pageBox.size.height)
        return (rotation == 90 || rotation == 270)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// The page's rectangle in the flipped view.
    public var pageFrame: CGRect {
        CGRect(
            origin: origin,
            size: CGSize(width: displaySize.width * zoom, height: displaySize.height * zoom)
        )
    }

    /// Page space to view space.
    public func viewPoint(from page: PDFPointValue) -> CGPoint {
        let u = CGFloat(page.x - pageBox.minX)
        let v = CGFloat(page.y - pageBox.minY)
        let w = CGFloat(pageBox.size.width)
        let h = CGFloat(pageBox.size.height)
        let local: CGPoint
        switch rotation {
        case 90: local = CGPoint(x: v, y: u)
        case 180: local = CGPoint(x: w - u, y: v)
        case 270: local = CGPoint(x: h - v, y: w - u)
        default: local = CGPoint(x: u, y: h - v)
        }
        return CGPoint(x: origin.x + local.x * zoom, y: origin.y + local.y * zoom)
    }

    /// View space to page space. The exact inverse of ``viewPoint(from:)``.
    public func pagePoint(from view: CGPoint) -> PDFPointValue {
        let x = (view.x - origin.x) / max(zoom, .leastNormalMagnitude)
        let y = (view.y - origin.y) / max(zoom, .leastNormalMagnitude)
        let w = CGFloat(pageBox.size.width)
        let h = CGFloat(pageBox.size.height)
        let uv: (u: CGFloat, v: CGFloat)
        switch rotation {
        case 90: uv = (u: y, v: x)
        case 180: uv = (u: w - x, v: y)
        case 270: uv = (u: w - y, v: h - x)
        default: uv = (u: x, v: h - y)
        }
        return PDFPointValue(x: Double(uv.u) + pageBox.minX, y: Double(uv.v) + pageBox.minY)
    }

    /// A page-space rectangle in the flipped view.
    ///
    /// Built from two opposite corners rather than from the origin and size, because under a 90 or
    /// 270 degree rotation width and height swap and an origin-plus-size construction would produce
    /// a rectangle with negative extents.
    public func viewRect(from rect: PDFRectValue) -> CGRect {
        let a = viewPoint(from: PDFPointValue(x: rect.minX, y: rect.minY))
        let b = viewPoint(from: PDFPointValue(x: rect.maxX, y: rect.maxY))
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// The part of the page that a view rectangle covers, clamped to the page box.
    public func pageRect(covering viewRect: CGRect) -> PDFRectValue {
        let a = pagePoint(from: CGPoint(x: viewRect.minX, y: viewRect.minY))
        let b = pagePoint(from: CGPoint(x: viewRect.maxX, y: viewRect.maxY))
        let minX = max(pageBox.minX, min(a.x, b.x))
        let minY = max(pageBox.minY, min(a.y, b.y))
        let maxX = min(pageBox.maxX, max(a.x, b.x))
        let maxY = min(pageBox.maxY, max(a.y, b.y))
        return PDFRectValue(
            origin: PDFPointValue(x: minX, y: minY),
            size: PDFSizeValue(width: max(0, maxX - minX), height: max(0, maxY - minY))
        )
    }
}
