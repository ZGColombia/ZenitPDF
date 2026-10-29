import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// An in-place row edit must produce *exactly* the view a full rebuild
/// produces — same tree, same order, same accumulators — while touching only the changed
/// row's paths. Every test here asserts equality against `store.makeView(spec)`, which is
/// the strongest available oracle: the incremental path cannot drift without failing.
@Suite("Incremental regrouping")
struct IncrementalRegroupTests {

    /// The reference: full rebuild over the same store and spec.
    private func expectMatchesFullRebuild(
        _ coordinator: LedgerCoordinator,
        _ comment: Comment
    ) {
        let rebuilt = coordinator.view.store.makeView(coordinator.view.spec)
        #expect(coordinator.view.matchingRowIndices == rebuilt.matchingRowIndices, comment)
        #expect(coordinator.view.tree == rebuilt.tree, comment)
    }

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

    @Test("Moving a row between existing groups matches a full rebuild, three levels deep")
    func moveBetweenGroups() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 2_000)
        let levels = SyntheticLedger.groupings(store.columns)[3] // zone, label, subject
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
        )
        let newStore = try edit(store, row: 123) { record, measurement in
            record.subject = "Steel"
            measurement = MeasurementResult(values: [
                .count: .count(1),
                .planArea: .area(999), .netArea: .area(999),
                .planLength: .length(1)
            ])
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [123]))
        expectMatchesFullRebuild(coordinator, "move between groups")
    }

    @Test("A key nobody had yet creates its group where the builder would have put it")
    func newGroupIsCreated() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 500)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        let newStore = try edit(store, row: 42) { record, _ in
            record.subject = "Aaa Brand New Trade"
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [42]))
        expectMatchesFullRebuild(coordinator, "created group")
        #expect(coordinator.view.tree.roots.contains { $0.key == .text("Aaa Brand New Trade") })
    }

    @Test("The last row leaving a group prunes the group, at every level")
    func emptiedGroupIsPruned() throws {
        // Seven rows, seven subjects: every leaf holds exactly one row.
        let store = try SyntheticLedger.makeStore(rowCount: 7)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        #expect(coordinator.view.tree.roots.count == 7)
        let victimSubject = store.record(at: 3).subject
        let newStore = try edit(store, row: 3) { record, _ in
            record.subject = store.record(at: 0).subject
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [3]))
        expectMatchesFullRebuild(coordinator, "pruned group")
        #expect(coordinator.view.tree.roots.count == 6)
        #expect(!coordinator.view.tree.roots.contains { $0.key == .text(victimSubject) })
    }

    @Test("An edit that crosses the filter boundary enters and leaves the view correctly")
    func filterBoundaryCrossing() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 1_000)
        let filter = LedgerFilterNode.rule(
            LedgerFilterRule(
                column: SyntheticLedger.columnID(.planArea),
                op: .greaterThan,
                value: .quantity(.area(5))
            )
        )
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(
                filter: filter,
                grouping: [subject],
                aggregation: SyntheticLedger.plan
            )
        )
        let countBefore = coordinator.view.rowCount

        // Row 900 (planArea 9.01) drops below the threshold: it must leave the view.
        var current = try edit(store, row: 900) { _, measurement in
            measurement = MeasurementResult(values: [
                .count: .count(1), .planArea: .area(1), .netArea: .area(1), .planLength: .length(1)
            ])
        }
        coordinator.apply(.editRows(store: current, editedIndices: [900]))
        expectMatchesFullRebuild(coordinator, "left the filter")
        #expect(coordinator.view.rowCount == countBefore - 1)

        // Row 10 (planArea 0.11) climbs above it: it must enter.
        current = try edit(current, row: 10) { _, measurement in
            measurement = MeasurementResult(values: [
                .count: .count(1), .planArea: .area(777), .netArea: .area(777), .planLength: .length(1)
            ])
        }
        coordinator.apply(.editRows(store: current, editedIndices: [10]))
        expectMatchesFullRebuild(coordinator, "entered the filter")
        #expect(coordinator.view.rowCount == countBefore)
    }

    @Test("A changed sort key repositions the row exactly where a full sort puts it")
    func sortRepositioning() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 1_000)
        let spec = LedgerViewSpec(
            sort: [LedgerSortDescriptor(column: SyntheticLedger.columnID(.planArea), ascending: false)],
            grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.subject))],
            aggregation: SyntheticLedger.plan
        )
        var coordinator = LedgerCoordinator(store: store, spec: spec)
        let newStore = try edit(store, row: 500) { _, measurement in
            measurement = MeasurementResult(values: [
                .count: .count(1), .planArea: .area(100_000), .netArea: .area(100_000), .planLength: .length(1)
            ])
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [500]))
        expectMatchesFullRebuild(coordinator, "sort reposition")
        // The biggest plan area, descending: the edited row now leads the sorted list.
        // (`orderedRowIndices` is grouped display order, so the assertion reads the
        // filtered, sorted list the groups partition.)
        #expect(coordinator.view.matchingRowIndices.first == 500)
    }

    @Test("A plan with extremes and distinct counts falls back to recompute, exactly")
    func nonInvertiblePlanRecomputes() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 400)
        var plan = SyntheticLedger.plan
        let planArea = SyntheticLedger.columnID(.planArea)
        plan.add(AggregateKey(column: planArea, function: .minimum))
        plan.add(AggregateKey(column: planArea, function: .maximum))
        plan.add(AggregateKey(column: SyntheticLedger.columnID(.subject), function: .distinctCount))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(
                grouping: [LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))],
                aggregation: plan
            )
        )
        let newStore = try edit(store, row: 200) { record, measurement in
            record.subject = "Renamed"
            measurement = MeasurementResult(values: [
                .count: .count(1), .planArea: .area(Decimal(string: "0.00001")!), .netArea: .area(Decimal(string: "0.00001")!), .planLength: .length(2)
            ])
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [200]))
        expectMatchesFullRebuild(coordinator, "extremes and distinct recompute")
    }

    @Test("A flat view's grand total moves by exactly the edit's delta")
    func flatGrandTotal() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 1_000)
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(aggregation: SyntheticLedger.plan)
        )
        let planArea = SyntheticLedger.columnID(.planArea)
        let before = try exactDecimal(coordinator.view.grandTotal[planArea])
        // Row 9 carries planArea 0.1; make it 10.1: the total moves by exactly 10.
        let newStore = try edit(store, row: 9) { _, measurement in
            measurement = MeasurementResult(values: [
                .count: .count(1),
                .planArea: .area(Decimal(string: "10.1")!), .netArea: .area(Decimal(string: "10.1")!),
                .planLength: .length(1)
            ])
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [9]))
        expectMatchesFullRebuild(coordinator, "flat grand total")
        let after = try exactDecimal(coordinator.view.grandTotal[planArea])
        #expect(after - before == 10)
    }

    @Test("Formula cells of an edited row are re-evaluated; every other row's are shared")
    func formulaReevaluationIsScopedToTheEdit() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 100)
        let doubled = SyntheticLedger.doubledColumnID
        let newStore = try edit(store, row: 5) { _, measurement in
            measurement = MeasurementResult(values: [
                .count: .count(1), .planArea: .area(21), .netArea: .area(21), .planLength: .length(1)
            ])
        }
        #expect(newStore.value(at: 5, column: doubled).quantity?.value == 42)
        // An untouched row still reads the shared formula cells.
        #expect(newStore.value(at: 6, column: doubled) == store.value(at: 6, column: doubled))
        // And the base store is unchanged: value semantics survived the overlay.
        #expect(store.value(at: 5, column: doubled).quantity?.value != 42)
    }

    @Test("The grouped-index cache serves a toggled-back grouping and survives edits")
    func groupedIndexCache() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 1_000)
        let subject = LedgerGroupingField(column: SyntheticLedger.columnID(.subject))
        let page = LedgerGroupingField(column: SyntheticLedger.columnID(.pageLabel))
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: [subject], aggregation: SyntheticLedger.plan)
        )
        let subjectTree = coordinator.view.tree
        coordinator.apply(.setGrouping([page]))
        let pageTree = coordinator.view.tree
        coordinator.apply(.setGrouping([subject]))
        #expect(coordinator.view.tree == subjectTree)

        // An edit keeps every cached tree current: toggling to the page grouping after the
        // edit must equal a from-scratch build over the edited store, not the stale cache.
        let newStore = try edit(store, row: 77) { record, _ in
            record.subject = "Steel"
        }
        coordinator.apply(.editRows(store: newStore, editedIndices: [77]))
        expectMatchesFullRebuild(coordinator, "post-edit active grouping")
        coordinator.apply(.setGrouping([page]))
        // The full-rebuild oracle proves the cached page tree was kept current through
        // the edit rather than served stale. (A subject move does not change any page
        // partition or any planned aggregate, so the tree may legitimately be equal —
        // the equality below is the real assertion.)
        expectMatchesFullRebuild(coordinator, "post-edit cached grouping")
        _ = pageTree
    }

    @Test("Several rows edited in one mutation match a full rebuild")
    func multiRowEdit() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 800)
        let levels = SyntheticLedger.groupings(store.columns)[2] // status, subject
        var coordinator = LedgerCoordinator(
            store: store,
            spec: LedgerViewSpec(grouping: levels, aggregation: SyntheticLedger.plan)
        )
        var edits: [LedgerStore.LedgerRowEdit] = []
        for index in [3, 400, 401, 799] {
            var record = store.record(at: index)
            record.subject = index % 2 == 0 ? "Concrete" : "Moved Elsewhere"
            edits.append(LedgerStore.LedgerRowEdit(index: index, record: record))
        }
        let newStore = try store.updatingRows(edits)
        coordinator.apply(.editRows(store: newStore, editedIndices: [3, 400, 401, 799]))
        expectMatchesFullRebuild(coordinator, "multi-row edit")
    }
}
