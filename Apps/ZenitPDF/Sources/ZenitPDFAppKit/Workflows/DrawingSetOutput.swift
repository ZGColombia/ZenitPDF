import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge

/// The whole set of a project that holds several drawings, as one PDF the exports can write on
/// (NL-DOCS-04/08).
///
/// The Marked, Clean and Annotated exports and Print were written against one drawing file:
/// every sheet's `sourcePageIndex` is an index into *that* file. A project of several drawings
/// has sheets from several files, in the set's own order, some turned. So the set is composed
/// first — `ZenitPDFProjectDocument.writeComposed`, the Export Arranged Set writer, which
/// carries the sheet numbers as page labels and the view turns onto `/Rotate` — and the export
/// then runs on that file, each sheet's markups mapped onto its position in it. A project of one
/// drawing takes this path too whenever its set is not the file as filed (V-018).
///
/// The composed file is the page order, the labels and the file an Annotated or layered export
/// is written on. It is not what the flatten and Print draw under the markups: those draw each
/// sheet from its own drawing (``contentSource(for:)``), so the project's layer visibility and
/// the drawing's own layer defaults apply as they do to the drawing as filed (it5r V-018).
@MainActor
struct DrawingSetOutput {

    /// The composed set, a temporary file — or, for ``sheets(of:_:)``, the drawing itself.
    let url: URL
    /// The folder holding the composed file, removed by ``cleanUp()``; `nil` when ``url`` is a
    /// drawing's own file, which is never removed.
    let directory: URL?
    /// The sheets in set order: each the session's page with `index` = its position in ``url``
    /// and the view turn added to its rotation, so markup geometry maps onto the composed page.
    let pages: [ZPDFContracts.PageDescriptor]
    /// Every drawing file the set was composed from. An export writes on ``url``, a temporary
    /// file, so its own same-file check protects none of these (S-060).
    var sources: [URL] = []
    /// Where each sheet's page is in its own drawing, keyed by the index the job's sheets carry
    /// (``pages``' `index`). The drawing under the markups is drawn from there, not from ``url``:
    /// the drawing's own file keeps its layer definitions and the project's layer visibility
    /// applies to it, and the composed file may have neither (it5r V-018).
    var origins: [Int: Origin] = [:]
    /// What the composed file does not carry of its drawings' structure, from the writer's
    /// receipt. Empty for a drawing's own file.
    var structureNotCarried: Set<DocumentStructureFeature> = []

    /// One sheet's page in its own drawing.
    struct Origin {
        let drawing: LoadedDrawing
        let pageID: PageID
        let pageIndex: Int
    }

    /// Whether the composed file lost its drawings' layer definitions (`/OCProperties`) — PDFKit
    /// composed it, and a drawing had layers. Measured on macOS 26: PDFKit writes each sheet's
    /// content as the drawing shows it by default — a switched-off layer's content left out, the
    /// rest as plain content — so the file has no layers left to switch, and a layer hidden in
    /// the Navigator is in it for good.
    var lostLayerDefinitions: Bool { structureNotCarried.contains(.optionalContent) }

    /// What an output written **on the composed file itself** (Annotated, the PDF layer) must
    /// say when the file lost its drawings' layer definitions; `nil` when nothing was lost.
    var lostLayerDefinitionsNote: String? {
        guard lostLayerDefinitions else { return nil }
        return NSLocalizedString(
            "The drawing's layer definitions could not be carried into the arranged set, so the layers in this file cannot be switched: each sheet shows them as the drawing does by default.",
            comment: "Export omission note: the composed set lost the drawing's /OCProperties, so its layers are fixed at the drawing's defaults"
        )
    }

    /// The composed file's page for a sheet, or `nil` for a sheet not in the set.
    func pageIndex(of pageID: PageID) -> Int? {
        pages.first { $0.id == pageID }?.index
    }

    func cleanUp() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static let folderPrefix = "zpdf-set-output-"

    /// Why a set of several drawings was not written (U-019): it could not be put together into
    /// one file. Every output of the set refuses with it — Marked, Clean, Annotated, the PDF
    /// layer and Print — rather than writing the primary drawing's sheets alone and reporting
    /// the file complete.
    struct ComposeFailure: LocalizedError, Equatable {
        var errorDescription: String? {
            NSLocalizedString(
                "The drawings of this project could not be put together into one file, so nothing was written.",
                comment: "Export refusal: a project of several drawings could not be composed"
            )
        }

