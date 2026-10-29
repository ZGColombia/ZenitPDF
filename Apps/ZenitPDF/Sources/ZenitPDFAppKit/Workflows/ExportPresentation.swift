import Foundation
import ZPDFAppCore
import ZPDFExport
import ZPDFUILedger
import ZPDFUIPresentation

/// What the ledger on screen shows, for the formats written from the export projection — the
/// workbook, the printed report, the export profiles, the interchange JSON and the overlay
/// (L-46, L-46b).
///
/// The projection is built from the ledger package's report, which knows column *keys* and
/// stored values. The words and the numbers a person checks are the application's: the column
/// titles ("Plan Area", "Page", "Unit"), the Unit each row shows (L-25 gave the CSV that, and
/// only the CSV), the number locale the ledger's cells are written in, and the filter in words.
/// The workbook headed its columns `planArea (m²)` and `displayUnit`, left Unit empty, and the
/// report wrote "Number locale invariant" with dot decimals under a Swedish ledger. Each value
/// here is read from the same `LedgerProjection` the ledger pane draws — the one rule, not a
/// second copy of it.
@MainActor
enum ExportPresentation {

    /// The ledger's words and numbers for an export of `request`.
    ///
    /// - Parameter grouping: whether numbers carry the locale's thousands separator, as the
    ///   ledger's cells do. A CSV written from the projection passes `false`: its delimiter may be
    ///   that separator (`,` in English), and the CSV writer refuses the collision.
    static func make(
        core: AppCoreEnvironment,
        request: LedgerRequest,
        grouping: Bool = true
    ) async -> LedgerExportPresentation {
        var presentation = LedgerExportPresentation()
        // The columns the ledger draws, then the columns of exactly this export: a report
        // template's own view can show a column the pane does not.
        var titled: [ZPDFUIPresentation.LedgerColumn] = core.ledger.columns
        if let shown = try? await core.session.ledgerProjection(request) {
            titled += shown.columns
            presentation.numberLocale = ExportNumberLocale.forLocale(
                Locale(identifier: shown.formatter.localeIdentifier), grouping: grouping
            )
            presentation.groupLabels = typeGroupLabels(shown.rootGroups)
        }
        // A grouping column the export does not show is still named in its group headings.
        let missing = request.grouping.filter { key in !titled.contains { $0.id == key } }
        if !missing.isEmpty {
            var grouped = LedgerRequest()
            grouped.visibleColumns = missing
            if let named = try? await core.session.ledgerProjection(grouped) { titled += named.columns }
        }
        for column in titled where presentation.columnTitles[column.id.rawValue] == nil {
            presentation.columnTitles[column.id.rawValue] = column.title
        }
        let cells = await rowCells(core: core, request: request)
        presentation.rowUnitTexts = cells.units
        presentation.rowTypeTexts = cells.types
        presentation.filterSummary = filterSummary(request, columns: titled)
        return presentation
    }

    /// What the ledger's Unit and Type columns show on each row of `request`, by markup UUID
    /// string.
    ///
    /// Read from a projection of the same rows that carries only the Type column and the quantity
    /// columns the unit rule looks at (`LedgerDefaultColumns.fallbackCandidates`), so the rows
    /// cost a fraction of the full table's cells. The rules themselves are the ledger's —
    /// `LedgerBridge.primaryUnitText` and the Type cell's tool name, badge and provenance mark —
    /// through the row the projection builds. The rows are read off the main thread.
    static func rowCells(core: AppCoreEnvironment, request: LedgerRequest) async -> (units: [String: String], types: [String: String]) {
        var cellRequest = request
        cellRequest.visibleColumns = [.icon] + LedgerDefaultColumns.fallbackCandidates
        guard let projection = try? await core.session.ledgerProjection(cellRequest) else { return ([:], [:]) }
        return await Task.detached(priority: .userInitiated) {
            var units: [String: String] = [:]
            var types: [String: String] = [:]
            units.reserveCapacity(projection.rowCount)
            types.reserveCapacity(projection.rowCount)
            for index in 0..<projection.rowCount {
                guard let row = projection.row(at: index) else { continue }
                let unit = row.displayValue(LedgerDefaultColumns.unitColumnID)
                if !unit.isEmpty { units[row.markupID.uuidString] = unit }
                let type = row.displayValue(.icon)
                if !type.isEmpty { types[row.markupID.uuidString] = type }
            }
            return (units, types)
        }.value
    }

    /// The headings the ledger gives its Type groups — "Rectangle Area" over a group keyed on
    /// the tool token `rectangleArea` — by group token, for every depth of the outline.
    static func typeGroupLabels(_ groups: [LedgerGroupNode]) -> [String: String] {
        var labels: [String: String] = [:]
        func visit(_ node: LedgerGroupNode) {
            if node.groupingColumn == .icon, let token = node.groupingValue, !node.title.isEmpty {
                labels[token] = node.title
            }
            node.children.forEach(visit)
        }
        groups.forEach(visit)
        return labels
    }

    /// The filter in the words the ledger's CSV banner uses, or `nil` when the export is
    /// neither filtered nor narrowed to selected rows.
    static func filterSummary(_ request: LedgerRequest, columns: [ZPDFUIPresentation.LedgerColumn]) -> String? {
        var parts: [String] = []
        if request.markupScope != nil {
            parts.append(NSLocalizedString("Selected rows only", comment: "Report cover filter line when only the selected rows are exported"))
        }
        if !request.filter.isEmpty {
            parts.append(LedgerExportWriter.describe(filter: request.filter, columns: columns))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
