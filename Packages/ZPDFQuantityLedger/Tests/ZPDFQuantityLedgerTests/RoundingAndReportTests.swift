import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

@Suite("Rounding at the boundary, once")
struct RoundingTests {

    /// The detector QUALITY_BAR A31 makes mandatory. `0.4449` rounds to `0.44` in one step and to
    /// `0.45` if it passes through three decimals first. If this test ever fails, some path is
    /// rounding twice — which is exactly the bug that makes an export disagree with the screen.
    @Test("0.4449 rounds to 0.44, never to 0.45")
    func doubleRoundingDetector() throws {
        let value = try #require(Decimal(string: "0.4449"))
        let formatting = LedgerValueFormatting(
            dimension: .count,
            displayUnit: .count,
            precision: .decimalPlaces(2)
        )
        #expect(formatting.displayDecimal(value) == Decimal(string: "0.44"))

        // The wrong answer, spelled out, so the test states what it is defending against.
        let viaThreeDecimals = NumericPolicy.rounded(
            NumericPolicy.rounded(value, decimalPlaces: 3),
            decimalPlaces: 2
        )
        #expect(viaThreeDecimals == Decimal(string: "0.45"))
        #expect(formatting.displayDecimal(value) != viaThreeDecimals)
    }

    @Test("The same detector holds through a cell and a total")
    func doubleRoundingThroughTheLedger() throws {
        let quantity = DecimalQuantity(
            value: try #require(Decimal(string: "0.4449")),
            dimension: .count
        )
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: HandBuiltLedger.valueColumn,
                key: "value",
                title: "Value",
                kind: .number,
                dimension: .count,
                displayUnit: .count,
                precision: .decimalPlaces(2),
                order: 0
            )
        ])
        let store = try HandBuiltLedger.makeStore(
            rows: [[HandBuiltLedger.valueColumn: .number(quantity)]],
            columns: columns
        )
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let cell = try #require(report.rows.first?.cells.first)
        #expect(cell.rawDecimal == Decimal(string: "0.4449"))
        #expect(cell.displayDecimal == Decimal(string: "0.44"))
        let total = try #require(report.grandTotals.first { $0.function == .sum })
        #expect(total.rawDecimal == Decimal(string: "0.4449"))
        #expect(total.displayDecimal == Decimal(string: "0.44"))
    }

    @Test("Unit conversion happens before the single rounding, never after")
    func convertThenRoundOnce() throws {
        let formatting = LedgerValueFormatting(
            dimension: .length,
            displayUnit: .length(.millimetre),
            precision: .decimalPlaces(1)
        )
        // 1.23456 m is 1234.56 mm, which is 1234.6 mm at one decimal. Rounding the metres first
        // would give 1.2 m = 1200 mm.
        let value = try #require(Decimal(string: "1.23456"))
        #expect(formatting.converted(value) == Decimal(string: "1234.56"))
        #expect(formatting.displayDecimal(value) == Decimal(string: "1234.6"))
    }

    @Test("Average has one definition: sum / count at the declared scale")
    func averageIsDeclared() throws {
        var accumulator = AggregateAccumulator()
        for value in [1, 2, 4] {
            accumulator.add(.value(.number(.area(Decimal(value)))))
        }
        let average = accumulator.value(.average)
        let expected = try DecimalSummation.divide(7, by: 3)
        #expect(average == .quantity(DecimalQuantity(value: expected, dimension: .area)))
        #expect(LedgerAggregationPolicy.averageScale == 12)
    }

    @Test("A weighted total multiplies before it adds")
    func weightedTotal() throws {
        let store = try HandBuiltLedger.makeStore(rows: [
            [
                HandBuiltLedger.valueColumn: .number(.area(10)),
                HandBuiltLedger.weightColumn: .number(.count(2))
            ],
            [
                HandBuiltLedger.valueColumn: .number(.area(5)),
                HandBuiltLedger.weightColumn: .number(.count(3))
            ]
        ])
        let key = AggregateKey(
            column: HandBuiltLedger.valueColumn,
            function: .weightedTotal(weight: HandBuiltLedger.weightColumn)
        )
        let view = store.makeView(LedgerViewSpec(aggregation: LedgerAggregationPlan(keys: [key])))
        #expect(view.grandTotal.value(key) == .quantity(.area(35)))
    }
}

@Suite("Report projection")
struct ReportProjectionTests {

    @Test("Two reports of the same view are identical, including their timestamp")
    func reportsAreDeterministic() throws {
        let store = try BigLedger.store()
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))],
                aggregation: SyntheticLedger.plan
            )
        )
        let builder = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
        #expect(builder.makeReport(view, title: "x") == builder.makeReport(view, title: "x"))
    }

    @Test("A report's totals equal the exact sum of the rows in that same report")
    func reportReconcilesWithItself() throws {
        let store = try BigLedger.store()
        let filter = LedgerFilterNode.rule(
            LedgerFilterRule(
                column: SyntheticLedger.columnID(.subject),
                op: .inSet,
                value: .textSet(["Steel", "Glazing"])
            )
        )
        let view = store.makeView(
            LedgerViewSpec(
                filter: filter,
                grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))],
                aggregation: SyntheticLedger.plan
            )
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let column = SyntheticLedger.costColumnID
        var rowSum = Decimal.zero
        for row in report.allRows() {
            guard let cell = row.cells.first(where: { $0.column == column }),
                  let raw = cell.rawDecimal else { continue }
            rowSum += raw
        }
        let grand = try #require(
            report.grandTotals.first { $0.column == column && $0.function == .sum }?.rawDecimal
        )
        #expect(rowSum == grand)
        #expect(report.metadata.rowCount == view.rowCount)
        #expect(report.metadata.totalRowCountBeforeFilter == store.rowCount)
        #expect(report.metadata.filterDescription.contains("subject inSet"))
    }

    @Test("Every report cell carries the formatting an exporter needs")
    func formattingTravels() throws {
        let store = try BigLedger.store()
        let view = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let area = try #require(report.columns.first { $0.id == SyntheticLedger.columnID(.planArea) })
        #expect(area.formatting.displayUnit == .area(.squareMetre))
        #expect(area.formatting.precision == .decimalPlaces(3))
        #expect(area.formatting.unitSymbol == "m²")
        let cost = try #require(report.columns.first { $0.id == SyntheticLedger.costColumnID })
        #expect(cost.formatting.currencyCode == "SEK")
        #expect(cost.formatting.unitSymbol == "SEK")
    }
}
