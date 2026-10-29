import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// The closed-form half of `⌘*` zoom-to-selection and marquee zoom:
/// given a page-space rectangle and a viewport, what zoom fits it and what page rect ends up
/// visible. Pure, so the arithmetic is testable without a window.
public enum ZoomMath {

    /// The padding around a fitted target, as a fraction of the target's size per side.
    public static let paddingRatio: Double = 0.12

    /// A fitted viewport: the zoom to set, and the page rect the viewport then shows.
    public struct Fit: Equatable {
        public init(zoom: Double, visiblePageRect: PDFRectValue) {
            self.zoom = zoom
            self.visiblePageRect = visiblePageRect
        }

        /// The zoom factor, clamped to the supported 5 %–6400 % range.
        public var zoom: Double
        /// The page-space rect the viewport shows at ``zoom``, centred on the target.
        public var visiblePageRect: PDFRectValue
    }

    /// Fits a page-space rectangle into a viewport with padding.
    ///
    /// The zoom is chosen so the padded target fits both axes, then clamped; the visible
    /// rect is re-derived *from the clamped zoom*, so the target stays centred even when
    /// the clamp refuses the ideal zoom. Degenerate targets (a point count markup) get a
    /// minimum working size instead of an infinite zoom.
    ///
    /// - Parameters:
    ///   - target: the rect to fit, in page points.
    ///   - viewSize: the viewport, in view points.
    ///   - minimumTargetSpan: the smallest span a degenerate target is widened to.
    /// The viewport measured along the **page's** axes.
    ///
    /// On a `/Rotate 90` or `270` sheet page x runs vertically on screen, so the page-space
    /// width the viewport can show is the view's *height*. Every function here compares page
    /// extents with view extents, and doing so without this swap chose the zoom on the wrong
    /// axis and centred an axis-swapped rect (BH-067).
    public static func pageAxes(_ viewSize: CGSize, rotation: Int) -> CGSize {
        let normalised = ((rotation % 360) + 360) % 360
        return (normalised == 90 || normalised == 270)
            ? CGSize(width: viewSize.height, height: viewSize.width)
            : viewSize
    }

    public static func fit(
        target: PDFRectValue,
        in displayViewSize: CGSize,
        rotation: Int = 0,
        minimumTargetSpan: Double = 8
    ) -> Fit? {
        let viewSize = pageAxes(displayViewSize, rotation: rotation)
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let width = max(target.size.width, minimumTargetSpan)
        let height = max(target.size.height, minimumTargetSpan)
        let centerX = target.origin.x + target.size.width / 2
        let centerY = target.origin.y + target.size.height / 2

        let paddedWidth = width * (1 + 2 * paddingRatio)
        let paddedHeight = height * (1 + 2 * paddingRatio)
        let ideal = min(Double(viewSize.width) / paddedWidth, Double(viewSize.height) / paddedHeight)
        let zoom = min(ViewportSnapshot.maximumZoom, max(ViewportSnapshot.minimumZoom, ideal))

        let visibleWidth = Double(viewSize.width) / zoom
        let visibleHeight = Double(viewSize.height) / zoom
        return Fit(
            zoom: zoom,
            visiblePageRect: PDFRectValue(
                x: centerX - visibleWidth / 2,
                y: centerY - visibleHeight / 2,
                width: visibleWidth,
                height: visibleHeight
            )
        )
    }

