import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFSpreadsheet
import ZPDFUIPresentation

/// The two-way spreadsheet link (NL-PLAT-07): every exported workbook carries row identity, and
/// File ▸ Import Spreadsheet Changes… reads an edited copy back, shows exactly which cells differ,
/// and applies the accepted ones as one undoable step. A measured quantity typed over in the sheet
/// is refused and named: quantities come from geometry, never from a cell.
@MainActor
enum SpreadsheetRoundTrip {

    static let openPanelIdentifier = "spreadsheet.importPanel"
    static let reviewIdentifier = "spreadsheet.importReview"
    static let refusalIdentifier = "spreadsheet.importRefused"
    static let resultNoteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A20")!

    /// Ledger keys a spreadsheet may change: Subject, Label, Comment, the estimating columns, and
    /// any custom text or money column. Everything measured, computed or chosen stays read-only.
    nonisolated static let standardEditableKeys: Set<String> = [
        StandardLedgerColumn.subject.rawValue, StandardLedgerColumn.label.rawValue, StandardLedgerColumn.comment.rawValue,
        StandardLedgerColumn.costCode.rawValue, StandardLedgerColumn.trade.rawValue, StandardLedgerColumn.phase.rawValue,
        StandardLedgerColumn.material.rawValue, StandardLedgerColumn.unitCost.rawValue,
    ]

    nonisolated static func editableKeys(of columns: [ExportColumn]) -> Set<String> {
        let standard = Set(StandardLedgerColumn.allCases.map(\.rawValue))
        return Set(columns.compactMap { column -> String? in
            if standardEditableKeys.contains(column.key) { return column.key }
            guard !standard.contains(column.key), column.kind == .text || column.kind == .currency else { return nil }
            return column.key
        })
    }

    /// The identity a workbook is exported under: the project's id when there is a package, else
    /// the drawing's fingerprint.
    static func identity(of document: ZenitPDFProjectDocument) async -> String {
        if let package = document.projectPackage {
            return "project:" + (await package.manifest.projectId)
        }
        return "drawing:" + (document.drawing?.digest.sha256 ?? "")
    }

    /// The export options with row identity added. Called by the XLSX export path.
    nonisolated static func withRowIdentity(_ options: XLSXExportOptions, projection: ExportProjection, identity: String, now: Date = Date()) -> XLSXExportOptions {
        var copy = options
        copy.rowIdentity = XLSXRowIdentity(
            projectID: identity,
            exportedAt: ISO8601DateFormatter().string(from: now),
            editableColumnKeys: editableKeys(of: projection.table.columns),
            revealLinkPrefix: ZenitURLNotes.revealLinkPrefix(project: identity)   // NL-PLAT-09
        )
        return copy
    }

    /// The ledger as the export wrote it, for the comparison: text as text, numbers as the exact
    /// doubles the writer put in the cells.
    nonisolated static let excelEpoch = Date(timeIntervalSince1970: -2_209_161_600)   // 1899-12-30T00:00:00Z

    nonisolated static func currentValues(of projection: ExportProjection) -> (values: [String: [String: RoundTripValue]], numeric: Set<String>) {
        let columns = projection.table.columns
        var values: [String: [String: RoundTripValue]] = [:]
        for row in projection.table.allRows() {
            var entry: [String: RoundTripValue] = [:]
            for (index, column) in columns.enumerated() where index < row.cells.count {
                switch row.cells[index] {
                case .blank: entry[column.key] = .empty
                case let .number(number): entry[column.key] = .number(NSDecimalNumber(decimal: number.convertedRaw).doubleValue)
                case let .text(text): entry[column.key] = .text(text)
                case let .date(date):
                    // The workbook holds an Excel serial day number (days since 1899-12-30, UTC).
                    entry[column.key] = .serialDate(date.date.timeIntervalSince(excelEpoch) / 86_400)
                case let cell: entry[column.key] = .text(cell.text)
                }
            }
            values[row.markupID] = entry
        }
        return (values, Set(columns.filter { $0.isNumeric || $0.kind == .date }.map(\.key)))
    }

