import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFRenderer
import ZPDFUIPresentation

/// The flattened export shape in the application: the drawing on paper, and the drawing as a file.
///
/// # The one job this type has
///
/// Turn an open project into `[FlattenPage]` — pages plus the markups that belong on them — and
/// hand that to `ZPDFExport`. Four consumers take it from there and every one of them runs the
/// same flatten path:
///
/// | Shape | Who writes it | Markups |
/// |---|---|---|
/// | Print | `DocumentPrintView` → `FlattenedPDFWriter.paintSheet` | painted |
/// | Flattened PDF | `FlattenedPDFWriter.write(shape: .flattened, …)` | painted |
/// | Clean PDF | `FlattenedPDFWriter.write(shape: .clean, …)` | none |
/// | Annotated PDF | `StandardAnnotationExport` → `StandardAnnotationWriter` | as annotations |
///
/// # `printable`, decided once
///
/// The scene is built by the canvas's own `CanvasSceneBuilder`, and the markups are turned into
/// renderer geometry by `SnippetSceneBuilder` with ``SnippetSceneBuilder/Destination/paper``,
/// which applies `ZPDFExport.PDFFlattenPolicy`. There is no second place a markup can be dropped
/// from paper, so the print sheet and the exported file cannot disagree about what a person asked
/// to leave off.
///
/// # Why the whole document rather than the current page
///
/// Printing a takeoff means printing the set. The page the window happens to be showing is a fact
/// about the window.
@MainActor
public enum FlattenedDrawingExport {

    /// Everything one flatten job needs, gathered off the document.
    public struct Job: Sendable {
        public var pages: [FlattenPage]
        /// A default file name for the save panel, without an extension.
        public var suggestedFileName: String
        /// The original drawing's URL, so a write can refuse to land on it.
        public var sourceURL: URL

        public init(pages: [FlattenPage], suggestedFileName: String, sourceURL: URL) {
            self.pages = pages
            self.suggestedFileName = suggestedFileName
            self.sourceURL = sourceURL
        }
    }

    /// Why a flatten could not be prepared. Every case is a sentence a person can act on.
    public enum PreparationFailure: Error, CustomStringConvertible {
        case noDocument
        case noPages

        public var description: String {
            switch self {
            case .noDocument:
                NSLocalizedString(
                    "Open a drawing before printing or exporting it.",
                    comment: "Flatten refusal: no document"
                )
            case .noPages:
                NSLocalizedString(
                    "This drawing has no pages.",
                    comment: "Flatten refusal: no pages"
                )
            }
        }
    }

    /// Gathers the sheets.
    ///
    /// - Parameter artwork: the project's artwork store, so a stamp's seal and a count's
    ///   imported symbol reach the paper rather than their fallback glyphs.
    ///   - set: a project of several drawings, composed (``DrawingSetOutput``): the job's sheets
    ///     are the set's, indexed into the composed file. `nil` is the one drawing, as always.
    ///   - only: the sheets to gather, when not every one is wanted — the saved thumbnail needs
    ///     the first sheet alone, and built a scene for every sheet to keep one (T-014).
    ///   - keepingHiddenLayers: gather the markups of hidden layers too — the layered export
    ///     carries a hidden layer as a group that is off by default (ADR-0042, L-22). A markup
    ///     hidden on its own, and every layer kept off paper, stay out as everywhere else.
    static func job(
        for document: ZenitPDFProjectDocument,
        artwork resolve: ((String) async -> ArtworkGeometry?)? = nil,
        set: DrawingSetOutput?,
        only: Set<PageID>? = nil,
        keepingHiddenLayers: Bool = false
    ) async throws -> Job {
        guard let core = document.core, let drawing = document.drawing else {
            throw PreparationFailure.noDocument
        }
        let sheets = (set?.pages ?? drawing.pages).filter { only?.contains($0.id) ?? true }
        guard !sheets.isEmpty else { throw PreparationFailure.noPages }

        // ADR-0032: with each markup layer's hidden and printable flags folded in — or, for the
        // layered export, every flag but the layer's hidden one.
        let records = keepingHiddenLayers
            ? Self.markupsWithLayersShown(await core.session.drawOrderedMarkups, layers: await core.session.markupLayerList)
            : await core.session.effectiveMarkups
        let artwork = await artworkGeometry(for: records, resolve: resolve)
        // ADR-0043 (L-81): an inserted picture reaches paper from its own pixels, as on screen.
        let pictures = await SnippetSceneBuilder.insertedImageBytes(for: records, package: document.projectPackage)
        let snapshot = core.snapshot

        var pages: [FlattenPage] = []
        pages.reserveCapacity(sheets.count)
        for page in sheets {
            let pageUUID = page.id.rawValue
            // The canvas's own scene builder, on the canvas's own records. Starting from the
            // records a second time here would be a second interpretation of the same geometry,
            // and the one that drifted would be the one nobody re-opens to check.
            let shapes = CanvasSceneBuilder.build(
                records: records,
                summaries: snapshot.markups(onPage: pageUUID),
                pageID: pageUUID,
                artwork: artwork,
                // NL-MEASURE-09: segment lengths on paper as on screen.
                segmentLabelling: SnippetSceneBuilder.segmentLabelling(core: core, page: pageUUID)
            )
            pages.append(FlattenPage(
                page: page,
                sourcePageIndex: page.index,
                markups: SnippetSceneBuilder.renderables(
                    from: shapes, for: .paper, rotation: page.rotation, insertedImages: pictures
                )
            ))
        }

        let name = document.displayName
            ?? drawing.url.deletingPathExtension().lastPathComponent
        return Job(
            pages: pages,
            suggestedFileName: name,
            sourceURL: set?.url ?? drawing.url
        )
    }

