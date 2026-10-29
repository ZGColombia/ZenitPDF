import CoreGraphics
import Foundation
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Why a viewport raster could not be planned.
///
/// Typed and closed, because gate Z8 turns on the difference between *refusing* an
/// over-budget raster and silently producing a smaller one. The old code did the second:
/// `PageRasterSource.clampedScale` lowered the scale until the page fitted 24 megapixels,
/// which above 122 % zoom on an A1 sheet meant the canvas stopped re-rendering altogether
/// and simply upscaled — x3.27 at 400 %, x6.54 at 800 %, permanently soft
/// (the defect gate Z5 exists for).
public enum ViewportRasterFault: Error, Hashable, CustomStringConvertible {
    /// The viewport and the page do not overlap in a whole device pixel.
    case emptyViewport
    /// The plan would allocate more pixels than the canvas budget allows. A viewport-sized
    /// raster only reaches this on an implausible window, which is the point: the budget
    /// stops being a sharpness cap and becomes an actual bound.
    case pixelBudgetExceeded(requestedPixels: Int, limit: Int)
    /// The zoom or backing scale is not a usable number.
    case invalidScale(Double)

    public var description: String {
        switch self {
        case .emptyViewport:
            return "the viewport does not cover a whole device pixel of the page"
        case let .pixelBudgetExceeded(pixels, limit):
            return "\(pixels) pixels requested, the canvas budget is \(limit)"
        case let .invalidScale(scale):
            return "scale \(scale) is not usable"
        }
    }
}

/// What to rasterise for one frame of the canvas, and where the result goes.
///
/// Two decisions live in this value, and they are the two the benchmark says matter most:
///
/// 1. **The region, not the page.** ``pageRegion`` is the part of the sheet the window can
///    see, plus a margin, at ``scale`` = `zoom x backingScale` — the *true* device scale, at
///    any zoom, never clamped. A viewport region costs 5.7x less cold, 21.6x less warm and
///    40x less memory than the whole page at 400 % (historical viewer benchmark), and unlike
///    the whole page it is renderable at all above 199.6 %.
/// 2. **Whole device pixels.** ``deviceRect`` has an integral origin and an integral size,
///    and ``pixelSize`` is exactly its size. Drawing the returned bitmap into ``destination``
///    is therefore a 1:1 copy rather than a resample: 1.71 ms instead of 12.81 ms for the
///    identical picture, because the old destination was 0.04 of a pixel off whole pixels
///    (historical viewer benchmark).
public struct ViewportRasterPlan: Equatable, Sendable {

    /// The page-space rectangle to rasterise: what the window shows plus the overscan margin.
    public let pageRegion: PDFRectValue
    /// The page-space rectangle the window actually shows, without the margin. A later plan
    /// whose ``visiblePageRegion`` is already inside a delivered ``pageRegion`` at the same
    /// ``scale`` needs no new raster, which is what makes a small pan free.
    public let visiblePageRegion: PDFRectValue
    /// The bitmap the rasteriser must produce, in whole device pixels.
    public let pixelSize: RenderPixelSize
    /// Device pixels per page point — `zoom x backingScale`. Never clamped (gate Z5).
    public let scale: CGFloat
    /// The backing scale the plan was made at.
    public let backingScale: CGFloat
    /// Where the bitmap goes, in the flipped page view's own coordinates.
    public let destination: CGRect
    /// ``destination`` in whole device pixels. Origin and size are integral (gate Z6).
    public let deviceRect: CGRect
    /// The bitmap's top-left corner as an offset, in device pixels, from the page's top-left
    /// corner. The content-stream renderer needs this because it draws the page itself
    /// rather than asking PDFKit for a page-space region.
    public let originInPageDevicePixels: CGPoint

    /// Pixels the plan allocates, in a wider type.
    public var pixelCount: Int { pixelSize.width * pixelSize.height }

    /// Public since the move to `ZPDFCanvasCore` (NL-PLAT-17): the memberwise initialiser the
    /// application and its tests used when the type lived in the application.
    public init(pageRegion: PDFRectValue, visiblePageRegion: PDFRectValue, pixelSize: RenderPixelSize, scale: CGFloat,
                backingScale: CGFloat, destination: CGRect, deviceRect: CGRect, originInPageDevicePixels: CGPoint) {
        self.pageRegion = pageRegion
        self.visiblePageRegion = visiblePageRegion
        self.pixelSize = pixelSize
        self.scale = scale
        self.backingScale = backingScale
        self.destination = destination
        self.deviceRect = deviceRect
        self.originInPageDevicePixels = originInPageDevicePixels
    }
}

