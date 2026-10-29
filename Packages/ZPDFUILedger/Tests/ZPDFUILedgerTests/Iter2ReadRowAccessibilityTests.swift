import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Quality-loop iteration 2, area "ui-presentation-measure", S-090 (the table half): a row read
/// from a schedule table says so to VoiceOver in every cell, as a locked row says "locked".
/// No window: the cells are vended straight from the controller's data source.
@MainActor
@Suite("Iteration 2 ui-presentation-measure (read rows in the table)", .ledgerTierSerialised)
struct Iter2ReadRowAccessibilityTests {

    /// Old output: the read row's cells read exactly like a measured row's ("Label: S-02") —
    /// `LedgerRow.provenance` was never set, and the table never looked at it.
    @Test("S-090: every cell of a read row carries 'read from a table'; a measured row's cells do not")
    func readRowSaysSo() throws {
        var rows = LedgerFixtures.rows
        rows[1].provenance = .read
        let controller = LedgerTableController(rowSource: LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns))
        controller.loadViewIfNeeded()
        let table = controller.mainTableViewForTesting
        #expect(!table.tableColumns.isEmpty)
        for column in table.tableColumns {
            let read = try #require(controller.tableView(table, viewFor: column, row: 1) as? LedgerCellView)
            let measured = try #require(controller.tableView(table, viewFor: column, row: 0) as? LedgerCellView)
            let readLabel = read.textField?.accessibilityLabel() ?? ""
            let measuredLabel = measured.textField?.accessibilityLabel() ?? ""
            #expect(readLabel.hasSuffix(", read from a table"), "\(column.identifier.rawValue): \(readLabel)")
            #expect(!measuredLabel.contains("read from a table"), "\(column.identifier.rawValue): \(measuredLabel)")
        }
    }
}