    /// `records` with their layer's flags folded in as ``MarkupLayerSet/effective(_:)`` folds
    /// them, except that no layer hides them: locked and kept-off-paper still apply.
    nonisolated static func markupsWithLayersShown(_ records: [MarkupRecord], layers: MarkupLayerSet) -> [MarkupRecord] {
        let shown = MarkupLayerSet(layers.layers.map { layer in
            var visible = layer
            visible.visible = true
            return visible
        })
        return records.map { shown.effective($0) }
    }

    /// Gathers the sheets of the primary drawing.
    public static func job(
        for document: ZenitPDFProjectDocument,
        artwork resolve: ((String) async -> ArtworkGeometry?)? = nil
    ) async throws -> Job {
        try await job(for: document, artwork: resolve, set: nil)
    }

    /// The drawing under the markups.
    ///
    /// Vector when Core Graphics will open the file — the original's own content stream, replayed
    /// at whatever resolution the destination can actually resolve. A raster fallback when it
    /// will not: an encrypted drawing, or a sandbox path reachable only through the bridge's
    /// handle. The fallback is the sheet the old print path produced, so the worst case is what
    /// the product did before, and the normal case is a plotter-resolution sheet.
    ///
    /// - Parameter rasterFallbackPages: pages to pre-rasterise if the vector path is
    ///   unavailable. Empty means a white ground with the markups on it, which is a true picture
    ///   and never a crash.
    public static func contentSource(
        for document: ZenitPDFProjectDocument,
        rasterFallbackPages: [ZPDFContracts.PageDescriptor] = []
    ) async -> (any FlattenPageContentDrawing)? {
        guard let drawing = document.drawing else { return nil }
        let vector = CGPDFPageContentSource(url: drawing.url)
        // The complete appearance first: content plus the drawing's own annotations, with the
        // project's layer visibility applied — what the canvas shows. A page the drawer
        // refuses falls back to the content-stream replay, and the omission note names exactly
        // those pages (BH-079, BH-377).
        if let appearance = await appearanceSource(for: document, fallback: vector) {
            return appearance
        }
        if let vector { return vector }
        CanvasLog.printing.notice(
            "the drawing could not be replayed as vector; falling back to a raster underlay"
        )
        // One page in memory at a time: each sheet is rendered, written to a temporary file
        // and released before the next. Holding every rendered A1 sheet of a 60-sheet set in
        // one dictionary until the first page was written cost gigabytes during Print, and a
        // page whose render failed was skipped without a word (BH-378).
        guard let source = DiskBackedRasterContentSource() else { return nil }
        for page in rasterFallbackPages {
            let size = CGSize(
                width: page.rotatedVisibleSize.width,
                height: page.rotatedVisibleSize.height
            )
            do {
                let image = try await drawing.rasterSource.render(
                    pageIndex: page.index,
                    displaySize: size,
                    requestedScale: 2
                )
                source.store(image, forPage: page.index)
            } catch {
                source.noteFailure(forPage: page.index)
            }
        }
        return source.storedPageCount == 0 ? nil : source
    }

