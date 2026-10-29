import AppKit
import CoreGraphics
import ZPDFAppCore
import ZPDFExport

/// What the print panel can add to the sheets (NL-PDF-06, round 2): the scope controls' data,
/// the header's title, and the Quantity Ledger's summary pages.
extension ZenitPDFProjectDocument {

    /// Fills `view` before the print panel opens. The summary is rendered once, by the same
    /// report writer File ▸ Export uses, from the ledger on screen; printing it stays a choice.
    func preparePrintExtras(for view: DocumentPrintView) async {
        guard let core else { return }
        let records = await core.session.orderedMarkups
        view.scopeRecords = records
        view.scopeLayers = core.snapshot.markupLayers   // ADR-0032: the print panel's layer boxes
        view.facts = DrawingOutputScope.facts(from: records, layers: core.snapshot.markupLayers)
        view.currentPageID = core.document.currentPageID
        view.headerTitle = displayName
        view.summary = await Self.summaryDocument(core: core, documentName: displayName ?? "Takeoff")
    }

    /// The ledger report as a PDF document in memory, or `nil` when the ledger is empty or the
    /// report cannot be written.
    static func summaryDocument(core: AppCoreEnvironment, documentName: String) async -> CGPDFDocument? {
        guard !core.snapshot.markups.isEmpty,
              let projection = try? await ProjectWindowController.projection(
                  core: core,
                  documentName: documentName,
                  scaleDescription: core.snapshot.documentScaleDescription,
                  request: core.ledger.request
              )
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-print-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let url = folder.appendingPathComponent("summary.pdf")
        guard (try? PDFReportRenderer().render(projection, to: url)) != nil,
              let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        return CGPDFDocument(provider)
    }
}
