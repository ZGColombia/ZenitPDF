import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// The core half of V-058 (blank formula inputs
/// no longer poison totals), V-061 (bulk edits rebuild instead of going quadratic) and V-069
/// (text "is" / "is not" follow the case-insensitive rule of the other text operators).
@Suite("Iteration 5 — ledger core fixes")
struct Iter5LedgerCoreFixTests {

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    // MARK: - V-058

    /// The ids Iter4WasteAndOrderTotalsTests.columnSet() gives its four preset columns.
    private static let wasteID = ColumnID(SyntheticLedger.deterministicUUID(-501))
    private static let packID = ColumnID(SyntheticLedger.deterministicUUID(-502))
    private static let grossID = ColumnID(SyntheticLedger.deterministicUUID(-503))
    static let orderID = ColumnID(SyntheticLedger.deterministicUUID(-504))

    /// Three rows under the Waste and Order by Area preset (Iter4WasteAndOrderTotalsTests'
    /// column set), hand-derived:
    /// - A, area 97.3 m², waste 0.10, pack 2.88 m²: Gross 97.3 × 1.10 = 107.03 m²; Order
    ///   ⌈107.03 / 2.88⌉ = ⌈37.163…⌉ = 38.
    /// - B, area 50 m², no waste, **no pack size**: Gross 50 × 1 = 50 m²; Order has nothing
    ///   to divide by.
    /// - C, a **Length** row, 12 m, pack 2.88 m²: no area, so no Gross, so no Order.
    ///
    /// Gross total 107.03 + 50 = 157.03 m² over two rows; Order total 38 boards over one.
    static func mixedStore(_ columns: LedgerColumnSet) throws -> LedgerStore {
        let pack = DecimalQuantity(value: decimal("2.88"), dimension: .area)
        func record(
            _ index: Int, subject: String, tool: MeasurementTool,
            values: [MeasurementField: DecimalQuantity], waste: String?, withPack: Bool
        ) -> MarkupRecord {
            var custom: [ColumnID: LedgerCellValue] = [:]
            if withPack { custom[Self.packID] = .number(pack) }
            if let waste {
                custom[Self.wasteID] =
                    .number(DecimalQuantity(value: decimal(waste), dimension: .ratio))
            }
            return MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(700 + index)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
                kind: .measurement,
                tool: tool,
                subject: subject,
                measurement: MeasurementResult(values: values),
                customValues: custom,
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
        }
        return try LedgerStore(
            markups: [
                record(0, subject: "A", tool: .rectangleArea,
                       values: [.planArea: .area(decimal("97.3")), .netArea: .area(decimal("97.3"))],
                       waste: "0.10", withPack: true),
                record(1, subject: "B", tool: .rectangleArea,
                       values: [.planArea: .area(50), .netArea: .area(50)],
                       waste: nil, withPack: false),
                record(2, subject: "C", tool: .length,
                       values: [.planLength: .length(12)],
                       waste: nil, withPack: true)
            ],
            columns: columns
        )
    }

