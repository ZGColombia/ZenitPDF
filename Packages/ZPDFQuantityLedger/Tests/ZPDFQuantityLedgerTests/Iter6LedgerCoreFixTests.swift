import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// The core half: W-060 (Radius and Diameter are
/// never summed), W-061 (a refusal survives a formula that tolerates blanks) and W-063 (a
/// "No input" cell is no value for grouping, the Is empty filter and sorting, as it already was
/// for totals).
@Suite("Iteration 6 — ledger core fixes")
struct Iter6LedgerCoreFixTests {

    // MARK: - W-060

    /// A circle measured with the Radius tool: its radius, its diameter and one count.
    private static func circle(_ index: Int, radius: Decimal) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(900 + index)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            tool: .radius,
            subject: "Column \(index + 1)",
            measurement: MeasurementResult(values: [
                .radius: .length(radius),
                .diameter: .length(radius * 2),
                .count: .count(1)
            ]),
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    /// Three circles, r = 1, 2 and 3 m (so d = 2, 4 and 6 m), grouped by Type: one "radius"
    /// group. Radius and Diameter carry no Sum at all — not 6 m and 12 m — and are still
    /// counted (3 cells each). The Count column on the same rows still sums: 1 + 1 + 1 = 3.
    @Test("W-060: three circles of r = 1, 2 and 3 m have no Radius or Diameter total")
    func radiusAndDiameterNeverSum() throws {
        let columns = try LedgerColumnSet.standard()
        let radius = try #require(columns.columnID(standard: .radius))
        let diameter = try #require(columns.columnID(standard: .diameter))
        let count = try #require(columns.columnID(standard: .count))
        let icon = try #require(columns.columnID(standard: .icon))
        let store = try LedgerStore(
            markups: [Self.circle(0, radius: 1), Self.circle(1, radius: 2), Self.circle(2, radius: 3)],
            columns: columns
        )
        #expect(store.value(at: 2, column: radius).quantity == .length(3))
        #expect(store.value(at: 2, column: diameter).quantity == .length(6))

        let plan = LedgerAggregationPlan.standard(for: columns)
        let view = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: icon)], aggregation: plan))
        #expect(view.tree.roots.map(\.key) == [.text("radius")])
        let group = try #require(view.tree.roots.first)
        #expect(group.rowIndices == [0, 1, 2])
        // Old output: .quantity(6 m) for Radius and .quantity(12 m) for Diameter, in the group
        // heading and in the grand total alike.
        for node in [group.aggregates, view.tree.grandTotal] {
            #expect(node.value(AggregateKey(column: radius, function: .sum)) == nil)
            #expect(node.value(AggregateKey(column: diameter, function: .sum)) == nil)
            #expect(node.value(AggregateKey(column: radius, function: .count)) == .integer(3))
            #expect(node.value(AggregateKey(column: diameter, function: .count)) == .integer(3))
            #expect(node.value(AggregateKey(column: count, function: .sum)) == .quantity(.count(3)))
        }
    }

    /// The sum rule and the repeat rule are one rule: every built-in column whose measurement
    /// field does not repeat with the markup (a slope, a rise, a depth, a radius …) is refused
    /// a Sum, and so it cannot drift from a hand-kept list again.
    @Test("W-060: no built-in column whose field does not repeat with the markup is summed")
    func sumRuleFollowsTheRepeatRule() throws {
        let columns = try LedgerColumnSet.standard()
        var refused: [StandardLedgerColumn] = []
        for standard in StandardLedgerColumn.allCases {
            guard let field = standard.measurementField, !field.repeatsWithMarkup else { continue }
            let definition = try #require(columns.column(standard: standard))
            #expect(!LedgerAggregationPlan.sums(definition), "\(standard) must not be summed")
            refused.append(standard)
        }
        // Old output: radius and diameter were summed; the others were refused by name.
        #expect(Set(refused) == [
            .rise, .run, .slopeRatio, .slopePercent, .slopeAngle, .depth, .height, .radius, .diameter
        ])
    }

    // MARK: - W-061

    private static let divisor = HandBuiltLedger.columnID("it6-divisor")
    private static let quotient = HandBuiltLedger.columnID("it6-quotient")
    private static let safe = HandBuiltLedger.columnID("it6-safe")
    private static let chained = HandBuiltLedger.columnID("it6-chained")

    /// Divisor, Quotient = `100 / [Divisor]`, Safe = `COALESCE([Quotient], 0) + 1` and, when
    /// asked, Chained = `[Safe] * 2`.
    private static func coalesceColumns(withChained: Bool) throws -> LedgerColumnSet {
        var definitions = [
            LedgerColumnDefinition(id: divisor, key: "divisor", title: "Divisor", kind: .number, dimension: .count, order: 0),
            LedgerColumnDefinition(
                id: quotient, key: "quotient", title: "Quotient", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "100 / [Divisor]"), isEditable: false, order: 1
            ),
            LedgerColumnDefinition(
                id: safe, key: "safe", title: "Safe", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "COALESCE([Quotient], 0) + 1"), isEditable: false, order: 2
            )
        ]
        if withChained {
            definitions.append(LedgerColumnDefinition(
                id: chained, key: "chained", title: "Chained", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Safe] * 2"), isEditable: false, order: 3
            ))
        }
        return try LedgerColumnSet(columns: definitions)
    }

    private static let coalesceRows: [[ColumnID: LedgerCellValue]] = [
        [divisor: .number(.count(0))], [divisor: .number(.count(4))], [:]
    ]

    /// Hand-derived, Divisor 0, 4 and blank:
    /// - row 0: Quotient ÷0, refused. Safe reads that refusal as a blank, so COALESCE would
    ///   give 0 + 1 = 1 — but a refusal never becomes a number: Safe refuses (division by zero).
    /// - row 1: Quotient 100 / 4 = 25; Safe 25 + 1 = 26.
    /// - row 2: Quotient has nothing to divide by ("No input", not a refusal); Safe 0 + 1 = 1.
    /// Sum(Safe) refuses; without row 0 it is 26 + 1 = 27 over two rows.
    @Test("W-061: a refused input stays refused through COALESCE")
    func refusalSurvivesCoalesce() throws {
        let store = try HandBuiltLedger.makeStore(rows: Self.coalesceRows, columns: try Self.coalesceColumns(withChained: false))
        #expect(store.value(at: 0, column: Self.quotient).cellError?.kind == .divisionByZero)
        // Old output: .value(.formulaResult(1)) — the refusal turned into a number.
        #expect(store.value(at: 0, column: Self.safe).cellError?.kind == .divisionByZero)
        #expect(store.value(at: 1, column: Self.safe).quantity == .count(26))
        #expect(store.value(at: 2, column: Self.quotient).cellError?.kind == .missingInput)
        #expect(store.value(at: 2, column: Self.safe).quantity == .count(1), "a blank is still COALESCE's to fill")

        let plan = HandBuiltLedger.plan([Self.safe])
        let all = store.makeView(LedgerViewSpec(aggregation: plan)).tree.grandTotal
        // Old output: .quantity(28) — 1 + 26 + 1, the refused row counted as 1.
        #expect(all.value(AggregateKey(column: Self.safe, function: .sum)) == .failed(.cellError(.divisionByZero)))
        let rest = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [1, 2])
        #expect(rest.value(AggregateKey(column: Self.safe, function: .sum)) == .quantity(.count(27)))
        #expect(rest.value(AggregateKey(column: Self.safe, function: .count)) == .integer(2))
    }

    /// The refusal passes on through a formula that reads the refused formula (Chained =
    /// `[Safe] * 2`: refused, 52, 2), and the partial pass — only Chained evaluated, Safe's
    /// stored refusal read back — gives the same cells as a store built from scratch.
    @Test("W-061: the inherited refusal chains, and the partial pass agrees with a full build")
    func inheritedRefusalChainsAndPartialPassAgrees() throws {
        let narrow = try HandBuiltLedger.makeStore(rows: Self.coalesceRows, columns: try Self.coalesceColumns(withChained: false))
        let widened = try narrow.replacingColumns(try Self.coalesceColumns(withChained: true))
        let scratch = try HandBuiltLedger.makeStore(rows: Self.coalesceRows, columns: try Self.coalesceColumns(withChained: true))
        // Old output: 2 on row 0, from Safe's substituted 1.
        #expect(scratch.value(at: 0, column: Self.chained).cellError?.kind == .divisionByZero)
        #expect(scratch.value(at: 1, column: Self.chained).quantity == .count(52))
        #expect(scratch.value(at: 2, column: Self.chained).quantity == .count(2))
        for row in 0..<3 {
            for column in [Self.quotient, Self.safe, Self.chained] {
                #expect(widened.value(at: row, column: column) == scratch.value(at: row, column: column), "row \(row)")
            }
        }
    }

    // MARK: - W-063

    @Test("W-063: hasNoValue is true for an empty cell and a No input cell, never for a refusal")
    func hasNoValueReading() {
        #expect(LedgerCellResult.empty.hasNoValue)
        #expect(LedgerCellResult.error(LedgerCellError(kind: .missingInput, detail: "`Area` is blank")).hasNoValue)
        #expect(!LedgerCellResult.error(LedgerCellError(kind: .divisionByZero, detail: "÷0")).hasNoValue)
        #expect(!LedgerCellResult.value(.number(.count(0))).hasNoValue)
        #expect(!LedgerCellResult.value(.text("")).hasNoValue, "an empty text is a value the grouping files under (none) itself")
    }

    /// Iteration 5's mixed ledger under the Waste and Order by Area preset: A has an Order of
    /// 38 boards; B has no pack size and C is a Length row, so both say "No input" for Order.
    @Test("W-063: rows with No input group under (none) and match Order is empty")
    func noInputGroupsAndFiltersAsEmpty() throws {
        let columns = try Iter4WasteAndOrderTotalsTests.columnSet()
        let store = try Iter5LedgerCoreFixTests.mixedStore(columns)
        let order = Iter5LedgerCoreFixTests.orderID
        #expect(store.value(at: 1, column: order).cellError?.kind == .missingInput)
        #expect(store.value(at: 2, column: order).cellError?.kind == .missingInput)

        let grouped = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: order)]))
        // Old output: [.number(38), .error] — "(error)" over two cells that say "No input".
        #expect(grouped.tree.roots.map(\.key) == [.number(.count(38)), .none])
        #expect(grouped.tree.roots.map(\.rowIndices) == [[0], [1, 2]])

        let evaluator = LedgerFilterEvaluator(store: store)
        let all = Array(0..<store.rowCount)
        // Old output: [] — Is empty matched neither row.
        #expect(evaluator.filter(all, with: .rule(LedgerFilterRule(column: order, op: .isEmpty))) == [1, 2])
        #expect(evaluator.filter(all, with: .rule(LedgerFilterRule(column: order, op: .isNotEmpty))) == [0])
        // The view's filter path is the same compiled filter.
        let filtered = store.makeView(LedgerViewSpec(filter: .rule(LedgerFilterRule(column: order, op: .isEmpty))))
        #expect(filtered.matchingRowIndices == [1, 2])
    }

    /// Divisor 0, 4 and blank: Quotient refused (÷0), 25, No input. A refusal still groups
    /// under "(error)" and matches neither Is empty nor Is not empty; the No input cell joins
    /// the empty block, which sorts before the error block.
    @Test("W-063: No input sorts with the empty cells; a refusal keeps its own group and block")
    func noInputSortsWithEmptyAndRefusalStaysAnError() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: [[Iter5LedgerCoreFixTests.divisor: .number(.count(0))], [Iter5LedgerCoreFixTests.divisor: .number(.count(4))], [:]],
            columns: try Iter5LedgerCoreFixTests.refusalColumns(withAdded: false)
        )
        let quotient = Iter5LedgerCoreFixTests.quotient

        let grouped = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: quotient)]))
        // Old output: [.number(25), .error] with rows [[1], [0, 2]].
        #expect(grouped.tree.roots.map(\.key) == [.number(.count(25)), .none, .error])
        #expect(grouped.tree.roots.map(\.rowIndices) == [[1], [2], [0]])

        let evaluator = LedgerFilterEvaluator(store: store)
        #expect(evaluator.filter([0, 1, 2], with: .rule(LedgerFilterRule(column: quotient, op: .isEmpty))) == [2])
        #expect(evaluator.filter([0, 1, 2], with: .rule(LedgerFilterRule(column: quotient, op: .isNotEmpty))) == [1])

        // Old output: [1, 0, 2] — the No input row tied with the refusal in the error block.
        let ascending = LedgerSorter(store: store, descriptors: [LedgerSortDescriptor(column: quotient)])
        #expect(ascending.sorted([0, 1, 2]) == [1, 2, 0])
        let nullsFirst = LedgerSorter(store: store, descriptors: [LedgerSortDescriptor(column: quotient, nulls: .first)])
        #expect(nullsFirst.sorted([0, 1, 2]) == [2, 0, 1])
    }
}
