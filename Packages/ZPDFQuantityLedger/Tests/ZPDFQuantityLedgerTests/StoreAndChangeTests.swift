import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Index-addressed store")
struct StoreTests {

    @Test("Rows are fetched by index and located by id")
    func indexAddressing() throws {
        let store = try BigLedger.store()
        #expect(store.rowCount == BigLedger.rowCount)
        let target = store.markupID(at: 73_421)
        #expect(store.index(of: target) == 73_421)
        #expect(store.row(at: 73_421).markupID == target)
        #expect(store.index(of: MarkupID(UUID())) == nil)
    }

    @Test("Built-in column and status ids are stable and collision-free")
    func deterministicIdentifiers() throws {
        var seen = Set<UUID>()
        for column in StandardLedgerColumn.allCases {
            let id = LedgerIdentifiers.columnID(for: column)
            #expect(seen.insert(id.rawValue).inserted, "collision on \(column)")
            #expect(id == LedgerIdentifiers.columnID(for: column))
        }
        for status in MarkupStatus.allCases {
            let id = LedgerIdentifiers.choiceOptionID(for: status)
            #expect(seen.insert(id.rawValue).inserted, "collision on \(status)")
            #expect(LedgerStatusChoices.optionValue(id) == status.rawValue)
        }
    }

    @Test("The full built-in column set of spec 15.2 builds and compiles")
    func standardColumnSet() throws {
        let columns = try LedgerColumnSet.standard()
        #expect(columns.count == StandardLedgerColumn.allCases.count)
        #expect(columns.column(standard: .planArea)?.dimension == .area)
        #expect(columns.column(standard: .status)?.kind == .choice)
        #expect(columns.column(standard: .status)?.choices.count == MarkupStatus.allCases.count)
    }

    @Test("A duplicate column key is refused")
    func duplicateKeysRefused() {
        let first = ColumnID(UUID())
        let second = ColumnID(UUID())
        #expect(throws: LedgerError.self) {
            _ = try LedgerColumnSet(columns: [
                LedgerColumnDefinition(id: first, key: "k", title: "A", kind: .text, order: 0),
                LedgerColumnDefinition(id: second, key: "k", title: "B", kind: .text, order: 1)
            ])
        }
    }
}

@Suite("Change propagation")
struct ChangePropagationTests {

    @Test("Each mutation reports only what it changed")
    func narrowChangeSets() throws {
        let store = try BigLedger.store()
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(aggregation: SyntheticLedger.plan)
        )

        let filtered = coordinator.apply(
            .setFilter(
                .rule(
                    LedgerFilterRule(
                        column: SyntheticLedger.columnID(.subject),
                        op: .equals,
                        value: .text("Steel")
                    )
                )
            )
        )
        #expect(filtered.change == [.filter, .rows, .totals])

        let grouped = coordinator.apply(
            .setGrouping([LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))])
        )
        #expect(grouped.change == [.grouping, .rows, .totals])

        let columnsChanged = coordinator.apply(
            .setVisibleColumns([SyntheticLedger.columnID(.subject), SyntheticLedger.costColumnID])
        )
        #expect(columnsChanged.change == [.columns])
        #expect(columnsChanged.view.columns.count == 2)

        // Re-applying the same value is not a change, so a view that binds to this does not
        // redraw 100 000 rows because a control re-emitted its current state.
        #expect(coordinator.apply(.setGrouping(coordinator.view.spec.grouping)).change == .none)
    }

    @Test("Replacing the store changes rows and totals, not the layout")
    func storeReplacement() throws {
        let small = try SyntheticLedger.makeStore(rowCount: 500)
        var coordinator = LedgerCoordinator(
            store: small,
            spec: LedgerViewSpec(aggregation: SyntheticLedger.plan)
        )
        #expect(try exactDecimal(coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)])
            == SyntheticLedger.expectedPlanArea(rowCount: 500))

        let larger = try SyntheticLedger.makeStore(rowCount: 900)
        let update = coordinator.apply(.replaceStore(larger))
        #expect(update.change == [.rows, .totals])
        #expect(try exactDecimal(coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)])
            == SyntheticLedger.expectedPlanArea(rowCount: 900))
    }
}