    /// `current` with the read-only cells an older export wrote differently read the way it wrote
    /// them, so a workbook from an earlier build is not refused for cells nobody touched.
    ///
    /// - **Type.** The ledger shows the tool's name ("Area"), and every export writes it since
    ///   L-46; an export before that wrote the tool's token (`area`), and one before T-046 the
    ///   markup kind (`measurement`). `typeTokens` holds each markup's token — its tool, or its
    ///   kind when it has none, the ledger store's own rule — so both older spellings of what the
    ///   ledger says are recognised.
    /// - **Page index.** An export before L-46 wrote the sheet's 0-based position; it now writes
    ///   the page number from 1.
    /// - **Unit.** An export before L-46 left the Unit cell blank.
    ///
    /// A markup's tool and page do not change with an export, so these cells say what the ledger
    /// says, spelled the old way; compared as they were, the read-only columns were refused on
    /// every row of every older workbook. Nothing else is touched: any other text in those cells
    /// is still a change, and still refused.
    nonisolated static func acceptingOlderSpellings(
        _ current: [String: [String: RoundTripValue]],
        in workbook: LedgerRoundTripWorkbook,
        typeTokens: [String: String]
    ) -> [String: [String: RoundTripValue]] {
        let type = StandardLedgerColumn.icon.rawValue
        let page = StandardLedgerColumn.pageIndex.rawValue
        let unit = StandardLedgerColumn.displayUnit.rawValue
        let carried = Set(workbook.columns.map(\.key))
        var result = current
        for row in workbook.rows {
            guard let now = current[row.markupID] else { continue }
            if carried.contains(type), let stored = row.values[type]?.trimmingCharacters(in: .whitespacesAndNewlines),
               case .text? = now[type], let token = typeTokens[row.markupID],
               stored == token || LedgerPreToolTypeToken.isOldSpelling(stored, of: token) {
                result[row.markupID]?[type] = .text(stored)
            }
            if carried.contains(page), let stored = row.values[page].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
               case let .number(number)? = now[page], stored == number - 1 {
                result[row.markupID]?[page] = .number(stored)
            }
            if carried.contains(unit), (row.values[unit] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               case .text? = now[unit] {
                result[row.markupID]?[unit] = .empty
            }
        }
        return result
    }

    /// Each markup's Type token, by UUID string: its tool, or its kind when it has none — the
    /// spelling the ledger store keeps and an export wrote before L-46.
    nonisolated static func typeTokens(of records: [MarkupRecord]) -> [String: String] {
        Dictionary(
            records.map { ($0.id.rawValue.uuidString, $0.tool?.rawValue ?? $0.kind.rawValue) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The review of a returned workbook against `projection` — the whole ledger, shaped by
    /// ``comparisonRequest(for:)`` — as the import command shows it.
    nonisolated static func review(
        _ workbook: LedgerRoundTripWorkbook,
        against projection: ExportProjection,
        projectID: String,
        typeTokens: [String: String] = [:]
    ) -> LedgerRoundTripReview {
        let (current, numeric) = currentValues(of: projection)
        return LedgerRoundTrip.review(
            workbook, current: acceptingOlderSpellings(current, in: workbook, typeTokens: typeTokens),
            numericKeys: numeric, projectID: projectID
        )
    }

    /// The review in words, for the confirmation: every changed cell (up to a screenful), then
    /// every refused one with its reason, then what only one side has.
    static func reviewText(_ review: LedgerRoundTripReview, fileName: String) -> (title: String, body: String) {
        // L-48: "changes 1 cell", not "changes 1 cells".
        let title = LocalizedPlural.string(
            "“%2$@” changes %1$lld cells",
            count: review.changes.count,
            one: NSLocalizedString("“%2$@” changes %1$lld cell", comment: "Spreadsheet import review title, one cell; number of changed cells, file name"),
            other: NSLocalizedString("“%2$@” changes %1$lld cells", comment: "Spreadsheet import review title; number of changed cells, file name"),
            arguments: [fileName]
        )
        var lines: [String] = []
        if review.fromAnotherProject {
            lines.append(NSLocalizedString("This workbook was exported from another project or drawing. Rows are matched by their Row ID; only rows this ledger has are changed.", comment: "Spreadsheet import review warning"))
            lines.append("")
        }
        let shown = 40
        for change in review.changes.prefix(shown) {
            lines.append(String(format: NSLocalizedString("%1$@: “%2$@” → “%3$@”", comment: "Spreadsheet import review line; column, before, after"),
                                change.header, change.before, change.after))
        }
        if review.changes.count > shown {
            lines.append(String(format: NSLocalizedString("…and %lld more.", comment: "Spreadsheet import review: hidden changes"), Int64(review.changes.count - shown)))   // always > 1
        }
        if !review.refusals.isEmpty {
            lines.append("")
            lines.append(NSLocalizedString("Not applied:", comment: "Spreadsheet import review: refused cells heading"))
            for refusal in review.refusals.prefix(shown) {
                let reason = refusal.reason == .readOnlyColumn
                    ? NSLocalizedString("a measured or computed value comes from the drawing, not from a cell", comment: "Spreadsheet refusal reason")
                    : NSLocalizedString("not a number", comment: "Spreadsheet refusal reason")
                lines.append(String(format: NSLocalizedString("%1$@ “%2$@” → “%3$@”: %4$@", comment: "Spreadsheet import refused line; column, before, after, reason"),
                                    refusal.header, refusal.before, refusal.after, reason))
            }
        }
        if !review.onlyInFile.isEmpty {
            lines.append("")
            lines.append(LocalizedPlural.string(
                "%lld rows in the workbook are no longer in the ledger and are ignored.",
                count: review.onlyInFile.count,
                one: NSLocalizedString("%lld row in the workbook is no longer in the ledger and is ignored.", comment: "Spreadsheet import review, one row"),
                other: NSLocalizedString("%lld rows in the workbook are no longer in the ledger and are ignored.", comment: "Spreadsheet import review")
            ))
        }
        if !review.onlyInLedger.isEmpty {
            lines.append(LocalizedPlural.string(
                "%lld ledger rows are not in the workbook and stay as they are.",
                count: review.onlyInLedger.count,
                one: NSLocalizedString("%lld ledger row is not in the workbook and stays as it is.", comment: "Spreadsheet import review, one row"),
                other: NSLocalizedString("%lld ledger rows are not in the workbook and stay as they are.", comment: "Spreadsheet import review")
            ))
        }
        return (title, lines.joined(separator: "\n"))
    }

    /// The ledger a returned workbook is compared with: the whole of it, whatever the screen
    /// shows (S-011). No filter, no "only values under an older scale", no selection scope, and
    /// every column the workbook carries. The on-screen request used to shape the comparison, so
    /// an edited row the filter hid was reported as "no longer in the ledger" and dropped, and a
    /// workbook column the screen did not show read as empty, which made phantom changes and
    /// read-only refusals out of cells nobody touched. (`visibleColumns == []` alone means the
    /// default visible columns, not all of them.)
    static func comparisonRequest(for workbook: LedgerRoundTripWorkbook) -> LedgerRequest {
        LedgerRequest(
            grouping: [],
            sort: [],
            filter: LedgerFilterGroup(id: UUID()),
            visibleColumns: workbook.columns.map { LedgerColumnID($0.key) }
        )
    }

    /// The review's confirm button (L-48): "Apply 1 Change", "Apply 3 Changes".
    static func applyButtonTitle(changeCount: Int) -> String {
        LocalizedPlural.string(
            "Apply %lld Changes",
            count: changeCount,
            one: NSLocalizedString("Apply %lld Change", comment: "Spreadsheet import review confirm, one cell; number of cells"),
            other: NSLocalizedString("Apply %lld Changes", comment: "Spreadsheet import review confirm; number of cells")
        )
    }

    /// The note after an import (L-48): "Applied 1 change from …", "Applied 3 changes from …".
    static func resultTitle(applied: Int, fileName: String) -> String {
        LocalizedPlural.string(
            "Applied %1$lld changes from “%2$@”",
            count: applied,
            one: NSLocalizedString("Applied %1$lld change from “%2$@”", comment: "Spreadsheet import result, one change; count, file name"),
            other: NSLocalizedString("Applied %1$lld changes from “%2$@”", comment: "Spreadsheet import result; count, file name"),
            arguments: [fileName]
        )
    }

    // MARK: - The command

    static func importChanges(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString(
            "Choose a workbook exported from this ledger and edited in a spreadsheet.",
            comment: "Open panel message for importing spreadsheet changes"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: openPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await importChanges(from: url, into: document) }
        }
    }

    /// Reads, reviews and — when the person accepts — applies one workbook.
    ///
    /// - Returns: the apply receipt, or `nil` when nothing was applied (refused, cancelled, or
    ///   no changes).
    @discardableResult
    static func importChanges(from url: URL, into document: ZenitPDFProjectDocument) async -> SpreadsheetApplyReceipt? {
        guard let core = document.core else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let workbook = try await Task.detached(priority: .userInitiated) { try LedgerRoundTripWorkbook(data: data) }.value
            let request = comparisonRequest(for: workbook)
            let projection = try await ProjectWindowController.projection(
                core: core, documentName: document.displayName ?? "Takeoff",
                scaleDescription: core.snapshot.documentScaleDescription, request: request
            )
            let review = Self.review(
                workbook, against: projection, projectID: await identity(of: document),
                typeTokens: typeTokens(of: await core.session.orderedMarkups)
            )
            let text = reviewText(review, fileName: url.lastPathComponent)
            guard !review.changes.isEmpty else {
                core.document.post(AppWarning(
                    id: resultNoteID, severity: review.refusals.isEmpty ? .info : .warning,
                    title: String(format: NSLocalizedString("“%@” changes nothing that can be brought back", comment: "Spreadsheet import note when nothing applies; file name"), url.lastPathComponent),
                    message: text.body, source: NSLocalizedString("Spreadsheet", comment: "Status note source for spreadsheet import"),
                    isDismissible: true, timestamp: Date()))
                return nil
            }
            let alert = NSAlert()
            alert.messageText = text.title
            alert.informativeText = text.body
            alert.addButton(withTitle: applyButtonTitle(changeCount: review.changes.count))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel"))
            let answer = ZenitModalPresenter.runAlert(alert, identifier: reviewIdentifier, answerWithoutAUser: .button(1))
            guard answer.buttonIndex == 0 else { return nil }
            let edits = review.changes.compactMap { change in
                UUID(uuidString: change.markupID).map { SpreadsheetCellEdit(markupID: $0, columnKey: change.key, text: change.after) }
            }
            let receipt = try await core.applySpreadsheetEdits(edits)
            core.document.post(AppWarning(
                id: resultNoteID, severity: receipt.refused.isEmpty && review.refusals.isEmpty ? .info : .warning,
                title: resultTitle(applied: receipt.applied, fileName: url.lastPathComponent),
                message: receipt.refused.isEmpty && review.refusals.isEmpty
                    ? NSLocalizedString("Undo takes them all back in one step.", comment: "Spreadsheet import result detail")
                    : LocalizedPlural.string(
                        "%lld cells were not applied; the review listed why. Undo takes the rest back in one step.",
                        count: receipt.refused.count + review.refusals.count,
                        one: NSLocalizedString("%lld cell was not applied; the review listed why. Undo takes the rest back in one step.", comment: "Spreadsheet import result detail with one refusal"),
                        other: NSLocalizedString("%lld cells were not applied; the review listed why. Undo takes the rest back in one step.", comment: "Spreadsheet import result detail with refusals")
                    ),
                source: NSLocalizedString("Spreadsheet", comment: "Status note source for spreadsheet import"),
                isDismissible: true, timestamp: Date()))
            // `applySpreadsheetEdits` lands as one bus batch, which the document counts itself;
            // marking it again kept the tab edited after ⌘Z, and edited when nothing applied
            // (R-018).
            return receipt
        } catch {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("“%@” was not imported", comment: "Overlay import refusal headline; the file name"), url.lastPathComponent)
            alert.informativeText = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            alert.alertStyle = .warning
            ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, answerWithoutAUser: .button(0))
            return nil
        }
    }
}
