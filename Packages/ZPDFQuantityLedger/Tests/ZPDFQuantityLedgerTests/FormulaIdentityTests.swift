import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

@Suite("Formula identity across cell, subtotal and export")
struct FormulaIdentityTests {

    @Test("One formula value serves the cell, the subtotal and the export")
    func oneEvaluationPath() throws {
        let store = try BigLedger.store()
        let column = SyntheticLedger.doubledColumnID
        let view = store.makeView(
            LedgerViewSpec(
                grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))],
                aggregation: SyntheticLedger.plan
            )
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view, title: "identity")

        // 1. Cell path: what a table row would draw.
        // 2. Export path: what the report projection carries.
        // 3. Subtotal path: what the group aggregate holds.
        var cellSum = Decimal.zero
        var exportSum = Decimal.zero
        var checked = 0
        for group in report.groups {
            for row in group.rows {
                let cell = try #require(row.cells.first { $0.column == column })
                let fromStore = store.value(at: row.storeIndex, column: column)
                #expect(cell.value == fromStore)
                let raw = try #require(cell.rawDecimal)
                exportSum += raw
                cellSum += try #require(fromStore.quantity).value
                checked += 1
            }
        }
        #expect(checked == store.rowCount)
        #expect(cellSum == exportSum)

        let subtotalSum = try report.groups.reduce(Decimal.zero) { partial, group in
            let total = try #require(group.totals.first { $0.column == column && $0.function == .sum })
            return partial + (try #require(total.rawDecimal))
        }
        #expect(subtotalSum == cellSum)

        let grand = try #require(
            report.grandTotals.first { $0.column == column && $0.function == .sum }
        )
        #expect(try #require(grand.rawDecimal) == cellSum)
        #expect(cellSum == SyntheticLedger.expectedDoubled(rowCount: BigLedger.rowCount))
    }

    @Test("A formula column compiles once, not once per row")
    func compiledOnce() throws {
        let store = try BigLedger.store()
        #expect(store.columns.compiledFormulas.programs.count == 1)
        let program = try #require(
            store.columns.compiledFormulas.programs[SyntheticLedger.doubledColumnID]
        )
        #expect(program.canonicalText == "[planArea] * 2")
        #expect(program.resultType.dimension == .area)
    }

    @Test("A formula failure is an error cell, never a zero")
    func failuresAreErrorCells() throws {
        let divisor = HandBuiltLedger.columnID("divisor")
        let quotient = HandBuiltLedger.columnID("quotient")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: divisor,
                key: "divisor",
                title: "Divisor",
                kind: .number,
                dimension: .count,
                order: 0
            ),
            LedgerColumnDefinition(
                id: quotient,
                key: "quotient",
                title: "Quotient",
                kind: .formula,
                dimension: .count,
                formula: FormulaExpression(source: "100 / [Divisor]"),
                isEditable: false,
                order: 1
            )
        ])
        let store = try HandBuiltLedger.makeStore(
            rows: [
                [divisor: .number(.count(4))],
                [divisor: .number(.count(0))]
            ],
            columns: columns
        )
        #expect(store.value(at: 0, column: quotient).quantity?.value == 25)
        let broken = store.value(at: 1, column: quotient)
        // T-057: the division by zero is named as such (it was `.formulaEvaluation`).
        #expect(broken.cellError?.kind == .divisionByZero)
        #expect(broken.quantity == nil)
        #expect(broken != .value(.empty))

        // And the aggregate refuses rather than treating the bad row as zero.
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([quotient]))
        )
        #expect(view.grandTotal[quotient]?.isRefusal == true)
    }

    @Test("Declared aggregation semantics travel into the report")
    func semanticsAreExported() throws {
        let store = try BigLedger.store()
        let view = store.makeView(LedgerViewSpec(aggregation: SyntheticLedger.plan))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let column = try #require(report.columns.first { $0.id == SyntheticLedger.doubledColumnID })
        #expect(column.aggregationSemantics == .evaluateThenAggregate)
        #expect(column.formulaCanonicalText == "[planArea] * 2")
        #expect(report.metadata.formulaGrammarVersion == FormulaEngine.grammarVersion)
    }

    @Test("aggregateThenEvaluate is refused, not silently substituted")
    func unimplementedSemanticsRefuse() throws {
        let column = HandBuiltLedger.columnID("twice")
        let base = HandBuiltLedger.columnID("base")
        #expect(throws: LedgerAggregationError.self) {
            _ = try LedgerColumnSet(
                columns: [
                    LedgerColumnDefinition(
                        id: base, key: "base", title: "Base", kind: .number,
                        dimension: .count, order: 0
                    ),
                    LedgerColumnDefinition(
                        id: column, key: "twice", title: "Twice", kind: .formula,
                        dimension: .count,
                        formula: FormulaExpression(source: "[Base] * 2"),
                        order: 1
                    )
                ],
                formulaSemantics: [column: .aggregateThenEvaluate]
            )
        }
    }
}
