import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell

/// NL-QTY-15 phase 2, the application half: the open panel that picks closed projects, the
/// read-only batch summary over them (``ProjectBatchSummary``), and the one workbook it exports.
@MainActor
enum BatchProjectSummaryFlow {

    static let openPanelIdentifier = "batchSummary.chooseProjects"
    static let savePanelIdentifier = "batchSummary.exportWorkbook"

    /// The project package type, by its declared identifier.
    static var projectType: UTType {
        UTType("com.zenitgroup.zenitpdf.project") ?? UTType(filenameExtension: "zpdfproj", conformingTo: .package) ?? .package
    }

    /// Gives a document's window the two hooks the Whole Project panel uses.
    ///
    /// `shell` is the window's own — a second window's (NL-UX-20); `nil` means the document's.
    static func wire(_ document: ZenitPDFProjectDocument, shell windowShell: ProjectShellEnvironment? = nil) {
        guard let shell = windowShell ?? document.shell, shell.onBatchProjectSummary == nil else { return }
        shell.onBatchProjectSummary = { [weak document] in
            guard let document else { return nil }
            return await run(for: document)
        }
        shell.onExportBatchSummary = { [weak document] batch in
            guard let document else { return }
            export(batch, for: document)
        }
    }

    /// Picks closed projects and summarises them; `nil` when nothing was picked.
    static func run(for document: ZenitPDFProjectDocument) async -> LedgerBatchSummary? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = NSLocalizedString(
            "Choose closed Zenit PDF projects to total together. They are read, never changed.",
            comment: "Batch summary open panel message"
        )
        let urls: [URL] = await withCheckedContinuation { continuation in
            ZenitModalPresenter.runOpenPanel(panel, identifier: openPanelIdentifier, sheetedOn: document.windowForSheet) { answer in
                if case let .urls(urls) = answer { continuation.resume(returning: urls) } else { continuation.resume(returning: []) }
            }
        }
        guard !urls.isEmpty else { return nil }
        return await summarise(urls, units: await document.core?.session.displayUnits ?? .metric)
    }

    /// The batch over `urls`, in the panel's form: totals with their unit, refusals named.
    static func summarise(_ urls: [URL], units: DisplayUnitSelection) async -> LedgerBatchSummary {
        let accessed = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, didAccess) in zip(urls, accessed) where didAccess { url.stopAccessingSecurityScopedResource() } }
        let locale = Locale.current.identifier
        let outcome = await ProjectBatchSummary.summarise(urls, units: units, localeIdentifier: locale)
        let formatter = QuantityFormatter(units: units, localeIdentifier: locale)
        func labelled(_ totals: [LedgerSubjectTotal]) -> [LedgerSubjectTotal] {
            totals.map { LedgerSubjectTotal(subject: $0.subject, quantity: $0.quantity, rowCount: $0.rowCount, text: formatter.textWithUnit($0.quantity)) }
        }
        return LedgerBatchSummary(
            drawings: outcome.drawings.map { .init(documentID: $0.documentID, title: $0.title, totals: labelled($0.totals)) },
            combined: labelled(outcome.combined),
            refused: outcome.refused.map { .init(name: $0.name, reason: $0.reason) }
        )
    }

    /// The workbook form of a batch: numbers in the display unit, converted once by the one
    /// formatter; the unit its own column.
    static func workbook(_ batch: LedgerBatchSummary, units: DisplayUnitSelection, title: String) -> XLSXSubjectSummaryWorkbook {
        let formatter = QuantityFormatter(units: units)
        func lines(_ totals: [LedgerSubjectTotal]) -> [XLSXSubjectSummaryWorkbook.Line] {
            totals.map { total in
                let dimension = total.quantity.dimension
                let dimensionless = dimension.lengthPower == 0 && !dimension.angle && dimension.currencyCode == nil
                return .init(
                    subject: total.subject,
                    unit: formatter.symbol(total.quantity),
                    rowCount: total.rowCount,
                    value: formatter.converted(total.quantity),
                    decimalPlaces: dimensionless ? 0 : units.metricDecimalPlaces
                )
            }
        }
        return XLSXSubjectSummaryWorkbook(
            title: title,
            combined: lines(batch.combined),
            projects: batch.drawings.map { .init(name: $0.title, lines: lines($0.totals)) },
            notIncluded: batch.refused.map { [$0.name, $0.reason] }
        )
    }

    static func export(_ batch: LedgerBatchSummary, for document: ZenitPDFProjectDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx", conformingTo: .data) ?? .spreadsheet]
        panel.nameFieldStringValue = NSLocalizedString("Batch Summary", comment: "Batch summary workbook default file name") + ".xlsx"
        let window = document.windowForSheet
        ZenitModalPresenter.runSavePanel(panel, identifier: savePanelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                let units = await document.core?.session.displayUnits ?? .metric
                do {
                    try workbook(batch, units: units, title: url.deletingPathExtension().lastPathComponent).export(to: url)
                    ExportCompletion.remember(url, document: document)   // R-028
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }
}
