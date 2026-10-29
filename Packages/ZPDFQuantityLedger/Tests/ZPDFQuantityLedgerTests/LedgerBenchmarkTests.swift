import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// `make benchmark-ledger`, in test form.
///
/// The numbers printed here are not an acceptance claim: no reference machine has been
/// designated for the QUALITY_BAR 4.7 ledger budgets, so none is asserted against them.
/// What this suite does assert is the rule that outlives the machine — **correctness after every
/// benchmarked operation** (QUALITY_BAR 4.7, rule 2). A fast path that produces a wrong subtotal
/// fails here, not only in the correctness suite.
@Suite("Benchmarks over 100 000 rows", .serialized)
struct LedgerBenchmarkTests {

    static let iterations = 12

    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(rank, sorted.count - 1)]
    }

    static func measure(_ label: String, _ body: () throws -> Void) rethrows -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        let p50 = percentile(samples, 0.50)
        let p95 = percentile(samples, 0.95)
        let worst = samples.max() ?? 0
        print(
            String(
                format: "benchmark-ledger  %-28@  n=%d  p50=%.1f ms  p95=%.1f ms  max=%.1f ms",
                label as NSString, iterations, p50, p95, worst
            )
        )
        return samples
    }

    @Test("Group by one column, with subtotals")
    func groupByBenchmark() throws {
        let store = try BigLedger.store()
        let spec = LedgerViewSpec(
            grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))],
            aggregation: SyntheticLedger.plan
        )
        var lastTotal = Decimal.zero
        _ = Self.measure("group-by (1 level)") {
            let view = store.makeView(spec)
            lastTotal = view.grandTotal[SyntheticLedger.columnID(.planArea)]?.decimal ?? -1
        }
        #expect(lastTotal == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount))
    }

    @Test("Regroup to a different key")
    func regroupBenchmark() throws {
        let store = try BigLedger.store()
        let keys = [
            SyntheticLedger.columnID(.pageLabel),
            SyntheticLedger.columnID(.status)
        ]
        var toggle = 0
        var lastTotal = Decimal.zero
        _ = Self.measure("regroup") {
            let spec = LedgerViewSpec(
                grouping: [LedgerGroupingField(column: keys[toggle % keys.count])],
                aggregation: SyntheticLedger.plan
            )
            toggle += 1
            lastTotal = store.makeView(spec).grandTotal[SyntheticLedger.costColumnID]?.decimal ?? -1
        }
        #expect(lastTotal == SyntheticLedger.expectedCost(rowCount: BigLedger.rowCount))
    }

    @Test("Regroup toggle through the coordinator: the grouped-index cache answers")
    func cachedRegroupBenchmark() throws {
        let store = try BigLedger.store()
        let keys = [
            SyntheticLedger.columnID(.pageLabel),
            SyntheticLedger.columnID(.status)
        ]
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(
                grouping: [LedgerGroupingField(column: keys[0])],
                aggregation: SyntheticLedger.plan
            )
        )
        // Pay for each grouping once, outside the timed region.
        coordinator.apply(.setGrouping([LedgerGroupingField(column: keys[1])]))
        coordinator.apply(.setGrouping([LedgerGroupingField(column: keys[0])]))
        var toggle = 1
        var lastTotal = Decimal.zero
        _ = Self.measure("regroup (cache hit)") {
            coordinator.apply(.setGrouping([LedgerGroupingField(column: keys[toggle % keys.count])]))
            toggle += 1
            lastTotal = coordinator.view.grandTotal[SyntheticLedger.costColumnID]?.decimal ?? -1
        }
        #expect(lastTotal == SyntheticLedger.expectedCost(rowCount: BigLedger.rowCount))
    }

    @Test("One-row mutation: incremental regroup instead of a full rebuild")
    func incrementalMutationBenchmark() throws {
        let store = try BigLedger.store()
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let spec = LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        var coordinator = LedgerCoordinator(store: store, spec: spec)

        // Each timed iteration is the whole mutation path: build the edited store (shared
        // arrays plus a sparse overlay, formulas re-run for the one row) and update the
        // filtered, sorted, grouped view incrementally. Target: < 16 ms, one display frame.
        var row = 50_000
        _ = try Self.measure("mutate 1 row (grouped)") {
            var record = coordinator.view.store.record(at: row)
            record.subject = SyntheticLedger.subjects[(row + 1) % SyntheticLedger.subjects.count]
            let measurement = MeasurementResult(values: [
                .count: .count(1),
                .planArea: .area(Decimal(row + 1) / 100 + 1), .netArea: .area(Decimal(row + 1) / 100 + 1),
                .planLength: .length(Decimal(row + 1) / 1000)
            ])
            let edited = try coordinator.view.store.updatingRows([
                LedgerStore.LedgerRowEdit(index: row, record: record, measurement: measurement)
            ])
            coordinator.apply(.editRows(store: edited, editedIndices: [row]))
            row += 1
        }

        // Correctness stays asserted after the benchmarked operation (QUALITY_BAR 4.7):
        // the incremental view must equal a from-scratch rebuild of the same edited store,
        // node for node, accumulator for accumulator.
        let rebuilt = coordinator.view.store.makeView(spec)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices)
        #expect(coordinator.view.tree == rebuilt.tree)
        // And the grand total moved by exactly the +1 m² each of the 12 mutations added.
        let planArea = try exactDecimal(coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)])
        #expect(planArea == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount) + Decimal(Self.iterations))
    }

    @Test("Apply a numeric filter")
    func filterBenchmark() throws {
        let store = try BigLedger.store()
        let filter = LedgerFilterNode.rule(
            LedgerFilterRule(
                column: SyntheticLedger.columnID(.planArea),
                op: .greaterThan,
                value: .quantity(.area(250))
            )
        )
        let evaluator = LedgerFilterEvaluator(store: store)
        let all = Array(0..<store.rowCount)
        var matched = 0
        _ = Self.measure("filter (numeric)") {
            matched = evaluator.filter(all, with: filter).count
        }
        // planArea = n/100, so n > 25 000: rows 25 001...100 000.
        #expect(matched == 75_000)
    }

    @Test("Total every planned column, flat")
    func totalBenchmark() throws {
        let store = try BigLedger.store()
        let aggregator = LedgerAggregator(store: store, plan: SyntheticLedger.plan)
        let all = Array(0..<store.rowCount)
        var lastTotal = Decimal.zero
        _ = Self.measure("total (5 columns)") {
            lastTotal = aggregator.aggregate(rowIndices: all)[SyntheticLedger.doubledColumnID]?
                .decimal ?? -1
        }
        #expect(lastTotal == SyntheticLedger.expectedDoubled(rowCount: BigLedger.rowCount))
    }

    @Test("Sort by one column")
    func sortBenchmark() throws {
        let store = try BigLedger.store()
        let sorter = LedgerSorter(
            store: store,
            descriptors: [LedgerSortDescriptor(column: SyntheticLedger.costColumnID, ascending: false)]
        )
        let all = Array(0..<store.rowCount)
        var first = -1
        _ = Self.measure("sort (1 column)") {
            first = sorter.sorted(all).first ?? -1
        }
        // Cost is monotone in the row index, so descending puts the last row first.
        #expect(first == store.rowCount - 1)
    }
}
