import AppKit
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFSnapEngine
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

/// Export, import, snippet and drawing-export commands, moved verbatim out of the window
/// controller's main file (IM-253). Reached only through `perform(app:)` and
/// `perform(external:)`.
extension ProjectWindowController {
    // MARK: - Export

    /// The export dialog: the Quantity Ledger as CSV, as an Excel workbook, as Zenit
    /// interchange JSON or as a PDF report, with the audit trail as an optional companion
    /// (ADR-0007 §3, the S22 remainder). One save panel, one powerbox grant, one file — the
    /// trail rides inside the chosen file (a second CSV section, or the report's appendix)
    /// because a sandboxed sibling write is exactly the 12.5 failure shape.
    ///
    /// `XLSXExporter` and `ZenitJSONExporter` were finished, gate-tested and unreachable from the
    /// application until 2026-08-24; the dialog offered CSV and the report only.
    func exportLedger(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let panel = NSSavePanel()
        panel.message = NSLocalizedString(
            "Export the Quantity Ledger as it is on screen.",
            comment: "Export panel message"
        )
        let ledger = core.ledger
        let accessory = ExportAccessoryView(
            panel: panel,
            scope: ExportAccessoryView.scopeText(
                rowCount: ledger.rowCount,
                totalRows: ledger.unfilteredRowCount,
                isFiltered: ledger.isFiltered
            ),
            preferences: Self.exportPreferences,
            selectedRowCount: ledger.selectedRowIDs.count,
            templateStore: Self.reportTemplateStore,
            captureRequest: { [weak ledger] in ledger?.request ?? LedgerRequest() },
            matrixOptions: Self.matrixOptions(core: core)
        )
        panel.accessoryView = accessory
        panel.nameFieldStringValue = Self.ledgerExportFileName(document: document, isFiltered: ledger.isFiltered)
        accessory.applyFormat()
        guard let window else { return }
        // The save panel is one of the six modal paths that must be injectable. A process
        // with no user chooses no destination, so nothing is written anywhere.
        ZenitModalPresenter.runSavePanel(
            panel,
            identifier: Self.exportLedgerModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            let includeTrail = accessory.includesAuditTrail
            let includeTrace = accessory.includesMeasurementTrace
            // NL-QTY-14: "Selected rows" narrows every format to the rows selected when the
            // dialog opened — the same rows the popup counted.
            let selection: Set<UUID>? = accessory.scope == .selected ? ledger.selectedRowIDs : nil
            // NL-QTY-11: a template that carries its own view replaces the on-screen grouping,
            // filter and columns; the CSV is then written from the same projection as the rest.
            let template = accessory.selectedTemplate
            let templateRequest = template.flatMap { $0.usesOnScreenView ? nil : $0.request(onScreen: ledger.request) }
            let pdfOptions = accessory.pdfOptions
            if accessory.format == .csv, let templateRequest {
                // The ticked audit trail travels here too: it was dropped in silence (R-043).
                self.writeProjectedExport(
                    format: .csv, for: document, core: core, includeTrail: includeTrail, includeTrace: includeTrace,
                    markupScope: selection, requestOverride: templateRequest, to: url
                )
                return
            }
            switch accessory.format {
            case .csv:
                let formatName = accessory.format.menuTitle
                Task { @MainActor in
                    do {
                        try await Self.writeOnScreenCSV(
                            for: document, core: core, includeTrail: includeTrail, includeTrace: includeTrace,
                            selection: selection, formatName: formatName, to: url
                        )
                    } catch {
                        ZenitErrorPresenter.present(error, in: window)
                    }
                }
            case .xlsx, .zenitJSON, .pdfReport:
                self.writeProjectedExport(
                    format: accessory.format,
                    for: document,
                    core: core,
                    includeTrail: includeTrail,
                    includeTrace: includeTrace,
                    markupScope: selection,
                    requestOverride: templateRequest,
                    pdfOptions: pdfOptions,
                    xlsxOptions: accessory.xlsxOptions,
                    summaryAxes: accessory.summaryAxes,
                    includePageImages: accessory.includesPageImages,
                    to: url
                )
            }
        }
    }

    /// The stable names of this controller's dialogues, for
    /// `ZenitModalPresenter.didRequest(_:)`.
    public static let damagedDrawingModalIdentifier = "document.damagedDrawing"
    public static let unreadableDrawingModalIdentifier = "document.unreadableDrawing"
    public static let grantAccessModalIdentifier = "document.grantReadAccess"
    public static let exportLedgerModalIdentifier = "export.ledgerDestination"
    public static let exportSnippetModalIdentifier = "export.snippetDestination"
    public static let exportDrawingModalIdentifier = "export.drawingDestination"

