import AppKit
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation
import ZPDFUIShell

/// Round 2 of the quantities features: what the export dialog adds to a workbook or a report beyond
/// the ledger table — the summary matrix (NL-QTY-09), the page-image appendix (NL-QTY-11) — and
/// the groupings the matrix may use.
extension ProjectWindowController {

    /// The groupings the export dialog's matrix popups offer: the ledger's own groupable columns,
    /// by the pane's rule (words, options, days, yes/no — never a quantity).
    static func matrixOptions(core: AppCoreEnvironment) -> [(column: LedgerColumnID, title: String)] {
        var seen: Set<LedgerColumnID> = []
        return core.ledger.columns.compactMap { column in
            guard !LedgerDefaultColumns.isDisplayColumn(column.id), LedgerPaneModel.groups(column),
                  seen.insert(column.id).inserted
            else { return nil }
            return (column.id, column.title)
        }
    }

    /// The summary matrix for `axes`, from two more projections of the same request — grouped
    /// down-then-across and across alone — so every number in it is the projector's and the
    /// matrix reconciles with the ledger export by construction.
    static func summaryMatrix(
        core: AppCoreEnvironment,
        documentName: String,
        scaleDescription: String?,
        request: LedgerRequest,
        axes: (rows: LedgerColumnID, columns: LedgerColumnID)
    ) async throws -> ExportSummaryMatrix {
        var nestedRequest = request
        nestedRequest.grouping = [axes.rows, axes.columns]
        var acrossRequest = request
        acrossRequest.grouping = [axes.columns]
        let nested = try await projection(
            core: core, documentName: documentName, scaleDescription: scaleDescription, request: nestedRequest
        )
        let across = try await projection(
            core: core, documentName: documentName, scaleDescription: scaleDescription, request: acrossRequest
        )
        return try ExportSummaryMatrix.make(nested: nested, across: across)
    }

    /// Every sheet of the set with its markups, through the flatten path, for the report's
    /// appendix — the set the other outputs write (U-013): composed first in a project of several
    /// drawings, and without the sheets removed from the set. The primary drawing's pages used to
    /// be the appendix, so every added drawing's sheet was missing and a removed one was there.
    /// `unavailable` says why there is no appendix at all, for the export's omission note.
    static func reportSheetImages(for document: ZenitPDFProjectDocument) async -> (pages: [PDFReportAppendixPage], skipped: [String], unavailable: String?) {
        func unavailable(_ error: any Error) -> (pages: [PDFReportAppendixPage], skipped: [String], unavailable: String?) {
            ([], [], String(
                format: NSLocalizedString("No page images: %@", comment: "Export omission note: the page-image appendix could not be built; the reason"),
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            ))
        }
        let set: DrawingSetOutput?
        do {
            set = try await DrawingSetOutput.make(for: document)
        } catch {
            return unavailable(error)
        }
        defer { set?.cleanUp() }
        let job: FlattenedDrawingExport.Job
        do {
            job = try await FlattenedDrawingExport.job(
                for: document,
                artwork: { [weak document] digest in
                    guard let package = document?.projectPackage else { return nil }
                    return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
                },
                // With no composed set the set is the drawing as filed (V-018): every page.
                set: set
            )
        } catch {
            // Said, not swallowed (U-013): a job that could not be gathered used to leave the
            // report with no appendix and no word about it.
            return unavailable(error)
        }
        let content: (any FlattenPageContentDrawing)? = if let set { await set.contentSource(for: document) } else {
            await FlattenedDrawingExport.contentSource(for: document, rasterFallbackPages: job.pages.map(\.page))
        }
        let rendered = PDFReportSheetImages.render(pages: job.pages, content: content)
        return (rendered.pages, rendered.skipped, nil)
    }

    /// The warning identity for an export extra that could not be included.
    static let exportExtrasWarningID = UUID(uuidString: "6A1D3F52-9B7E-4C08-8E2A-3F5D7B9C1E60")!

    /// Says what the exported file does not carry that the dialog asked for.
    static func postExportExtrasOmitted(_ notes: [String], fileName: String, core: AppCoreEnvironment) {
        guard !notes.isEmpty else { return }
        core.document.post(AppWarning(
            id: exportExtrasWarningID,
            severity: .warning,
            title: String(
                format: NSLocalizedString(
                    "“%@” was exported without part of what was asked for.",
                    comment: "Export warning title when a summary matrix or page images could not be included; the file name"
                ),
                fileName
            ),
            message: notes.joined(separator: "\n"),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: Date()
        ))
    }
}
