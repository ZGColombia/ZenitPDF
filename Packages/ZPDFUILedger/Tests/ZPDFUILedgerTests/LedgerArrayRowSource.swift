import Foundation
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// A row source over an in-memory array, for the table tests (test target only since C-04).
///
/// It used to ship in the library, where a grouped table over it folded the rows itself. The
/// table has no fold any more (R-129): every heading and subtotal comes from the source's
/// outline. This source supplies one the way the preview mock does — built by
/// `MockLedgerOutline` from the rows — and hands it to the table through
/// ``LedgerGroupPlanProviding``, with ``LedgerGroupPlan/order`` mapping each display position
/// back to the array, so the rows can stay in whatever order a test wrote them.
@MainActor
final class LedgerArrayRowSource: LedgerIndexedRowProviding, LedgerGroupPlanProviding {

    /// The rows, in source order.
    private(set) var rows: [LedgerRow]
    /// The columns, in display order.
    let columns: [LedgerColumn]
    /// How many outlines the table asked for.
    private(set) var planRequests = 0

    private var positionByMarkupID: [UUID: Int]

    /// Creates a row source over a fixed array.
    init(rows: [LedgerRow], columns: [LedgerColumn]) {
        self.rows = rows
        self.columns = columns
        self.positionByMarkupID = Self.positions(of: rows)
    }

    var ledgerColumns: [LedgerColumn] { columns }
    var ledgerRowCount: Int { rows.count }
    func ledgerRow(at index: Int) -> LedgerRow? {
        rows.indices.contains(index) ? rows[index] : nil
    }
    func ledgerRowIndex(of markupID: UUID) -> Int? { positionByMarkupID[markupID] }

    /// Replaces the rows.
    func replace(rows newRows: [LedgerRow]) {
        rows = newRows
        positionByMarkupID = Self.positions(of: newRows)
    }

    func ledgerGroupPlan(groupingColumns: [LedgerColumnID], columns: [LedgerColumn]) -> LedgerGroupPlan? {
        planRequests += 1
        return Self.plan(rows: rows, groupingColumns: groupingColumns, columns: columns)
    }

    /// The plan the mock's outline gives for `rows`: its groups and totals bridged exactly as a
    /// presenter's are (``LedgerPrecomputedGroup/init(bridging:columns:)``), its order mapped
    /// back to the input rows.
    static func plan(rows: [LedgerRow], groupingColumns: [LedgerColumnID], columns: [LedgerColumn]) -> LedgerGroupPlan? {
        let outline = MockLedgerOutline.build(rows: rows, groupingColumns: groupingColumns, columns: columns)
        guard let grouped = LedgerGroupPlan.precomputed(
            rowCount: rows.count,
            groups: outline.rootGroups.map { LedgerPrecomputedGroup(bridging: $0, columns: columns) },
            grandSubtotals: LedgerSubtotals.bridging(outline.grandTotals, columns: columns),
            groupingColumns: groupingColumns
        ) else { return nil }
        return LedgerGroupPlan(
            order: outline.order,
            groups: grouped.groups,
            grandSubtotals: grouped.grandSubtotals,
            groupingColumns: groupingColumns
        )
    }

    private static func positions(of rows: [LedgerRow]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(rows.count)
        for (position, row) in rows.enumerated() { map[row.markupID] = position }
        return map
    }
}
