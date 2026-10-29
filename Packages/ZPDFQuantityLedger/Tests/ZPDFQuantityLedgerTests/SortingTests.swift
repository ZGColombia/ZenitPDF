import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Sorting")
struct SortingTests {

    @Test("Sorting is stable: equal keys keep their store order")
    func stability() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: Array(repeating: [HandBuiltLedger.textColumn: LedgerCellValue.text("same")], count: 200)
        )
        let sorter = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.textColumn)]
        )
        #expect(sorter.sorted(Array(0..<200)) == Array(0..<200))
        let descending = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.textColumn, ascending: false)]
        )
        // Reversing the direction must not reverse rows the comparison calls equal.
        #expect(descending.sorted(Array(0..<200)) == Array(0..<200))
    }

    @Test("Nulls sort to one end and stay there when the direction flips")
    func nullOrdering() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.length(2))],
            [:],
            [HandBuiltLedger.valueColumn: .number(.length(1))],
            [:]
        ])
        let ascending = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.valueColumn)]
        ).sorted(Array(0..<4))
        #expect(ascending == [2, 0, 1, 3])

        let descending = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.valueColumn, ascending: false)]
        ).sorted(Array(0..<4))
        #expect(descending == [0, 2, 1, 3])

        let nullsFirst = LedgerSorter(
            store: store,
            descriptors: [
                LedgerSortDescriptor(column: HandBuiltLedger.valueColumn, nulls: .first)
            ]
        ).sorted(Array(0..<4))
        #expect(nullsFirst == [1, 3, 2, 0])
    }

    @Test("Mixed types order by kind, then within kind")
    func mixedTypeOrdering() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .text("zebra")],
            [HandBuiltLedger.valueColumn: .number(.length(9))],
            [HandBuiltLedger.valueColumn: .checkbox(true)],
            [HandBuiltLedger.valueColumn: .number(.length(1))]
        ])
        let sorted = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.valueColumn)]
        ).sorted(Array(0..<4))
        // numbers (rank 0) before checkbox (rank 2) before text (rank 5).
        #expect(sorted == [3, 1, 2, 0])
    }

    @Test("Different dimensions never interleave in a sort")
    func dimensionsDoNotInterleave() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.area(1))],
            [HandBuiltLedger.valueColumn: .number(.length(1000))],
            [HandBuiltLedger.valueColumn: .number(.area(2))],
            [HandBuiltLedger.valueColumn: .number(.length(1))]
        ])
        let sorted = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.valueColumn)]
        ).sorted(Array(0..<4))
        #expect(sorted == [3, 1, 0, 2])
    }

    @Test("Identifier comparison is locale-independent")
    func identifierComparison() {
        // Under a Turkish collation "I".lowercased() is "ı", which reorders these. Scalar order
        // does not care what locale the machine is set to.
        #expect(LedgerOrdering.compareIdentifiers("I", "i") == .orderedAscending)
        #expect(LedgerOrdering.compareIdentifiers("ABC", "ABCD") == .orderedAscending)
        #expect(LedgerOrdering.compareIdentifiers("abc", "abc") == .orderedSame)
        let uuidA = "00000000-0000-0000-0000-000000000001"
        let uuidB = "00000000-0000-0000-0000-000000000002"
        #expect(LedgerOrdering.compareIdentifiers(uuidA, uuidB) == .orderedAscending)
    }

    @Test("A sort changes rows but never a total")
    func sortDoesNotChangeTotals() throws {
        let store = try BigLedger.store()
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(aggregation: SyntheticLedger.plan)
        )
        let before = try exactDecimal(coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)])
        let update = coordinator.apply(
            .setSort([LedgerSortDescriptor(column: SyntheticLedger.costColumnID, ascending: false)])
        )
        #expect(update.change.contains(.sort))
        #expect(update.change.contains(.rows))
        #expect(!update.change.contains(.totals))
        let after = try exactDecimal(coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)])
        #expect(before == after)
    }
}
