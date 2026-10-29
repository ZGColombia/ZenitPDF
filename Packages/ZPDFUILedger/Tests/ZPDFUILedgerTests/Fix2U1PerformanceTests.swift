import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Measurements for IM-097 (outline item cache) and IM-202 (per-cell column lookups).
///
/// Each test prints its timing as `FIX2U1-PERF <name> <ms>` so the same file, run against
/// the code before and after the change, gives the before/after pair; the assertions are
/// generous ceilings, not the evidence.
@MainActor
@Suite("Fix2 U1 performance", .ledgerTierSerialised)
struct Fix2U1PerformanceTests {

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @Test("IM-097: group item lookups on a three-level plan over 100 000 rows")
    func groupItemLookup() throws {
        // A supplied three-level outline (5 × 8 × 25 groups of 100 rows), the shape a core
        // outline hands the table; the table builds no outline of its own since C-04.
        let rows = 100_000
        let grouping: [LedgerColumnID] = [.projectZone, .trade, .subject]
        func level(_ depth: Int, count: Int, rowsEach: Int) -> [LedgerPrecomputedGroup] {
            (0..<count).map { index in
                let children = depth + 1 < grouping.count
                    ? level(depth + 1, count: depth == 0 ? 8 : 25, rowsEach: rowsEach / (depth == 0 ? 8 : 25))
                    : []
                return LedgerPrecomputedGroup(
                    title: "G\(depth)-\(index)", column: grouping[depth], value: "g\(depth)-\(index)",
                    rowCount: rowsEach, subtotals: .empty, children: children
                )
            }
        }
        let plan = try #require(LedgerGroupPlan.precomputed(
            rowCount: rows, groups: level(0, count: 5, rowsEach: rows / 5),
            grandSubtotals: .empty, groupingColumns: grouping
        ))
        #expect(plan.groupCount == 5 + 5 * 8 + 5 * 8 * 25)
        let cache = LedgerOutlineItemCache()
        let top = plan.groups
        #expect(!top.isEmpty)
        for slice in top { _ = cache.item(for: slice) }
        let lookups = 20_000
        let elapsed = Self.milliseconds {
            for index in 0..<lookups { _ = cache.item(for: top[index % top.count]) }
        }
        print("FIX2U1-PERF im097-group-lookup-\(lookups) \(String(format: "%.2f", elapsed)) ms (\(top.count) top groups, levels \(grouping.count))")
        #expect(elapsed < 60_000)
    }

    @Test("IM-097: inserting 100 000 row items into a full cache")
    func rowItemEviction() {
        let cache = LedgerOutlineItemCache(rowLimit: 4096)
        let elapsed = Self.milliseconds {
            for position in 0..<100_000 { _ = cache.item(displayPosition: position) }
        }
        print("FIX2U1-PERF im097-row-insert-100000 \(String(format: "%.2f", elapsed)) ms")
        #expect(cache.residentRowCount <= 4096)
    }

    @Test("IM-202: drawing 20 rows x 500 columns of cells")
    func wideTableCells() {
        let columnCount = 500
        var columns: [LedgerColumn] = []
        for index in 0..<columnCount {
            columns.append(LedgerColumn(id: .custom("c\(index)"), title: "C\(index)", kind: .text, width: 60))
        }
        var rows: [LedgerRow] = []
        for index in 0..<20 {
            var values: [LedgerColumnID: LedgerCellValue] = [:]
            var display: [LedgerColumnID: String] = [:]
            for column in columns {
                values[column.id] = .text("r\(index)")
                display[column.id] = "r\(index)"
            }
            rows.append(LedgerRow(
                markupID: UUID(), values: values, displayValues: display,
                colorRGBA: ColorRGBA.Zenit.Dark.cyan, kind: .measurement
            ))
        }
        let source = LedgerArrayRowSource(rows: rows, columns: columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let table = controller.mainTableViewForTesting
        let tableColumns = table.tableColumns
        #expect(tableColumns.count >= columnCount)
        var cells = 0
        let elapsed = Self.milliseconds {
            for row in 0..<20 {
                for tableColumn in tableColumns {
                    if controller.tableView(table, viewFor: tableColumn, row: row) != nil { cells += 1 }
                }
            }
        }
        print("FIX2U1-PERF im202-cells-\(cells) \(String(format: "%.2f", elapsed)) ms")

        // The lookup the change replaced, isolated from view creation (which dominates the
        // figure above): the old per-cell `columns.first(where:)` against the new index.
        let ids = tableColumns.map { LedgerColumnID($0.identifier.rawValue) }
        let all = controller.columns
        var found = 0
        let linear = Self.milliseconds {
            for _ in 0..<20 { for id in ids where all.first(where: { $0.id == id }) != nil { found += 1 } }
        }
        let indexed = Self.milliseconds {
            for _ in 0..<20 { for id in ids where controller.column(id) != nil { found += 1 } }
        }
        print("FIX2U1-PERF im202-lookup-linear \(String(format: "%.2f", linear)) ms indexed \(String(format: "%.2f", indexed)) ms")
        #expect(found == 2 * 20 * ids.count)
        #expect(cells >= 20 * columnCount)
    }
}
