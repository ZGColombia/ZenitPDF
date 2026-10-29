import CoreGraphics
import Foundation
import PDFKit

extension PDFKitDocumentProvider {

    // MARK: - Region rendering

    public func renderPageRegion(_ request: PageRenderRequest) async throws -> RenderedPageImage {
        try checkCancellation()
        let open = try unlockedEntry(request.document)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: request.pageIndex)
        let limits = open.limits

        guard request.scale.isFinite, request.scale > 0, request.scale <= 1000 else {
            throw PDFBridgeError.invalidScale(Double(request.scale))
        }

        let displayBox = Self.displayBox(for: request.box)
        let boxRect = page.bounds(for: displayBox)
        guard boxRect.width > 0, boxRect.height > 0 else { throw PDFBridgeError.emptyRenderRegion }

        let requested = request.region ?? boxRect
        let clamped = requested.intersection(boxRect)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            throw PDFBridgeError.emptyRenderRegion
        }

        // The sheet's own `/Rotate`, and on top of it the view rotation a person chose
        // (NL-DOCS-07): the bitmap is in the display space of both.
        let ownRotation = PageRotationMath.normalised(page.rotation)
        let rotation = PageRotationMath.normalised(ownRotation + request.viewRotation)
        let displayRegion = PageDisplayGeometry.displayRect(
            forPageRect: clamped,
            box: boxRect,
            rotation: rotation
        )
        // PDFKit draws in the display space of the page's own rotation; this maps that space
        // into the turned one. `nil` when the view is not turned.
        let turn: CGAffineTransform? = rotation == ownRotation ? nil
            : PageDisplayGeometry.pageToDisplay(box: boxRect, rotation: ownRotation).inverted()
                .concatenating(PageDisplayGeometry.pageToDisplay(box: boxRect, rotation: rotation))

        // `ceil` is right for an export and wrong for a canvas: see
        // `PageRenderRequest.exactPixelSize`. When the caller pins the bitmap we honour it
        // exactly, and the budget below still applies -- a pinned size is a request, not a
        // waiver.
        let pixelWidth: Int
        let pixelHeight: Int
        if let exact = request.exactPixelSize {
            pixelWidth = exact.width
            pixelHeight = exact.height
        } else {
            // Converted through a guard: a hostile `/MediaBox [0 0 1e23 792]` reaches here
            // intact, and `Int(1e23)` is a trap, not a thrown error (BH-172).
            // `RenderPixelSize.renderedDimension` is this rule, shared with the callers that
            // plan a render inside a budget (T-069).
            let scale = Double(request.scale)
            guard let width = Self.pixelDimension(CGFloat(RenderPixelSize.renderedDimension(Double(displayRegion.width), scale: scale))),
                  let height = Self.pixelDimension(CGFloat(RenderPixelSize.renderedDimension(Double(displayRegion.height), scale: scale)))
            else {
                throw PDFBridgeError.pixelBudgetExceeded(
                    requestedPixels: Int.max, limit: limits.maximumRenderPixels
                )
            }
            pixelWidth = width
            pixelHeight = height
        }
        guard pixelWidth > 0, pixelHeight > 0 else { throw PDFBridgeError.emptyRenderRegion }
        // Multiplied in a wider type first: a hostile scale must not overflow into a
        // small, allocatable-looking number.
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumRenderPixels else {
            throw PDFBridgeError.pixelBudgetExceeded(
                requestedPixels: pixels.overflow ? Int.max : pixels.partialValue,
                limit: limits.maximumRenderPixels
            )
        }

        try checkCancellation()
        let image = try Self.rasterise(
            page: page,
            displayBox: displayBox,
            displayRegion: displayRegion,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: request.scale,
            opaqueBackground: request.opaqueBackground,
            turn: turn
        )
        try checkCancellation()

        return RenderedPageImage(
            image: image,
            pageIndex: request.pageIndex,
            renderedRegion: clamped,
            box: request.box,
            scale: request.scale,
            rotation: rotation
        )
    }

    // MARK: - Thumbnails

    public func thumbnail(_ request: ThumbnailRequest) async throws -> ThumbnailResult {
        try checkCancellation()
        let open = try unlockedEntry(request.document)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: request.pageIndex)
        let limits = open.limits

        let edge = max(1, min(request.maximumPixelSize, limits.maximumThumbnailEdge))
        let displayBox = Self.displayBox(for: request.box)
        let boxRect = page.bounds(for: displayBox)
        guard boxRect.width > 0, boxRect.height > 0 else { throw PDFBridgeError.emptyRenderRegion }

        let rotation = PageRotationMath.normalised(page.rotation)
        let displaySize = PageDisplayGeometry.displaySize(of: boxRect.size, rotation: rotation)
        let fit = min(CGFloat(edge) / displaySize.width, CGFloat(edge) / displaySize.height)
        // An infinite box made `fit` zero and `inf * 0` NaN, and `Int(NaN)` traps inside the
        // `max(1, …)` that was meant to clamp it (BH-572).
        guard fit.isFinite, fit > 0,
              let fittedWidth = Self.pixelDimension((displaySize.width * fit).rounded()),
              let fittedHeight = Self.pixelDimension((displaySize.height * fit).rounded())
        else { throw PDFBridgeError.emptyRenderRegion }
        let pixelWidth = max(1, fittedWidth)
        let pixelHeight = max(1, fittedHeight)

        let key = ThumbnailCache.Key(
            documentSHA256: open.digest.sha256,
            pageIndex: request.pageIndex,
            box: request.box,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayState: open.annotationDisplayState
        )

        if let cached = withThumbnailCache({ $0.value(for: key) }) {
            return ThumbnailResult(
                image: cached,
                pageIndex: request.pageIndex,
                wasCacheHit: true,
                key: key
            )
        }

        // The disk tier, when there is one: a drawing opened again is answered from the
        // images its last session wrote, keyed by the same digest (IM-073).
        if let disk = thumbnailDiskCache, let stored = disk.load(key) {
            withThumbnailCache { $0.insert(stored, for: key) }
            noteThumbnailDiskHit()
            return ThumbnailResult(image: stored, pageIndex: request.pageIndex, wasCacheHit: true, key: key)
        }

        let pixels = pixelWidth * pixelHeight
        guard pixels <= limits.maximumRenderPixels else {
            throw PDFBridgeError.pixelBudgetExceeded(requestedPixels: pixels, limit: limits.maximumRenderPixels)
        }

        try checkCancellation()
        let image = try Self.rasterise(
            page: page,
            displayBox: displayBox,
            displayRegion: CGRect(origin: .zero, size: displaySize),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: fit,
            opaqueBackground: true
        )
        noteThumbnailRendered()
        withThumbnailCache { $0.insert(image, for: key) }
        scheduleThumbnailDiskWrite(image, for: key)
        return ThumbnailResult(image: image, pageIndex: request.pageIndex, wasCacheHit: false, key: key)
    }

    /// Writes a rendered thumbnail to the disk tier off the actor, at utility priority, so the
    /// PNG encode never competes with the canvas's own renders on this actor.
    private func scheduleThumbnailDiskWrite(_ image: CGImage, for key: ThumbnailCache.Key) {
        guard let disk = thumbnailDiskCache, disk.fileURL(for: key) != nil else { return }
        let trims = thumbnailDiskWritesSinceTrim >= 64
        thumbnailDiskWritesSinceTrim = trims ? 0 : thumbnailDiskWritesSinceTrim + 1
        // Every write stays listed until it has finished and removes itself: the list used to be
        // truncated at 256 by dropping the oldest handles, running or not, so the wait below
        // could return while those writes were still in flight (R-117).
        let ticket = nextThumbnailDiskWriteTicket
        nextThumbnailDiskWriteTicket &+= 1
        let gate = thumbnailDiskWriteGate
        pendingThumbnailDiskWrites[ticket] = Task.detached(priority: .utility) { [weak self] in
            if let gate { await gate() }
            disk.store(image, for: key)
            if trims { disk.trim() }
            await self?.thumbnailDiskWriteFinished(ticket)
        }
    }

    private func thumbnailDiskWriteFinished(_ ticket: UInt64) {
        pendingThumbnailDiskWrites.removeValue(forKey: ticket)
    }

    /// Test seam: every disk write started from now on awaits `gate` before it stores.
    func setThumbnailDiskWriteGate(_ gate: (@Sendable () async -> Void)?) {
        thumbnailDiskWriteGate = gate
    }

    /// Waits until every thumbnail disk write started so far has finished.
    public func waitForThumbnailDiskWrites() async {
        for task in Array(pendingThumbnailDiskWrites.values) { await task.value }
    }

    public func thumbnailCacheStatistics() async -> ThumbnailCacheStatistics {
        withThumbnailCache { $0.statistics }
    }

    public func clearThumbnailCache() async {
        withThumbnailCache { $0.removeAll() }
    }

    /// `value` as a pixel count, or `nil` when it is not a finite, non-negative number a
    /// bitmap could ever have on one edge. Converting first and checking afterwards is not an
    /// option: `Int(_:)` traps on NaN, on infinity and on anything past `Int.max`.
    static func pixelDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value >= 0, value <= CGFloat(Int32.max) else { return nil }
        return Int(value)
    }

    // MARK: - Rasterisation

    /// Draws into a fresh bitmap.
    ///
    /// `displayRegion` is in *display* space: the space `PDFPage.draw(with:to:)` renders
    /// into, whose origin is the box's lower-left corner and whose axes have already had
    /// `/Rotate` applied by PDFKit.
    private static func rasterise(
        page: PDFPage,
        displayBox: PDFDisplayBox,
        displayRegion: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: CGFloat,
        opaqueBackground: Bool,
        turn: CGAffineTransform? = nil
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw PDFBridgeError.renderFailed(reason: "no bitmap context for \(pixelWidth)x\(pixelHeight)")
        }

        if opaqueBackground {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -displayRegion.minX, y: -displayRegion.minY)
        context.clip(to: displayRegion)
        if let turn { context.concatenate(turn) }
        // Drawing walks the content stream through PDFKit, which raises rather than
        // returning on some malformed pages.
        try EngineBarrier.guarded("draw") { page.draw(with: displayBox, to: context) }

        guard let image = context.makeImage() else {
            throw PDFBridgeError.renderFailed(reason: "context produced no image")
        }
        return image
    }
}

