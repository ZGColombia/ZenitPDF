import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Asserts mixed-value handling and the confirmation counts of the bulk-edit panel.
@MainActor
@Suite("Ledger bulk edit", .ledgerTierSerialised)
struct LedgerBulkEditTests {

    private func makeModel(rowIndexes: [Int]) -> LedgerBulkEditModel {
        LedgerBulkEditModel(
            rows: rowIndexes.map { LedgerFixtures.rows[$0] },
            columns: LedgerFixtures.columns
        )
    }

    @Test("Fields the selection agrees on report one value")
    func uniformValue() {
        let model = makeModel(rowIndexes: [0, 1])
        #expect(model.displayState(.subject) == .uniform("Concrete Slab"))
        #expect(model.displayState(.projectZone) == .uniform("Zone A"))
    }

    @Test("Fields the selection disagrees on report mixed and stay untouched")
    func mixedValue() {
        let model = makeModel(rowIndexes: [0, 2])
        #expect(model.displayState(.subject) == .mixed)
        #expect(model.displayState(.status) == .uniform("Approved"))
        #expect(model.summary.isEmpty, "A mixed field is not an edit until the user writes it")
    }

    @Test("The confirmation counts only the markups that really change")
    func changeCount() {
        let model = makeModel(rowIndexes: [0, 1, 2])
        model.setEdit(.text("Slab on Grade"), for: .subject)
        // Rows 0 and 1 already say "Concrete Slab", row 2 says "Interior Partition":
        // all three change, because none of them says "Slab on Grade".
        #expect(model.summary.markupCount == 3)
        #expect(model.summary.fieldCount == 1)

        model.setEdit(.choice("approved"), for: .status)
        // Row 1 is a draft, rows 0 and 2 are already approved.
        #expect(model.summary.changesPerField[.status] == 1)
        #expect(model.summary.fieldCount == 2)
        #expect(model.summary.markupCount == 3)
    }

    @Test("Setting a value the whole selection already has changes nothing")
    func noOpEdit() {
        let model = makeModel(rowIndexes: [0, 1])
        model.setEdit(.text("Concrete Slab"), for: .subject)
        #expect(model.summary.isEmpty)
        #expect(model.summary.message.isEmpty == false)
    }

    @Test("Colour is counted as a field and can be left unchanged")
    func colorEdit() {
        let model = makeModel(rowIndexes: [0, 1])
        #expect(model.colorState == .uniform(ColorRGBA.Zenit.Dark.cyan))
        model.colorEdit = ColorRGBA.Zenit.Dark.green
        #expect(model.summary.changesPerField[.color] == 2)
        model.colorEdit = nil
        #expect(model.summary.isEmpty)
    }

    @Test("Applying hands over the staged edits once and then clears them")
    func applyClears() {
        let model = makeModel(rowIndexes: [0, 1])
        var received: [LedgerColumnID: LedgerCellValue]?
        var receivedIDs: Set<UUID>?
        model.onApply = { edits, _, ids in
            received = edits
            receivedIDs = ids
        }
        model.setEdit(.text("Slab"), for: .subject)
        model.apply()

        #expect(received?[.subject] == .text("Slab"))
        #expect(receivedIDs == Set([LedgerFixtures.rows[0].markupID, LedgerFixtures.rows[1].markupID]))
        #expect(model.summary.isEmpty)
    }

    @Test("Clearing the selection drops staged edits so they cannot leak to new rows")
    func selectionChangeClearsEdits() {
        let model = makeModel(rowIndexes: [0, 1])
        model.setEdit(.text("Slab"), for: .subject)
        model.setSelection(rows: [])
        #expect(model.edits.isEmpty)
        #expect(model.summary.isEmpty)
    }

    @Test("Folding an empty selection is empty, not mixed")
    func emptyFold() {
        let folded: LedgerMixedValue<String> = LedgerMixedValue.folding([nil, nil])
        #expect(folded == .empty)
        #expect(folded.isMixed == false)
        #expect(folded.uniformValue == nil)
    }
}
