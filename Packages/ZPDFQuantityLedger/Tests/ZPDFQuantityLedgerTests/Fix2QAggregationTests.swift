import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// Bug hunt 2 / improvements, aggregation layer: BH-191, BH-193, BH-194, BH-195, BH-613,
/// BH-614, BH-615, IM-076, IM-078. Every assertion is against an oracle the code under test
/// did not produce: a closed form, the reverse comparison, or a from-scratch
/// ``LedgerGroupBuilder`` build.
@Suite("Fix2 Q — aggregation, ordering and incremental editing")
struct Fix2QAggregationTests {

    // MARK: - Helpers

    private func edit(
        _ store: LedgerStore,
        row index: Int,
        mutate: (inout MarkupRecord, inout MeasurementResult) -> Void
    ) throws -> LedgerStore {
        var record = store.record(at: index)
        var measurement = store.measurement(at: index)
        mutate(&record, &measurement)
        return try store.updatingRows([
            LedgerStore.LedgerRowEdit(index: index, record: record, measurement: measurement)
        ])
    }

    private func area(_ value: Decimal) -> MeasurementResult {
        MeasurementResult(values: [
            .count: .count(1), .planArea: .area(value), .netArea: .area(value), .planLength: .length(1)
        ])
    }

    private static let unknownColumn = HandBuiltLedger.columnID("deleted column")
    private static let unknownWeight = HandBuiltLedger.columnID("deleted weight")

    // MARK: - BH-191

