import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFPDFKitBridge
import ZPDFRenderer
import ZPDFUIPresentation

/// ADR-0006 in the application: *"how wide is that opening?"* answered with a dimensioned
/// picture, on the clipboard, in ten seconds.
///
/// `ZPDFExport`'s ``ZPDFExport/SnippetExporter`` has been finished and hard-verified since
/// 2026-08-23 — byte-identical at three window sizes, caption digit-for-digit against the
/// ledger — and until this file existed no user could reach any of it. It was the seventh
/// built-but-unwired capability in this project. This is the door.
///
/// # The two ways in
///
/// * **Selection.** Select markups, run one command, the image is on the pasteboard. The
///   region is the union of those markups' page-space bounds; the caption quotes their ledger
///   rows. This is the ten-second path and it is the default.
/// * **Region.** Drag a rectangle on the canvas. Same pipeline, `.rect` instead of `.markups`.
///
/// # What is deliberately absent
///
/// No zoom, no scroll offset, no window size and no `NSView` is read anywhere below. The region
/// comes from geometry, the output scale is the spec's, and the markups come from the session's
/// records through the canvas's own scene builder. That is ADR-0006 §1 as a property of the
/// code: the same selection exported from a 700-point window scrolled to a corner and from a
/// 1600-point window scrolled elsewhere produces the *same bytes*, and
/// `SnippetExportWiringTests` asserts exactly that through this type.
@MainActor
public enum SnippetExport {

    /// Padding around a selection's bounding box, in page points.
    ///
    /// Enough that the outermost stroke, its arrowheads and its value pill are inside the
    /// picture rather than clipped by it — a dimension line cropped at its own arrow tip reads
    /// as a different measurement.
    public static let selectionPaddingPagePoints: Double = 24

    /// The default output scale: 3x, ADR-0006's own default. Legible in a mail thread at
    /// 100 % and still small enough to send.
    public static let defaultScaleFactor: Double = 3

    // MARK: - Inputs

    /// Everything one snippet is rendered from, gathered off the document and the session.
    ///
    /// A value type on purpose: gathering is asynchronous (the session is an actor, the ledger
    /// projection is a computation) and rendering is asynchronous, but nothing between the two
    /// may consult the interface. Once this exists the picture is decided.
    public struct Inputs: Sendable {
        public var spec: SnippetSpec
        public var page: ZPDFContracts.PageDescriptor
        public var markups: [RenderableMarkup]
        public var projection: ExportProjection?
        public var captionOptions: SnippetCaptionOptions
        /// A default file name for the save panel, without an extension.
        public var suggestedFileName: String
        /// The sheet's own drawing under the markups, and its file for the vector variant
        /// (T-007): decided with the page, so the picture is of the sheet the markups are on —
        /// in a project of several drawings the primary drawing's same-index sheet used to be
        /// drawn under them.
        public var pageSource: (any SnippetPageRasterizing)?
        public var drawingURL: URL?
    }

    /// What a snippet is of, before the document has been consulted.
    public enum Subject: Sendable, Hashable {
        /// The markups currently selected on the canvas.
        case selection(Set<UUID>)
        /// A rectangle the user dragged, in page space.
        case region(PDFRectValue)
    }

    /// Why a snippet could not be prepared. Every case is a sentence a person can act on.
    public enum PreparationFailure: Error, CustomStringConvertible {
        case noDocument
        case noSelection
        case noPage
        case emptyRegion

        public var description: String {
            switch self {
            case .noDocument:
                NSLocalizedString(
                    "Open a drawing before copying a snippet.",
                    comment: "Snippet export refusal: no document"
                )
            case .noSelection:
                NSLocalizedString(
                    "Select one or more measurements, then copy the snippet.",
                    comment: "Snippet export refusal: nothing selected"
                )
            case .noPage:
                NSLocalizedString(
                    "This drawing has no page to take a snippet of.",
                    comment: "Snippet export refusal: no current page"
                )
            case .emptyRegion:
                NSLocalizedString(
                    "Drag a larger region: that rectangle is too small to export.",
                    comment: "Snippet export refusal: degenerate region"
                )
            }
        }
    }