    /// The page rect a viewport shows when it is centred on a target **without changing zoom**.
    ///
    /// Reported 2026-08-26: searching a drawing for a sheet title found two hits, and clicking
    /// one zoomed the canvas to roughly 500 %. That is ``fit(target:in:minimumTargetSpan:)`` doing
    /// exactly what it says — a word is a few points across, and fitting a few points to a
    /// viewport is an enormous magnification. Correct for `⌘*` on a selected markup, wrong for
    /// "show me where this word is": the reader loses the drawing around it.
    ///
    /// So a search hit scrolls instead. Zoom is the reader's setting, and a search result is not
    /// a reason to take it from them.
    ///
    /// Returns `nil` for a viewport with no area or a non-positive zoom.
    public static func centred(
        target: PDFRectValue, in displayViewSize: CGSize, zoom: Double, rotation: Int = 0
    ) -> PDFRectValue? {
        let viewSize = pageAxes(displayViewSize, rotation: rotation)
        guard viewSize.width > 0, viewSize.height > 0, zoom > 0 else { return nil }
        let centerX = target.origin.x + target.size.width / 2
        let centerY = target.origin.y + target.size.height / 2
        let visibleWidth = Double(viewSize.width) / zoom
        let visibleHeight = Double(viewSize.height) / zoom
        return PDFRectValue(
            x: centerX - visibleWidth / 2,
            y: centerY - visibleHeight / 2,
            width: visibleWidth,
            height: visibleHeight
        )
    }

    /// Whether a target fits inside a viewport at a given zoom, with the usual padding.
    ///
    /// The one case where revealing a hit still has to change the zoom: a hit larger than the
    /// viewport cannot be shown by scrolling, so it is zoomed **out** to fit. Zooming out to see
    /// more is not the surprise that zooming in to 500 % is.
    public static func fits(
        target: PDFRectValue, in displayViewSize: CGSize, zoom: Double, rotation: Int = 0
    ) -> Bool {
        let viewSize = pageAxes(displayViewSize, rotation: rotation)
        guard viewSize.width > 0, viewSize.height > 0, zoom > 0 else { return false }
        let paddedWidth = max(target.size.width, 0) * (1 + 2 * paddingRatio)
        let paddedHeight = max(target.size.height, 0) * (1 + 2 * paddingRatio)
        return paddedWidth <= Double(viewSize.width) / zoom
            && paddedHeight <= Double(viewSize.height) / zoom
    }

    /// The document-view scroll origin that keeps one page point under one screen point across
    /// a zoom change — the *zoom about the pointer* invariant.
    ///
    /// - Parameters:
    ///   - anchorInDocumentAfterZoom: where the anchored page point lands in the document view
    ///     once the new transform is applied.
    ///   - anchorInClipBounds: the anchor converted into the clip view's coordinate space, as
    ///     `NSClipView.convert(_:from: nil)` returns it.
    ///   - clipBoundsOrigin: the clip view's `bounds.origin`, which **is** the current scroll
    ///     offset.
    ///
    /// The subtlety, and the bug this exists to prevent: `anchorInClipBounds` already contains
    /// `clipBoundsOrigin`, because a clip view's bounds origin moves as it scrolls. Subtracting
    /// the converted point whole therefore removes the scroll offset twice and lands the reader
    /// `clipBoundsOrigin` closer to the top-left corner than they should be. At the top-left the
    /// offset is zero and the mistake is invisible; the further the reader has scrolled, the
    /// harder every zoom drags them back to the corner.
    public static func scrollOrigin(
        anchorInDocumentAfterZoom: CGPoint,
        anchorInClipBounds: CGPoint,
        clipBoundsOrigin: CGPoint
    ) -> CGPoint {
        // Where the anchor sits inside the *visible rectangle*, independent of scroll.
        let insideVisible = CGPoint(
            x: anchorInClipBounds.x - clipBoundsOrigin.x,
            y: anchorInClipBounds.y - clipBoundsOrigin.y
        )
        return CGPoint(
            x: anchorInDocumentAfterZoom.x - insideVisible.x,
            y: anchorInDocumentAfterZoom.y - insideVisible.y
        )
    }

    /// The union of markup bounds, or `nil` when the selection is empty.
    public static func union(of rects: [PDFRectValue]) -> PDFRectValue? {
        guard let first = rects.first else { return nil }
        var minX = first.minX
        var minY = first.minY
        var maxX = first.minX + first.size.width
        var maxY = first.minY + first.size.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.minX + rect.size.width)
            maxY = max(maxY, rect.minY + rect.size.height)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
