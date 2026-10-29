import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer

/// The review report's per-markup snapshot (NL-COLLAB-16): a cropped picture of each markup on
/// its sheet, through the snippet compositor (ADR-0006) — the canvas's own scene builder for the
/// marks, the drawing's raster underneath — at a modest resolution, with no caption band (the
/// report row beside it is the caption).
@MainActor
enum ReviewReportSnapshots {

    /// Pixels per page point: enough to read a cloud and its text, small enough for a mail.
    static let scaleFactor: Double = 1.5

    /// PNG bytes per markup. A markup whose picture cannot be made is simply absent: the report
    /// row still says everything in words.
    ///
    /// Each markup is drawn on its own sheet, found by the markup's page id (V-019). The row's
    /// `pageIndex` is the sheet's position in the set, not an index into any one file, and it
    /// used to pick the primary drawing's page at that index: a markup on an added drawing's
    /// sheet, on any sheet after a removed one, or in a reordered set got the wrong page or no
    /// picture at all. Each drawing draws under its own sheets, as the snippet export does
    /// (T-007).
    static func snapshots(for entries: [ReviewReportExport.Entry], document: ZenitPDFProjectDocument) async -> [UUID: Data] {
        guard let core = document.core, let primary = document.drawing else { return [:] }
        let documentName = document.displayName ?? primary.url.deletingPathExtension().lastPathComponent
        let sheetOfMarkup = Dictionary(core.snapshot.markups.map { ($0.id, $0.pageID) }, uniquingKeysWith: { first, _ in first })
        let setLabels = Dictionary(core.snapshot.pages.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var pageSources: [DocumentID: CanvasSnippetPageSource] = [:]
        var renderablesByPage: [UUID: [RenderableMarkup]] = [:]
        var output: [UUID: Data] = [:]
        for entry in entries {
            guard let pageUUID = sheetOfMarkup[entry.row.id],
                  let drawing = document.loadedDrawing(forPage: pageUUID),
                  let page = drawing.pages.first(where: { $0.id.rawValue == pageUUID })
            else { continue }
            let pageSource = pageSources[drawing.documentID] ?? CanvasSnippetPageSource(source: drawing.rasterSource)
            pageSources[drawing.documentID] = pageSource
            if renderablesByPage[pageUUID] == nil {
                renderablesByPage[pageUUID] = await SnippetExport.renderables(core: core, page: pageUUID, artwork: nil, rotation: page.rotation)
            }
            let spec = SnippetSpec(
                source: SnippetSource(documentName: documentName, pageIndex: page.index, pageLabel: setLabels[pageUUID] ?? page.label),
                region: .markups([MarkupID(entry.row.id)], padding: SnippetExport.selectionPaddingPagePoints),
                caption: .none,
                scaleFactor: scaleFactor
            )
            guard let image = try? await SnippetExporter().render(
                spec: spec, page: page, markups: renderablesByPage[pageUUID] ?? [], pageSource: pageSource
            ), let png = try? image.pngData() else { continue }
            output[entry.row.id] = png
        }
        return output
    }
}
