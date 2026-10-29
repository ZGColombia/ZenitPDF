import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Mixed dimensions refuse to total")
struct MixedDimensionTests {

    @Test("Metres and square metres do not add")
    func lengthAndAreaRefuse() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.length(3))],
            [HandBuiltLedger.valueColumn: .number(.area(4))]
        ])
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        let total = try #require(view.grandTotal[HandBuiltLedger.valueColumn])
        guard case .mixedDimensions(let dimensions) = total else {
            Issue.record("expected mixedDimensions, got \(total)")
            return
        }
        #expect(dimensions == [.length, .area])
        #expect(total.decimal == nil)
        #expect(total.isRefusal)
    }

    @Test("Metres and millimetres are the same dimension and do add")
    func lengthUnitsConvertAndSum() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.length(1))],
            [HandBuiltLedger.valueColumn: .number(.length(5, in: .millimetre))]
        ])
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        // Stored values are SI, so 5 mm is 0.005 m and the total is exactly 1.005 m.
        #expect(try exactDecimal(view.grandTotal[HandBuiltLedger.valueColumn]) == Decimal(string: "1.005"))
    }

    @Test("Two ISO currency codes refuse to total")
    func currencyMixRefuses() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.moneyColumn: .currency(amount: 100, code: "SEK")],
            [HandBuiltLedger.moneyColumn: .currency(amount: 200, code: "SEK")],
            [HandBuiltLedger.moneyColumn: .currency(amount: 50, code: "EUR")]
        ])
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.moneyColumn]))
        )
        let total = try #require(view.grandTotal[HandBuiltLedger.moneyColumn])
        guard case .mixedDimensions(let dimensions) = total else {
            Issue.record("expected mixedDimensions, got \(total)")
            return
        }
        #expect(dimensions == [.currency("EUR"), .currency("SEK")])
        #expect(total.decimal == nil)
    }

    @Test("One currency code totals per code")
    func singleCurrencyTotals() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.moneyColumn: .currency(amount: Decimal(string: "100.25")!, code: "SEK")],
            [HandBuiltLedger.moneyColumn: .currency(amount: Decimal(string: "200.50")!, code: "SEK")]
        ])
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.moneyColumn]))
        )
        #expect(view.grandTotal[HandBuiltLedger.moneyColumn]
            == .currency(amount: Decimal(string: "300.75")!, code: "SEK"))
    }

    @Test("A mixed subtotal makes its parent and the grand total mixed")
    func mixedStatePropagates() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: [
                [HandBuiltLedger.valueColumn: .number(.length(3))],
                [HandBuiltLedger.valueColumn: .number(.area(4))],
                [HandBuiltLedger.valueColumn: .number(.length(7))]
            ],
            subjects: ["mixed", "mixed", "clean"]
        )
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: HandBuiltLedger.subjectColumn)],
                aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn])
            )
        )
        let clean = try #require(view.tree.roots.first { $0.key == .text("clean") })
        #expect(try exactDecimal(clean.aggregates[HandBuiltLedger.valueColumn]) == 7)

        let mixed = try #require(view.tree.roots.first { $0.key == .text("mixed") })
        #expect(mixed.aggregates[HandBuiltLedger.valueColumn]?.isRefusal == true)

        // The mixed group is not quietly dropped from the grand total: it poisons it, correctly.
        let grand = try #require(view.grandTotal[HandBuiltLedger.valueColumn])
        guard case .mixedDimensions(let dimensions) = grand else {
            Issue.record("expected the grand total to be mixed, got \(grand)")
            return
        }
        #expect(dimensions == [.length, .area])
    }

    @Test("A mixed total exports one machine-distinguishable token, never a blank")
    func mixedStateExports() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.length(3))],
            [HandBuiltLedger.valueColumn: .number(.area(4))]
        ])
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let total = try #require(
            report.grandTotals.first {
                $0.column == HandBuiltLedger.valueColumn && $0.function == .sum
            }
        )
        #expect(total.rawDecimal == nil)
        #expect(total.displayDecimal == nil)
        let token = try #require(total.refusalToken)
        #expect(token.hasPrefix(LedgerReport.mixedDimensionsToken))
        #expect(token.contains("m"))
        #expect(!token.isEmpty)
    }

    @Test("An errored cell fails the aggregate rather than counting as zero")
    func errorCellFailsTheAggregate() throws {
        var accumulator = AggregateAccumulator()
        accumulator.add(.value(.number(.area(10))))
        accumulator.add(.error(LedgerCellError(kind: .formulaEvaluation, detail: "boom")))
        let value = accumulator.value(.sum)
        guard case .failed(let code) = value else {
            Issue.record("expected a failure, got \(value)")
            return
        }
        #expect(code == .cellError(.formulaEvaluation))
    }
}