    /// Gathers everything a snippet needs, from the document and the session only.
    ///
    /// - Parameters:
    ///   - subject: the selection or the dragged rectangle.
    ///   - caption: ADR-0006 §2 — `.compact` and **on** by default. `.none` exists and is not
    ///     the default, because a dimensioned image travelling without its scale is the whole
    ///     risk this feature carries.
    ///   - scaleFactor: output pixels per page point, `1...8`.
    public static func inputs(
        for subject: Subject,
        document: ZenitPDFProjectDocument,
        caption: SnippetCaptionDetail = .compact,
        scaleFactor: Double = defaultScaleFactor,
        artwork: ((String) async -> ArtworkGeometry?)? = nil
    ) async throws -> Inputs {
        guard let core = document.core, document.drawing != nil else {
            throw PreparationFailure.noDocument
        }
        guard let currentPage = core.document.currentPage else { throw PreparationFailure.noPage }
        // The sheet's own drawing, in a project of several (T-007, NL-DOCS-04).
        guard let drawing = document.loadedDrawing(forPage: currentPage.id),
              let page = drawing.pages.first(where: { $0.id.rawValue == currentPage.id }) else {
            throw PreparationFailure.noPage
        }
        let pageIndex = page.index

        let region: SnippetRegion
        switch subject {
        case let .selection(ids):
            guard !ids.isEmpty else { throw PreparationFailure.noSelection }
            // Sorted, so two exports of one selection are the same export: a `Set`'s
            // iteration order is not a property of the takeoff, and the caption's line
            // order is visible in the picture.
            let ordered = ids.sorted { $0.uuidString < $1.uuidString }.map(MarkupID.init)
            region = .markups(ordered, padding: selectionPaddingPagePoints)
        case let .region(rect):
            let standardized = PDFRect(
                x: Swift.min(rect.origin.x, rect.origin.x + rect.size.width),
                y: Swift.min(rect.origin.y, rect.origin.y + rect.size.height),
                width: abs(rect.size.width),
                height: abs(rect.size.height)
            )
            guard standardized.width > 1, standardized.height > 1 else {
                throw PreparationFailure.emptyRegion
            }
            region = .rect(standardized)
        }

        let markups = await renderables(
            core: core, page: currentPage.id, artwork: artwork, rotation: page.rotation, package: document.projectPackage
        )
        let documentName = document.displayName ?? drawing.url.deletingPathExtension().lastPathComponent
        let spec = SnippetSpec(
            source: SnippetSource(
                documentName: documentName,
                pageIndex: pageIndex,
                pageLabel: currentPage.label,
                revision: nil
            ),
            region: region,
            content: SnippetContent(),
            caption: caption,
            scaleFactor: scaleFactor
        )

        // The caption's numbers come from the same `ExportProjection` the CSV, the workbook
        // and the PDF report are written from (ADR-0006 §2, ADR-0003 lineage), so a snippet
        // cannot disagree with the ledger. Built over the **flat** request rather than the
        // ledger's live one: ADR-0006's preparation point 3 is that a report is obtainable
        // for an arbitrary markup subset, and a selected measurement the current filter
        // happens to hide still has a true value to quote.
        // The scales the pictured quantities were actually measured at: a measurement inside a
        // Scale Region is at the region's ratio, and captioning the page's ratio under it was
        // the exact mismatch the caption exists to prevent (BH-388).
        let scales = await pictureScales(core: core, subject: subject, page: currentPage.id)
        var projection: ExportProjection?
        if caption != .none {
            do {
                projection = try await ProjectWindowController.projection(
                    core: core,
                    documentName: documentName,
                    scaleDescription: Self.scaleDescription(scales),
                    request: .flat
                )
            } catch {
                // The real cause, not "the caption requires a projection" (BH-921).
                throw error
            }
        }

        return Inputs(
            spec: spec,
            page: page,
            markups: markups,
            projection: projection,
            captionOptions: SnippetCaptionOptions(
                calibrationDescription: Self.calibrationDescription(scales)
            ),
            suggestedFileName: fileName(documentName: documentName),
            pageSource: CanvasSnippetPageSource(source: drawing.rasterSource),
            drawingURL: drawing.url
        )
    }

