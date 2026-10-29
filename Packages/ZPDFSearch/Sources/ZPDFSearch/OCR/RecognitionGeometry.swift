import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// Maps a recogniser's normalised rectangles back into PDF page space.
///
/// Three coordinate systems meet here and none of them is the others:
///
/// 1. **Vision space** — the unit square over the image, origin bottom-left, `y` up.
/// 2. **Display space** — what `PDFPage.draw(with:to:)` renders into: the box's lower-left
///    corner at the origin, with `/Rotate` already applied, so a 90-degree page is
///    transposed. ``ZPDFPDFKitBridge/PageDisplayGeometry/displayRect(forPageRect:box:rotation:)``
///    is the forward map into it.
/// 3. **Page space** — PDF points in the box's own coordinates, negative origins included.
///    This is the space every measurement, markup and snap in Zenit PDF lives in, and the
///    only space an OCR bound may be stored in.
///
/// The map below is the exact inverse of the bridge's forward map, case for case; no
/// floating-point rotation matrix is involved, so a rectangle round-trips bit-for-bit for
/// all four rotations. `RecognitionGeometryTests` asserts exactly that.
///
/// Spec 17.3: these are search and highlight bounds. They are never snap geometry — a
/// recogniser's idea of where a glyph sits is worth a highlight and is not worth a
/// dimension.
enum RecognitionGeometry {

    /// Maps a rectangle from display space back into page space.
    ///
    /// - Parameters:
    ///   - displayRect: a rectangle in the space the page was drawn into.
    ///   - box: the page box, in page coordinates, that was drawn.
    ///   - rotation: the page's `/Rotate`, any multiple of 90 in any sign.
    static func pageRect(forDisplayRect displayRect: CGRect, box: CGRect, rotation: Int) -> CGRect {
        let normalised = normalisedRotation(rotation)
        let x0 = displayRect.minX
        let y0 = displayRect.minY
        let x1 = displayRect.maxX
        let y1 = displayRect.maxY
        let width = box.width
        let height = box.height

        // Offsets from the box's lower-left corner, in page space.
        let u0: CGFloat, v0: CGFloat, u1: CGFloat, v1: CGFloat
        switch normalised {
        case 90:
            // Forward was (u, v) -> (v, width - u).
            u0 = width - y1
            u1 = width - y0
            v0 = x0
            v1 = x1
        case 180:
            // Forward was (u, v) -> (width - u, height - v).
            u0 = width - x1
            u1 = width - x0
            v0 = height - y1
            v1 = height - y0
        case 270:
            // Forward was (u, v) -> (height - v, u).
            u0 = y0
            u1 = y1
            v0 = height - x1
            v1 = height - x0
        default:
            u0 = x0
            u1 = x1
            v0 = y0
            v1 = y1
        }

        return CGRect(
            x: box.minX + u0,
            y: box.minY + v0,
            width: u1 - u0,
            height: v1 - v0
        )
    }

    /// Maps a Vision-normalised rectangle into page space.
    ///
    /// - Parameters:
    ///   - normalisedRect: Vision's unit-square rectangle, origin bottom-left.
    ///   - displayOrigin: the lower-left corner, in display space, of the rendered region.
    ///   - displaySize: the size, in display-space points, the rendered bitmap covers.
    ///     Derived from the bitmap's own pixel dimensions divided by the render scale, not
    ///     from the requested region: the renderer rounds the pixel count up, and using the
    ///     requested size would shear every bound by up to one pixel.
    ///   - box: the page box in page coordinates.
    ///   - rotation: the page's `/Rotate`.
    /// - Returns: `nil` when the input is not a finite, non-degenerate rectangle.
    static func pageRect(
        forNormalisedRect normalisedRect: CGRect,
        displayOrigin: CGPoint,
        displaySize: CGSize,
        box: CGRect,
        rotation: Int
    ) -> CGRect? {
        guard normalisedRect.isFinite,
              displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0,
              displayOrigin.x.isFinite, displayOrigin.y.isFinite
        else { return nil }

        // Clamp into the unit square: a recogniser occasionally reports a box a hair
        // outside it, and a bound outside the page is worse than a bound on its edge.
        let minX = min(max(normalisedRect.minX, 0), 1)
        let maxX = min(max(normalisedRect.maxX, 0), 1)
        let minY = min(max(normalisedRect.minY, 0), 1)
        let maxY = min(max(normalisedRect.maxY, 0), 1)
        guard maxX > minX, maxY > minY else { return nil }

        let display = CGRect(
            x: displayOrigin.x + minX * displaySize.width,
            y: displayOrigin.y + minY * displaySize.height,
            width: (maxX - minX) * displaySize.width,
            height: (maxY - minY) * displaySize.height
        )
        let page = pageRect(forDisplayRect: display, box: box, rotation: rotation)
        guard page.isFinite else { return nil }
        return page
    }

    /// A rectangle as the four counter-clockwise corners a `GeometryBlob` of kind
    /// `.rectangle` holds.
    static func corners(of rect: CGRect) -> [(x: Double, y: Double)] {
        [
            (Double(rect.minX), Double(rect.minY)),
            (Double(rect.maxX), Double(rect.minY)),
            (Double(rect.maxX), Double(rect.maxY)),
            (Double(rect.minX), Double(rect.maxY))
        ]
    }

    /// `/Rotate` folded into `{0, 90, 180, 270}`, negative and out-of-range values included.
    static func normalisedRotation(_ degrees: Int) -> Int {
        let wrapped = degrees % 360
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        // Anything that is not a right angle is treated as upright, which is what every
        // reader does with a nonsense `/Rotate`.
        return positive % 90 == 0 ? positive : 0
    }
}

extension CGRect {
    /// `true` when every component is finite. `CGRect.isInfinite` only catches the
    /// sentinel, not a `NaN` origin.
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
