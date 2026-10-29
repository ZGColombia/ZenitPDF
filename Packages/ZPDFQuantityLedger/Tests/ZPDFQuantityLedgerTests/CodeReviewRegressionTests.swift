import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// Regression tests for the code-review findings on the aggregation core
/// (CR-52 … CR-71). Every test names, in its own
/// comment, what the code under review answered before the fix — the number a person would
/// have read.
@Suite("Code-review regressions: aggregation core")
struct CodeReviewRegressionTests {

    // MARK: - Fixtures

    private static let statusColumn = LedgerIdentifiers.columnID(for: .status)
    private static let planAreaColumn = LedgerIdentifiers.columnID(for: .planArea)

    private static func record(
        _ index: Int,
        subject: String = "S",
        status: MarkupStatus = .none,
        measurement: MeasurementResult? = nil,
        customValues: [ColumnID: LedgerCellValue] = [:]
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(index)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            subject: subject,
            status: status,
            measurement: measurement,
            customValues: customValues,
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    /// Subject and the built-in Status column — a Choice column over ``LedgerStatusChoices``,
    /// exactly as ``LedgerColumnSet/standard(displayPolicy:)`` declares it.
    private static func statusStore() throws -> LedgerStore {
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: HandBuiltLedger.subjectColumn, key: "subject", title: "Subject",
                kind: .text, standard: .subject, order: 0
            ),
            LedgerColumnDefinition(
                id: statusColumn, key: "status", title: "Status", kind: .choice, standard: .status,
                choices: LedgerStatusChoices.options,
                defaultChoiceID: LedgerIdentifiers.choiceOptionID(for: .none),
                order: 1
            )
        ])
        return try LedgerStore(
            markups: [
                record(0, status: .open),
                record(1, status: .resolved),
                record(2, status: .none)
            ],
            columns: columns
        )
    }

    private static func rows(
        _ store: LedgerStore,
        _ column: ColumnID,
        _ op: LedgerFilterOperator,
        _ value: LedgerFilterValue
    ) -> [Int] {
        LedgerFilterEvaluator(store: store).filter(
            Array(0..<store.rowCount),
            with: .rule(LedgerFilterRule(column: column, op: op, value: value))
        )
    }

    // MARK: - CR-52

    @Test("A Status rule with a text operand matches by the option's stored value or its id")
    func choiceCellsMatchTextOperands() throws {
        // Old output: `equals .text("open")` → [] — the evaluator had no `(.choice, .text)`
        // case — and `notEquals .text("open")` → [0, 1, 2], every row, the open one included.
        // `inSet .textSet(["open", "resolved"])` → [] for the same reason.
        let store = try Self.statusStore()
        let openID = LedgerIdentifiers.choiceOptionID(for: .open)
        #expect(store.value(at: 0, column: Self.statusColumn) == .value(.choice(openID)))

        func rows(_ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            Self.rows(store, Self.statusColumn, op, value)
        }
        // The seam's text spelling — the option's stored value.
        #expect(rows(.equals, .text("open")) == [0])
        #expect(rows(.notEquals, .text("open")) == [1, 2])
        #expect(rows(.inSet, .textSet(["open", "resolved"])) == [0, 1])
        #expect(rows(.notInSet, .textSet(["open", "resolved"])) == [2])
        // The option id, spelled as text.
        #expect(rows(.equals, .text(openID.rawValue.uuidString)) == [0])
        #expect(rows(.inSet, .textSet([openID.rawValue.uuidString])) == [0])
        // The seam's other spelling keeps working unchanged.
        #expect(rows(.equals, .choice(openID)) == [0])
        #expect(rows(.notEquals, .choice(openID)) == [1, 2])
        #expect(rows(.inSet, .choiceSet([openID])) == [0])
        // A text that names no option matches nothing — and its negation everything.
        #expect(rows(.equals, .text("nonsense")).isEmpty)
        #expect(rows(.notEquals, .text("nonsense")) == [0, 1, 2])
    }

    @Test("A choice column with its own catalogue resolves option values without the status table")
    func customChoiceCatalogueResolves() throws {
        // Old output: `equals .text("oak")` → [].
        let choice = HandBuiltLedger.columnID("finish")
        let oak = ChoiceOptionID(SyntheticLedger.deterministicUUID(701))
        let pine = ChoiceOptionID(SyntheticLedger.deterministicUUID(702))
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: choice, key: "finish", title: "Finish", kind: .choice,
                choices: [
                    ChoiceOption(id: oak, value: "oak", order: 0),
                    ChoiceOption(id: pine, value: "pine", order: 1)
                ],
                order: 0
            )
        ])
        let store = try LedgerStore(
            markups: [
                Self.record(0, customValues: [choice: .choice(oak)]),
                Self.record(1, customValues: [choice: .choice(pine)])
            ],
            columns: columns
        )
        #expect(Self.rows(store, choice, .equals, .text("oak")) == [0])
        #expect(Self.rows(store, choice, .inSet, .textSet(["pine"])) == [1])
        #expect(Self.rows(store, choice, .contains, .text("OA")) == [0])
    }

    // MARK: - CR-58

    @Test("A negated text operator is the exact complement of its positive form")
    func negatedTextOperatorsAreComplements() throws {
        // Old output: `notContains "beta"` → [1]. The empty third row was dropped, while
        // `notEquals "Alpha beta"` and `notInSet {"Alpha beta"}` both answered [1, 2].
        let text = HandBuiltLedger.textColumn
        let store = try HandBuiltLedger.makeStore(rows: [
            [text: .text("Alpha beta")],
            [text: .text("gamma")],
            [:]
        ])
        func rows(_ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            Self.rows(store, text, op, value)
        }
        #expect(rows(.contains, .text("beta")) == [0])
        #expect(rows(.notContains, .text("beta")) == [1, 2])
        #expect(rows(.notEquals, .text("Alpha beta")) == [1, 2])
        #expect(rows(.notInSet, .textSet(["Alpha beta"])) == [1, 2])

        let all = Set(0..<store.rowCount)
        for (positive, negative) in [
            (LedgerFilterOperator.contains, LedgerFilterOperator.notContains),
            (.equals, .notEquals)
        ] {
            let kept = Set(rows(positive, .text("gamma")))
            let dropped = Set(rows(negative, .text("gamma")))
            #expect(kept.union(dropped) == all, "\(positive)/\(negative) must partition the rows")
            #expect(kept.isDisjoint(with: dropped))
        }
        let inSet = Set(rows(.inSet, .textSet(["gamma"])))
        let notInSet = Set(rows(.notInSet, .textSet(["gamma"])))
        #expect(inSet.union(notInSet) == all)
        #expect(inSet.isDisjoint(with: notInSet))
    }

    // MARK: - CR-55

    @Test("The standard plan never sums a page index, a slope, an angle or a per-markup extent")
    func standardPlanSumsOnlyExtensiveColumns() throws {
        // Old output: `standard(for:)` switched on the column kind alone, so every `.number`
        // column carried a Sum — the built-in set's plan summed pageIndex, slopeRatio,
        // slopePercent, slopeAngle, rise, run, depth and height, and an export printed
        // "Page index 3" over three pages and "Slope % 60" over three ramps.
        let plan = LedgerAggregationPlan.standard(for: try LedgerColumnSet.standard())
        func sums(_ standard: StandardLedgerColumn) -> Bool {
            plan.keys.contains(
                AggregateKey(column: LedgerIdentifiers.columnID(for: standard), function: .sum)
            )
        }
        func counts(_ standard: StandardLedgerColumn) -> Bool {
            plan.keys.contains(
                AggregateKey(column: LedgerIdentifiers.columnID(for: standard), function: .count)
            )
        }
        // Unit Cost joined the refused list with ADR-0020: it is a rate (money per square metre,
        // per metre, per piece), and this test used to demand the "Sum: Unit Cost" that turned
        // up in every grouped export. Radius and Diameter joined it with
        // W-060: three circles of r = 1, 2 and 3 m used to total "6 m".
        let refused: [StandardLedgerColumn] = [
            .pageIndex, .slopeRatio, .slopePercent, .slopeAngle, .rise, .run, .depth, .height, .unitCost,
            .radius, .diameter
        ]
        for column in refused {
            #expect(!sums(column), "\(column) must not be summed")
            #expect(counts(column), "\(column) is still counted")
        }
        let summed: [StandardLedgerColumn] = [
            .count, .planLength, .trueLength, .perimeter, .planArea, .trueArea, .wallArea,
            .volume, .totalCost
        ]
        for column in summed {
            #expect(sums(column), "\(column) must be summed")
        }

        // Custom columns follow the same rule: a count is an extent, a ratio is not, and a
        // column with no declared dimension decides per row.
        func custom(_ name: String, dimension: QuantityDimension?) -> LedgerColumnDefinition {
            LedgerColumnDefinition(
                id: HandBuiltLedger.columnID(name), key: name, title: name,
                kind: .number, dimension: dimension, order: 0
            )
        }
        #expect(LedgerAggregationPlan.sums(custom("pieces", dimension: .count)))
        #expect(!LedgerAggregationPlan.sums(custom("ratio", dimension: .ratio)))
        #expect(!LedgerAggregationPlan.sums(custom("angle", dimension: .angle)))
        #expect(LedgerAggregationPlan.sums(custom("dynamic", dimension: nil)))
        #expect(LedgerAggregationPlan.sums(custom("length", dimension: .length)))
    }

    // MARK: - CR-62

    @Test("Count and Rows survive an errored member; only the arithmetic refuses")
    func talliesSurviveAnErroredMember() throws {
        // Old output: Count → .failed(.cellError(.formulaEvaluation)) and Rows → the same,
        // so the report printed `#ERROR[a member cell is in error: formulaEvaluation]` in
        // both cells, where Count 2 and Rows 3 were the truth.
        let divisor = HandBuiltLedger.columnID("divisor")
        let quotient = HandBuiltLedger.columnID("quotient")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: divisor, key: "divisor", title: "Divisor", kind: .number,
                dimension: .count, order: 0
            ),
            LedgerColumnDefinition(
                id: quotient, key: "quotient", title: "Quotient", kind: .formula,
                dimension: .count, formula: FormulaExpression(source: "100 / [Divisor]"),
                isEditable: false, order: 1
            )
        ])
        let store = try HandBuiltLedger.makeStore(
            rows: [
                [divisor: .number(.count(4))],
                [divisor: .number(.count(0))],
                [divisor: .number(.count(5))]
            ],
            columns: columns
        )
        // T-057: 100 / 0 is recorded as the division by zero it is (it was `.formulaEvaluation`).
        #expect(store.value(at: 1, column: quotient).cellError?.kind == .divisionByZero)

        let plan = LedgerAggregationPlan(keys: [
            AggregateKey(column: quotient, function: .sum),
            AggregateKey(column: quotient, function: .count),
            AggregateKey(column: quotient, function: .rowCount),
            AggregateKey(column: quotient, function: .distinctCount)
        ])
        let aggregates = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: 0..<3)
        #expect(aggregates.value(AggregateKey(column: quotient, function: .count)) == .integer(2))
        #expect(aggregates.value(AggregateKey(column: quotient, function: .rowCount)) == .integer(3))
        #expect(aggregates.value(AggregateKey(column: quotient, function: .distinctCount)) == .integer(2))
        #expect(
            aggregates.value(AggregateKey(column: quotient, function: .sum))
                == .failed(.cellError(.divisionByZero))
        )

        // The same answers through the view and the export projection.
        let view = store.makeView(LedgerViewSpec(aggregation: plan))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        let byFunction = Dictionary(
            uniqueKeysWithValues: report.grandTotals.map { ($0.function, $0) }
        )
        #expect(byFunction[.count]?.refusalToken == nil)
        #expect(byFunction[.count]?.value == .integer(2))
        #expect(byFunction[.rowCount]?.value == .integer(3))
        #expect(byFunction[.sum]?.refusalToken?.hasPrefix(LedgerReport.errorToken) == true)

        // Merging keeps the tallies exact as well.
        var left = AggregateAccumulator([])
        left.add(store.value(at: 0, column: quotient))
        left.add(store.value(at: 1, column: quotient))
        var right = AggregateAccumulator([])
        right.add(store.value(at: 2, column: quotient))
        left.merge(right)
        #expect(left.value(.count) == .integer(2))
        #expect(left.value(.rowCount) == .integer(3))
    }

    // MARK: - CR-68

    @Test("A row edit that omits its measurement keeps the store's measurement override")
    func rowEditKeepsMeasurementOverride() throws {
        // Old output: after the edit, `measurement(at: 0)` was `.empty` — the record carries
        // no measurement of its own — and the Plan Area cell went blank; the override the
        // store had been built with was dropped by the edit.
        let columns = try LedgerColumnSet.standard()
        let original = Self.record(0, subject: "Slab")
        let override = MeasurementResult(values: [.planArea: .area(42), .netArea: .area(42)])
        let store = try LedgerStore(
            markups: [original],
            columns: columns,
            measurements: [original.id: override]
        )
        #expect(store.measurement(at: 0) == override)
        #expect(store.value(at: 0, column: Self.planAreaColumn).quantity?.value == 42)

        var renamed = original
        renamed.subject = "Slab, renamed"
        let edited = try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: renamed)
        ])
        #expect(edited.record(at: 0).subject == "Slab, renamed")
        #expect(edited.measurement(at: 0) == override)
        #expect(edited.value(at: 0, column: Self.planAreaColumn).quantity?.value == 42)

        // An edit that carries a measurement is the recomputed result not yet written back:
        // it becomes the row's override, and a later edit without one keeps it.
        let recomputed = MeasurementResult(values: [.planArea: .area(7), .netArea: .area(7)])
        let twice = try edited.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: renamed, measurement: recomputed)
        ])
        #expect(twice.measurement(at: 0) == recomputed)
        let thrice = try twice.updatingRows([
            LedgerStore.LedgerRowEdit(index: 0, record: renamed)
        ])
        #expect(thrice.measurement(at: 0) == recomputed)
        #expect(thrice.value(at: 0, column: Self.planAreaColumn).quantity?.value == 7)
    }

    // MARK: - ADR-0014 (the ratio dimension from the measurement engine)

    @Test("A ratio no longer sums into a count total")
    func ratioDoesNotSumIntoCount() throws {
        // Old output (before the ratio tag): `.quantity(5.15 count)` — a waste factor added
        // straight into a count, because `.ratio` and `.count` were the same value.
        let value = HandBuiltLedger.valueColumn // dynamic dimension: decided per row
        let store = try HandBuiltLedger.makeStore(rows: [
            [value: .number(.count(4))],
            [value: .number(DecimalQuantity(value: Decimal(string: "1.15")!, dimension: .ratio))]
        ])
        let view = store.makeView(LedgerViewSpec(aggregation: HandBuiltLedger.plan([value], functions: [.sum])))
        #expect(view.grandTotal[value] == .mixedDimensions([.count, .ratio]))

        var accumulator = AggregateAccumulator()
        accumulator.add(.value(.number(.count(4))))
        accumulator.add(.value(.number(DecimalQuantity(value: 1, dimension: .ratio))))
        #expect(accumulator.value(.sum).isRefusal)
        // And the standard plan never asks for a ratio column's sum in the first place.
        #expect(!LedgerAggregationPlan.sums(LedgerColumnDefinition(
            id: HandBuiltLedger.columnID("waste"), key: "waste", title: "Waste",
            kind: .number, dimension: .ratio, order: 0
        )))
    }

    @Test("A pre-tag stored value decodes as a count and is re-tagged by its column on load")
    func preTagValueIsRetaggedByColumn() throws {
        // Old output: the stored cell read `.count` through the store — its bytes carry no
        // tag — so a fresh `.ratio` value in the same column made the total
        // `.mixedDimensions([count, ratio])` instead of `0.35`.
        let waste = HandBuiltLedger.columnID("waste")
        let columns = try LedgerColumnSet(columns: [
            LedgerColumnDefinition(
                id: waste, key: "waste", title: "Waste", kind: .number, dimension: .ratio, order: 0
            )
        ])
        // What an archive written before ADR-0014 holds: a dimensionless value with no tag.
        let encoded = try JSONEncoder().encode(
            LedgerCellValue.number(DecimalQuantity(value: Decimal(string: "0.15")!, dimension: .count))
        )
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ratio"))
        let stored = try JSONDecoder().decode(LedgerCellValue.self, from: encoded)
        #expect(stored == .number(DecimalQuantity(value: Decimal(string: "0.15")!, dimension: .count)))

        let store = try LedgerStore(
            markups: [
                Self.record(0, customValues: [waste: stored]),
                Self.record(1, customValues: [waste: .number(DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .ratio))])
            ],
            columns: columns
        )
        #expect(store.value(at: 0, column: waste).quantity?.dimension == .ratio)
        #expect(store.value(at: 1, column: waste).quantity?.dimension == .ratio)
        let view = store.makeView(LedgerViewSpec(aggregation: HandBuiltLedger.plan([waste], functions: [.sum])))
        #expect(view.grandTotal[waste] == .quantity(DecimalQuantity(value: Decimal(string: "0.35")!, dimension: .ratio)))

        // The re-tag is by column identity only: a column that declares nothing leaves the
        // stored tag alone, and a dimensioned value is never touched.
        let plain = try HandBuiltLedger.makeStore(rows: [[HandBuiltLedger.valueColumn: stored]])
        #expect(plain.value(at: 0, column: HandBuiltLedger.valueColumn).quantity?.dimension == .count)
        #expect(LedgerStore.Storage.retagged(.number(.length(2)), forColumnDeclaring: .ratio) == .number(.length(2)))
        #expect(LedgerStore.Storage.retagged(.number(.count(2)), forColumnDeclaring: .length) == .number(.count(2)))
    }

    @Test("A stored slope ratio reads as a ratio through the ledger, whatever its bytes said")
    func storedSlopeRatioReadsAsRatio() throws {
        // Old output: `.count` — the value came off the measurement result untouched, and a
        // pre-tag archive's slope ratio was a count in the bytes.
        let columns = try LedgerColumnSet.standard()
        let slopeRatio = LedgerIdentifiers.columnID(for: .slopeRatio)
        let slopePercent = LedgerIdentifiers.columnID(for: .slopePercent)
        let preTag = MeasurementResult(values: [
            .slopeRatio: DecimalQuantity(value: Decimal(string: "0.5")!, dimension: .count),
            .slopePercent: DecimalQuantity(value: 50, dimension: .count),
            .planLength: .length(3)
        ])
        let store = try LedgerStore(
            markups: [Self.record(0)],
            columns: columns,
            measurements: [MarkupID(SyntheticLedger.deterministicUUID(0)): preTag]
        )
        #expect(store.value(at: 0, column: slopeRatio).quantity?.dimension == .ratio)
        #expect(store.value(at: 0, column: slopeRatio).quantity?.value == Decimal(string: "0.5"))
        #expect(store.value(at: 0, column: slopePercent).quantity?.dimension == .ratio)
        // A length keeps its dimension; only the count ↔ ratio tag is corrected.
        let planLength = LedgerIdentifiers.columnID(for: .planLength)
        #expect(store.value(at: 0, column: planLength).quantity?.dimension == .length)
    }

    // MARK: - CR-53

    @Test("The display rounding rule is half away from zero, applied once, and never -0.00")
    func displayRoundingRule() throws {
        // Old output: no rule existed in this package for the screen to cite. The screen's
        // `decimalText` fed the unrounded Decimal to a NumberFormatter set to .halfEven and
        // printed 0.12, 1.00, -0.00, -0.12 and 8.12 where every export wrote 0.13, 1.01,
        // 0.00, -0.13 and 8.13 — reproduced below as `unrounded`.
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfEven

        let cases: [(input: String, export: String, unrounded: String)] = [
            ("0.125", "0.13", "0.12"),
            ("1.005", "1.01", "1.00"),
            ("2.675", "2.68", "2.68"),
            ("-0.004", "0.00", "-0.00"),
            ("-0.125", "-0.13", "-0.12"),
            ("8.125", "8.13", "8.12"),
            ("0.4449", "0.44", "0.44")
        ]
        for item in cases {
            let value = try #require(Decimal(string: item.input))
            let rounded = LedgerDisplayRounding.round(value, places: 2)
            // The rule is the export's rounding, by construction.
            #expect(
                rounded == LedgerValueFormatting(precision: .decimalPlaces(2)).displayDecimal(value),
                Comment(rawValue: item.input)
            )
            #expect(rounded == Decimal(string: item.export), Comment(rawValue: item.input))
            // A formatter given the pre-rounded value has nothing left to round, whatever its
            // own mode says — and prints the export's digits.
            #expect(
                formatter.string(from: NSDecimalNumber(decimal: rounded)) == item.export,
                Comment(rawValue: item.input)
            )
            // The disagreement being retired, stated: the same formatter on the raw value.
            #expect(
                formatter.string(from: NSDecimalNumber(decimal: value)) == item.unrounded,
                Comment(rawValue: item.input)
            )
        }
        #expect(LedgerDisplayRounding.mode == .plain)
        let negativeZero = LedgerDisplayRounding.round(try #require(Decimal(string: "-0.004")), places: 2)
        #expect(negativeZero == .zero)
        #expect(!negativeZero.isSignMinus)
    }
}
