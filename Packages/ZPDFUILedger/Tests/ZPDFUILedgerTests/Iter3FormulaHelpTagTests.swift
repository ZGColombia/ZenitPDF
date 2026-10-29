import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Quality-loop iteration 3, area "ui-presentation-measure", T-057 (the table half): a failed
/// formula cell shows the engine's diagnostic as its help tag and VoiceOver help. No window:
/// the cells are vended straight from the controller's data source.
@MainActor
@Suite("Iteration 3 ui-presentation-measure (formula error help tag)", .ledgerTierSerialised)
struct Iter3FormulaHelpTagTests {

    /// Old output: nothing in the table read `LedgerCellError.detail`; an error cell had no help
    /// tag, so "Formula error" never said which operand failed or why.
    @Test("T-057: an error cell carries its diagnostic; every other cell carries none")
    func errorCellHelpTag() throws {
        let note = "Division by zero in `[Total Cost] / [Count]`."
        var rows = LedgerFixtures.rows
        rows[1].displayValues[LedgerFixtures.wasteFactor] = "Divide by zero"
        rows[1].cellNotes = [LedgerFixtures.wasteFactor: note]
        let controller = LedgerTableController(rowSource: LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns))
        controller.loadViewIfNeeded()
        let table = controller.mainTableViewForTesting
        let waste = try #require(table.tableColumns.first { $0.identifier.rawValue == LedgerFixtures.wasteFactor.rawValue })

        let failed = try #require(controller.tableView(table, viewFor: waste, row: 1) as? LedgerCellView)
        #expect(failed.textField?.stringValue == "Divide by zero")
        #expect(failed.textField?.toolTip == note, "old output: nil")
        #expect(failed.textField?.accessibilityHelp() == note, "old output: nil")

        // The same column on a row that did not fail, and another column of the failed row.
        let fine = try #require(controller.tableView(table, viewFor: waste, row: 0) as? LedgerCellView)
        #expect(fine.textField?.toolTip == nil)
        #expect(fine.textField?.accessibilityHelp() == nil)
        let subject = try #require(table.tableColumns.first { $0.identifier.rawValue == LedgerColumnID.subject.rawValue })
        let sameRow = try #require(controller.tableView(table, viewFor: subject, row: 1) as? LedgerCellView)
        #expect(sameRow.textField?.toolTip == nil)

        // A reused cell view never keeps another row's diagnostic.
        failed.configure(text: "0.10", column: LedgerFixtures.columns[9], swatchColor: nil, isDimmed: false, accessibilityLabel: "Waste Factor: 0.10")
        #expect(failed.textField?.toolTip == nil)
        #expect(failed.textField?.accessibilityHelp() == nil)
    }
}