    /// What the flatten and print paths leave out that the canvas shows — said, not hidden.
    ///
    /// The content stream they replay never draws the drawing's own annotation appearances
    /// (revision clouds, a reviewer's stamps, annotation-borne linework: BH-079), and honours
    /// only the file's default layer configuration, not layers hidden in the Navigator
    /// (BH-377). Until the bridge can draw both into a vector context, every flatten names
    /// what it could not include.
    /// The appearance-first source, or `nil` when PDFKit will not open the drawing.
    static func appearanceSource(
        for document: ZenitPDFProjectDocument,
        fallback: (any FlattenPageContentDrawing)?
    ) async -> AppearanceContentSource? {
        guard let drawer = await primaryAppearanceDrawer(for: document) else { return nil }
        let preferred = PreferredPageContentSource(
            preferred: { index, context, rect, page in
                drawer.drawPageAppearance(sourcePageIndex: index, into: context, rect: rect, page: page)
            },
            fallback: fallback
        )
        return AppearanceContentSource(preferred: preferred, refusedAhead: drawer.pagesRefusedForLayerVisibility)
    }

    /// The primary drawing's appearance drawer, opened with its password and the project's
    /// layer visibility — the one drawer both the drawing as filed and a set's sheets of it are
    /// drawn with (it5r V-018). `nil` when PDFKit will not open the drawing.
    static func primaryAppearanceDrawer(for document: ZenitPDFProjectDocument) async -> PDFPageAppearanceDrawer? {
        guard let drawing = document.drawing else { return nil }
        var bindings = document.annotationLayerBindings ?? []
        if document.annotationLayerBindings == nil, document.layerVisibility.hasLayers {
            bindings = (try? await drawing.rasterSource.annotationLayerBindings()) ?? []
        }
        return PDFPageAppearanceDrawer(
            url: drawing.url,
            password: document.drawingPassword,
            layerTree: document.layerVisibility.tree,
            bindings: bindings,
            hiddenLayerIDs: document.layerVisibility.hiddenLayerIDs,
            // Every output drawn with this drawer paints the project's markups or promises none,
            // so the annotations an earlier Save Markups into PDF wrote for them are not drawn a
            // second time (L-23). Everybody else's are — a colleague's for markups this project
            // does not hold included, as the canvas draws them.
            hidingZenitAnnotations: await ZenitAnnotationSupersession.names(for: document)
        )
    }

    /// What the flatten and print paths leave out, given the source that drew (or will draw)
    /// the pages. With the appearance source only the pages that fell back to the content
    /// replay lose annotations or hidden layers, and only those are named.
    public static func omissionNotes(
        for document: ZenitPDFProjectDocument,
        content: (any FlattenPageContentDrawing)?
    ) async -> [String] {
        guard let appearance = content as? AppearanceContentSource else {
            return await omissionNotes(for: document)
        }
        let fellBack = appearance.fallbackPages
        guard !fellBack.isEmpty else { return [] }
        let pages = fellBack.sorted().map { String($0 + 1) }.joined(separator: ", ")
        var notes: [String] = []
        if let source = document.drawing?.rasterSource, await source.drawingAnnotationCount() > 0 {
            notes.append(String(
                format: NSLocalizedString(
                    "Annotations in the original PDF are not included on page(s) %@.",
                    comment: "Flatten omission note: pages drawn without the drawing's own annotations; the page numbers"
                ),
                pages
            ))
        }
        if document.layerVisibility.hasLayers, !document.layerVisibility.matchesDocumentDefault {
            notes.append(String(
                format: NSLocalizedString(
                    "Layers hidden in the Navigator are still included on page(s) %@.",
                    comment: "Flatten omission note: pages where project layer visibility could not be applied; the page numbers"
                ),
                pages
            ))
        }
        return notes
    }

    public static func omissionNotes(for document: ZenitPDFProjectDocument) async -> [String] {
        var notes: [String] = []
        if let source = document.drawing?.rasterSource {
            let annotations = await source.drawingAnnotationCount()
            if annotations > 0 {
                notes.append(String(
                    format: NSLocalizedString(
                        "%d annotations in the original PDF are not included in this output.",
                        comment: "Flatten omission note: the drawing's own PDF annotations are not replayed"
                    ),
                    annotations
                ))
            }
        }
        if document.layerVisibility.hasLayers, !document.layerVisibility.matchesDocumentDefault {
            notes.append(NSLocalizedString(
                "Layers hidden in the Navigator are still included in this output.",
                comment: "Flatten omission note: per-project layer visibility is not applied to print or export"
            ))
        }
        return notes
    }

    /// The warning identity flatten reports use, so a second export replaces the first.
    public static let reportWarningID = UUID(uuidString: "6B1F0C7E-3D2A-4B8E-9E55-7A2C4F1D9B30")!