    /// The CSV branch of the export dialog: the table on screen, narrowed to `selection` when
    /// "Selected rows" is chosen, then the confirmation. The half worth asserting.
    static func writeOnScreenCSV(
        for document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment,
        includeTrail: Bool,
        includeTrace: Bool,
        selection: Set<UUID>?,
        formatName: String,
        to url: URL
    ) async throws {
        // Queued audit writes first (BH-911).
        if includeTrail { await core.history.settle() }
        let traces = includeTrace ? await exportRowTraces(core: core) : [:]
        try writeLedgerCSV(
            core: core, includeTrail: includeTrail,
            traces: Dictionary(uniqueKeysWithValues: traces.compactMap { key, trace in
                UUID(uuidString: key).map { ($0, trace) }
            }),
            onlyMarkups: selection,
            to: url
        )
        // The rows the file holds: "Selected rows" narrows it, and the confirmation said the
        // whole ledger's count (R-043).
        ExportCompletion.announce(
            url, rowCount: selection?.count ?? core.ledger.rowCount,
            formatName: formatName, document: document
        )
    }

    /// The ledger CSV, with the audit trail appended as a second, labelled CSV section
    /// when asked — one file, so the panel's grant covers everything written.
    static func writeLedgerCSV(
        core: AppCoreEnvironment,
        includeTrail: Bool,
        traces: [UUID: ExportRowTrace] = [:],
        onlyMarkups: Set<UUID>? = nil,
        to url: URL
    ) throws {
        let delimiter = LedgerCSVExport.delimiter(for: .current)
        var text = LedgerCSVExport.render(
            presenter: core.ledger, delimiter: delimiter, traces: traces, onlyMarkups: onlyMarkups
        )
        if includeTrail {
            text += auditTrailCSVSection(events: core.history.events, delimiter: delimiter)
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: url, options: .atomic)
    }

    /// The audit trail as a second, labelled CSV section, blank line first: what both CSV writers
    /// append when the trail is asked for.
    static func auditTrailCSVSection(events: [LedgerAuditEvent], delimiter: Character) -> String {
        "\r\n"
            + LedgerCSVExport.field(NSLocalizedString(
                "Audit Trail", comment: "Header of the CSV audit-trail section"
            ), delimiter: delimiter) + "\r\n"
            + AuditTrailExport.renderCSV(events: events, delimiter: delimiter)
    }

    /// The three formats rendered from one ``ZPDFExport/ExportProjection``: the PDF report, the
    /// Excel workbook and the Zenit interchange JSON.
    ///
    /// One projection, three writers. Every unit conversion and every rounding happens inside
    /// `ExportProjector` exactly once, so the number in the workbook is the number in the report
    /// is the number in the JSON (QUALITY_BAR A29, A30) — and all three are built from the
    /// ledger's live request, so they agree with the CSV, which renders the on-screen table.
    /// Where the export dialog remembers its format: the person's defaults in the assembled
    /// app, nowhere in a test process unless a test injects a scratch suite — a test must
    /// never write the user's own defaults.
    static var exportPreferences: UserDefaults? =
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier ? .standard : nil

    /// Where report templates are kept (NL-QTY-11): the person's library in the assembled app,
    /// nowhere in a test process unless a test injects a temporary store.
    static var reportTemplateStore: LedgerReportTemplateStore? =
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier ? .standard() : nil

    /// The proposed ledger export name (IM-185): "<Project> — Quantity Ledger <date>", with
    /// "(filtered)" when the ledger is — a subset must not look like the whole takeoff.
    static func ledgerExportFileName(document: ZenitPDFProjectDocument, isFiltered: Bool, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var name = "\(document.displayName ?? "Takeoff") — "
            + NSLocalizedString("Quantity Ledger", comment: "Ledger export file-name part")
            + " \(formatter.string(from: date))"
        if isFiltered {
            name += " " + NSLocalizedString("(filtered)", comment: "Ledger export file-name suffix when a filter is active")
        }
        return name + ".csv"
    }

