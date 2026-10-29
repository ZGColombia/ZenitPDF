import CoreGraphics
import Foundation

/// Everything Zenit PDF is allowed to ask a PDF engine for.
///
/// This is the only PDF-shaped surface the rest of the app sees. `ZPDFPDFKitBridge` ships
/// one implementation, ``PDFKitDocumentProvider``, and a fake for tests; a PDFium- or
/// qpdf-backed implementation can be added later and dropped in without a call-site edit,
/// which is the whole reason PDFKit is behind a protocol rather than used directly.
/// PDFKit itself parses every drawing inside the application process, also when the
/// geometry and repair XPC services are present; only vector extraction, DXF conversion,
/// revision comparison and qpdf work run in those services. The full table of parsers and
/// the process each runs in is "Parsing and input surfaces" in
/// `Docs/Execution/FINAL_SECURITY_REPORT.md`.
///
/// ### Rules every implementation must keep
///
/// 1. **The source is never mutated.** There is no method that writes into an open
///    document. Everything that produces a changed document writes a new file to a
///    ``DocumentDestination`` and returns a ``DocumentWriteReceipt`` carrying the source's
///    SHA-256 from before and after the write.
/// 2. **Nothing is executed.** JavaScript, launch actions, open actions, remote
///    destinations and embedded files are reported as data and never acted on.
/// 3. **Every long operation is cancellable** and honours `Task.isCancelled` by throwing
///    ``PDFBridgeError/cancelled``.
/// 4. **Every loop and allocation is bounded** by the ``DocumentLimits`` passed in.
/// 5. **Page index and page label are different things** and are never conflated.
public protocol PDFDocumentProviding: Sendable {

    // MARK: - Opening

    /// Opens a document and reports everything knowable about it without reading a page's
    /// content: page count, boxes and rotation are available separately through
    /// ``pageDescriptors(of:range:)``.
    ///
    /// An encrypted document opens successfully with
    /// ``EncryptionState/locked``; supply `password`, or call ``unlock(_:password:)``
    /// afterwards. Content APIs throw ``PDFBridgeError/documentLocked`` until then.
    func open(
        _ source: DocumentSource,
        password: String?,
        limits: DocumentLimits
    ) async throws -> OpenedDocument

    /// Supplies a password for an already-open encrypted document.
    ///
    /// - Throws: ``PDFBridgeError/incorrectPassword`` when the password is wrong. The
    ///   document stays open and locked, so the user can try again.
    func unlock(_ handle: DocumentHandle, password: String) async throws -> DocumentDescriptor

    /// Releases a document and drops its cached thumbnails.
    func close(_ handle: DocumentHandle) async

    /// Releases every open document.
    func closeAll() async

    /// The descriptor of an open document.
    func descriptor(of handle: DocumentHandle) async throws -> DocumentDescriptor

    /// Page boxes, rotation and labels. `range` limits the work on a 1 000-sheet set.
    func pageDescriptors(
        of handle: DocumentHandle,
        range: Range<Int>?
    ) async throws -> [PDFPageDescriptor]

    // MARK: - Rendering

    /// Rasterises a page region. Cancellable, and rejected before allocation when the
    /// pixel count exceeds ``DocumentLimits/maximumRenderPixels``.
    func renderPageRegion(_ request: PageRenderRequest) async throws -> RenderedPageImage

    /// A whole-page thumbnail, from the LRU cache when possible.
    func thumbnail(_ request: ThumbnailRequest) async throws -> ThumbnailResult

    func thumbnailCacheStatistics() async -> ThumbnailCacheStatistics
    func clearThumbnailCache() async

    // MARK: - Text

    /// One page's text, with ``TextAvailability`` saying whether there is a text layer at
    /// all rather than returning an ambiguous empty string.
    func pageText(of handle: DocumentHandle, pageIndex: Int) async throws -> PageText

    /// Per-character bounding boxes in page space, for the characters PDFKit reports.
    ///
    /// `range` is in the page's UTF-16 character space; `nil` means every character, up
    /// to ``DocumentLimits/maximumCharacterBoxes``.
    func characterBoxes(
        of handle: DocumentHandle,
        pageIndex: Int,
        range: CharacterRange?
    ) async throws -> [CharacterBox]

