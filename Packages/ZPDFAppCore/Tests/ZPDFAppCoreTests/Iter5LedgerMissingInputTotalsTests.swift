import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// V-058 / ADR-0040: a Waste and Order row with no
/// pack size has no order, and the Order total is the sum over the rows that have one — through
/// the shipping presenter seam.
///
/// Hand-derived, 0.1 m/pt, as Iter4LedgerWasteAndOrderTotalsTests. Row 0: 97.3 m², waste 0.10,
/// pack 2.88 m² → Gross 107.03 m², Order ⌈37.163…⌉ = 38. Row 1: 50 m², no waste, **no pack
/// size** → Gross 50 m², no Order. Totals: Gross 157.03 m², Order 38.
@Suite("Iteration 5 — a blank formula input through the presenter (V-058)")
@MainActor
struct Iter5LedgerMissingInputTotalsTests {

    let bugs = NLQuantitiesBugTests()

    @Test("V-058: a row without a pack size reads No input and the Order total still sums")
    func orderTotalSkipsRowsWithoutAPackSize() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(97.3, 100), (50, 100)])
        let columns = try #require(fixture.environment.ledger as? any LedgerColumnManaging)
        let waste = LedgerColumnID.custom(UUID().uuidString)
        let pack = LedgerColumnID.custom(UUID().uuidString)
        let gross = LedgerColumnID.custom(UUID().uuidString)
        let order = LedgerColumnID.custom(UUID().uuidString)
        let receipt = await columns.applyColumnSpecs([
            LedgerColumnSpec(id: waste, title: "Waste", kind: .number, dimension: .ratio, decimalPlaces: 2),
            LedgerColumnSpec(id: pack, title: "Pack size", kind: .number, dimension: .area, neverSums: true),
            LedgerColumnSpec(id: gross, title: "Gross", kind: .formula, formulaSource: "Area * (1 + COALESCE([Waste], 0))"),
            LedgerColumnSpec(
                id: order, title: "Order", kind: .formula, decimalPlaces: 0,
                formulaSource: "CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)"
            )
        ], actionName: "Add Waste and Order Columns")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")

        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        let packSize = ZPDFUIPresentation.LedgerCellValue.quantity(DecimalQuantity(value: Decimal(string: "2.88")!, dimension: .area))
        let edit = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue], values: [waste: .number(Decimal(string: "0.10")!), pack: packSize]
        ))
        #expect(!edit.didFail, "\(edit.failureDescription ?? "")")
        await fixture.environment.ledger.refresh()

        // The row with no pack size says why it has no order, and the help tag names the input.
        let ledger = fixture.environment.ledger
        let blankRow = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }
            .first { $0.markupID == fixture.ids[1].rawValue })
        #expect(blankRow.displayValue(order) == "No input", "old output: Formula error")
        #expect(blankRow.cellNote(order)?.contains("blank") == true, "\(blankRow.cellNote(order) ?? "")")

        // Old output: Gross and Order grand totals absent — the refused total — because one row
        // had nothing to divide by.
        let totals = ledger.grandTotals
        #expect(totals.quantities[order] == DecimalQuantity(value: 38, dimension: .count))
        #expect(totals.quantities[gross] == DecimalQuantity(value: Decimal(string: "157.03")!, dimension: .area))
    }
}
