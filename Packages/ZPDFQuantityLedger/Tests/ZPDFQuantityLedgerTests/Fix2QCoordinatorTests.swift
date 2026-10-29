import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// Improvements IM-008 (key-based sort), IM-082 (cheapest path per mutation) and IM-195
/// (lazy catch-up of cached group trees). Work is asserted with the coordinator's counters;
/// every result is asserted equal to ``LedgerStore/makeView(_:)`` over the same store.
@Suite("Fix2 Q — coordinator paths and sort keys")
struct Fix2QCoordinatorTests {

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

    /// The pre-IM-008 sort, which reads both cells inside the comparator: the reference the
    /// key-based sort is checked and measured against. Every sorter here has a descriptor.
    private func sortedReadingCellsInComparator(_ sorter: LedgerSorter, _ indices: [Int]) -> [Int] {
        indices.sorted { sorter.compare($0, $1) == .orderedAscending }
    }

    private func expectMatchesMakeView(_ coordinator: LedgerCoordinator, _ comment: Comment) {
        let rebuilt = coordinator.view.store.makeView(coordinator.view.spec)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices, comment)
        #expect(coordinator.view.tree == rebuilt.tree, comment)
    }

    private var areaFilter: LedgerFilterNode {
        .rule(LedgerFilterRule(
            column: SyntheticLedger.columnID(.planArea),
            op: .greaterThan,
            value: .quantity(.area(2))
        ))
    }

    // MARK: - IM-082

    @Test("IM-082: a sort, an aggregation plan or a columns-only spec never re-runs the filter")
    func cheapestPathPerMutation() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 900)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(filter: areaFilter, grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        let start = coordinator.diagnostics

        coordinator.apply(.setSort([LedgerSortDescriptor(column: SyntheticLedger.columnID(.planArea), ascending: false)]))
        // Old path: `makeView`, one full filter scan.
        #expect(coordinator.diagnostics.filterScans == start.filterScans)
        #expect(coordinator.diagnostics.sorts == start.sorts + 1)
        expectMatchesMakeView(coordinator, "setSort")

        var plan = SyntheticLedger.plan
        plan.add(AggregateKey(column: SyntheticLedger.columnID(.planArea), function: .maximum))
        let beforePlan = coordinator.diagnostics
        coordinator.apply(.setAggregation(plan))
        // Old path: a filter scan and an n log n sort.
        #expect(coordinator.diagnostics.filterScans == beforePlan.filterScans)
        #expect(coordinator.diagnostics.sorts == beforePlan.sorts)
        #expect(coordinator.diagnostics.treeBuilds == beforePlan.treeBuilds + 1)
        expectMatchesMakeView(coordinator, "setAggregation")

        // Warm the cache with a second grouping, then switch the spec's columns only.
        let page = LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))
        coordinator.apply(.setGrouping([page]))
        coordinator.apply(.setGrouping([subject]))
        var columnsOnly = coordinator.view.spec
        columnsOnly.visibleColumns = [SyntheticLedger.columnID(.subject), SyntheticLedger.columnID(.planArea)]
        let beforeColumns = coordinator.diagnostics
        let update = coordinator.apply(.setSpec(columnsOnly))
        #expect(update.change == [.columns])
        #expect(coordinator.diagnostics.filterScans == beforeColumns.filterScans)
        #expect(coordinator.diagnostics.sorts == beforeColumns.sorts)
        #expect(coordinator.diagnostics.treeBuilds == beforeColumns.treeBuilds)
        // The cache survived the spec switch: toggling back is a hit, not a build.
        coordinator.apply(.setGrouping([page]))
        #expect(coordinator.diagnostics.cacheHits == beforeColumns.cacheHits + 1)
        #expect(coordinator.diagnostics.treeBuilds == beforeColumns.treeBuilds)
        expectMatchesMakeView(coordinator, "cached grouping after a columns-only spec")

        // A spec that changes the sort and the grouping still skips the filter.
        var sortAndGroup = coordinator.view.spec
        sortAndGroup.sort = [LedgerSortDescriptor(column: SyntheticLedger.columnID(.label))]
        sortAndGroup.grouping = [subject, page]
        let beforeSpec = coordinator.diagnostics
        coordinator.apply(.setSpec(sortAndGroup))
        #expect(coordinator.diagnostics.filterScans == beforeSpec.filterScans)
        expectMatchesMakeView(coordinator, "setSpec sort + grouping")

        // A filter change is the one that must scan.
        var refiltered = coordinator.view.spec
        refiltered.filter = .all
        coordinator.apply(.setSpec(refiltered))
        #expect(coordinator.diagnostics.filterScans == beforeSpec.filterScans + 1)
        expectMatchesMakeView(coordinator, "setSpec filter")
    }

    // MARK: - IM-195

    @Test("IM-195: an edit touches only the active tree; cached trees catch up when shown")
    func cachedTreesCatchUpLazily() throws {
        var store = try SyntheticLedger.makeStore(rowCount: 700)
        let groupings = SyntheticLedger.groupings(store.columns)
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(filter: areaFilter, grouping: groupings[0], aggregation: SyntheticLedger.plan)
        )
        for levels in groupings.dropFirst() + [[], groupings[0]] { coordinator.apply(.setGrouping(levels)) }

        let before = coordinator.diagnostics
        var generator = SeededGenerator(seed: 195)
        for _ in 0..<6 {
            let row = Int.random(in: 0..<700, using: &generator)
            // Values straddle the filter's 2 m² threshold, so rows enter and leave the view.
            let value = Decimal(Int.random(in: 0...400, using: &generator)) / 100
            store = try edit(store, row: row) { record, measurement in
                record.subject = SyntheticLedger.subjects[Int.random(in: 0..<7, using: &generator)]
                record.status = MarkupStatus.allCases[Int.random(in: 0..<MarkupStatus.allCases.count, using: &generator)]
                measurement = MeasurementResult(values: [
                    .count: .count(1), .planArea: .area(value), .netArea: .area(value), .planLength: .length(1)
                ])
            }
            coordinator.apply(.editRows(store: store, editedIndices: [row]))
        }
        // Old path: every edit updated all six cached trees plus the active one (42 tree
        // edits); now each edit pays for the active tree alone.
        #expect(coordinator.diagnostics.incrementalTreeEdits + coordinator.diagnostics.treeBuilds
            - before.incrementalTreeEdits - before.treeBuilds == 6)
        expectMatchesMakeView(coordinator, "active grouping after edits")

        // Every cached grouping, flat included, is caught up to the same answer a fresh build
        // gives over the edited store.
        for levels in groupings.dropFirst() + [[]] {
            coordinator.apply(.setGrouping(levels))
            expectMatchesMakeView(coordinator, "cached grouping \(levels.count) levels")
        }
    }

    @Test("IM-195: a cached tree that fell too far behind is dropped and rebuilt")
    func staleCacheEntryIsDropped() throws {
        var store = try SyntheticLedger.makeStore(rowCount: 400)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let page = LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))
        var coordinator = LedgerCoordinator(
            store: store, spec: LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        coordinator.apply(.setGrouping([page]))
        coordinator.apply(.setGrouping([subject]))
        let everyRow = Array(0..<(LedgerCoordinator.pendingEditLimit + 1))
        var edits: [LedgerStore.LedgerRowEdit] = []
        for index in everyRow {
            var record = store.record(at: index)
            record.subject = "Bulk"
            edits.append(LedgerStore.LedgerRowEdit(index: index, record: record))
        }
        store = try store.updatingRows(edits)
        coordinator.apply(.editRows(store: store, editedIndices: everyRow))
        let before = coordinator.diagnostics
        coordinator.apply(.setGrouping([page]))
        #expect(coordinator.diagnostics.cacheHits == before.cacheHits)
        #expect(coordinator.diagnostics.treeBuilds == before.treeBuilds + 1)
        expectMatchesMakeView(coordinator, "dropped entry rebuilt")
    }

    // MARK: - IM-008

    @Test("IM-008: the key-based sort is the comparator's order, nulls, errors, choices and mixed kinds included")
    func keyedSortMatchesComparator() throws {
        var store = try SyntheticLedger.makeStore(rowCount: 1_500)
        var generator = SeededGenerator(seed: 8)
        var edits: [LedgerStore.LedgerRowEdit] = []
        for index in stride(from: 0, to: 1_500, by: 7) {
            var record = store.record(at: index)
            record.label = ["", "B", "A-10", "A-9"][Int.random(in: 0..<4, using: &generator)]
            // No measurement: Plan Area is empty and the `[planArea] * 2` formula errors.
            edits.append(LedgerStore.LedgerRowEdit(index: index, record: record, measurement: .empty))
        }
        store = try store.updatingRows(edits)
        let descriptorSets: [[LedgerSortDescriptor]] = [
            [LedgerSortDescriptor(column: SyntheticLedger.doubledColumnID)],
            [LedgerSortDescriptor(column: SyntheticLedger.doubledColumnID, ascending: false, nulls: .first)],
            [LedgerSortDescriptor(column: SyntheticLedger.columnID(.status), ascending: false),
             LedgerSortDescriptor(column: SyntheticLedger.columnID(.label))],
            [LedgerSortDescriptor(column: SyntheticLedger.columnID(.subject)),
             LedgerSortDescriptor(column: SyntheticLedger.columnID(.planArea), ascending: false, nulls: .first)]
        ]
        var input = Array(0..<1_500)
        input.shuffle(using: &generator)
        for descriptors in descriptorSets {
            let sorter = LedgerSorter(store: store, descriptors: descriptors)
            #expect(sorter.sorted(input) == sortedReadingCellsInComparator(sorter, input))
        }

        // Mixed kinds in one column: numbers of several dimensions, text, dates, empties.
        let mixed: [LedgerCellValue] = [
            .number(.area(2)), .text("b"), .number(.length(2)), .empty, .number(.count(1)),
            .number(.ratio(1)), .date(SyntheticLedger.epoch), .text("A"), .checkbox(true), .empty
        ]
        let rows = (0..<200).map { _ in
            [HandBuiltLedger.valueColumn: mixed[Int.random(in: 0..<mixed.count, using: &generator)]]
        }
        let handBuilt = try HandBuiltLedger.makeStore(rows: rows)
        for ascending in [true, false] {
            let sorter = LedgerSorter(
                store: handBuilt,
                descriptors: [LedgerSortDescriptor(column: HandBuiltLedger.valueColumn, ascending: ascending)]
            )
            let shuffled = Array(0..<200).shuffled(using: &generator)
            #expect(sorter.sorted(shuffled) == sortedReadingCellsInComparator(sorter, shuffled))
        }
    }

    @Test("IM-008: sorting 100 000 rows by label, page and a formula column reads each cell once")
    func keyedSortMeasurement() throws {
        let store = try BigLedger.store()
        let clock = ContinuousClock()
        // Shuffled: the fixture's rows are already in formula order, and a presorted input
        // lets the standard library's run detection hide the comparator's cost.
        var generator = SeededGenerator(seed: 1_008)
        let input = Array(0..<store.rowCount).shuffled(using: &generator)
        for column in [
            SyntheticLedger.columnID(.label), SyntheticLedger.columnID(.pageLabel), SyntheticLedger.doubledColumnID
        ] {
            let sorter = LedgerSorter(
                store: store,
                descriptors: [LedgerSortDescriptor(column: column, ascending: false)]
            )
            var keyed: [Int] = []
            var comparator: [Int] = []
            let keyedTime = clock.measure { keyed = sorter.sorted(input) }
            let comparatorTime = clock.measure { comparator = sortedReadingCellsInComparator(sorter, input) }
            print("IM-008 sort 100 000 rows by \(column): keys \(keyedTime), comparator reads \(comparatorTime)")
            #expect(keyed == comparator)
            if column == SyntheticLedger.doubledColumnID {
                // 100 000 distinct Decimals: the exact comparison itself dominates, so the
                // gain is the saved reads only. Guard against a regression, not for a ratio.
                #expect(keyedTime < comparatorTime * 1.25)
            } else {
                // Four labels, eight pages: dense ranks turn the sort into integer compares
                // (measured 17x and 20x in a debug build).
                #expect(keyedTime * 4 < comparatorTime)
            }
        }
    }
}