    @discardableResult
    func writeProjectedExport(
        format: ExportAccessoryView.Format,
        for document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment,
        includeTrail: Bool,
        includeTrace: Bool = false,
        markupScope: Set<UUID>? = nil,
        requestOverride: LedgerRequest? = nil,
        pdfOptions: PDFReportOptions = PDFReportOptions(),
        xlsxOptions: XLSXExportOptions = XLSXExportOptions(),
        summaryAxes: (rows: LedgerColumnID, columns: LedgerColumnID)? = nil,
        includePageImages: Bool = false,
        to url: URL
    ) -> Task<Void, Never> {
        let documentName = document.displayName ?? "Takeoff"
        // A whole-document export has no page. `documentScaleDescription` names the one ratio
        // when the set shares one and lists them when it does not, rather than printing the
        // first sheet's over a mixed set.
        let scaleDescription = core.snapshot.documentScaleDescription
        let window = self.window
        var request = requestOverride ?? core.ledger.request
        request.markupScope = markupScope
        return Task { @MainActor in
            // Never onto the drawing, a drawing of the set, a revision or the project (U-017):
            // the save panel's Replace was the only thing between a report and Plan.pdf.
            do {
                try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
            } catch {
                ZenitErrorPresenter.present(error, in: window)
                return
            }
            core.status.setActiveToolNote(String(
                format: NSLocalizedString("Exporting “%@”…", comment: "Status note while an export is written; the file name"),
                url.lastPathComponent
            ))
            // The trail is read after the history's queued writes land: an edit made just
            // before Export was missing from a trail whose caption claims completeness (BH-911).
            if includeTrail { await core.history.settle() }
            let appendix = includeTrail
                ? AuditTrailExport.pdfAppendix(events: core.history.events, documentName: documentName)
                : nil
            // A CSV written from the projection (a template with its own view) carries the trail
            // as the on-screen CSV does: a second section in the same file (R-043).
            let trailEvents = includeTrail && format == .csv ? core.history.events : nil
            let rowTraces = includeTrace ? await Self.exportRowTraces(core: core) : [:]
            // Round 2: the summary matrix and the page images, each optional; one that cannot
            // be built is said in a warning, and the export goes on without it.
            var omitted: [String] = []
            var matrix: ExportSummaryMatrix?
            if let summaryAxes, format == .xlsx || format == .pdfReport {
                do {
                    matrix = try await Self.summaryMatrix(
                        core: core, documentName: documentName, scaleDescription: scaleDescription,
                        request: request, axes: summaryAxes
                    )
                } catch {
                    omitted.append(String(
                        format: NSLocalizedString("The summary matrix could not be built: %@", comment: "Export omission note; the reason"),
                        String(describing: error)
                    ))
                }
            }
            let sheetImages = includePageImages && format == .pdfReport
                ? await Self.reportSheetImages(for: document) : (pages: [], skipped: [], unavailable: nil)
            if let unavailable = sheetImages.unavailable { omitted.append(unavailable) }
            if !sheetImages.skipped.isEmpty {
                omitted.append(String(
                    format: NSLocalizedString("No page image for: %@", comment: "Export omission note; sheet labels"),
                    sheetImages.skipped.joined(separator: ", ")
                ))
            }
            // Bytes, not images: they travel to the background writer below (Sendable).
            let encoded = PDFReportSheetImages.encode(sheetImages.pages)
            if !encoded.failed.isEmpty {
                omitted.append(String(
                    format: NSLocalizedString("No page image for: %@", comment: "Export omission note; sheet labels"),
                    encoded.failed.joined(separator: ", ")
                ))
            }
            let pageImages = encoded.images
            do {
                let (plainProjection, unappliedRules) = try await Self.projectionWithDiagnostics(
                    core: core,
                    documentName: documentName,
                    scaleDescription: scaleDescription,
                    request: request,
                    rowTraces: rowTraces,
                    groupedNumbers: format != .csv
                )
                let projection = plainProjection.withSummaryMatrix(matrix)
                // The numbers are in the ledger's locale (L-46), so the CSV takes the delimiter a
                // spreadsheet in that locale splits on, as the on-screen CSV does: a comma decimal
                // under a comma delimiter is refused by the writer.
                let csvDelimiter: Character = projection.numberLocale.decimalSeparator == "," ? ";" : ","
                let csvTrail = trailEvents.map { Self.auditTrailCSVSection(events: $0, delimiter: csvDelimiter) }
                // The writers run off the main actor, into a temporary file that replaces the
                // destination only once it is complete: a 100 000-row workbook no longer froze
                // the window, and a failed or cancelled export leaves no partial file (IM-052).
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zpdf-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let temporary = staging.appendingPathComponent(url.lastPathComponent)
                // NL-PLAT-07: every workbook carries row identity, so it can come back.
                let workbookOptions = format == .xlsx
                    ? SpreadsheetRoundTrip.withRowIdentity(xlsxOptions, projection: projection, identity: await SpreadsheetRoundTrip.identity(of: document))
                    : xlsxOptions
                try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    switch format {
                    case .pdfReport:
                        _ = try PDFReportRenderer().render(
                            projection, to: temporary, options: pdfOptions,
                            appendix: PDFReportSheetImages.decode(pageImages), auditAppendix: appendix
                        )
                    case .xlsx:
                        try XLSXExporter().export(projection, to: temporary, options: workbookOptions)
                    case .zenitJSON:
                        try ZenitJSONExporter().export(projection).write(to: temporary, options: .atomic)
                    case .csv:
                        // Normally written by `writeLedgerCSV` from the table on screen; with a
                        // template that carries its own view (NL-QTY-11) it is written here, from
                        // the same projection as the other three formats.
                        try CSVExporter().export(
                            projection, options: CSVExportOptions(delimiter: csvDelimiter), to: temporary
                        )
                        if let csvTrail {
                            let handle = try FileHandle(forWritingTo: temporary)
                            defer { try? handle.close() }
                            try handle.seekToEnd()
                            try handle.write(contentsOf: Data(csvTrail.utf8))
                        }
                    }
                    try Task.checkCancellation()
                }.value
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
                core.status.setActiveToolNote(nil)
                // The data rows of the projection that was written (S-018): a template with a view
                // of its own, or a selection its filter narrows, writes a different number of rows
                // than the screen or the selection shows.
                let rowCount = projection.table.allRows().count
                ExportCompletion.announce(url, rowCount: rowCount, formatName: format.menuTitle, document: document)
                Self.postUnappliedFilterRules(unappliedRules, fileName: url.lastPathComponent, core: core)
                Self.postExportExtrasOmitted(omitted, fileName: url.lastPathComponent, core: core)
            } catch {
                core.status.setActiveToolNote(nil)
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// The warning identity for an export's unapplied filter rules, so a second export replaces it.
    static let unappliedRulesWarningID = UUID(uuidString: "2C5E8A41-7B0D-4F3A-9E61-5D8B7C2A1F04")!

    /// Says which filter rules the exported file does not honour (BH-101).
    static func postUnappliedFilterRules(_ rules: [String], fileName: String, core: AppCoreEnvironment) {
        guard !rules.isEmpty else { return }
        core.document.post(AppWarning(
            id: unappliedRulesWarningID,
            severity: .warning,
            title: String(
                format: NSLocalizedString(
                    "“%@” was exported without some of the ledger's filter rules.",
                    comment: "Export warning title when filter rules were not applied; the file name"
                ),
                fileName
            ),
            message: rules.joined(separator: "\n"),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    // MARK: - Import

    /// File ▸ Import Zenit JSON… — the reader `ZenitJSONImporter` never had a caller for
    /// before this.
    ///
    /// The panel is put up **first** and the comparison ledger is built **second**, from the
    /// same `ExportProjection` the export dialog writes, so the file is held against exactly the
    /// numbers the person is looking at rather than against a re-derived approximation of them.
    /// When there is no document, or the ledger is empty, the file is reviewed and not compared;
    /// that is stated in the sheet rather than left as a silently missing paragraph.
    ///
    /// Nothing this reads is written into the project. See ``ZenitJSONImport`` for why a ledger
    /// export cannot rebuild a takeoff and is not made to look as though it could.
    ///
    /// With no project window (`window` `nil`, the menu answered by the application delegate
    /// after the last window closed — T-009) the chooser and the review are app-modal.
    static func importLedgerJSON(for document: ZenitPDFProjectDocument?, window: NSWindow?) {
        guard let document, let core = document.core, !core.ledger.isEmpty else {
            ZenitJSONImport.present(in: window, against: nil)
            return
        }
        Task { @MainActor in
            ZenitJSONImport.present(in: window, against: await comparisonLedger(for: document))
        }
    }

    /// What a `.zpdfjson` is held against: the ledger on screen in interchange form, or `nil`
    /// when there is no takeoff or its ledger is empty. The one rule the menu and a file opened
    /// from Finder share (R-040).
    ///
    /// A failure to build it must not stop the review: the file is still readable and still
    /// worth showing, so it degrades to review-only.
    static func comparisonLedger(for document: ZenitPDFProjectDocument?) async -> ZenitInterchangeDocument? {
        guard let document, let core = document.core, !core.ledger.isEmpty else { return nil }
        // A whole-document export has no page. `documentScaleDescription` names the one ratio
        // when the set shares one and lists them when it does not, rather than printing the
        // first sheet's over a mixed set.
        return try? await interchange(
            core: core,
            documentName: document.displayName ?? "Takeoff",
            scaleDescription: core.snapshot.documentScaleDescription,
            request: core.ledger.request
        )
    }

    /// The ledger on screen in interchange form — the same projection, through the same writer,
    /// that File ▸ Export… would put in a `.zpdfjson`.
    ///
    /// Not private, so the app suite can export a project, import the bytes back and reconcile
    /// them through the shipping path rather than through a fixture.
    static func interchange(
        core: AppCoreEnvironment,
        documentName: String,
        scaleDescription: String?,
        request: LedgerRequest
    ) async throws -> ZenitInterchangeDocument {
        ZenitJSONExporter().document(from: try await projection(
            core: core,
            documentName: documentName,
            scaleDescription: scaleDescription,
            request: request
        ))
    }

    /// The one projection every non-CSV format is written from.
    ///
    /// Built from the ledger's **live** request, because the panel says "as it is on screen": an
    /// export built over an empty spec is the whole document with a matching grand total, under a
    /// label claiming the view was unfiltered (QUALITY_BAR A35, twice).
    ///
    /// Not private, so the app suite can assert that the workbook, the interchange JSON and the
    /// report really are three renderings of one set of numbers.
    static func projection(
        core: AppCoreEnvironment,
        documentName: String,
        scaleDescription: String?,
        request: LedgerRequest
    ) async throws -> ExportProjection {
        try await projectionWithDiagnostics(
            core: core, documentName: documentName, scaleDescription: scaleDescription, request: request
        ).projection
    }

    /// The projection, and the filter rules the ledger could not apply — which the export
    /// then says out loud rather than presenting a narrower-looking file (BH-101, app half).
    ///
    /// - Parameter groupedNumbers: whether numbers carry the locale's thousands separator, as the
    ///   ledger's cells do; `false` for a CSV, whose delimiter may be that separator.
    static func projectionWithDiagnostics(
        core: AppCoreEnvironment,
        documentName: String,
        scaleDescription: String?,
        request: LedgerRequest,
        rowTraces: [String: ExportRowTrace] = [:],
        groupedNumbers: Bool = true
    ) async throws -> (projection: ExportProjection, unappliedRules: [String]) {
        let (report, unapplied) = try await core.session.exportReportWithDiagnostics(
            title: ExportProjectionOptions.ledgerReportTitle(documentName: documentName),
            request: request
        )
        // L-46: the ledger's titles, each row's Unit, its number locale and its filter in words.
        let presentation = await ExportPresentation.make(core: core, request: request, grouping: groupedNumbers)
        // Dates in the file read in the zone the ledger shows them in (BH-533), and numbers carry
        // the precision the screen uses (BH-142, BH-143). One definition, shared with the `zenit`
        // command-line tool (r2-platform, NL-PLAT-13), so the two exports cannot drift apart.
        // Values kept under an older scale are said in every format (ADR-0030 §2, K-04).
        let stale = Set(await core.session.staleMeasurementIDs.map(\.rawValue.uuidString))
        let projection = try ExportProjector().project(
            report,
            options: .ledgerExport(
                documentName: documentName,
                scaleDescription: scaleDescription,
                preparedBy: AuthorIdentity.current(),
                screenDecimalPlaces: core.snapshot.units.metricDecimalPlaces,
                rowTraces: rowTraces,
                staleScaleRowIDs: stale,
                presentation: presentation
            )
        )
        return (projection, unapplied.map(\.message))
    }

    /// Every ledger row's measurement trace in the exporters' vocabulary (feature 16),
    /// keyed by the markup's UUID string as ``ExportProjectionOptions/rowTraces``
    /// is. The scale is the one the row was measured at, or `nil` — which prints "unknown" —
    /// never the scale in force today: that rule is ``MeasurementTraceResolver``'s, and this only
    /// changes the spelling.
    static func exportRowTraces(core: AppCoreEnvironment) async -> [String: ExportRowTrace] {
        let facts = await core.measurementTraceFacts()
        var traces: [String: ExportRowTrace] = [:]
        traces.reserveCapacity(facts.count)
        for (id, fact) in facts {
            traces[id.rawValue.uuidString] = ExportRowTrace(
                sheetLabel: fact.sheetLabel,
                scaleAtMeasureTime: fact.scaleAtMeasureTime,
                scaleRegionLabel: fact.scaleRegionLabel,
                createdAt: fact.createdAt,
                measuredAt: fact.measuredAt,
                author: fact.author,
                capture: fact.capture   // r2-platform, ADR-0031
            )
        }
        return traces
    }

    // MARK: - Snippet export (ADR-0006)

    /// Edit ▸ Copy Snippet — the ten-second path of ADR-0006.
    ///
    /// Select the measurements, one command, the picture is on the clipboard with its values
    /// under it. Nothing between the selection and the PNG reads the canvas's zoom, its scroll
    /// offset or the window's size; ``SnippetExport/inputs(for:document:caption:scaleFactor:artwork:)``
    /// gathers from the document and the session only.
    func copySnippet(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        copySnippet(for: document, of: .selection(core.canvas.selectedMarkupIDs))
    }

    /// The shared body of both copy paths — the selection command and the region drag.
    ///
    /// Not private, so the app suite can drive exactly what the menu drives.
    func copySnippet(for document: ZenitPDFProjectDocument, of subject: SnippetExport.Subject) {
        let window = self.window
        let pasteboard = snippetPasteboard
        Task { @MainActor in
            do {
                let inputs = try await self.snippetInputs(for: document, of: subject)
                let image = try await SnippetExport.render(inputs, pageSource: inputs.pageSource)
                pasteboard.write(try image.pasteboardPayload())
                // L-59: the picture went to the clipboard and nothing said so — the status line
                // kept asking for the box, and three tries in, the command looked dead.
                document.core?.status.setActiveToolNote(Self.snippetCopiedNote)
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// Said once the snippet is on the clipboard (L-59).
    static var snippetCopiedNote: String {
        NSLocalizedString(
            "Picture copied to the clipboard. Paste it into an email, a report or a chat.",
            comment: "Status note after Copy Snippet or Snippet of Region put the picture on the clipboard"
        )
    }

    /// File ▸ Export Snippet… — the same picture, saved instead of pasted.
    ///
    /// PNG or the vector PDF variant, decided by the extension the person picks, because the
    /// two are one pipeline (ADR-0006 §3) and a format popup for two formats is a dialogue
    /// nobody needs.
    func exportSnippet(for document: ZenitPDFProjectDocument) {
        guard let core = document.core, let window else { return }
        let subject = SnippetExport.Subject.selection(core.canvas.selectedMarkupIDs)
        let panel = NSSavePanel()
        panel.message = NSLocalizedString(
            "Save the selected measurements as an image, with their values.",
            comment: "Snippet export panel message"
        )
        panel.allowedContentTypes = [.png, .pdf]
        panel.nameFieldStringValue = SnippetExport.fileName(
            documentName: document.displayName ?? "Snippet"
        ) + ".png"
        // The save panel is one of the six modal paths that must be injectable. Only the presentation moved here — the snippet pipeline below is
        // untouched — and a process with no user chooses no destination, so nothing is written.
        ZenitModalPresenter.runSavePanel(
            panel,
            identifier: Self.exportSnippetModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                do {
                    try await self.writeSnippet(for: document, of: subject, to: url)
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    /// Renders one snippet and writes it. The extension decides raster or vector.
    ///
    /// Not private: this is the half of Export Snippet… that has nothing to do with a panel,
    /// and it is the half worth asserting.
    func writeSnippet(
        for document: ZenitPDFProjectDocument,
        of subject: SnippetExport.Subject,
        to url: URL
    ) async throws {
        // A snippet saved as PDF can be named like the drawing (U-017).
        try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
        let inputs = try await snippetInputs(for: document, of: subject)
        // The sheet's own drawing, decided with the inputs (T-007).
        let source = inputs.pageSource
        if url.pathExtension.lowercased() == "pdf" {
            try await SnippetExport.renderPDF(inputs, pageSource: source, drawingURL: inputs.drawingURL)
                .write(to: url, options: .atomic)
        } else {
            try await SnippetExport.render(inputs, pageSource: source)
                .pngData()
                .write(to: url, options: .atomic)
        }
        ExportCompletion.remember(url, document: document)
    }

    // MARK: - The drawing itself

    /// File ▸ Export Marked PDF… and File ▸ Export Clean PDF….
    ///
    /// Both shapes are the same writer with one flag different, which is the point:
    /// `ZPDFExport.FlattenedPDFWriter` decides what a marked page looks like and
    /// `ZPDFExport.PDFExportShape` decides whether the marks are drawn, so "clean" cannot
    /// accidentally carry ink and "marked" cannot accidentally lose it.
    func exportDrawing(_ shape: PDFExportShape, for document: ZenitPDFProjectDocument) {
        guard document.drawing != nil, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = Self.drawingExportMessage(shape)
        panel.nameFieldStringValue = Self.drawingExportFileName(shape, document: document)
        Task { @MainActor in
            // NL-PDF-05: the Marked shape's scope sheet — sheets, subjects, statuses
            // (`Workflows/DrawingOutputScope.swift`), the same predicate print uses.
            let scopeControls = shape == .flattened ? await self.drawingScopeControls(for: document) : nil
            panel.accessoryView = scopeControls
            // The save panel is one of the six modal paths that must be injectable. A process with no user chooses no destination, so nothing is written.
            ZenitModalPresenter.runSavePanel(
                panel,
                identifier: Self.exportDrawingModalIdentifier,
                sheetedOn: window
            ) { answer in
                guard let url = answer.firstURL else { return }
                let scope = scopeControls?.scope ?? .everything
                Task { @MainActor in
                    do {
                        try await self.writeDrawing(shape, for: document, to: url, scope: scope)
                    } catch {
                        ZenitErrorPresenter.present(error, in: window)
                    }
                }
            }
        }
    }

    /// Gathers the sheets and writes one of the two content-stream shapes.
    ///
    /// Not private: this is the half of the command that has nothing to do with a panel, and it
    /// is the half worth asserting — `FlattenedDrawingExportTests` re-opens what it wrote.
    @discardableResult
    func writeDrawing(
        _ shape: PDFExportShape,
        for document: ZenitPDFProjectDocument,
        to url: URL,
        scope: DrawingOutputScope = .everything
    ) async throws -> FlattenedDrawingExport.Report {
        // A project of several drawings writes the whole set: composed
        // first, then marked on the composed file (`Workflows/DrawingSetOutput.swift`). One that
        // could not be composed is refused, never written as its first drawing alone (U-019).
        let set = try await DrawingSetOutput.make(for: document)
        defer { set?.cleanUp() }
        // Never onto the drawing, or any drawing of the set, it is made from (S-060).
        try DerivedCopyGuard.refuseIfSource(url, document: document, set: set)
        var job = try await FlattenedDrawingExport.job(
            for: document,
            artwork: { [weak document] digest in
                guard let package = document?.projectPackage else { return nil }
                return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
            },
            set: set
        )
        // NL-PDF-05: the scope sheet narrows the markups; it never adds any back.
        let scopeNote = await DrawingOutputScope.narrow(&job, scope: scope, document: document)
        let content: (any FlattenPageContentDrawing)? = if let set { await set.contentSource(for: document) } else {
            await FlattenedDrawingExport.contentSource(
                for: document,
                rasterFallbackPages: document.drawing?.pages ?? []
            )
        }
        // The marked shape keeps the drawing's structure when it can (NL-PDF-05); the clean shape
        // and every fallback rebuild the pages.
        var path: FlattenedDrawingExport.MarkedPath?
        let report: FlattenedDrawingExport.Report
        if shape == .flattened {
            let marked = try await FlattenedDrawingExport.writeMarked(job: job, content: content, document: document, to: url, set: set)
            report = marked.report
            path = marked.path
        } else {
            report = try FlattenedDrawingExport.write(shape: shape, job: job, content: content, to: url)
        }
        // What the file does not carry, said rather than discovered on the plotter
        // (BH-079, BH-377, BH-378, BH-379). An appended marked file keeps the drawing's own
        // annotations and layers as they are, so those omission notes do not apply to it.
        var notes: [String] = []
        if case .appended? = path {
            notes = []
        } else {
            notes = await FlattenedDrawingExport.omissionNotes(for: document, content: content)
        }
        if let path { notes.append(FlattenedDrawingExport.markedPathNote(path)) }
        if let scopeNote { notes.append(scopeNote) }
        if let url = document.drawing?.url, let note = FlattenedDrawingExport.signatureNote(forDrawingAt: url) {
            notes.append(note)
        }
        let complete: Bool = if case .appended? = path { report.isComplete } else { false }
        FlattenedDrawingExport.postReport(
            report,
            notes: notes,
            title: complete
                ? String(
                    format: NSLocalizedString("“%@” was exported.", comment: "Export report headline when nothing is missing; the file name"),
                    url.lastPathComponent
                )
                : String(
                    format: NSLocalizedString(
                        "“%@” was exported, but not everything on the canvas is in it.",
                        comment: "Export report headline; the file name"
                    ),
                    url.lastPathComponent
                ),
            core: document.core
        )
        ExportCompletion.remember(url, document: document)
        return report
    }

    /// File ▸ Export Annotated PDF… — the editable shape.
    ///
    /// A different writer, on purpose: annotations are objects in the file's page tree rather
    /// than marks in a content stream, so `ZPDFPDFKitBridge` writes them against a pristine
    /// reopen of the original and hands back a receipt carrying the source's hash before and
    /// after. What this shares with the other two is the half that decides *which* markups go —
    /// the same ``FlattenedDrawingExport/job(for:artwork:)``, and therefore the same
    /// `printable` rule.
    func exportAnnotatedDrawing(for document: ZenitPDFProjectDocument) {
        guard document.drawing != nil, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = Self.drawingExportMessage(.annotated)
        panel.nameFieldStringValue = Self.drawingExportFileName(.annotated, document: document)
        ZenitModalPresenter.runSavePanel(
            panel,
            identifier: Self.exportDrawingModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                do {
                    let receipt = try await self.writeAnnotatedDrawing(for: document, to: url)
                    // The bridge measures the source's bytes either side of the write. If they
                    // ever differ the export is a defect, not a warning, and it must be visible.
                    if !receipt.sourceIsUnchanged {
                        ZenitErrorPresenter.present(
                            Self.annotatedExportIntegrityError(for: document), in: window
                        )
                    }
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }

    /// The error an annotated export that changed its source is presented as (BH-374): the
    /// integrity breach in words, never "the drawing is still opening", which invited the
    /// retry that could damage the source again.
    static func annotatedExportIntegrityError(for document: ZenitPDFProjectDocument) -> ZenitDocumentError {
        .exportChangedSource(
            document.drawing?.url.lastPathComponent ?? document.displayName ?? ""
        )
    }

    /// Builds one standard annotation per markup and writes them (NL-PDF-01): appended to the
    /// drawing's own bytes when it allows, through PDFKit when it does not. What the file does
    /// not carry — a fallback, a signature that did not survive — is posted as the export report.
    @discardableResult
    func writeAnnotatedDrawing(
        for document: ZenitPDFProjectDocument,
        to url: URL
    ) async throws -> StandardAnnotationExport.Result {
        guard let source = document.drawing?.rasterSource else {
            throw FlattenedDrawingExport.PreparationFailure.noDocument
        }
        // A project of several drawings: the annotations go onto the composed set;
        // its sheet links point at the set's own pages. A set that could not be
        // composed is refused (U-019).
        let set = try await DrawingSetOutput.make(for: document)
        defer { set?.cleanUp() }
        // Never onto the drawing, or any drawing of the set, it is made from (S-060).
        try DerivedCopyGuard.refuseIfSource(url, document: document, set: set)
        let job = try await StandardAnnotationExport.job(
            for: document,
            artwork: { [weak document] digest in
                guard let package = document?.projectPackage else { return nil }
                return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
            },
            // NL-COLLAB-07: each markup's replies travel as /IRT replies (nl-collaboration).
            replies: document.reviewRepliesForExport(),
            set: set
        )
        let result = try await StandardAnnotationExport.write(job, to: url, fallback: set != nil ? nil : { annotations in
            try await source.writeAnnotations(
                AnnotationWriteRequest(
                    annotations: annotations,
                    // A reviewer's own annotations on the incoming drawing are theirs and stay;
                    // Zenit's own from an earlier export are replaced, never stacked.
                    mode: .supersedeZenitOwned
                ),
                to: DocumentDestination(url: url, overwritePolicy: .replace)
            )
        })
        // The annotations go onto the composed set, so what it lost is in the file (it5r V-018).
        let layerNote = set?.lostLayerDefinitionsNote
        let lines = [StandardAnnotationExport.reportMessage(for: result), layerNote].compactMap { $0 }
        if !lines.isEmpty, let core = document.core {
            let message = lines.joined(separator: "\n")
            core.document.post(AppWarning(
                id: FlattenedDrawingExport.reportWarningID,
                severity: { if case .rewritten = result.writer { return .warning } else { return layerNote == nil ? .info : .warning } }(),
                title: String(
                    format: NSLocalizedString(
                        "“%@” was exported with %d annotations.",
                        comment: "Annotated export report headline; the file name and the annotation count"
                    ),
                    url.lastPathComponent,
                    result.annotationCount
                ),
                message: message,
                source: NSLocalizedString("Export", comment: "Warning source for print and export"),
                isDismissible: true,
                timestamp: Date()
            ))
        }
        ExportCompletion.remember(url, document: document)
        return result
    }

    static func drawingExportMessage(_ shape: PDFExportShape) -> String {
        switch shape {
        case .flattened:
            NSLocalizedString(
                "Save the drawing with your markups drawn into it, exactly as it prints.",
                comment: "Flattened PDF export panel message"
            )
        case .annotated:
            NSLocalizedString(
                "Save the drawing with your markups as PDF annotations another reader can edit.",
                comment: "Annotated PDF export panel message"
            )
        case .clean:
            NSLocalizedString(
                "Save the drawing with none of your markups on it.",
                comment: "Clean PDF export panel message"
            )
        }
    }

    /// The name the save panel opens with. The suffix says which of the three shapes it is, so a
    /// folder of exports of one sheet is still readable a month later.
    static func drawingExportFileName(
        _ shape: PDFExportShape,
        document: ZenitPDFProjectDocument
    ) -> String {
        let base = document.displayName ?? "Drawing"
        let suffix: String = switch shape {
        case .flattened:
            NSLocalizedString("Marked", comment: "Flattened PDF file-name suffix")
        case .annotated:
            NSLocalizedString("Annotated", comment: "Annotated PDF file-name suffix")
        case .clean:
            NSLocalizedString("Clean", comment: "Clean PDF file-name suffix")
        }
        return "\(base) — \(suffix).pdf"
    }

    /// Tools ▸ Snippet of Region… — arms the canvas; the release copies.
    func beginSnippetRegion(for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document) else { return }
        // The arming is SPOKEN. Live, this command changed nothing visible — no note, no
        // banner — and with the old click-cancels-capture rule the mode was usually dead
        // before the person even started dragging; the whole snippet path read as a dead
        // menu item (LT-29, 2026-08-29).
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a box around the part of the drawing to copy. Escape cancels.",
            comment: "Status note after Tools ▸ Snippet of Region…"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString(
                "Snippet cancelled.",
                comment: "Status note when region capture ends without a rectangle"
            )
        ) { [weak self, weak document] pageRect in
            guard let self, let document else { return }
            self.copySnippet(for: document, of: .region(pageRect))
        }
    }

    /// Arms the canvas's region capture for one feature: the rectangle handler AND the
    /// cancel note, together. Replacing only the handler left Escape out of a table import
    /// saying "Snippet cancelled." (CR-162).
    func beginRegionCapture(
        on canvas: PDFCanvasViewController,
        for document: ZenitPDFProjectDocument,
        cancelNote: String,
        onRegion: @escaping @MainActor (PDFRectValue) -> Void
    ) {
        canvas.onSnippetRegion = onRegion
        canvas.onSnippetRegionCancelled = { [weak document] in
            document?.core?.status.setActiveToolNote(cancelNote)
        }
        canvas.beginSnippetRegion()
    }

    /// The inputs one snippet is rendered from, with the project's artwork store attached so a
    /// stamp's seal and a count's imported symbol appear in the picture rather than as their
    /// fallback glyphs.
    func snippetInputs(
        for document: ZenitPDFProjectDocument,
        of subject: SnippetExport.Subject
    ) async throws -> SnippetExport.Inputs {
        try await SnippetExport.inputs(
            for: subject,
            document: document,
            artwork: { [weak document] digest in
                guard let package = document?.projectPackage else { return nil }
                return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
            }
        )
    }
}
