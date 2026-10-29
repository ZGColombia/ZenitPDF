import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Exact totals over 100 000 rows")
struct ExactTotalTests {

    @Test("Every column total equals its closed-form value, exactly")
    func closedFormTotals() throws {
        let store = try BigLedger.store()
        #expect(store.rowCount == BigLedger.rowCount)

        let view = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        let totals = view.grandTotal

        #expect(
            try exactDecimal(totals[SyntheticLedger.columnID(.planArea)])
                == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount)
        )
        #expect(
            try exactDecimal(totals[SyntheticLedger.columnID(.planLength)])
                == SyntheticLedger.expectedPlanLength(rowCount: BigLedger.rowCount)
        )
        #expect(
            try exactDecimal(totals[SyntheticLedger.costColumnID])
                == SyntheticLedger.expectedCost(rowCount: BigLedger.rowCount)
        )
        #expect(
            try exactDecimal(totals[SyntheticLedger.doubledColumnID])
                == SyntheticLedger.expectedDoubled(rowCount: BigLedger.rowCount)
        )
        #expect(
            try exactDecimal(totals[SyntheticLedger.columnID(.count)])
                == SyntheticLedger.expectedCount(rowCount: BigLedger.rowCount)
        )
    }

    @Test("A currency total stays a currency total with its ISO code")
    func currencyTotalKeepsCode() throws {
        let store = try BigLedger.store()
        let view = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        let total = try #require(view.grandTotal[SyntheticLedger.costColumnID])
        guard case .currency(let amount, let code) = total else {
            Issue.record("expected a currency total, got \(total)")
            return
        }
        #expect(code == SyntheticLedger.currencyCode)
        #expect(amount == SyntheticLedger.expectedCost(rowCount: BigLedger.rowCount))
    }

    @Test("Counts are integers, not decimals that look like integers")
    func countsAreIntegers() throws {
        let store = try BigLedger.store()
        let plan = LedgerAggregationPlan(keys: [
            AggregateKey(column: SyntheticLedger.columnID(.planArea), function: .count),
            AggregateKey(column: SyntheticLedger.columnID(.planArea), function: .rowCount)
        ])
        let view = store.makeView(LedgerViewSpec(aggregation: plan))
        let counted = view.grandTotal.value(
            AggregateKey(column: SyntheticLedger.columnID(.planArea), function: .count)
        )
        #expect(counted == .integer(BigLedger.rowCount))
        let rows = view.grandTotal.value(
            AggregateKey(column: SyntheticLedger.columnID(.planArea), function: .rowCount)
        )
        #expect(rows == .integer(BigLedger.rowCount))
    }

    @Test("Summing a permuted row order yields a bit-identical Decimal")
    func orderIndependence() throws {
        let store = try BigLedger.store()
        let column = SyntheticLedger.columnID(.planArea)
        let plan = LedgerAggregationPlan(keys: [AggregateKey(column: column, function: .sum)])
        let aggregator = LedgerAggregator(store: store, plan: plan)

        let ordered = Array(0..<store.rowCount)
        let baseline = try exactDecimal(aggregator.aggregate(rowIndices: ordered)[column])
        #expect(baseline == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount))

        for seed in UInt64(1)...UInt64(8) {
            var generator = SeededGenerator(seed: seed)
            let permuted = ordered.shuffled(using: &generator)
            let total = try exactDecimal(aggregator.aggregate(rowIndices: permuted)[column])
            #expect(total == baseline, "permutation \(seed) changed the total")
        }
    }

    @Test("Exact addition refuses rather than rounds")
    func inexactAdditionIsAnError() throws {
        // 38 significant digits is Decimal's ceiling; adding a 39th digit's worth cannot be exact.
        let huge = Decimal(string: "12345678901234567890123456789012345678")
        let tiny = Decimal(string: "0.00000001")
        let left = try #require(huge)
        let right = try #require(tiny)
        #expect(throws: LedgerAggregationError.self) {
            _ = try DecimalSummation.add(left, right)
        }
        // And the same terms through an accumulator become a typed refusal, never a number.
        var accumulator = AggregateAccumulator()
        accumulator.add(.value(.number(.count(left))))
        accumulator.add(.value(.number(.count(right))))
        guard case .failed = accumulator.value(.sum) else {
            Issue.record("expected a failed aggregate, got \(accumulator.value(.sum))")
            return
        }
    }
}