    /// Posts what a print or export could not include, or nothing when it is complete.
    public static func postReport(_ report: Report, notes: [String], title: String, core: AppCoreEnvironment?) {
        guard let core, let message = reportMessage(report, notes: notes) else { return }
        core.document.post(AppWarning(
            id: reportWarningID,
            severity: report.isComplete ? .info : .warning,
            title: title,
            message: message,
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// The report's body: the writer's own sentence first, then each omission note, one per
    /// line. `nil` when there is nothing to say.
    ///
    /// Joined with a real line feed. The separator was the two characters `\` `n`, so a report
    /// with two notes read "…page(s) 3.\nLayers hidden…" as literal text (nl-pdf bug 1).
    static func reportMessage(_ report: Report, notes: [String]) -> String? {
        var lines = notes
        if let text = report.warningText { lines.insert(text, at: 0) }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// What a Marked or Clean export of a **signed** drawing must say (NL-PDF-15): the export is
    /// a new file and carries no signature, and the annotated export is the one that keeps the
    /// signed drawing intact. `nil` for an unsigned drawing.
    static func signatureNote(forDrawingAt url: URL) -> String? {
        guard DocumentHazardProbe.hazards(ofFileAt: url).contains(.signedDocument) else { return nil }
        let signer = SignatureInspector.signatures(ofFileAt: url).compactMap(\.signer).first
        if let signer {
            return String(
                format: NSLocalizedString(
                    "The drawing is digitally signed by %@. This export is a new file and carries no signature; Export Annotated PDF… keeps the signed drawing intact.",
                    comment: "Export note for a signed drawing; the signer's name"
                ),
                signer
            )
        }
        return NSLocalizedString(
            "The drawing is digitally signed. This export is a new file and carries no signature; Export Annotated PDF… keeps the signed drawing intact.",
            comment: "Export note for a signed drawing whose signer could not be read"
        )
    }

    // MARK: - Writing a file

    /// What a flatten write could not put on paper. Empty is the normal case.
    public struct Report: Sendable, Equatable {
        /// Markups the renderer refused (non-finite or out-of-range geometry, an untriangulable
        /// fill). They are missing from the file.
        public var rejectedMarkupCount: Int = 0
        /// Zero-based pages whose drawing underlay could not be drawn: those sheets carry the
        /// markups on white.
        public var pagesWithoutUnderlay: [Int] = []

        public var isComplete: Bool { rejectedMarkupCount == 0 && pagesWithoutUnderlay.isEmpty }

        /// The sentence a person reads when the file is not the whole picture.
        public var warningText: String? {
            guard !isComplete else { return nil }
            var parts: [String] = []
            if rejectedMarkupCount > 0 {
                parts.append(String(
                    format: NSLocalizedString(
                        "%d markups could not be drawn and are missing from the file.",
                        comment: "Flatten report: markups the renderer refused"
                    ),
                    rejectedMarkupCount
                ))
            }
            if !pagesWithoutUnderlay.isEmpty {
                parts.append(String(
                    format: NSLocalizedString(
                        "The drawing could not be drawn under the markups on page(s) %@.",
                        comment: "Flatten report: pages whose drawing underlay failed; the page numbers"
                    ),
                    pagesWithoutUnderlay.map { String($0 + 1) }.joined(separator: ", ")
                ))
            }
            return parts.joined(separator: " ")
        }
    }

    /// Writes one of the two content-stream shapes to `url`, and reports what did not make it.
    ///
    /// The writer returns success whatever its underlay and markup passes refused, so the
    /// report is gathered beside it: the underlay's per-page answer through a recording proxy,
    /// and the markups the renderer rejects through a dry pass of the same flattener. A write
    /// that lost markups or a sheet's drawing used to return success in silence (BH-379).
    ///
    /// ``PDFExportShape/annotated`` is not written here: annotations are objects in the page
    /// tree, not marks in a content stream, and `ZPDFPDFKitBridge` owns the writer that puts them
    /// there. ``FlattenedDrawingExport/annotations(for:)`` builds its input from the same job.
    @discardableResult
    public static func write(
        shape: PDFExportShape,
        job: Job,
        content: (any FlattenPageContentDrawing)?,
        to url: URL
    ) throws -> Report {
        let recorder = content.map { RecordingContentSource(wrapping: $0) }
        try FlattenedPDFWriter().write(
            shape: shape,
            pages: job.pages,
            content: recorder,
            to: url,
            metadata: FlattenedPDFWriter.Metadata(
                title: job.suggestedFileName,
                creator: ZenitAppInfo.displayName,
                subject: shape.rawValue
            ),
            protecting: [job.sourceURL]
        )
        var report = Report()
        if let recorder {
            report.pagesWithoutUnderlay = recorder.failedPages.sorted()
        } else {
            report.pagesWithoutUnderlay = job.pages.map(\.sourcePageIndex)
        }
        if shape.includesMarkups {
            report.rejectedMarkupCount = rejectedMarkupCount(in: job.pages)
        }
        return report
    }

    /// Counts the markups the flattener refuses, by running it into a one-pixel context.
    static func rejectedMarkupCount(in pages: [FlattenPage]) -> Int {
        guard let scratch = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        var rejected = 0
        for page in pages where !page.markups.isEmpty {
            let rect = CGRect(origin: .zero, size: page.paperSize)
            guard rect.width > 0, rect.height > 0 else { continue }
            if let outcome = try? MarkupFlattener.paint(
                page: page.page, markups: page.markups, into: scratch, rect: rect
            ) {
                rejected += outcome.rejectedMarkupCount
            } else {
                rejected += page.markups.count
            }
        }
        return rejected
    }

    // MARK: - The annotated shape

    // The annotated shape is ``StandardAnnotationExport``: one standard annotation per markup,
    // appended to the drawing (NL-PDF-01). It replaced a mapping of renderer *fragments* to
    // annotations, which exported a stamp as one polygon per artwork contour, a count as squares,
    // an area as two unrelated annotations, with no names, no opacity and no appearance. Each
    // annotation's `/Rect` is the writer's (`StandardAnnotationWriter.pageRect(of:)`), and a text
    // markup's box is the canvas shape's own.

    // MARK: - Support

    static func artworkGeometry(
        for records: [MarkupRecord],
        resolve: ((String) async -> ArtworkGeometry?)?
    ) async -> [String: ArtworkGeometry] {
        guard let resolve else { return [:] }
        var wanted: Set<String> = []
        for record in records {
            for digest in [record.symbol?.artworkDigest, record.stamp?.artworkDigest] {
                if let digest { wanted.insert(digest) }
            }
        }
        var artwork: [String: ArtworkGeometry] = [:]
        for digest in wanted.sorted() {
            if let geometry = await resolve(digest) { artwork[digest] = geometry }
        }
        return artwork
    }
}

// MARK: - Content sources

/// A raster underlay held on disk, one sheet in memory at a time (BH-378).
final class DiskBackedRasterContentSource: FlattenPageContentDrawing {

    private let directory: URL
    private var files: [Int: URL] = [:]
    /// Pages whose render failed, so the report can name them.
    private(set) var failedPages: Set<Int> = []

    var storedPageCount: Int { files.count }

    init?() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-flatten-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }
        self.directory = directory
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func store(_ image: CGImage, forPage index: Int) {
        let url = directory.appendingPathComponent("page-\(index).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            failedPages.insert(index)
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            files[index] = url
        } else {
            failedPages.insert(index)
        }
    }

    func noteFailure(forPage index: Int) {
        failedPages.insert(index)
    }

    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
        guard let url = files[sourcePageIndex],
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
        return true
    }
}

/// Forwards to a content source and remembers which pages it could not draw (BH-379).
final class RecordingContentSource: FlattenPageContentDrawing {

    private let inner: any FlattenPageContentDrawing
    private(set) var failedPages: Set<Int> = []

    init(wrapping inner: any FlattenPageContentDrawing) {
        self.inner = inner
    }

    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
        let drawn = inner.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect)
        if !drawn { failedPages.insert(sourcePageIndex) }
        return drawn
    }

    func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page: ZPDFContracts.PageDescriptor
    ) -> Bool {
        let drawn = inner.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect, page: page)
        if !drawn { failedPages.insert(sourcePageIndex) }
        return drawn
    }
}

/// The appearance-first page source (BH-079): the bridge's drawer, falling back per page to
/// the content-stream replay. Knows up front which pages the drawer refuses for layer
/// visibility, so a print's note can be written before the pages are drawn.
final class AppearanceContentSource: FlattenPageContentDrawing {
    let preferred: PreferredPageContentSource
    let refusedAhead: Set<Int>

    init(preferred: PreferredPageContentSource, refusedAhead: Set<Int>) {
        self.preferred = preferred
        self.refusedAhead = refusedAhead
    }

    /// Pages drawn — or to be drawn — without the complete appearance.
    var fallbackPages: Set<Int> { refusedAhead.union(preferred.fellBackPages) }

    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
        preferred.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect)
    }

    func drawPageContent(
        sourcePageIndex: Int,
        into context: CGContext,
        rect: CGRect,
        page: ZPDFContracts.PageDescriptor
    ) -> Bool {
        preferred.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect, page: page)
    }
}