    /// The page's markups as renderer geometry, through the canvas's own scene builder, placed
    /// for the sheet turned by its `/Rotate` (U-077).
    ///
    /// - Parameter package: the project's package, from which an inserted picture's stored bytes
    ///   are read so the snippet shows it from its own pixels, as the canvas does (ADR-0043,
    ///   L-81). `nil` paints its mosaic.
    static func renderables(
        core: AppCoreEnvironment,
        page: UUID,
        artwork resolve: ((String) async -> ArtworkGeometry?)?,
        rotation: ZPDFContracts.PageRotation = .degrees0,
        package: ProjectPackage? = nil
    ) async -> [RenderableMarkup] {
        let records = await core.session.effectiveMarkups   // ADR-0032: layer flags folded in
        var artwork: [String: ArtworkGeometry] = [:]
        if let resolve {
            var wanted: Set<String> = []
            for record in records {
                for digest in [record.symbol?.artworkDigest, record.stamp?.artworkDigest] {
                    if let digest { wanted.insert(digest) }
                }
            }
            for digest in wanted.sorted() {
                if let geometry = await resolve(digest) { artwork[digest] = geometry }
            }
        }
        let pictures = await SnippetSceneBuilder.insertedImageBytes(for: records, package: package)
        return SnippetSceneBuilder.renderables(from: CanvasSceneBuilder.build(
            records: records,
            summaries: core.canvas.visibleMarkups,
            pageID: page,
            artwork: artwork,
            // NL-MEASURE-09: segment lengths in the snippet as on screen.
            segmentLabelling: SnippetSceneBuilder.segmentLabelling(core: core, page: page)
        ), rotation: rotation, insertedImages: pictures)
    }

    /// The `.full` caption's calibration sentence. The ledger does not know it; the document
    /// layer does (``ZPDFExport/SnippetCaptionOptions/calibrationDescription``).
    static func calibrationDescription(core: AppCoreEnvironment, page: UUID) -> String? {
        calibrationDescription(core.snapshot.scale(onPage: page).map { [$0] } ?? [])
    }

    /// The caption's calibration line for the scales in the picture.
    static func calibrationDescription(_ scales: [ScaleSummary]) -> String? {
        guard !scales.isEmpty else { return nil }
        return String(
            format: NSLocalizedString(
                "scale “%@”",
                comment: "Snippet caption: the named scale a measurement was taken against"
            ),
            scales.map(\.name).joined(separator: "”, “")
        )
    }

    /// The caption's ratio for the scales in the picture: one ratio, or the distinct ones
    /// listed — never one picked for a picture that holds several.
    static func scaleDescription(_ scales: [ScaleSummary]) -> String? {
        let distinct = Array(NSOrderedSet(array: scales.map(\.displayString))) as? [String] ?? []
        guard !distinct.isEmpty else { return nil }
        return distinct.joined(separator: ", ")
    }

    /// The scales the pictured measurements were taken against: each record's own scale — a
    /// Scale Region's, when it has one — falling back to the page's.
    static func pictureScales(core: AppCoreEnvironment, subject: Subject, page: UUID) async -> [ScaleSummary] {
        let pageScale = core.snapshot.scale(onPage: page)
        let records = await core.session.orderedMarkups.filter { record in
            guard record.pageID.rawValue == page, record.kind == .measurement else { return false }
            switch subject {
            case let .selection(ids): return ids.contains(record.id.rawValue)
            case let .region(rect):
                guard let bounds = record.geometry?.bounds else { return false }
                return bounds.maxX >= rect.minX && bounds.minX <= rect.maxX
                    && bounds.maxY >= rect.minY && bounds.minY <= rect.maxY
            }
        }
        var result: [ScaleSummary] = []
        var seen: Set<UUID> = []
        for record in records {
            let summary: ScaleSummary?
            if let scaleID = record.scaleID, scaleID.rawValue != pageScale?.id,
               let transform = await core.session.scaleTransform(scaleID) {
                summary = ScaleSummary(domain: transform, name: nil)
            } else {
                summary = pageScale
            }
            if let summary, seen.insert(summary.id).inserted { result.append(summary) }
        }
        if result.isEmpty, let pageScale { result = [pageScale] }
        return result
    }