        var recoverySuggestion: String? {
            NSLocalizedString(
                "The warning tray says why. Check that every drawing of the project is still where it was added from, then try again.",
                comment: "Export refusal: what to do when the set could not be composed"
            )
        }
    }

    /// The composed set, or `nil` when the set is the primary drawing's own file exactly as it
    /// stands — the drawing's own file is what those outputs then write on, as they always did.
    /// A set that could not be composed throws ``ComposeFailure`` — `writeComposed` has said why
    /// in the tray — so no caller falls back to the primary drawing alone (U-019).
    ///
    /// A set whose every sheet is from one *added* drawing — the primary's sheets all removed —
    /// is composed too (U-013). Counting drawings made it `nil`, and every output then wrote the
    /// primary drawing: its removed sheets, and none of the set's.
    ///
    /// So is a one-drawing set that is not the file as filed (V-018): a sheet removed, the
    /// sheets reordered, a sheet turned or given its own sheet number. Only the report appendix
    /// used to honour those; Print and the Marked, Clean, Annotated and Layered exports wrote
    /// every page of the file, in file order, unturned.
    static func make(for document: ZenitPDFProjectDocument) async throws -> DrawingSetOutput? {
        let setPages = await document.setExportPages()
        guard let primary = document.drawing, !setPages.isEmpty,
              !isDrawingAsFiled(setPages, primary: primary)
        else { return nil }
        removeStale()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            throw ComposeFailure()
        }
        let url = directory.appendingPathComponent("set.pdf")
        guard let receipt = await document.writeComposed(setPages, sheetBookmarks: false, to: url) else {
            try? FileManager.default.removeItem(at: directory)
            throw ComposeFailure()
        }
        var pages: [ZPDFContracts.PageDescriptor] = []
        var origins: [Int: Origin] = [:]
        for (position, setPage) in setPages.enumerated() {
            guard var page = setPage.drawing.pages.first(where: { $0.id == setPage.pageID }) else { continue }
            origins[position] = Origin(drawing: setPage.drawing, pageID: page.id, pageIndex: page.index)
            page.index = position
            page.rotation = (try? PageRotation.normalizing(degrees: page.rotation.rawValue + setPage.viewRotation)) ?? page.rotation
            if let number = setPage.sheetNumber, !number.isEmpty { page.label = number }
            pages.append(page)
        }
        var sources: [URL] = []
        for setPage in setPages where !sources.contains(setPage.drawing.url) { sources.append(setPage.drawing.url) }
        return DrawingSetOutput(
            url: url, directory: directory, pages: pages, sources: sources,
            origins: origins, structureNotCarried: receipt.structureNotCarried
        )
    }

    /// Whether the set is `primary`'s file exactly as filed: every page of it, in the file's
    /// order, none turned and none carrying a sheet number other than its own page label — the
    /// one arrangement the drawing's own file already is. Pure.
    static func isDrawingAsFiled(_ setPages: [ZenitPDFProjectDocument.SetExportPage], primary: LoadedDrawing) -> Bool {
        let filed = primary.pages.sorted { $0.index < $1.index }
        guard setPages.count == filed.count else { return false }
        for (setPage, page) in zip(setPages, filed) {
            guard setPage.drawing.documentID == primary.documentID,
                  setPage.pageID == page.id,
                  ((setPage.viewRotation % 360) + 360) % 360 == 0
            else { return false }
            if let number = setPage.sheetNumber, !number.isEmpty, number != setPage.label { return false }
        }
        return true
    }

    /// Sheets of one drawing, read from its own file with nothing composed: each page keeps its
    /// index in that file. What a single-sheet output of an added drawing's sheet runs on — the
    /// saved thumbnail of a set that starts with one (U-013).
    static func sheets(of drawing: LoadedDrawing, _ pages: [ZPDFContracts.PageDescriptor]) -> DrawingSetOutput {
        var origins: [Int: Origin] = [:]
        for page in pages { origins[page.index] = Origin(drawing: drawing, pageID: page.id, pageIndex: page.index) }
        return DrawingSetOutput(url: drawing.url, directory: nil, pages: pages, sources: [drawing.url], origins: origins)
    }

    /// Composed sets an earlier print left behind (a print keeps its file until the next one).
    static func removeStale() {
        let root = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    /// The drawing under the markups for the set: each sheet drawn from **its own drawing** —
    /// its complete appearance (content and the drawing's own annotations) through PDFKit, with
    /// the drawing's password and, for the primary drawing, the project's layer visibility (the
    /// layers hidden in the Navigator, the annotation-to-layer bindings), exactly as a flatten of
    /// the drawing itself draws it. A page the drawer refuses falls back to the content replay of
    /// the sheet's drawing, then of the composed file, and the omission note names it.
    ///
    /// It drew the composed file (it5r V-018): a drawer opened with no password, layer tree or
    /// hidden layers refused nothing, so a layer hidden in the Navigator was drawn with no note —
    /// and a set PDFKit composed (a turned or renumbered sheet) had no layers left at all, its
    /// sheets fixed at the drawing's defaults (``lostLayerDefinitions``).
    func contentSource(for document: ZenitPDFProjectDocument) async -> (any FlattenPageContentDrawing)? {
        let composed = directory == nil ? nil : CGPDFPageContentSource(url: url)
        var drawers: [DocumentID: PDFPageAppearanceDrawer] = [:]
        var vectors: [DocumentID: CGPDFPageContentSource] = [:]
        let primaryID = document.drawing?.documentID
        var opened: Set<DocumentID> = []
        let zenitAnnotationNames = await ZenitAnnotationSupersession.names(for: document)
        for origin in origins.values.sorted(by: { $0.pageIndex < $1.pageIndex }) where !opened.contains(origin.drawing.documentID) {
            let id = origin.drawing.documentID
            opened.insert(id)
            if id == primaryID {
                drawers[id] = await FlattenedDrawingExport.primaryAppearanceDrawer(for: document)
            } else {
                drawers[id] = PDFPageAppearanceDrawer(
                    url: origin.drawing.url,
                    password: document.drawingPassword(forPage: origin.pageID.rawValue),
                    hidingZenitAnnotations: zenitAnnotationNames // L-23, as the primary drawer
                )
            }
            vectors[id] = CGPDFPageContentSource(url: origin.drawing.url)
        }
        let origins = self.origins
        guard !origins.isEmpty else { return composed }
        let fallback = SetSheetContentSource(origins: origins, vectors: vectors, composed: composed)
        let preferred = PreferredPageContentSource(
            preferred: { [drawers] index, context, rect, page in
                guard let origin = origins[index], let drawer = drawers[origin.drawing.documentID] else { return false }
                return drawer.drawPageAppearance(sourcePageIndex: origin.pageIndex, into: context, rect: rect, page: page)
            },
            fallback: fallback
        )
        let refused = Set(origins.compactMap { key, origin in
            drawers[origin.drawing.documentID]?.pagesRefusedForLayerVisibility.contains(origin.pageIndex) == true ? key : nil
        })
        return AppearanceContentSource(preferred: preferred, refusedAhead: refused)
    }
}

