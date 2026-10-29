import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Grouping and regrouping")
struct GroupingTests {

    private static let measured: [ColumnID] = [
        SyntheticLedger.columnID(.planArea),
        SyntheticLedger.columnID(.planLength),
        SyntheticLedger.costColumnID,
        SyntheticLedger.doubledColumnID,
        SyntheticLedger.columnID(.count)
    ]

    @Test("Regrouping five ways never changes a total")
    func regroupingInvariance() throws {
        let store = try BigLedger.store()
        let flat = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        var expected: [ColumnID: Decimal] = [:]
        for column in Self.measured {
            expected[column] = try exactDecimal(flat.grandTotal[column])
        }

        for (offset, levels) in SyntheticLedger.groupings(store.columns).enumerated() {
            let view = store.makeView(
                LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
            )
            for column in Self.measured {
                let total = try exactDecimal(view.grandTotal[column])
                #expect(total == expected[column], "grouping \(offset) changed \(column)")
            }
            // Σ subtotal(root) == grand total, exactly (QUALITY_BAR A5).
            for column in Self.measured {
                var sumOfRoots = Decimal.zero
                for root in view.tree.roots {
                    sumOfRoots += try exactDecimal(root.aggregates[column])
                }
                #expect(sumOfRoots == expected[column], "roots of grouping \(offset) do not reconstitute \(column)")
            }
        }
    }

    @Test("Grouping by A, then B, then A again restores bit-identical subtotals")
    func regroupRoundTrip() throws {
        let store = try BigLedger.store()
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let page = LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        let before = coordinator.view.tree.roots.map { node in
            (node.key, node.aggregates[SyntheticLedger.columnID(.planArea)])
        }
        coordinator.apply(.setGrouping([page]))
        coordinator.apply(.setGrouping([subject]))
        let after = coordinator.view.tree.roots.map { node in
            (node.key, node.aggregates[SyntheticLedger.columnID(.planArea)])
        }
        #expect(before.count == after.count)
        for (left, right) in zip(before, after) {
            #expect(left.0 == right.0)
            #expect(left.1 == right.1)
        }
    }

    @Test("Every parent subtotal equals the exact sum of its children")
    func nestedSubtotalsReconcile() throws {
        let store = try BigLedger.store()
        let levels = SyntheticLedger.groupings(store.columns)[3]
        let view = store.makeView(
            LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
        )
        var checked = 0
        try view.tree.forEachNode { node in
            guard !node.isLeaf else { return }
            for column in Self.measured {
                var childSum = Decimal.zero
                for child in node.children {
                    childSum += try exactDecimal(child.aggregates[column])
                }
                let parent = try exactDecimal(node.aggregates[column])
                #expect(childSum == parent)
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("A leaf subtotal equals a recomputation over its own rows")
    func leafSubtotalsMatchIndependentSum() throws {
        let store = try BigLedger.store()
        let levels = SyntheticLedger.groupings(store.columns)[2]
        let view = store.makeView(
            LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
        )
        try view.tree.forEachNode { node in
            guard node.isLeaf else { return }
            let reference = SyntheticLedger.referenceSum(
                store,
                column: SyntheticLedger.columnID(.planArea),
                rows: node.rowIndices
            )
            let subtotal = try exactDecimal(node.aggregates[SyntheticLedger.columnID(.planArea)])
            #expect(subtotal == reference)
        }
    }

    @Test("Every row belongs to exactly one group at each level")
    func partitionIsComplete() throws {
        let store = try BigLedger.store()
        for levels in SyntheticLedger.groupings(store.columns) {
            let view = store.makeView(
                LedgerViewSpec(grouping: levels, aggregation: LedgerAggregationPlan())
            )
            var seen = Set<Int>()
            var duplicated = 0
            view.tree.forEachNode { node in
                guard node.isLeaf else { return }
                for index in node.rowIndices where !seen.insert(index).inserted {
                    duplicated += 1
                }
            }
            #expect(duplicated == 0)
            #expect(seen.count == store.rowCount)
            #expect(view.tree.orderedRowIndices.count == store.rowCount)
        }
    }

    @Test("A null grouping key produces an explicit (none) group, not a disappearance")
    func nullKeysGetTheirOwnGroup() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: [
                [HandBuiltLedger.textColumn: .text("alpha")],
                [:],
                [HandBuiltLedger.textColumn: .text("")],
                [HandBuiltLedger.textColumn: .text("alpha")]
            ]
        )
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: HandBuiltLedger.textColumn)],
                aggregation: HandBuiltLedger.plan([HandBuiltLedger.textColumn], functions: [.count])
            )
        )
        #expect(view.tree.roots.count == 2)
        let none = try #require(view.tree.roots.first { $0.key == .none })
        #expect(none.descendantRowCount == 2)
        #expect(none.key.token == "(none)")
        #expect(view.tree.orderedRowIndices.count == 4)
    }
}
