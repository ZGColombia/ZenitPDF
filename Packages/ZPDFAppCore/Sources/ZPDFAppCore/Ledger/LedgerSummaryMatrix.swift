import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

extension TakeoffSession {

    /// A summary matrix (NL-QTY-09) built from three projections of the one aggregation core:
    /// grouped by rows then columns (the cells and the row totals), grouped by columns alone
    /// (the column totals), and the grand total. Nothing is re-added here, so every total is
    /// the ledger's own number and the matrix reconciles with the ledger by construction
    /// (QUALITY_BAR A5, A7). A cell whose rows carry different units says so in words (A11).
    public func summaryMatrix(
        rows rowColumn: LedgerColumnID,
        columns columnColumn: LedgerColumnID,
        filter: LedgerFilterGroup
    ) throws -> LedgerMatrix {
        let valueID = LedgerDefaultColumns.valueColumnID
        func cell(_ totals: LedgerTotals) -> LedgerMatrix.Cell {
            LedgerMatrix.Cell(
                text: totals.displayValues[valueID] ?? "",
                quantity: totals.quantities[valueID],
                rowCount: totals.rowCount
            )
        }
        let nested = try ledgerProjection(LedgerRequest(grouping: [rowColumn, columnColumn], filter: filter))
        let across = try ledgerProjection(LedgerRequest(grouping: [columnColumn], filter: filter))
        let columnKeys = across.rootGroups.map { $0.groupingValue ?? $0.title }
        var cells: [[LedgerMatrix.Cell]] = []
        for group in nested.rootGroups {
            var byKey: [String: LedgerMatrix.Cell] = [:]
            for child in group.children { byKey[child.groupingValue ?? child.title] = cell(child.totals) }
            cells.append(columnKeys.map { byKey[$0] ?? .empty })
        }
        return LedgerMatrix(
            rowColumn: rowColumn,
            columnColumn: columnColumn,
            rowTitles: nested.rootGroups.map(\.title),
            columnTitles: across.rootGroups.map(\.title),
            cells: cells,
            rowTotals: nested.rootGroups.map { cell($0.totals) },
            columnTotals: across.rootGroups.map { cell($0.totals) },
            grandTotal: cell(nested.grandTotals)
        )
    }
}

extension AppLedgerPresenter: LedgerMatrixProviding {
    public func matrix(rows: LedgerColumnID, columns: LedgerColumnID) async throws -> LedgerMatrix {
        guard let buildMatrix else { throw DocumentCommandError.ledgerFailed("no document") }
        return try await buildMatrix(rows, columns, filter)
    }
}