/// The content replay under a set's sheets (it5r V-018): each sheet from its own drawing's
/// content stream — which honours the drawing's own layer defaults — and from the composed file
/// only when the drawing will not open for Core Graphics (an encrypted drawing).
final class SetSheetContentSource: FlattenPageContentDrawing {
    private let origins: [Int: DrawingSetOutput.Origin]
    private let vectors: [DocumentID: CGPDFPageContentSource]
    private let composed: CGPDFPageContentSource?

    init(origins: [Int: DrawingSetOutput.Origin], vectors: [DocumentID: CGPDFPageContentSource], composed: CGPDFPageContentSource?) {
        self.origins = origins
        self.vectors = vectors
        self.composed = composed
    }

    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
        if let origin = origins[sourcePageIndex], let vector = vectors[origin.drawing.documentID],
           vector.drawPageContent(sourcePageIndex: origin.pageIndex, into: context, rect: rect) {
            return true
        }
        return composed?.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect) ?? false
    }

    func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect, page: ZPDFContracts.PageDescriptor) -> Bool {
        if let origin = origins[sourcePageIndex], let vector = vectors[origin.drawing.documentID],
           vector.drawPageContent(sourcePageIndex: origin.pageIndex, into: context, rect: rect, page: page) {
            return true
        }
        return composed?.drawPageContent(sourcePageIndex: sourcePageIndex, into: context, rect: rect, page: page) ?? false
    }
}