    /// The name the save panel opens with: the drawing, then the word Snippet, so a folder of
    /// them still says which sheet each came from.
    static func fileName(documentName: String) -> String {
        let base = documentName.isEmpty ? "Snippet" : documentName
        let suffix = NSLocalizedString("Snippet", comment: "Snippet file-name suffix")
        return "\(base) — \(suffix)"
    }

    // MARK: - Rendering

    /// Renders the snippet to a composited raster (ADR-0006 §3).
    public static func render(
        _ inputs: Inputs,
        pageSource: (any SnippetPageRasterizing)?
    ) async throws -> SnippetImage {
        try await SnippetExporter().render(
            spec: inputs.spec,
            page: inputs.page,
            markups: inputs.markups,
            projection: inputs.projection,
            captionOptions: inputs.captionOptions,
            pageSource: pageSource
        )
    }

    /// The vector variant: the same region, the same caption text, as a one-page PDF.
    /// - Parameter drawingURL: the drawing's file; when Core Graphics opens it, the snippet's
    ///   page layer is the drawing's own vector content (NL-PDF-21) rather than a raster.
    public static func renderPDF(
        _ inputs: Inputs,
        pageSource: (any SnippetPageRasterizing)?,
        drawingURL: URL? = nil
    ) async throws -> Data {
        try await SnippetExporter().renderPDF(
            spec: inputs.spec,
            page: inputs.page,
            markups: inputs.markups,
            projection: inputs.projection,
            captionOptions: inputs.captionOptions,
            pageSource: pageSource,
            vectorPage: drawingURL.flatMap(CGPDFPageContentSource.init(url:))
        )
    }
}

// MARK: - The page raster seam

/// The application's ``ZPDFExport/SnippetPageRasterizing``: the drawing under the markups,
/// rasterised by the one object in the product that holds an open PDF.
///
/// It holds no `PDFDocumentProviding` or `DocumentHandle` of its own: ``PageRasterSource``
/// exists precisely so that no other object in the
/// application can hold a handle to a document it may already have closed, and a snippet is not
/// a reason to make an exception.
public struct CanvasSnippetPageSource: SnippetPageRasterizing {
    private let source: PageRasterSource

    public init(source: PageRasterSource) {
        self.source = source
    }

    public func rasterizePageRegion(
        pageIndex: Int,
        region: PDFRect,
        pixelsPerPoint: Double
    ) async throws -> CGImage {
        try await source.renderRegion(
            pageIndex: pageIndex,
            region: region,
            pixelsPerPoint: pixelsPerPoint
        )
    }
}

// MARK: - Destinations

/// Where a finished snippet goes. The platform pasteboard is one process-wide object, so it is
/// reached through a seam rather than touched directly: a test that wrote the real pasteboard
/// would be doing to the clipboard what `PresetApplySkipReportTests` once did to
/// `UserDefaults`, and the user's clipboard is not a test rig either.
@MainActor
public protocol SnippetPasteboardWriting: AnyObject {
    /// Writes both representations of one snippet: the PNG, and the caption as plain text.
    func write(_ payload: SnippetPasteboardPayload)
}

/// The shipping destination: `NSPasteboard.general`, PNG plus plain text.
public final class SystemSnippetPasteboard: SnippetPasteboardWriting {

    public init() {}

    public func write(_ payload: SnippetPasteboardPayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // One item carrying two representations, not two items: a mail composer takes the
        // PNG, a plain-text field takes the caption, and both are talking about the same
        // snippet (ADR-0006 §3).
        let item = NSPasteboardItem()
        item.setData(payload.png, forType: .png)
        item.setString(payload.plainText, forType: .string)
        pasteboard.writeObjects([item])
    }
}
