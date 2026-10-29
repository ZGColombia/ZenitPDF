import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFPDFKitBridge

/// The one object in the application that holds an open PDF.
///
/// It is an `actor` around `PDFKitDocumentProvider`, which is itself an actor: the extra layer
/// exists so the rest of the application never sees a `DocumentHandle`, and therefore cannot
/// render from a document it has already closed. Closing goes through ``close()``, after which
/// every request fails with a typed error instead of a stale handle.
///
/// Nothing here constructs a `PDFView`. That is the structural reason the no-active-content rule holds:
/// `PDFView` is the PDFKit object that follows links, runs `/OpenAction` and opens embedded files,
/// and it is absent from the whole product. Pages reach the screen as `CGImage`.
public actor PageRasterSource {

    /// Above this a **whole-page** raster is refused. It is not clamped (gate Z8).
    ///
    /// This number used to lower the scale instead, and that is the defect that showed as
    /// lag. On an A1 sheet 24 megapixels allows at most 2.445 device
    /// pixels per page point, so above 122 % zoom the canvas stopped producing a new raster
    /// and upscaled the old one: x1.64 at 200 %, x3.27 at 400 %, x6.54 at 800 %, permanently
    /// soft, with no error and nothing on screen to say so (the defect gate Z5 exists for).
    ///
    /// The canvas no longer asks for whole pages at all — it asks for the viewport region
    /// through ``renderViewport(pageIndex:plan:)``, whose cost is bounded by the window and
    /// not by the sheet. What remains here is print and export, where a whole page really is
    /// wanted, and where an over-budget request must come back as
    /// ``PDFBridgeError/pixelBudgetExceeded(requestedPixels:limit:)`` rather than as a
    /// quietly blurry sheet.
    static let maximumRasterPixels: Int = 24_000_000

    private let provider: PDFKitDocumentProvider
    private var handle: DocumentHandle?

    /// The SHA-256 of the file, for the manifest and the thumbnail cache.
    public let digest: FileDigest
    /// Number of pages the document declares.
    public let pageCount: Int
    /// The document's encryption state as opened: `.locked` means PDFKit "opened" it
    /// without its password — page geometry exists, every page renders blank — which is
    /// LT-38's silent white sheet unless the caller asks for the password and reopens.
    public let encryption: EncryptionState

    /// Whether the drawing is still locked behind its password.
    public var isLocked: Bool { encryption == .locked }

    private init(
        provider: PDFKitDocumentProvider,
        handle: DocumentHandle,
        digest: FileDigest,
        pageCount: Int,
        encryption: EncryptionState
    ) {
        self.provider = provider
        self.handle = handle
        self.digest = digest
        self.pageCount = pageCount
        self.encryption = encryption
    }

    /// Opens a PDF and reads its page geometry.
    ///
    /// - Parameter password: the password for an encrypted drawing, when the person has
    ///   given one. `nil` opens an encrypted drawing in its locked state, which the caller
    ///   must check through ``isLocked`` — PDFKit does not refuse the open on its own.
    /// - Throws: `PDFBridgeError.incorrectPassword` when a password was given and refused.
    /// - Returns: the raster source and the page descriptors PDFKit read out of the file.
    public static func open(
        url: URL,
        limits: DocumentLimits = .standard,
        password: String? = nil,
        knownDigest: FileDigest? = nil
    ) async throws -> (source: PageRasterSource, pages: [PDFPageDescriptor]) {
        // Thumbnails survive a reopen on disk (IM-073); only the
        // assembled app writes that cache, so a test process never fills the user's Caches.
        let provider = PDFKitDocumentProvider(
            thumbnailCacheCapacity: 256,
            thumbnailDiskCache: thumbnailDiskCache
        )
        // A digest already verified in this process is not hashed again (IM-005).
        let opened = try await provider.open(
            .url(url), password: password, limits: limits, knownDigest: knownDigest
        )
        let pages = try await provider.pageDescriptors(of: opened.handle, range: nil)
        let source = PageRasterSource(
            provider: provider,
            handle: opened.handle,
            digest: opened.descriptor.digest,
            pageCount: opened.descriptor.pageCount,
            encryption: opened.descriptor.encryption
        )
        return (source, pages)
    }

    /// The on-disk thumbnail tier, in the app's own Caches folder; `nil` outside the bundle.
    nonisolated static var thumbnailDiskCache: ThumbnailDiskCache? {
        guard Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return ThumbnailDiskCache(directory: caches.appendingPathComponent("Thumbnails", isDirectory: true))
    }

    /// Pixels a whole-page raster of this page at this scale would allocate.
    ///
    /// Saturating rather than overflowing: a hostile scale must produce a refusal, not a
    /// small allocatable-looking number.
    public static func wholePagePixelCount(displaySize: CGSize, scale: CGFloat) -> Int {
        guard displaySize.width > 0, displaySize.height > 0, scale.isFinite, scale > 0 else { return 0 }
        let width = (Double(displaySize.width) * Double(scale)).rounded(.up)
        let height = (Double(displaySize.height) * Double(scale)).rounded(.up)
        let pixels = width * height
        guard pixels.isFinite, pixels < Double(Int.max) else { return Int.max }
        return Int(pixels)
    }

    /// Whether a whole-page raster at this scale is inside the canvas budget.
    public static func allowsWholePageRaster(displaySize: CGSize, scale: CGFloat) -> Bool {
        let pixels = wholePagePixelCount(displaySize: displaySize, scale: scale)
        return pixels > 0 && pixels <= maximumRasterPixels
    }

    /// Rasterises a whole page at a scale.
    ///
    /// - Throws: ``PDFBridgeError/pixelBudgetExceeded(requestedPixels:limit:)`` when the
    ///   request is over budget. It is never quietly satisfied at a lower scale — gate Z8.
    public func render(pageIndex: Int, displaySize: CGSize, requestedScale: CGFloat) async throws -> CGImage {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        let pixels = Self.wholePagePixelCount(displaySize: displaySize, scale: requestedScale)
        guard pixels > 0 else { throw PDFBridgeError.emptyRenderRegion }
        guard pixels <= Self.maximumRasterPixels else {
            throw PDFBridgeError.pixelBudgetExceeded(
                requestedPixels: pixels,
                limit: Self.maximumRasterPixels
            )
        }
        let request = PageRenderRequest(
            document: handle,
            pageIndex: pageIndex,
            box: .crop,
            region: nil,
            scale: requestedScale,
            opaqueBackground: true
        )
        return try await provider.renderPageRegion(request).image
    }

    /// Rasterises the part of a page the window can see, at the true device scale.
    ///
    /// This is the canvas path, and the one that fixes the sharpness ceiling: the scale in a
    /// ``ViewportRasterPlan`` is `zoom x backingScale` with no cap anywhere in it, because
    /// the pixel count is bounded by the window rather than by the sheet. On an A1 sheet
    /// at 400 % that is 3200 x 2000 pixels and 24 MB instead of 19072 x 13471 pixels and
    /// 980 MB — a request the whole-page path is required to refuse and this one satisfies
    /// in 6.2 ms warm (a historical viewer-benchmark measurement).
    ///
    /// The bitmap comes back at exactly ``ViewportRasterPlan/pixelSize``, so the canvas can
    /// blit it 1:1 onto whole device pixels (gates Z5 and Z6).
    public func renderViewport(pageIndex: Int, plan: ViewportRasterPlan, viewRotation: Int = 0) async throws -> CGImage {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        var request = PageRenderRequest(
            document: handle,
            pageIndex: pageIndex,
            box: .crop,
            region: plan.pageRegion.cgRect,
            scale: plan.scale,
            opaqueBackground: true,
            exactPixelSize: plan.pixelSize
        )
        // A sheet turned on screen (NL-DOCS-07) comes back turned.
        request.viewRotation = viewRotation
        return try await provider.renderPageRegion(request).image
    }

    /// Rasterises an arbitrary **page-space** region at a given number of output pixels per
    /// page point — the drawing under an ADR-0006 snippet.
    ///
    /// Neither of the two paths above fits. ``render(pageIndex:displaySize:requestedScale:)``
    /// takes whole pages, and ``renderViewport(pageIndex:plan:)`` takes a
    /// ``ViewportRasterPlan``, which is a *window*: it carries the visible rectangle and the
    /// backing scale, and a snippet has neither. Handing a snippet a viewport would be the one
    /// thing ADR-0006 §1 forbids — the region would come from what happened to be on screen.
    ///
    /// The budget is the bridge's own: an over-large request comes back as
    /// ``ZPDFPDFKitBridge/PDFBridgeError/pixelBudgetExceeded(requestedPixels:limit:)`` rather
    /// than as a quietly downscaled picture. `SnippetExporter` refuses earlier still, on the
    /// arithmetic, before anything is allocated.
    ///
    /// `viewRotation` turns the picture on top of the page's `/Rotate`, as
    /// ``renderViewport(pageIndex:plan:viewRotation:)`` does: a Split Canvas pane shows a sheet
    /// turned in the view (NL-DOCS-07) the way the canvas does (T-003). A snippet keeps the
    /// default, 0.
    public func renderRegion(
        pageIndex: Int,
        region: PDFRect,
        pixelsPerPoint: Double,
        viewRotation: Int = 0
    ) async throws -> CGImage {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        let box = region.standardized
        guard box.width > 0, box.height > 0, pixelsPerPoint.isFinite, pixelsPerPoint > 0 else {
            throw PDFBridgeError.emptyRenderRegion
        }
        var request = PageRenderRequest(
            document: handle,
            pageIndex: pageIndex,
            box: .crop,
            region: CGRect(
                x: box.origin.x,
                y: box.origin.y,
                width: box.size.width,
                height: box.size.height
            ),
            scale: CGFloat(pixelsPerPoint),
            opaqueBackground: true
        )
        request.viewRotation = viewRotation
        return try await provider.renderPageRegion(request).image
    }

    /// A cached page thumbnail for the Navigator.
    public func thumbnail(pageIndex: Int, maximumPixelSize: Int) async throws -> CGImage {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        let request = ThumbnailRequest(
            document: handle,
            pageIndex: pageIndex,
            box: .crop,
            maximumPixelSize: maximumPixelSize
        )
        return try await provider.thumbnail(request).image
    }

    /// The document's optional-content layer catalogue, or `nil` when the drawing
    /// declares no `/OCProperties`. Read through the engine barrier (gap 10).
    /// Every annotation→layer binding in the drawing. Read once per document; the bindings are
    /// indices and cannot go stale while the file is open read-only.
    public func annotationLayerBindings() async throws -> [AnnotationLayerBindingReader.Binding] {
        guard let handle else { return [] }
        return try await provider.annotationLayerBindings(of: handle)
    }

    /// The bindings and whether the walk was cut short by its budget or a cancellation — a
    /// truncated list looks exactly like a complete one (BH-177).
    public func annotationLayerBindingReport() async throws -> AnnotationLayerBindingReader.Report {
        guard let handle else { return AnnotationLayerBindingReader.Report(bindings: [], wasTruncated: false) }
        return try await provider.annotationLayerBindingReport(of: handle)
    }

    /// Applies layer visibility to the bound annotations, on the rendering document.
    /// Returns how many annotations changed state. See the provider's documentation.
    @discardableResult
    public func applyAnnotationLayerVisibility(
        bindings: [AnnotationLayerBindingReader.Binding],
        hiddenLayerIDs: Set<PDFLayerID>
    ) async throws -> Int {
        guard let handle else { return 0 }
        return try await provider.applyAnnotationLayerVisibility(
            of: handle,
            bindings: bindings,
            hiddenLayerIDs: hiddenLayerIDs
        )
    }

    /// How many annotations the drawing itself carries, across every page (capped).
    ///
    /// The flatten and print paths replay the page's content stream, which never draws
    /// annotation appearances; until they can, an export must *say* that the drawing's own
    /// annotations are not on it (BH-079).
    public func drawingAnnotationCount(cap: Int = 10_000) async -> Int {
        guard let handle else { return 0 }
        var total = 0
        for index in 0..<pageCount {
            total += (try? await provider.annotations(of: handle, pageIndex: index).count) ?? 0
            if total >= cap { return cap }
        }
        return total
    }

    /// The embedded text of one page, through the engine barrier.
    ///
    /// Vector drawings carry their title block as real text, so the scale notation is readable
    /// without OCR — which is what the scale proposal reads on open.
    public func pageText(pageIndex: Int) async throws -> PageText {
        guard let handle else { throw PDFBridgeError.renderFailed(reason: "source closed") }
        return try await provider.pageText(of: handle, pageIndex: pageIndex)
    }

    /// The page's embedded text as positioned lines, for the dimension check (feature 13).
    public func pageTextLines(pageIndex: Int) async throws -> [PageTextLine] {
        guard let handle else { throw PDFBridgeError.renderFailed(reason: "source closed") }
        return try await provider.pageTextLines(of: handle, pageIndex: pageIndex)
    }

    /// The drawing's own link annotations on one page, as values (NL-DOCS-09). Read through
    /// the engine barrier; an action is described, never executed.
    public func links(pageIndex: Int) async throws -> [DrawingLink] {
        guard let handle else { throw PDFBridgeError.renderFailed(reason: "source closed") }
        return try await provider.annotations(of: handle, pageIndex: pageIndex).compactMap(DrawingLink.init(annotation:))
    }

    /// The drawing's bookmarks through the bridge's bounded, cycle-safe reader, with each
    /// destination's left/top (NL-DOCS-06).
    public func outline() async -> DocumentOutline? {
        guard let handle else { return nil }
        return try? await provider.outline(of: handle)
    }

    /// The zero-based page a named destination points at, or `nil`.
    public func namedDestinationPage(_ name: String) async -> Int? {
        guard let handle, let named = try? await provider.namedDestinations(of: handle) else { return nil }
        return named.first { $0.name == name }?.target.pageIndex
    }

    public func layerTree() async throws -> PDFLayerTree? {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        return try await provider.layerTree(of: handle)
    }

    /// Writes the editable annotated export shape: the drawing, with Zenit's markups
    /// added as **PDF annotations**, into a new file.
    ///
    /// # Why this method is on this actor
    ///
    /// The write needs the open `DocumentHandle`, and the whole point of this actor is that no
    /// other object in the application ever holds one — the comment at the top of the file is
    /// the reason, and a PDF export is not a reason to make an exception. So the handle stays
    /// here and the operation comes to it.
    ///
    /// # What the bridge guarantees, and what the receipt proves
    ///
    /// The annotations are added to a *pristine* `PDFDocument` reopened from the original bytes,
    /// and `DocumentDestination` is refused outright if it resolves to the source or to any other
    /// file the provider has open. The returned ``DocumentWriteReceipt`` carries the source's
    /// SHA-256 taken immediately before and immediately after the write, so
    /// ``DocumentWriteReceipt/sourceIsUnchanged`` is a measurement rather than a promise — which
    /// is exactly the assertion the flatten path makes for the other two shapes.
    public func writeAnnotations(
        _ request: AnnotationWriteRequest,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        guard let handle else { throw PDFBridgeError.unsupported("the document is closed") }
        return try await provider.writeAnnotations(request, of: handle, to: destination)
    }

    /// Closes the document. Idempotent.
    public func close() async {
        guard let handle else { return }
        self.handle = nil
        await provider.close(handle)
    }
}