    /// The text between two points on a page, as a drag-select would produce it.
    ///
    /// Returns `nil` when the two points select nothing.
    func selection(
        of handle: DocumentHandle,
        pageIndex: Int,
        from: CGPoint,
        to: CGPoint
    ) async throws -> TextSelection?

    /// Searches the document, returning ranges with page index, page label and bounds.
    func search(
        in handle: DocumentHandle,
        query: String,
        options: TextSearchOptions
    ) async throws -> TextSearchResults

    // MARK: - Navigation

    /// The bookmark tree, bounded in depth and node count.
    func outline(of handle: DocumentHandle) async throws -> DocumentOutline

    /// The `/Dests` name tree, resolved to page indices where possible.
    func namedDestinations(of handle: DocumentHandle) async throws -> [NamedDestination]

    /// The page-label table. Always non-`nil`: a document with no `/PageLabels` gets the
    /// implicit decimal table `1 … pageCount`, with ``PageLabelTable/isExplicit`` `false`.
    func pageLabels(of handle: DocumentHandle) async throws -> PageLabelTable

    // MARK: - Layers

    /// The optional-content layer tree from `/OCProperties`, or `nil` for the normal
    /// document that declares no layers.
    ///
    /// - Throws: ``PDFBridgeError/layerCatalogUnreadable(reason:)`` when the catalogue
    ///   exists but is broken (a missing `/OCGs` array, or a reference in it that does
    ///   not resolve), and ``PDFBridgeError/documentLocked`` for an encrypted document
    ///   that has not been unlocked.
    ///
    /// Rendering honesty: both PDFKit and CoreGraphics honour only the document's
    /// *default* configuration when drawing — neither exposes a per-render layer
    /// toggle — so a caller whose effective visibility differs from the default must
    /// re-render through the CoreGraphics content-stream-filtering path. See the notes
    /// on ``PDFLayerTree``.
    func layerTree(of handle: DocumentHandle) async throws -> PDFLayerTree?

    // MARK: - Annotations

    /// Existing annotations on one page, as neutral values.
    func annotations(of handle: DocumentHandle, pageIndex: Int) async throws -> [NeutralAnnotation]

    /// Existing annotations across the whole document.
    func allAnnotations(of handle: DocumentHandle) async throws -> [NeutralAnnotation]

    /// Writes annotations into a **copy** of the document.
    ///
    /// The open document and its file are untouched; the receipt proves it.
    func writeAnnotations(
        _ request: AnnotationWriteRequest,
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt

    // MARK: - Page operations

    /// The dry run: what ``applyPageOperations(_:on:to:)`` would produce, with no file
    /// touched and no writer opened.
    func planPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle
    ) async throws -> PageOperationPlan

    /// Applies page operations, producing a new document at `destination`.
    ///
    /// The result is exactly the ``PageOperationPlan/resultingPages`` of the plan for the
    /// same operations.
    ///
    /// - Note: page *geometry* is not guaranteed byte-identical across a page operation.
    ///   The PDFKit-backed implementation re-serialises `/MediaBox`, which rounds an ISO
    ///   A1 sheet's 1683.7795275590554 pt to 1683.78 — half a micrometre on a 594 mm
    ///   sheet, far below any measurement tolerance in spec 12, but real. Code that needs
    ///   the original bytes of a page must copy the file, not run it through a page
    ///   operation.
    func applyPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt

    /// Writes the named pages of `handle` to a new document. Shorthand for
    /// ``PageOperation/extract(pageIndices:)``.
    func extractPages(
        _ pageIndices: [Int],
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt

    /// Concatenates several open documents into a new one, in the order given.
    func mergeDocuments(
        _ handles: [DocumentHandle],
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt
}

public extension PDFDocumentProviding {
    /// Opens with the standard limits and no password.
    func open(_ source: DocumentSource) async throws -> OpenedDocument {
        try await open(source, password: nil, limits: .standard)
    }

    /// Opens a file with the standard limits.
    func open(fileAt url: URL, password: String? = nil) async throws -> OpenedDocument {
        try await open(.url(url), password: password, limits: .standard)
    }

    /// Every page's descriptor.
    func pageDescriptors(of handle: DocumentHandle) async throws -> [PDFPageDescriptor] {
        try await pageDescriptors(of: handle, range: nil)
    }

    /// Searches with the standard options.
    func search(in handle: DocumentHandle, query: String) async throws -> TextSearchResults {
        try await search(in: handle, query: query, options: .standard)
    }
}