/// Turns a page transform and a visible rectangle into a ``ViewportRasterPlan``.
///
/// Pure arithmetic, so gates Z5, Z6 and Z8 are unit tests on a struct rather than claims
/// about a window no automated run can put on screen.
public enum ViewportRasterPlanner {

    /// View points of page kept around the viewport, so a small pan reuses the raster
    /// instead of asking for a new one.
    ///
    /// 64 pt on each side is a short scroll flick and costs 22 % more pixels on the
    /// benchmark's 1600 x 1000 pt window: 3456 x 2256 instead of 3200 x 2000, which is
    /// 29.7 MiB against gate Z7's 32 MiB ceiling for one viewport raster. 128 pt would be
    /// 35.6 MiB and would break that gate, so the margin is chosen by the memory budget
    /// rather than by feel.
    public static let overscanViewPoints: CGFloat = 64

    /// Gate Z7: RGBA8 byte threshold for dropping a viewport raster's overscan margin.
    ///
    /// A plan over this threshold loses its margin — a pan then costs a render, which is
    /// slower but still sharp. The bare viewport is not checked against this byte threshold;
    /// `pixelBudget` is the refusal threshold, including after the margin is removed.
    /// Sharpness is never traded away to fit either budget.
    public static let maximumViewportRasterBytes: Int = 32 * 1024 * 1024

    /// The canvas raster budget, in pixels.
    ///
    /// Unchanged from the 24 megapixels the canvas has always carried, and deliberately so:
    /// gate Z8 keeps the number and changes what it does. It used to lower the scale; it now
    /// refuses. Because a viewport raster is bounded by the window rather than by the sheet,
    /// 24 MP is a 4900 x 4900 device-pixel window — larger than any display Apple ships —
    /// so in practice it never fires, which is exactly the difference between a bound and a
    /// cap.
    public static let maximumRasterPixels: Int = 24_000_000

    /// Plans the raster for one frame.
    ///
    /// - Parameters:
    ///   - transform: the page-to-view mapping the canvas is laid out with.
    ///   - visibleViewRect: the visible rectangle of the page view, in its own coordinates.
    ///   - backingScale: device pixels per view point.
    ///   - overscanViewPoints: margin kept around the viewport.
    ///   - pixelBudget: the refusal threshold.
    public static func plan(
        transform: PageDisplayTransform,
        visibleViewRect: CGRect,
        backingScale: CGFloat,
        overscanViewPoints: CGFloat = ViewportRasterPlanner.overscanViewPoints,
        pixelBudget: Int = ViewportRasterPlanner.maximumRasterPixels,
        byteCeiling: Int = ViewportRasterPlanner.maximumViewportRasterBytes
    ) throws -> ViewportRasterPlan {
        do {
            let planned = try planExactly(
                transform: transform,
                visibleViewRect: visibleViewRect,
                backingScale: backingScale,
                overscanViewPoints: overscanViewPoints,
                pixelBudget: pixelBudget
            )
            guard overscanViewPoints > 0, planned.pixelCount * 4 > byteCeiling else { return planned }
        } catch ViewportRasterFault.pixelBudgetExceeded where overscanViewPoints > 0 {
            // The stated order is "lose the margin first, refuse only a bare viewport". The
            // pixel budget used to skip that step: a 6K full-screen canvas whose bare
            // viewport fits was refused because its overscan did not (BH-351).
        }
        // Over the pixel budget or Z7 byte threshold: give up the margin, keep the scale.
        return try planExactly(
            transform: transform,
            visibleViewRect: visibleViewRect,
            backingScale: backingScale,
            overscanViewPoints: 0,
            pixelBudget: pixelBudget
        )
    }