    @Test("BH-191: a plan key whose column or weight column is gone reports #ERROR, never vanishes")
    func unresolvedPlanKeysFail() throws {
        // Old output: `value(key)` was nil for all three keys — the aggregator `continue`d past
        // them — and the report's totals block compactMapped the rows away without a token.
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.area(2))],
            [HandBuiltLedger.valueColumn: .number(.area(3))]
        ])
        let missingSum = AggregateKey(column: Self.unknownColumn, function: .sum)
        let missingCount = AggregateKey(column: Self.unknownColumn, function: .count)
        let missingWeight = AggregateKey(
            column: HandBuiltLedger.valueColumn,
            function: .weightedTotal(weight: Self.unknownWeight)
        )
        var plan = HandBuiltLedger.plan([HandBuiltLedger.valueColumn])
        plan.add(missingSum)
        plan.add(missingCount)
        plan.add(missingWeight)

        let flat = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [0, 1])
        #expect(flat.value(missingSum) == .failed(.unknownColumn(Self.unknownColumn)))
        // A tally of a column that does not exist is not 0.
        #expect(flat.value(missingCount) == .failed(.unknownColumn(Self.unknownColumn)))
        #expect(flat.value(missingWeight) == .failed(.unknownWeightColumn(Self.unknownWeight)))
        // The resolvable keys are untouched.
        #expect(flat[HandBuiltLedger.valueColumn] == .quantity(.area(5)))

        // The failure reaches every group and the grand total through the same merge.
        let tree = LedgerGroupBuilder(store: store, plan: plan).build(
            rowIndices: [0, 1],
            levels: [LedgerGroupingField(column: HandBuiltLedger.subjectColumn)]
        )
        #expect(tree.grandTotal.value(missingWeight) == .failed(.unknownWeightColumn(Self.unknownWeight)))
        tree.forEachNode { node in
            #expect(node.aggregates.value(missingSum) == .failed(.unknownColumn(Self.unknownColumn)))
        }
        // And the one-row delta path carries it too.
        let added = LedgerAggregator(store: store, plan: plan).adding(row: 0, to: .empty)
        #expect(added.value(missingSum) == .failed(.unknownColumn(Self.unknownColumn)))
    }

    // MARK: - BH-193

    @Test("BH-193: an edit the tree disagrees with rebuilds instead of counting the row twice")
    func divergentTreeFallsBackToRebuild() throws {
        // Old output: the removal's sibling search missed, `assertionFailure` was compiled out,
        // the row stayed in its old leaf ("Doors") and was inserted again into "Steel" — it
        // appeared twice in `orderedRowIndices` and both its old and new area were in the
        // grand total.
        let storeA = try SyntheticLedger.makeStore(rowCount: 70)
        let storeB = try edit(storeA, row: 5) { record, _ in record.subject = "Phantom" }
        let storeC = try edit(storeB, row: 5) { record, measurement in
            record.subject = "Steel"
            measurement = area(1000)
        }
        let levels = [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))]
        let all = Array(0..<70)
        // The tree was built from storeA, but the editor is told the old store is storeB.
        let staleTree = LedgerGroupBuilder(store: storeA, plan: SyntheticLedger.plan)
            .build(rowIndices: all, levels: levels)
        let editor = LedgerGroupTreeEditor(
            oldStore: storeB, newStore: storeC, plan: SyntheticLedger.plan, sort: []
        )
        let change = LedgerGroupTreeEditor.RowChange(index: 5, wasIncluded: true, isIncluded: true)

        #expect(editor.applyIncrementally([change], to: staleTree, newMatching: all) == nil)
        let applied = editor.apply([change], to: staleTree, newMatching: all)
        let oracle = LedgerGroupBuilder(store: storeC, plan: SyntheticLedger.plan)
            .build(rowIndices: all, levels: levels)
        #expect(applied == oracle)
        #expect(applied.orderedRowIndices.filter { $0 == 5 }.count == 1)
        #expect(applied.rowCount == 70)
    }

    // MARK: - BH-194

    @Test("BH-194: count and ratio quantities have a total order, antisymmetric and transitive")
    func countAndRatioOrderTotally() {
        // Old output: compareQuantities(count 5, ratio 5) and (ratio 5, count 5) were both
        // `.orderedDescending`.
        let values: [DecimalQuantity] = [
            .count(3), .count(5), .ratio(5), .ratio(2), .length(5), .area(5),
            .money(5, currencyCode: "EUR"), .money(5, currencyCode: "SEK"),
            DecimalQuantity(value: 5, dimension: .angle)
        ]
        for a in values {
            for b in values {
                let forward = LedgerOrdering.compareQuantities(a, b)
                let backward = LedgerOrdering.compareQuantities(b, a)
                if a == b {
                    #expect(forward == .orderedSame)
                } else {
                    #expect(forward != .orderedSame, "\(a) vs \(b)")
                    #expect(forward != backward, "\(a) vs \(b) must be antisymmetric")
                }
                for c in values where
                    forward == .orderedAscending && LedgerOrdering.compareQuantities(b, c) == .orderedAscending {
                    #expect(LedgerOrdering.compareQuantities(a, c) == .orderedAscending, "\(a) < \(b) < \(c)")
                }
            }
        }
        #expect(LedgerOrdering.compareQuantities(.count(5), .ratio(5)) == .orderedAscending)
        #expect(LedgerOrdering.compareQuantities(.ratio(5), .count(5)) == .orderedDescending)
        // No code sorts before any code; `nil` and `""` are not a tie.
        #expect(LedgerOrdering.compareDimensions(.count, QuantityDimension(lengthPower: 0, currencyCode: ""))
            == .orderedAscending)
    }

    @Test("BH-194: grouping a column that mixes counts and ratios survives an edit exactly")
    func countRatioGroupingIsStable() throws {
        let values: [LedgerCellValue] = [
            .number(.count(5)), .number(.ratio(5)), .number(.count(3)), .number(.ratio(2)),
            .number(.count(5)), .number(.ratio(5)), .number(.count(7))
        ]
        let store = try HandBuiltLedger.makeStore(
            rows: values.map { [HandBuiltLedger.valueColumn: $0, HandBuiltLedger.weightColumn: .number(.count(1))] }
        )
        let levels = [LedgerGroupingField(column: HandBuiltLedger.valueColumn)]
        let plan = HandBuiltLedger.plan([HandBuiltLedger.weightColumn])
        var coordinator = LedgerCoordinator(
            store: store, spec: LedgerViewSpec(grouping: levels, aggregation: plan)
        )
        let keys = coordinator.view.tree.roots.map(\.key)
        #expect(keys == [.number(.count(3)), .number(.count(5)), .number(.count(7)),
                         .number(.ratio(2)), .number(.ratio(5))])
        var record = store.record(at: 2)
        record.customValues[HandBuiltLedger.valueColumn] = .number(.ratio(5))
        let edited = try store.updatingRows([LedgerStore.LedgerRowEdit(index: 2, record: record)])
        coordinator.apply(.editRows(store: edited, editedIndices: [2]))
        let rebuilt = edited.makeView(coordinator.view.spec)
        #expect(coordinator.view.tree == rebuilt.tree)
    }

    // MARK: - BH-195

    @Test("BH-195: a choice the catalogue lacks orders after every known option, transitively")
    func unknownChoiceOrdersLast() throws {
        // Old output: A < B by order, B < C and C < A by UUID — a cycle.
        let a = ChoiceOptionID(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!)
        let b = ChoiceOptionID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!)
        let c = ChoiceOptionID(UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!)
        let order: [ChoiceOptionID: Int] = [a: 0, b: 1]
        let keys: [LedgerGroupKey] = [.choice(a), .choice(b), .choice(c)]
        #expect(LedgerGroupKey.compare(keys[0], keys[1], choiceOrder: order) == .orderedAscending)
        #expect(LedgerGroupKey.compare(keys[1], keys[2], choiceOrder: order) == .orderedAscending)
        #expect(LedgerGroupKey.compare(keys[0], keys[2], choiceOrder: order) == .orderedAscending)
        #expect(LedgerGroupKey.compare(keys[2], keys[0], choiceOrder: order) == .orderedDescending)
        // The group order and the sort order are one rule.
        #expect(LedgerOrdering.compareValues(.choice(c), .choice(a), choiceOrder: order) == .orderedDescending)
    }

    // MARK: - BH-613

    @Test("BH-613: accumulators that saw the same rows in another order are equal")
    func accumulatorEqualityIsOrderIndependent() {
        // Old output: `dimension`/`extraDimensions` kept arrival order, so [m², m] and [m, m²]
        // were unequal, and `.mixedDimensions([count, ratio])` vs `[ratio, count]` differed.
        let cells: [LedgerCellResult] = [
            .value(.number(.area(1))), .value(.number(.length(2))),
            .value(.number(.count(3))), .value(.number(.ratio(4)))
        ]
        for requirements in [AggregateAccumulator.Requirements.default, [.sum], [.extremes]] {
            var forward = AggregateAccumulator(requirements)
            var backward = AggregateAccumulator(requirements)
            for cell in cells { forward.add(cell) }
            for cell in cells.reversed() { backward.add(cell) }
            #expect(forward == backward)
            #expect(forward.value(.sum) == backward.value(.sum))

            var left = AggregateAccumulator(requirements)
            left.add(cells[0]); left.add(cells[2])
            var right = AggregateAccumulator(requirements)
            right.add(cells[1]); right.add(cells[3])
            var leftThenRight = left
            leftThenRight.merge(right)
            var rightThenLeft = right
            rightThenLeft.merge(left)
            #expect(leftThenRight == rightThenLeft)
        }

        var countRatio = AggregateAccumulator()
        countRatio.add(.value(.number(.ratio(1))))
        countRatio.add(.value(.number(.count(1))))
        #expect(countRatio.value(.sum) == .mixedDimensions([.count, .ratio]))

        // Two different failures: the reported one does not depend on which came first.
        let first = LedgerCellResult.error(LedgerCellError(kind: .formulaEvaluation, detail: "x"))
        let second = LedgerCellResult.error(LedgerCellError(kind: .divisionByZero, detail: "y"))
        var failedForward = AggregateAccumulator()
        failedForward.add(.value(.number(.area(1))))
        failedForward.add(first)
        failedForward.add(.value(.number(.area(2))))
        failedForward.add(second)
        var failedBackward = AggregateAccumulator()
        failedBackward.add(second)
        failedBackward.add(.value(.number(.area(2))))
        failedBackward.add(first)
        failedBackward.add(.value(.number(.area(1))))
        #expect(failedForward == failedBackward)
        #expect(failedForward.value(.count) == .integer(2))
    }

    // MARK: - BH-614

    @Test("BH-614: Average divides by the summed quantities, not by text cells")
    func averageIgnoresTextCells() throws {
        // Old output: 10 m² — the text cell counted as a zero in the mean.
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.area(10))],
            [HandBuiltLedger.valueColumn: .number(.area(20))],
            [HandBuiltLedger.valueColumn: .text("n/a")]
        ])
        let plan = HandBuiltLedger.plan([HandBuiltLedger.valueColumn], functions: [.average, .count])
        let aggregates = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [0, 1, 2])
        let average = AggregateKey(column: HandBuiltLedger.valueColumn, function: .average)
        #expect(aggregates.value(average) == .quantity(.area(15)))
        // Count still counts every value, the text included.
        #expect(aggregates.value(AggregateKey(column: HandBuiltLedger.valueColumn, function: .count)) == .integer(3))
        // Only text: there is no mean.
        let onlyText = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [2])
        #expect(onlyText.value(average) == .empty)
    }

    // MARK: - BH-615

    @Test("BH-615: a count 5 and a ratio 5 are two distinct values and two groups")
    func countAndRatioAreDistinct() throws {
        // Old output: DistinctCount 1, and both group keys had the token "n:5@1".
        let store = try HandBuiltLedger.makeStore(rows: [
            [HandBuiltLedger.valueColumn: .number(.count(5))],
            [HandBuiltLedger.valueColumn: .number(.ratio(5))]
        ])
        let plan = HandBuiltLedger.plan([HandBuiltLedger.valueColumn], functions: [.distinctCount])
        let aggregates = LedgerAggregator(store: store, plan: plan).aggregate(rowIndices: [0, 1])
        #expect(aggregates.value(AggregateKey(column: HandBuiltLedger.valueColumn, function: .distinctCount))
            == .integer(2))
        #expect(LedgerGroupKey.number(.count(5)).token != LedgerGroupKey.number(.ratio(5)).token)
        // Every other dimension keeps its token.
        #expect(LedgerGroupKey.number(.area(5)).token == "n:5@\(QuantityDimension.area.baseUnitSymbol)")
        #expect(LedgerGroupKey.number(.count(5)).token == "n:5@1")
    }

    // MARK: - IM-076

    @Test("IM-076: removing a value strictly between the extremes is exact; the extreme refuses")
    func extremesRemoveInterior() {
        var accumulator = AggregateAccumulator([.extremes])
        for value in [1, 5, 9] as [Decimal] { accumulator.add(.value(.number(.area(value)))) }
        var interior = accumulator
        let removedInterior = interior.remove(.value(.number(.area(5))))
        #expect(removedInterior)
        var rebuilt = AggregateAccumulator([.extremes])
        for value in [1, 9] as [Decimal] { rebuilt.add(.value(.number(.area(value)))) }
        #expect(interior == rebuilt)
        var extreme = accumulator
        let removedMaximum = extreme.remove(.value(.number(.area(9))))
        let removedMinimum = extreme.remove(.value(.number(.area(1))))
        #expect(!removedMaximum)
        #expect(!removedMinimum)
    }

    @Test("IM-076: Min/Max plans keep the delta path and match a full rebuild after random edits")
    func extremesInvarianceUnderRandomEdits() throws {
        var store = try SyntheticLedger.makeStore(rowCount: 600)
        var plan = SyntheticLedger.plan
        let planArea = SyntheticLedger.columnID(.planArea)
        plan.add(AggregateKey(column: planArea, function: .minimum))
        plan.add(AggregateKey(column: planArea, function: .maximum))
        plan.add(AggregateKey(column: SyntheticLedger.costColumnID, function: .maximum))
        var generator = SeededGenerator(seed: 76)
        for levels in [[], SyntheticLedger.groupings(store.columns)[2]] {
            var coordinator = LedgerCoordinator(
                store: store, spec: LedgerViewSpec(grouping: levels, aggregation: plan)
            )
            for step in 0..<40 {
                let row = Int.random(in: 0..<600, using: &generator)
                let value = Decimal(Int.random(in: 0...700, using: &generator)) / 100
                store = try edit(store, row: row) { record, measurement in
                    record.subject = SyntheticLedger.subjects[Int.random(in: 0..<7, using: &generator)]
                    measurement = area(value)
                }
                coordinator.apply(.editRows(store: store, editedIndices: [row]))
                let rebuilt = store.makeView(coordinator.view.spec)
                #expect(coordinator.view.tree == rebuilt.tree, "levels \(levels.count), step \(step)")
                #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices)
            }
        }
    }

    @Test("IM-076: only the key that refuses is named for recompute")
    func partialRemovalNamesOnlyRefusingKeys() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 10)
        var plan = LedgerAggregationPlan()
        let planArea = SyntheticLedger.columnID(.planArea)
        let sum = AggregateKey(column: planArea, function: .sum)
        let maximum = AggregateKey(column: planArea, function: .maximum)
        plan.add(sum)
        plan.add(maximum)
        let aggregator = LedgerAggregator(store: store, plan: plan)
        let all = aggregator.aggregate(rowIndices: Array(0..<10))
        // Row 4 (0.05 m²) is interior: nothing refuses.
        let interior = aggregator.removingWhereExact(row: 4, from: all, readingFrom: store)
        #expect(interior.refused.isEmpty)
        #expect(interior.aggregates == aggregator.aggregate(rowIndices: [0, 1, 2, 3, 5, 6, 7, 8, 9]))
        // Row 9 (0.10 m²) is the maximum: only the Max key refuses; the Sum delta is kept.
        let top = aggregator.removingWhereExact(row: 9, from: all, readingFrom: store)
        #expect(top.refused == [maximum])
        #expect(top.aggregates.value(sum) == aggregator.aggregate(rowIndices: Array(0..<9)).value(sum))
        // The public all-or-nothing form still refuses as a whole.
        #expect(aggregator.removing(row: 9, from: all, readingFrom: store) == nil)
    }

    @Test("IM-076: a one-row edit on a flat 100 000-row ledger with a Max aggregate takes the delta path")
    func flatMaxEditMeasurement() throws {
        let store = try BigLedger.store()
        var plan = SyntheticLedger.plan
        let planArea = SyntheticLedger.columnID(.planArea)
        plan.add(AggregateKey(column: planArea, function: .maximum))
        let view = store.makeView(LedgerViewSpec(aggregation: plan))
        let edited = try edit(store, row: 50_000) { _, measurement in measurement = area(3) }

        let clock = ContinuousClock()
        var incremental: LedgerIncrementalUpdater.Result?
        let delta = clock.measure {
            incremental = LedgerIncrementalUpdater.update(view: view, newStore: edited, editedIndices: [50_000])
        }
        // The pre-IM-076 path: one refusing slot made the whole flat set re-aggregate.
        var full: LedgerAggregates?
        let recompute = clock.measure {
            full = LedgerAggregator(store: edited, plan: plan).aggregate(rowIndices: view.matchingRowIndices)
        }
        let result = try #require(incremental)
        #expect(!result.rebuiltTree)
        #expect(result.view.grandTotal == full)
        print("IM-076 flat Max edit at 100 000 rows: delta \(delta), full re-aggregation \(recompute)")
        #expect(delta < recompute)
    }

    // MARK: - IM-078

    @Test("IM-078: options with equal order keep catalogue position, in builder, editor and sorter alike")
    func choiceRankTieRule() throws {
        func option(_ n: Int, order: Int) -> ChoiceOption {
            ChoiceOption(
                id: ChoiceOptionID(SyntheticLedger.deterministicUUID(9_000 + n)),
                value: "Option \(n)", order: order
            )
        }
        // Three options share order 1; catalogue position must break the tie.
        let options = [option(0, order: 1), option(1, order: 0), option(2, order: 1), option(3, order: 1)]
        let choiceColumn = HandBuiltLedger.columnID("phase choice")
        var definitions = try HandBuiltLedger.makeColumnSet().columns
        definitions.append(LedgerColumnDefinition(
            id: choiceColumn, key: "phaseChoice", title: "Phase", kind: .choice,
            choices: options, order: 10
        ))
        let columns = try LedgerColumnSet(columns: definitions)
        let rank = try #require(columns.column(id: choiceColumn)).choiceRank
        #expect(rank == [options[1].id: 0, options[0].id: 1, options[2].id: 2, options[3].id: 3])

        let picks = [3, 0, 2, 1, 3, 2, 0, 0, 1, 3]
        let store = try HandBuiltLedger.makeStore(
            rows: picks.map { [choiceColumn: .choice(options[$0].id), HandBuiltLedger.weightColumn: .number(.count(1))] },
            columns: columns
        )
        let expected = [1, 0, 2, 3].map { LedgerGroupKey.choice(options[$0].id) }
        let spec = LedgerViewSpec(
            sort: [LedgerSortDescriptor(column: choiceColumn)],
            grouping: [LedgerGroupingField(column: choiceColumn)],
            aggregation: HandBuiltLedger.plan([HandBuiltLedger.weightColumn])
        )
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        #expect(coordinator.view.tree.roots.map(\.key) == expected)
        // The sorter's order is the builder's order.
        let sortedKeys = coordinator.view.matchingRowIndices.map {
            LedgerGroupKey(store.value(at: $0, column: choiceColumn), dayCalendar: spec.dayCalendar)
        }
        var deduplicated: [LedgerGroupKey] = []
        for key in sortedKeys where deduplicated.last != key { deduplicated.append(key) }
        #expect(deduplicated == expected)
        // And the editor places a moved row where a full build would.
        var record = store.record(at: 3)
        record.customValues[choiceColumn] = .choice(options[3].id)
        let edited = try store.updatingRows([LedgerStore.LedgerRowEdit(index: 3, record: record)])
        coordinator.apply(.editRows(store: edited, editedIndices: [3]))
        let rebuilt = edited.makeView(spec)
        #expect(coordinator.view.tree == rebuilt.tree)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices)
    }
}
