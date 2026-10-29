import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// U-056 / ADR-0039: the Waste and Order preset's
/// totals through the shipping presenter seam and command bus.
///
/// Hand-derived, 0.1 m/pt. Row 0: 97.3 × 100 pt = 9.73 m × 10 m = 97.3 m², waste 0.10, pack
/// 2.88 m². Row 1: 50 × 100 pt = 5 m × 10 m = 50 m², no waste, pack 2.88 m².
/// - Order: 97.3 × 1.10 = 107.03; 107.03 / 2.88 = 37.163… → 38. 50 / 2.88 = 17.361… → 18.
///   Grand total 56.
/// - Pack size: no total. Before ADR-0039 the grand total printed 2.88 + 2.88 = 5.76 m² and
///   Order had no total at all.
@Suite("Iteration 4 — Waste and Order totals through the presenter")
@MainActor
struct Iter4LedgerWasteAndOrderTotalsTests {

    let bugs = NLQuantitiesBugTests()

    @Test("U-056: the grand total and the Subject groups show Order and no Pack size total")
    func wasteAndOrderTotals() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(97.3, 100), (50, 100)])
        let columns = try #require(fixture.environment.ledger as? any LedgerColumnManaging)
        let waste = LedgerColumnID.custom(UUID().uuidString)
        let pack = LedgerColumnID.custom(UUID().uuidString)
        let gross = LedgerColumnID.custom(UUID().uuidString)
        let order = LedgerColumnID.custom(UUID().uuidString)
        // The four specs `LedgerColumnManagerModel.addWasteAndOrderColumns(basis: .area)` adds
        // (ZPDFUILedgerTests NLQuantitiesColumnManagerModelTests.wasteAndOrderPreset holds the
        // model to them).
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
        var edit = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue], values: [waste: .number(Decimal(string: "0.10")!), pack: packSize]
        ))
        #expect(!edit.didFail, "\(edit.failureDescription ?? "")")
        edit = await editor.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [fixture.ids[1].rawValue], values: [pack: packSize]))
        #expect(!edit.didFail, "\(edit.failureDescription ?? "")")
        await fixture.environment.ledger.refresh()

        // The declared columns: Order is a count, Pack size is flagged.
        let orderDefinition = try #require(await fixture.session.ledgerColumns.column(key: order.rawValue))
        let packDefinition = try #require(await fixture.session.ledgerColumns.column(key: pack.rawValue))
        // Old output: Order declared `.ratio` (area / area), Pack size unflagged.
        #expect(orderDefinition.dimension == .count)
        #expect(packDefinition.neverSums == true)

        // The presented columns: Order totals, Pack size does not.
        let presentedOrder = try #require(fixture.environment.ledger.columns.first { $0.id == order })
        let presentedPack = try #require(fixture.environment.ledger.columns.first { $0.id == pack })
        #expect(presentedOrder.aggregate == .sum)
        #expect(presentedPack.aggregate == nil)

        // Grand totals. Old output: no Order entry; Pack size 5.76 m².
        let totals = fixture.environment.ledger.grandTotals
        #expect(totals.quantities[order] == DecimalQuantity(value: 56, dimension: .count))
        #expect(totals.quantities[pack] == nil)
        #expect(totals.quantities[gross] == DecimalQuantity(value: Decimal(string: "157.03")!, dimension: .area))

        // Group totals by Subject ("Slab 0", "Slab 1").
        fixture.environment.ledger.setGrouping([.subject])
        await fixture.environment.ledger.refresh()
        let groups = fixture.environment.ledger.rootGroups
        #expect(groups.map(\.title) == ["Slab 0", "Slab 1"])
        #expect(groups.map { $0.totals.quantities[order] } == [
            DecimalQuantity(value: 38, dimension: .count), DecimalQuantity(value: 18, dimension: .count)
        ])
        #expect(groups.allSatisfy { $0.totals.quantities[pack] == nil })

        // The flag survives another edit through the Column Manager seam.
        var specs = columns.userColumnSpecs
        let packIndex = try #require(specs.firstIndex { $0.id == pack })
        #expect(specs[packIndex].neverSums)
        specs[packIndex].decimalPlaces = 2
        let edited = await columns.applyColumnSpecs(specs, actionName: "Edit Column")
        #expect(!edited.didFail, "\(edited.failureDescription ?? "")")
        #expect(await fixture.session.ledgerColumns.column(key: pack.rawValue)?.neverSums == true)
    }
}