    private static func planExactly(
        transform: PageDisplayTransform,
        visibleViewRect: CGRect,
        backingScale: CGFloat,
        overscanViewPoints: CGFloat,
        pixelBudget: Int
    ) throws -> ViewportRasterPlan {
        guard backingScale.isFinite, backingScale > 0 else {
            throw ViewportRasterFault.invalidScale(Double(backingScale))
        }
        guard transform.zoom.isFinite, transform.zoom > 0 else {
            throw ViewportRasterFault.invalidScale(Double(transform.zoom))
        }
        guard visibleViewRect.width > 0, visibleViewRect.height > 0 else {
            throw ViewportRasterFault.emptyViewport
        }

        let pageFrame = transform.pageFrame
        let wanted = visibleViewRect
            .insetBy(dx: -max(0, overscanViewPoints), dy: -max(0, overscanViewPoints))
            .intersection(pageFrame)
        guard !wanted.isNull, wanted.width > 0, wanted.height > 0 else {
            throw ViewportRasterFault.emptyViewport
        }

        // From here on the arithmetic is in device pixels, because that is the only space in
        // which "whole pixel" means anything.
        let devicePage = scaled(pageFrame, by: backingScale)
        let deviceWanted = scaled(wanted, by: backingScale)

        // Outward to whole pixels so no visible pixel is left uncovered, then *inward* to the
        // page. The inward snap matters at the sheet's own edge, where the page rectangle is
        // fractional — an A1 at fit-to-window is 2832.04 device pixels wide. Snapping outward
        // there would put the bitmap's first column half a pixel outside the page and
        // reintroduce exactly the 0.04-pixel misalignment this plan exists to remove. The
        // cost is at most one device pixel of paper at each border, under the white page fill
        // the canvas draws first, so nothing the estimator can see.
        let deviceRect = insetToIntegral(deviceWanted.integral.intersection(devicePage))
        guard deviceRect.width >= 1, deviceRect.height >= 1 else {
            throw ViewportRasterFault.emptyViewport
        }

        let pixelSize = RenderPixelSize(
            width: Int(deviceRect.width.rounded()),
            height: Int(deviceRect.height.rounded())
        )
        let pixels = pixelSize.width.multipliedReportingOverflow(by: pixelSize.height)
        guard !pixels.overflow, pixels.partialValue <= pixelBudget else {
            throw ViewportRasterFault.pixelBudgetExceeded(
                requestedPixels: pixels.overflow ? Int.max : pixels.partialValue,
                limit: pixelBudget
            )
        }

        let destination = CGRect(
            x: deviceRect.minX / backingScale,
            y: deviceRect.minY / backingScale,
            width: deviceRect.width / backingScale,
            height: deviceRect.height / backingScale
        )
        // What *any* plan can deliver of the visible area: the snapped destination clips the
        // sub-pixel sliver at a sheet edge (the inward snap above), so requiring that sliver
        // made `satisfies` fail for an identical plan whenever a page edge was on screen — the
        // default fit-to-window state — and the canvas re-rasterised on every pointer move
        // (BH-065).
        let visibleDestination = visibleViewRect.intersection(destination)

        return ViewportRasterPlan(
            pageRegion: transform.pageRect(covering: destination),
            visiblePageRegion: visibleDestination.isNull
                ? transform.pageRect(covering: destination)
                : transform.pageRect(covering: visibleDestination),
            pixelSize: pixelSize,
            scale: transform.zoom * backingScale,
            backingScale: backingScale,
            destination: destination,
            deviceRect: deviceRect,
            originInPageDevicePixels: CGPoint(
                x: deviceRect.minX - devicePage.minX,
                y: deviceRect.minY - devicePage.minY
            )
        )
    }

    /// Whether a delivered plan still covers what a new plan needs.
    ///
    /// Scale equality is exact on purpose. Any zoom change changes the sharpness of every
    /// pixel, and gate Z5 says the settled magnification is 1.00 at *every* zoom; a
    /// tolerance band here would be the 5 % band that helped hide the 24 MP cap.
    public static func satisfies(_ delivered: ViewportRasterPlan, _ wanted: ViewportRasterPlan) -> Bool {
        guard delivered.scale == wanted.scale, delivered.backingScale == wanted.backingScale else {
            return false
        }
        return contains(delivered.pageRegion, wanted.visiblePageRegion)
    }

    /// Rectangle containment in page points, with a tolerance of a thousandth of a point so
    /// the float round trip through view space cannot report a false miss.
    public static func contains(_ outer: PDFRectValue, _ inner: PDFRectValue) -> Bool {
        let epsilon = 1e-3
        return inner.minX >= outer.minX - epsilon
            && inner.minY >= outer.minY - epsilon
            && inner.maxX <= outer.maxX + epsilon
            && inner.maxY <= outer.maxY + epsilon
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * factor,
            y: rect.minY * factor,
            width: rect.width * factor,
            height: rect.height * factor
        )
    }

    /// The largest rectangle with integral edges *inside* `rect`.
    private static func insetToIntegral(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite else { return .zero }
        let minX = rect.minX.rounded(.up)
        let minY = rect.minY.rounded(.up)
        let maxX = rect.maxX.rounded(.down)
        let maxY = rect.maxY.rounded(.down)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
