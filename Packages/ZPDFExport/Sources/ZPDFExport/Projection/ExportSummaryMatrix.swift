import Foundation

/// A two-way summary of the ledger for the workbook's "Summary" sheet and the report's matrix
/// page (NL-QTY-09, NL-QTY-13).
///
/// One grouping down, another across, each cell the `Sum` of one quantity column over the rows in
/// both groups. It is **reshaped, never re-added**: every cell is an ``ExportCell`` the projector
/// already produced — the nested projection's leaf subtotals (the cells), its top-level subtotals
/// (the row totals), the across projection's subtotals (the column totals) and the nested grand
/// total. So a row total is that group's subtotal in the ledger export, a column total is the
/// other grouping's subtotal, and the matrix reconciles with the ledger by construction
/// (QUALITY_BAR A5, A7, A25). A cell whose rows mix units carries the ledger's own refusal token
/// (A11). Nothing here converts, rounds or formats a digit.
public struct ExportSummaryMatrix: Hashable, Sendable {

    /// One matrix for one quantity column.
    public struct Block: Hashable, Sendable {
        public let column: ExportColumn
        /// `cells[row][column]`; ``ExportCell/blank`` where no row falls in both groups.
        public let cells: [[ExportCell]]
        public let rowTotals: [ExportCell]
        public let columnTotals: [ExportCell]
        public let grandTotal: ExportCell

        /// The column header text: title with its unit, as the ledger sheet spells it.
        public var heading: String {
            column.unitSymbol.isEmpty ? column.title : "\(column.title) (\(column.unitSymbol))"
        }
    }

    /// The grouping column keys: down, then across.
    public let rowKey: String
    public let columnKey: String
    public let rowTitles: [String]
    public let columnTitles: [String]
    /// The printed report's titles: a date group reads as a day, as its heading does (BH-532).
    public let printedRowTitles: [String]
    public let printedColumnTitles: [String]
    public let blocks: [Block]
    /// The two grouping columns as the ledger titles them — "Subject", "Page" — for the
    /// matrix's corner and headings (L-46). ``rowKey`` and ``columnKey`` stay the keys.
    public var rowAxisTitle: String = ""
    public var columnAxisTitle: String = ""

    /// The word printed in the corner and on the total line.
    public static let totalTitle = "Total"
    /// The default sheet name in a workbook.
    public static let defaultSheetName = "Summary"

    /// Builds the matrix from two projections of the same filtered ledger.
    ///
    /// - Parameters:
    ///   - nested: grouped by `[rowKey, columnKey]`.
    ///   - across: grouped by `[columnKey]` alone, same filter.
    ///   - columnKeys: the quantity columns to summarise; `nil` takes every numeric column whose
    ///     grand `Sum` is not blank, in column order.
    /// - Throws: ``ExportError/summaryMatrixShape(_:)`` when the two projections are not the
    ///   two groupings this needs; a matrix built from anything else would not reconcile.
    public static func make(
        nested: ExportProjection,
        across: ExportProjection,
        columnKeys: [String]? = nil
    ) throws -> ExportSummaryMatrix {
        let nestedKeys = nested.table.metadata.groupingColumnKeys
        let acrossKeys = across.table.metadata.groupingColumnKeys
        guard nestedKeys.count == 2, acrossKeys == [nestedKeys[1]] else {
            throw ExportError.summaryMatrixShape(
                "expected groupings [row, column] and [column], got \(nestedKeys) and \(acrossKeys)"
            )
        }
        guard nested.table.metadata.rowCount == across.table.metadata.rowCount else {
            throw ExportError.summaryMatrixShape(
                "the two projections cover \(nested.table.metadata.rowCount) and \(across.table.metadata.rowCount) rows"
            )
        }
        let nestedColumns = nested.table.columns
        let acrossIndex = Dictionary(
            across.table.columns.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        func sum(_ totals: [ExportTotalRow], at index: Int?) -> ExportCell {
            guard let index, let row = totals.first(where: { $0.function == "Sum" }), index < row.cells.count
            else { return .blank }
            return row.cells[index]
        }
        let wanted: [Int]
        if let columnKeys {
            wanted = try columnKeys.map { key in
                guard let index = nestedColumns.firstIndex(where: { $0.key == key }) else {
                    throw ExportError.unknownColumn(key)
                }
                return index
            }
        } else {
            wanted = nestedColumns.indices.filter { index in
                guard nestedColumns[index].isNumeric else { return false }
                return sum(nested.table.grandTotals, at: index) != .blank
            }
        }

        let columnGroups = across.table.groups
        let rowGroups = nested.table.groups
        var blocks: [Block] = []
        for index in wanted {
            let column = nestedColumns[index]
            let acrossColumn = acrossIndex[column.key]
            var cells: [[ExportCell]] = []
            for group in rowGroups {
                var byToken: [String: ExportCell] = [:]
                for child in group.subgroups { byToken[child.token] = sum(child.subtotals, at: index) }
                cells.append(columnGroups.map { byToken[$0.token] ?? .blank })
            }
            blocks.append(Block(
                column: column,
                cells: cells,
                rowTotals: rowGroups.map { sum($0.subtotals, at: index) },
                columnTotals: columnGroups.map { sum($0.subtotals, at: acrossColumn) },
                grandTotal: sum(nested.table.grandTotals, at: index)
            ))
        }
        var matrix = ExportSummaryMatrix(
            rowKey: nestedKeys[0],
            columnKey: nestedKeys[1],
            rowTitles: rowGroups.map(\.label),
            columnTitles: columnGroups.map(\.label),
            printedRowTitles: rowGroups.map(\.printedLabel),
            printedColumnTitles: columnGroups.map(\.printedLabel),
            blocks: blocks
        )
        let axisTitles = nested.table.metadata.groupingColumnTitles
        matrix.rowAxisTitle = axisTitles.count == 2 ? axisTitles[0] : nestedKeys[0]
        matrix.columnAxisTitle = axisTitles.count == 2 ? axisTitles[1] : nestedKeys[1]
        return matrix
    }
}

extension ExportProjection {
    /// This projection with a summary matrix attached. The workbook writes it as its own sheet
    /// and the report as its own page; a projection without one exports exactly as before.
    public func withSummaryMatrix(_ matrix: ExportSummaryMatrix?) -> ExportProjection {
        var copy = self
        copy.summaryMatrix = matrix
        return copy
    }
}
