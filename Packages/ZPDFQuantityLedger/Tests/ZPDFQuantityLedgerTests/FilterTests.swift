import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Filtering")
struct FilterTests {

    private static let areaColumn = SyntheticLedger.columnID(.planArea)
    private static let subjectColumn = SyntheticLedger.columnID(.subject)
    private static let costColumn = SyntheticLedger.costColumnID

    private static var concrete: LedgerFilterNode {
        .rule(LedgerFilterRule(column: subjectColumn, op: .equals, value: .text("Concrete")))
    }

    private static var bigAreas: LedgerFilterNode {
        .rule(
            LedgerFilterRule(
                column: areaColumn,
                op: .greaterThan,
                value: .quantity(.area(500))
            )
        )
    }

    @Test("A filtered view is a strict subset, asserted on ids")
    func strictSubset() throws {
        let store = try BigLedger.store()
        let all = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        let filtered = store.makeView(
            LedgerViewSpec(filter: Self.concrete, aggregation: SyntheticLedger.plan)
        )
        let allIDs = Set(all.orderedRowIndices.map { store.markupID(at: $0) })
        let filteredIDs = Set(filtered.orderedRowIndices.map { store.markupID(at: $0) })
        #expect(filteredIDs.isSubset(of: allIDs))
        #expect(filteredIDs.count < allIDs.count)
        #expect(!filteredIDs.isEmpty)
    }

    @Test("Every filtered subtotal equals a full recomputation over the visible rows")
    func subtotalsMatchRecomputation() throws {
        let store = try BigLedger.store()
        let view = store.makeView(
            LedgerViewSpec(
                filter: .and([Self.concrete, Self.bigAreas]),
                grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))],
                aggregation: SyntheticLedger.plan
            )
        )
        #expect(view.rowCount > 0)
        for column in [Self.areaColumn, Self.costColumn] {
            let grand = try exactDecimal(view.grandTotal[column])
            let reference = SyntheticLedger.referenceSum(
                store,
                column: column,
                rows: view.orderedRowIndices
            )
            #expect(grand == reference)
            var sumOfGroups = Decimal.zero
            for root in view.tree.roots {
                let subtotal = try exactDecimal(root.aggregates[column])
                sumOfGroups += subtotal
                #expect(
                    subtotal == SyntheticLedger.referenceSum(
                        store,
                        column: column,
                        rows: root.allRowIndices()
                    )
                )
            }
            #expect(sumOfGroups == grand)
        }
    }

    @Test("Applying the same filter twice equals applying it once")
    func idempotence() throws {
        let store = try BigLedger.store()
        let once = store.makeView(LedgerViewSpec(filter: Self.concrete))
        let twice = store.makeView(LedgerViewSpec(filter: .and([Self.concrete, Self.concrete])))
        #expect(once.orderedRowIndices == twice.orderedRowIndices)
    }

    @Test("Filter composition commutes")
    func commutativity() throws {
        let store = try BigLedger.store()
        let ab = store.makeView(LedgerViewSpec(filter: .and([Self.concrete, Self.bigAreas])))
        let ba = store.makeView(LedgerViewSpec(filter: .and([Self.bigAreas, Self.concrete])))
        #expect(ab.orderedRowIndices == ba.orderedRowIndices)
    }

    @Test("A filter and its complement partition the ledger and its total")
    func complement() throws {
        let store = try BigLedger.store()
        let plan = LedgerAggregationPlan(keys: [
            AggregateKey(column: Self.areaColumn, function: .sum)
        ])
        let inside = store.makeView(LedgerViewSpec(filter: Self.concrete, aggregation: plan))
        let outside = store.makeView(
            LedgerViewSpec(filter: .not(Self.concrete), aggregation: plan)
        )
        let insideSet = Set(inside.orderedRowIndices)
        let outsideSet = Set(outside.orderedRowIndices)
        #expect(insideSet.isDisjoint(with: outsideSet))
        #expect(insideSet.union(outsideSet).count == store.rowCount)

        let insideTotal = try exactDecimal(inside.grandTotal[Self.areaColumn])
        let outsideTotal = try exactDecimal(outside.grandTotal[Self.areaColumn])
        #expect(
            insideTotal + outsideTotal
                == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount)
        )
    }

    @Test("Clearing a filter restores bit-identical totals")
    func roundTrip() throws {
        let store = try BigLedger.store()
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(aggregation: SyntheticLedger.plan)
        )
        let before = try exactDecimal(coordinator.view.grandTotal[Self.areaColumn])
        coordinator.apply(.setFilter(Self.concrete))
        #expect(coordinator.view.rowCount < store.rowCount)
        coordinator.apply(.setFilter(.all))
        let after = try exactDecimal(coordinator.view.grandTotal[Self.areaColumn])
        #expect(before == after)
        #expect(coordinator.view.rowCount == store.rowCount)
    }

    @Test("Filter-then-group and group-then-filter agree")
    func filterGroupOrderIndependence() throws {
        let store = try BigLedger.store()
        let levels = [LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))]
        let grouped = store.makeView(
            LedgerViewSpec(filter: Self.concrete, grouping: levels, aggregation: SyntheticLedger.plan)
        )
        // Group first, then filter each group's rows by hand and re-aggregate.
        let ungrouped = store.makeView(
            LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
        )
        let evaluator = LedgerFilterEvaluator(store: store)
        let aggregator = LedgerAggregator(store: store, plan: SyntheticLedger.plan)
        var byKey: [LedgerGroupKey: Decimal] = [:]
        for root in ungrouped.tree.roots {
            let visible = evaluator.filter(root.allRowIndices(), with: Self.concrete)
            byKey[root.key] = try exactDecimal(aggregator.aggregate(rowIndices: visible)[Self.areaColumn])
        }
        for root in grouped.tree.roots {
            #expect(try exactDecimal(root.aggregates[Self.areaColumn]) == byKey[root.key])
        }
        #expect(Set(grouped.tree.roots.map(\.key)) == Set(byKey.keys))
    }

    @Test("Operators behave, and an errored cell never matches a value predicate")
    func operatorBehaviour() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.textColumn: .text("Alpha beta"), HandBuiltLedger.valueColumn: .number(.length(1))],
            [HandBuiltLedger.textColumn: .text("gamma"), HandBuiltLedger.valueColumn: .number(.length(5))],
            [:]
        ])
        let evaluator = LedgerFilterEvaluator(store: store)
        let all = Array(0..<store.rowCount)

        let contains = evaluator.filter(
            all,
            with: .rule(LedgerFilterRule(column: HandBuiltLedger.textColumn, op: .contains, value: .text("BETA")))
        )
        #expect(contains == [0])

        let begins = evaluator.filter(
            all,
            with: .rule(LedgerFilterRule(column: HandBuiltLedger.textColumn, op: .beginsWith, value: .text("alp")))
        )
        #expect(begins == [0])

        let between = evaluator.filter(
            all,
            with: .rule(
                LedgerFilterRule(
                    column: HandBuiltLedger.valueColumn,
                    op: .between,
                    value: .numberRange(lower: 2, upper: 10)
                )
            )
        )
        #expect(between == [1])

        let empties = evaluator.filter(
            all,
            with: .rule(LedgerFilterRule(column: HandBuiltLedger.textColumn, op: .isEmpty))
        )
        #expect(empties == [2])

        #expect(evaluator.filter(all, with: .and([])) == all)
        #expect(evaluator.filter(all, with: .or([])).isEmpty)
    }
}
