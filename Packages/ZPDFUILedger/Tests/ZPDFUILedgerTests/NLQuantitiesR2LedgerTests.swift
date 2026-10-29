import AppKit
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Quantities round 2 in the table: child rows step in under their source (NL-QTY-07), and
/// the Explain model.
@MainActor
@Suite("Quantities round 2 — ledger table", .ledgerTierSerialised)
struct NLQuantitiesR2LedgerTests {

    @Test("A child row's leading cell is stepped in by one indent; a heading never is")
    func childIndent() {
        let cell = LedgerCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        let column = LedgerColumn(id: .subject, title: "Subject", kind: .text, width: 100)
        cell.configure(text: "Studs", column: column, swatchColor: .red, isDimmed: false,
                       accessibilityLabel: "Studs", indent: LedgerCellView.childIndent)
        #expect(cell.indent == LedgerCellView.childIndent)
        #expect(LedgerCellView.childIndent > 0)
        cell.configureAsGroup(text: "Wall", column: column, isHeading: true, swatchColor: nil, accessibilityLabel: "Wall")
        #expect(cell.indent == 0, "a reused cell does not keep a child's indent")
        cell.configure(text: "Wall W1", column: column, swatchColor: nil, isDimmed: false, accessibilityLabel: "Wall W1")
        #expect(cell.indent == 0)
    }
}