    @Test("V-058: Gross and Order total over the rows that have them, in a mixed ledger")
    func wasteAndOrderTotalsInAMixedLedger() throws {
        let columns = try Iter4WasteAndOrderTotalsTests.columnSet()
        let store = try Self.mixedStore(columns)
        let grossID = Self.grossID
        let orderID = Self.orderID

        // Per row. The cells with nothing to compute from still say why, with the engine's words.
        #expect(store.value(at: 0, column: grossID).quantity == DecimalQuantity(value: Self.decimal("107.03"), dimension: .area))
        #expect(store.value(at: 1, column: grossID).quantity == DecimalQuantity(value: 50, dimension: .area))
        #expect(store.value(at: 0, column: orderID).quantity == DecimalQuantity(value: 38, dimension: .count))
        let lengthGross = try #require(store.value(at: 2, column: grossID).cellError)
        // Old output: formulaEvaluation, which every total treated as a refusal.
        #expect(lengthGross.kind == .missingInput)
        #expect(lengthGross.detail.contains("blank"), "\(lengthGross.detail)")
        #expect(store.value(at: 1, column: orderID).cellError?.kind == .missingInput)
        #expect(store.value(at: 2, column: orderID).cellError?.kind == .missingInput)

        var plan = LedgerAggregationPlan.standard(for: columns)
        for id in [grossID, orderID] {
            plan.add(AggregateKey(column: id, function: .count))
            plan.add(AggregateKey(column: id, function: .rowCount))
        }
        let flat = store.makeView(LedgerViewSpec(aggregation: plan))
        let grossSum = AggregateKey(column: grossID, function: .sum)
        let orderSum = AggregateKey(column: orderID, function: .sum)
        // Old output: both .failed(.cellError(.formulaEvaluation)).
        #expect(flat.tree.grandTotal.value(grossSum) == .quantity(DecimalQuantity(value: Self.decimal("157.03"), dimension: .area)))
        #expect(flat.tree.grandTotal.value(orderSum) == .quantity(DecimalQuantity(value: 38, dimension: .count)))
        // Left out of Count like an empty cell; still one of the Rows.
        #expect(flat.tree.grandTotal.value(AggregateKey(column: grossID, function: .count)) == .integer(2))
        #expect(flat.tree.grandTotal.value(AggregateKey(column: orderID, function: .count)) == .integer(1))
        #expect(flat.tree.grandTotal.value(AggregateKey(column: orderID, function: .rowCount)) == .integer(3))

        // Each group total, and their merge, agree.
        let subject = try #require(columns.columnID(standard: .subject))
        let grouped = store.makeView(LedgerViewSpec(grouping: [LedgerGroupingField(column: subject)], aggregation: plan))
        #expect(grouped.tree.roots.map { $0.aggregates.value(grossSum) } == [
            .quantity(DecimalQuantity(value: Self.decimal("107.03"), dimension: .area)),
            .quantity(DecimalQuantity(value: 50, dimension: .area)),
            .empty
        ])
        #expect(grouped.tree.roots.map { $0.aggregates.value(orderSum) } == [
            .quantity(DecimalQuantity(value: 38, dimension: .count)), .empty, .empty
        ])
        #expect(grouped.tree.grandTotal.value(grossSum) == flat.tree.grandTotal.value(grossSum))
        #expect(grouped.tree.grandTotal.value(orderSum) == flat.tree.grandTotal.value(orderSum))
    }

    static let divisor = HandBuiltLedger.columnID("it5-divisor")
    static let quotient = HandBuiltLedger.columnID("it5-quotient")
    private static let doubled = HandBuiltLedger.columnID("it5-doubled")
    private static let added = HandBuiltLedger.columnID("it5-added")

    static func refusalColumns(withAdded: Bool) throws -> LedgerColumnSet {
        var definitions = [
            LedgerColumnDefinition(id: divisor, key: "divisor", title: "Divisor", kind: .number, dimension: .count, order: 0),
            LedgerColumnDefinition(
                id: quotient, key: "quotient", title: "Quotient", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "100 / [Divisor]"), isEditable: false, order: 1
            ),
            LedgerColumnDefinition(
                id: doubled, key: "doubled", title: "Doubled", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Quotient] * 2"), isEditable: false, order: 2
            )
        ]
        if withAdded {
            definitions.append(LedgerColumnDefinition(
                id: added, key: "added", title: "Added", kind: .formula, dimension: .count,
                formula: FormulaExpression(source: "[Quotient] + 1"), isEditable: false, order: 3
            ))
        }
        return try LedgerColumnSet(columns: definitions)
    }

    /// Divisor 0, 4 and blank. Quotient: refused (÷0), 25, nothing. Doubled reads Quotient.
    @Test("V-058: a blank that is only blank because its input was refused keeps the refusal")
    func refusedInputIsNotMissingInput() throws {
        let store = try HandBuiltLedger.makeStore(
            rows: [[Self.divisor: .number(.count(0))], [Self.divisor: .number(.count(4))], [:]],
            columns: try Self.refusalColumns(withAdded: false)
        )
        #expect(store.value(at: 0, column: Self.quotient).cellError?.kind == .divisionByZero)
        // Without the inheritance this would read missingInput, and the Doubled total would
        // quietly be 50 over one row while the Quotient total refuses.
        #expect(store.value(at: 0, column: Self.doubled).cellError?.kind == .divisionByZero)
        #expect(store.value(at: 1, column: Self.doubled).quantity == DecimalQuantity(value: 50, dimension: .count))
        #expect(store.value(at: 2, column: Self.quotient).cellError?.kind == .missingInput)
        #expect(store.value(at: 2, column: Self.doubled).cellError?.kind == .missingInput)

        let plan = HandBuiltLedger.plan([Self.quotient, Self.doubled])
        let all = store.makeView(LedgerViewSpec(aggregation: plan)).tree.grandTotal
        #expect(all.value(AggregateKey(column: Self.doubled, function: .sum)) == .failed(.cellError(.divisionByZero)))
        // Without the refused row: 50 over one row; the blank row is left out.
        let rest = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [1, 2])
        #expect(rest.value(AggregateKey(column: Self.doubled, function: .sum)) == .quantity(DecimalQuantity(value: 50, dimension: .count)))
        #expect(rest.value(AggregateKey(column: Self.doubled, function: .count)) == .integer(1))

        // The partial pass (only the new column is evaluated; Quotient's stored refusal is
        // read back) gives the same cells as a store built from scratch.
        let widened = try store.replacingColumns(try Self.refusalColumns(withAdded: true))
        let scratch = try HandBuiltLedger.makeStore(
            rows: [[Self.divisor: .number(.count(0))], [Self.divisor: .number(.count(4))], [:]],
            columns: try Self.refusalColumns(withAdded: true)
        )
        #expect(widened.value(at: 0, column: Self.added).cellError?.kind == .divisionByZero)
        for row in 0..<3 {
            #expect(widened.value(at: row, column: Self.added) == scratch.value(at: row, column: Self.added), "row \(row)")
        }
    }

    @Test("V-058: a missing-input cell folds in and out of an accumulator like an empty cell")
    func missingInputRoundTripsLikeEmpty() throws {
        let missing = LedgerCellResult.error(LedgerCellError(kind: .missingInput, detail: "`Area` is blank"))
        var accumulator = AggregateAccumulator()
        accumulator.add(.value(.number(.area(5))))
        accumulator.add(missing)
        #expect(accumulator.value(.sum) == .quantity(.area(5)))
        #expect(accumulator.value(.count) == .integer(1))
        #expect(accumulator.value(.rowCount) == .integer(2))

        var reference = AggregateAccumulator()
        reference.add(.value(.number(.area(5))))
        reference.add(.empty)
        #expect(accumulator == reference, "the same state as an empty cell")
        // The incremental editor's exact reversal accepts it (it refused every error cell).
        let reversed = accumulator.remove(missing)
        #expect(reversed)
        #expect(accumulator.value(.rowCount) == .integer(1))

        var weighted = AggregateAccumulator()
        weighted.addWeighted(missing, weight: .value(.number(.count(2))), weightColumn: Self.divisor)
        #expect(weighted.value(.sum) == .empty, "old output: .failed(.cellError(.formulaEvaluation))")
    }

    // MARK: - V-061

    private static func statusEdits(_ store: LedgerStore, rows: Range<Int>, to status: MarkupStatus) throws -> LedgerStore {
        try store.updatingRows(rows.map { index in
            var record = store.record(at: index)
            record.status = status
            return LedgerStore.LedgerRowEdit(index: index, record: record)
        })
    }

    @Test("V-061: a select-all edit over 100 000 rows rebuilds once instead of shifting row by row")
    func selectAllEditRebuilds() throws {
        let store = try BigLedger.store()
        let status = LedgerGroupingField(column: SyntheticLedger.columnID(.status))
        let spec = LedgerViewSpec(grouping: [status], aggregation: SyntheticLedger.plan)
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        let edited = try Self.statusEdits(store, rows: 0..<store.rowCount, to: .resolved)

        let before = coordinator.diagnostics
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            coordinator.apply(.editRows(store: edited, editedIndices: Array(0..<edited.rowCount)))
        }
        print("V-061 select-all status edit, 100 000 rows, grouped: \(elapsed)")
        // Old path: 100 000 incremental row changes, each an O(n) shift in the matching list
        // and in its leaf — about n²/2 = 5·10⁹ element moves.
        #expect(coordinator.diagnostics.incrementalTreeEdits == before.incrementalTreeEdits)
        #expect(coordinator.diagnostics.filterScans == before.filterScans + 1)
        let rebuilt = edited.makeView(spec)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices)
        #expect(coordinator.view.tree == rebuilt.tree)
        #expect(coordinator.view.tree.roots.count == 1, "every row is Resolved now")
        let planArea = coordinator.view.grandTotal[SyntheticLedger.columnID(.planArea)]?.decimal
        #expect(planArea == SyntheticLedger.expectedPlanArea(rowCount: BigLedger.rowCount))
    }

    @Test("V-061 measurement: the old row-by-row path against the rebuild, 20 000 rows")
    func bulkEditMeasurement() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 20_000)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let spec = LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        let edited = try Self.statusEdits(store, rows: 0..<store.rowCount, to: .resolved)
        let all = Array(0..<edited.rowCount)
        let clock = ContinuousClock()
        var old: LedgerView?
        let oldTime = clock.measure {
            old = LedgerIncrementalUpdater.update(view: store.makeView(spec), newStore: edited, editedIndices: all).view
        }
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        let newTime = clock.measure {
            coordinator.apply(.editRows(store: edited, editedIndices: all))
        }
        print("V-061 select-all edit, 20 000 rows: row-by-row \(oldTime), rebuild \(newTime)")
        // The same view either way; only the cost differs.
        #expect(old?.tree == coordinator.view.tree)
        #expect(old?.matchingRowIndices == coordinator.view.matchingRowIndices)
    }

    @Test("V-061: the bound — at the limit edits stay incremental, past it the view is rebuilt")
    func bulkEditBound() throws {
        #expect(LedgerCoordinator.bulkEditLimit(rowCount: 400) == LedgerCoordinator.pendingEditLimit)
        #expect(LedgerCoordinator.bulkEditLimit(rowCount: 100_000) == 3_125)

        let store = try SyntheticLedger.makeStore(rowCount: 400)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let page = LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))
        let spec = LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        coordinator.apply(.setGrouping([page]))
        coordinator.apply(.setGrouping([subject]))

        // Two batches of 200 rows: each within the bound, so each is a delta …
        let first = try Self.statusEdits(store, rows: 0..<200, to: .resolved)
        var before = coordinator.diagnostics
        coordinator.apply(.editRows(store: first, editedIndices: Array(0..<200)))
        #expect(coordinator.diagnostics.filterScans == before.filterScans)
        let second = try Self.statusEdits(first, rows: 200..<400, to: .resolved)
        coordinator.apply(.editRows(store: second, editedIndices: Array(200..<400)))
        #expect(coordinator.diagnostics.filterScans == before.filterScans)
        #expect(coordinator.view.tree == second.makeView(spec).tree)
        // … and the cached Page tree, 400 edits behind, is dropped rather than replayed (IM-195).
        before = coordinator.diagnostics
        coordinator.apply(.setGrouping([page]))
        #expect(coordinator.diagnostics.cacheHits == before.cacheHits)
        #expect(coordinator.view.tree == second.makeView(coordinator.view.spec).tree)

        // One batch of 257 rows over 400 is past the bound: one filter scan, no delta.
        coordinator.apply(.setGrouping([subject]))
        let third = try Self.statusEdits(second, rows: 0..<257, to: .open)
        before = coordinator.diagnostics
        coordinator.apply(.editRows(store: third, editedIndices: Array(0..<257)))
        #expect(coordinator.diagnostics.filterScans == before.filterScans + 1)
        #expect(coordinator.diagnostics.incrementalTreeEdits == before.incrementalTreeEdits)
        #expect(coordinator.view.tree == third.makeView(coordinator.view.spec).tree)
    }

    // MARK: - V-069

    @Test("V-069: text is / is not / is any of ignore case, like contains")
    func textEqualityIgnoresCase() throws {
        let text = HandBuiltLedger.textColumn
        let store = try HandBuiltLedger.makeStore(rows: [
            [text: .text("Wall")], [text: .text("wall")], [text: .text("WALL")], [text: .text("Floor")], [:]
        ])
        let evaluator = LedgerFilterEvaluator(store: store)
        func rows(_ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            evaluator.filter(Array(0..<store.rowCount), with: .rule(LedgerFilterRule(column: text, op: op, value: value)))
        }
        // Old output: [1] and [0, 2, 3, 4] — 'Label is wall' missed "Wall".
        #expect(rows(.equals, .text("wall")) == [0, 1, 2])
        #expect(rows(.notEquals, .text("wall")) == [3, 4])
        #expect(rows(.inSet, .textSet(["WALL"])) == [0, 1, 2])
        #expect(rows(.notInSet, .textSet(["WALL"])) == [3, 4])
        #expect(rows(.contains, .text("WAL")) == [0, 1, 2], "the rule the others now share")
        // The single-row path and the static rule agree with the compiled scan.
        #expect((0..<store.rowCount).filter {
            evaluator.matches(rowIndex: $0, node: .rule(LedgerFilterRule(column: text, op: .equals, value: .text("wALL"))))
        } == [0, 1, 2])
        #expect(LedgerFilterEvaluator.matches(value: .text("Wall"), op: .inSet, operand: .textSet(["wall"])))
        #expect(LedgerFilterEvaluator.matches(value: .text("straße"), op: .equals, operand: .text("STRASSE")))
    }

    /// V-069 re-fix: the finding kept tokens as they were, and the first fix folded case on
    /// every text cell — the built-in Type column included, whose cells are tool tokens
    /// (`"length"`, `"rectangleArea"`). The display name "Length" then equalled the token
    /// `"length"`, which broke U-059 (Iter4LedgerCoreBridgeTests.pickedTypeMatchesInTheCore).
    @Test("V-069 re-fix: the Type column compares its tokens exactly; Label still ignores case")
    func typeTokensStayExact() throws {
        let columns = try LedgerColumnSet.standard()
        func record(_ index: Int, _ tool: MeasurementTool, label: String) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(900 + index)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
                kind: .measurement,
                tool: tool,
                label: label,
                createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )
        }
        let store = try LedgerStore(
            markups: [record(0, .length, label: "Wall"), record(1, .rectangleArea, label: "wall"), record(2, .length, label: "Floor")],
            columns: columns,
            names: LedgerNameCatalog()
        )
        let type = try #require(columns.columnID(standard: .icon))
        let label = try #require(columns.columnID(standard: .label))
        let evaluator = LedgerFilterEvaluator(store: store)
        func rows(_ column: ColumnID, _ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            evaluator.filter([0, 1, 2], with: .rule(LedgerFilterRule(column: column, op: op, value: value)))
        }
        func single(_ column: ColumnID, _ op: LedgerFilterOperator, _ value: LedgerFilterValue) -> [Int] {
            [0, 1, 2].filter {
                evaluator.matches(rowIndex: $0, node: .rule(LedgerFilterRule(column: column, op: op, value: value)))
            }
        }
        // Type: the token matches, a spelling that differs only in case does not.
        // First-fix output for the five case-differing rules below, in order: [0, 2], [1],
        // [0, 2], [0, 1, 2] and [1].
        #expect(rows(type, .equals, .text("length")) == [0, 2])
        #expect(rows(type, .equals, .text("Length")) == [])
        #expect(rows(type, .notEquals, .text("LENGTH")) == [0, 1, 2])
        #expect(rows(type, .inSet, .textSet(["Length"])) == [])
        #expect(rows(type, .inSet, .textSet(["LENGTH", "RECTANGLEAREA"])) == [])
        #expect(rows(type, .notInSet, .textSet(["Length"])) == [0, 1, 2])
        #expect(rows(type, .inSet, .textSet(["length", "rectangleArea"])) == [0, 1, 2])
        #expect(single(type, .equals, .text("Length")) == [], "the single-row path agrees")
        #expect(single(type, .inSet, .textSet(["Length"])) == [])
        // The substring operators keep their case-insensitive rule on Type, as before V-069.
        #expect(rows(type, .contains, .text("AREA")) == [1])
        // A name column still follows V-069.
        #expect(rows(label, .equals, .text("WALL")) == [0, 1])
        #expect(rows(label, .notEquals, .text("WALL")) == [2])
        #expect(rows(label, .inSet, .textSet(["wALL"])) == [0, 1])
        #expect(single(label, .equals, .text("WALL")) == [0, 1])
        // The static rule, for a caller that knows the column holds tokens.
        #expect(!LedgerFilterEvaluator.matches(value: .text("length"), op: .equals, operand: .text("Length"), exactText: true))
        #expect(!LedgerFilterEvaluator.matches(value: .text("length"), op: .inSet, operand: .textSet(["Length"]), exactText: true))
        #expect(LedgerFilterEvaluator.comparesTextExactly(columns.column(standard: .icon)))
        #expect(!LedgerFilterEvaluator.comparesTextExactly(columns.column(standard: .label)))
        #expect(!LedgerFilterEvaluator.comparesTextExactly(nil))
    }
}