/// Mapping page space to the space PDFKit actually draws into.
///
/// `PDFPage.draw(with:to:)` puts the box's lower-left corner at the context origin and
/// applies `/Rotate` itself. A 90 or 270 degree page therefore draws into a transposed
/// rectangle, and a caller that hands us a region in honest page coordinates needs it
/// mapped. The four cases are exact: no floating-point rotation is involved.
public enum PageDisplayGeometry {

    /// The size the page occupies on screen once `/Rotate` is applied.
    public static func displaySize(of boxSize: CGSize, rotation: Int) -> CGSize {
        let normalised = PageRotationMath.normalised(rotation)
        return (normalised == 90 || normalised == 270)
            ? CGSize(width: boxSize.height, height: boxSize.width)
            : boxSize
    }

    /// Page space to display space for a rotation, as an affine map: the same four exact cases
    /// as ``displayRect(forPageRect:box:rotation:)`` (display space y-up, origin bottom-left).
    public static func pageToDisplay(box: CGRect, rotation: Int) -> CGAffineTransform {
        let width = box.width, height = box.height
        switch PageRotationMath.normalised(rotation) {
        case 90:  // (u, v) -> (v, width - u)
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: width + box.minX)
        case 180: // (u, v) -> (width - u, height - v)
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width + box.minX, ty: height + box.minY)
        case 270: // (u, v) -> (height - v, u)
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height + box.minY, ty: -box.minX)
        default:
            return CGAffineTransform(translationX: -box.minX, y: -box.minY)
        }
    }

    /// Page space onto `rect`: ``pageToDisplay(box:rotation:)``, then stretched onto the
    /// rectangle with independent x and y scales. The one mapping the flattened underlay, the
    /// burned-in annotation appearances and the markups on them share, so the drawing and the ink
    /// cannot land in different places (R-112). `nil` for a degenerate box or rectangle.
    public static func pageToRect(box: CGRect, rotation: Int, rect: CGRect) -> CGAffineTransform? {
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite,
              rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite
        else { return nil }
        let sheet = displaySize(of: box.size, rotation: rotation)
        return pageToDisplay(box: box, rotation: rotation)
            .concatenating(CGAffineTransform(scaleX: rect.width / sheet.width, y: rect.height / sheet.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Maps a rectangle given in page space into display space.
    ///
    /// - Parameters:
    ///   - pageRect: a rectangle in the box's own coordinates, negative origins included.
    ///   - box: the page box, in page coordinates.
    ///   - rotation: the page's `/Rotate`.
    public static func displayRect(forPageRect pageRect: CGRect, box: CGRect, rotation: Int) -> CGRect {
        let normalised = PageRotationMath.normalised(rotation)
        let u0 = pageRect.minX - box.minX
        let v0 = pageRect.minY - box.minY
        let u1 = pageRect.maxX - box.minX
        let v1 = pageRect.maxY - box.minY
        let width = box.width
        let height = box.height

        switch normalised {
        case 90:
            // (u, v) -> (v, width - u)
            return CGRect(
                x: v0,
                y: width - u1,
                width: v1 - v0,
                height: u1 - u0
            )
        case 180:
            return CGRect(
                x: width - u1,
                y: height - v1,
                width: u1 - u0,
                height: v1 - v0
            )
        case 270:
            // (u, v) -> (height - v, u)
            return CGRect(
                x: height - v1,
                y: u0,
                width: v1 - v0,
                height: u1 - u0
            )
        default:
            return CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0)
        }
    }
}
