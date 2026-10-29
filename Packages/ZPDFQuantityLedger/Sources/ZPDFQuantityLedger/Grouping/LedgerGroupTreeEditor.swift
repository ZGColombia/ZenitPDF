import Foundation
import ZPDFContracts

/// Applies a set of in-place row edits to an existing ``LedgerGroupTree`` without
/// re-partitioning or re-aggregating the rows that did not change, so a one-row edit in a
/// 100 000-row ledger costs one group path, not a rebuild.
///
/// # Why this is exact and not merely fast
///
/// Every subtotal in the tree is an exact `Decimal` accumulator. Moving a row from one
/// group to another therefore has an exact algebraic form: subtract its old cells from the
/// old group's path, add its new cells to the new group's path, both through the same
/// checked arithmetic the full build uses. Where a reversal cannot be proven exact — a
/// running extreme that *is* the removed value, a distinct set, a mixed or failed
/// accumulator — that one aggregate key of the affected node is marked dirty and recomputed
/// from its own rows (leaf) or its own children (interior) after the structural pass, so the
/// fallback is slower, never wrong (IM-076: only the refusing keys, not the whole set). The
/// regrouping invariance tests hold over this path for the same reason they hold over the
/// full build: it is the same accumulator algebra, entered from the other side.
///
/// # When the tree and the edit disagree (BH-193)
///
/// Every removal walks to the row's old leaf by its old key path. If that walk misses — the
/// tree does not have the group the row claims, or the leaf does not hold the row — the tree
/// and the edit have diverged and no delta can be trusted. The old code kept the row in its
/// old leaf and inserted it again, so it was counted twice; now the editor gives up on the
/// delta and the caller rebuilds the tree from the new store. Slower, never wrong.
struct LedgerGroupTreeEditor {

    /// One edited row's membership before and after the edit, under the view's filter.
    struct RowChange: Sendable {
        let index: Int
        /// The row passed the filter before the edit (so it is in the tree now).
        let wasIncluded: Bool
        /// The row passes the filter after the edit (so it belongs in the updated tree).
        let isIncluded: Bool
    }

    let oldStore: LedgerStore
    let newStore: LedgerStore
    let aggregator: LedgerAggregator
    let newSorter: LedgerSorter

    init(oldStore: LedgerStore, newStore: LedgerStore, plan: LedgerAggregationPlan, sort: [LedgerSortDescriptor]) {
        self.oldStore = oldStore
        self.newStore = newStore
        self.aggregator = LedgerAggregator(store: newStore, plan: plan)
        self.newSorter = LedgerSorter(store: newStore, descriptors: sort)
    }

    /// Dirty bookkeeping: per node path, the aggregate keys whose delta was refused.
    private typealias DirtyKeys = [[LedgerGroupKey]: Set<AggregateKey>]

    // MARK: - Entry point

    /// The tree after the edits, over `newMatching` (the filtered, sorted index list the
    /// caller has already updated incrementally).
    ///
    /// Falls back to a full ``LedgerGroupBuilder`` build over `newMatching` when the tree
    /// and the edits disagree (BH-193).
    func apply(
        _ changes: [RowChange],
        to tree: LedgerGroupTree,
        newMatching: [Int]
    ) -> LedgerGroupTree {
        applyIncrementally(changes, to: tree, newMatching: newMatching)
            ?? LedgerGroupBuilder(store: newStore, plan: aggregator.plan, dayCalendar: tree.dayCalendar)
                .build(rowIndices: newMatching, levels: tree.levels)
    }

    /// The incremental result, or `nil` when the tree and the edits disagree and only a
    /// rebuild is trustworthy.
    func applyIncrementally(
        _ changes: [RowChange],
        to tree: LedgerGroupTree,
        newMatching: [Int]
    ) -> LedgerGroupTree? {
        guard !tree.levels.isEmpty else {
            return flatTree(after: changes, from: tree, newMatching: newMatching)
        }

        let definitions = tree.levels.map { newStore.columns.column(id: $0.column) }
        let choiceOrders = definitions.map { $0?.choiceRank ?? [:] }

        var roots = tree.roots
        var dirty: DirtyKeys = [:]

        // Structural pass: removals first, so every index list stays sorted consistently
        // under both stores' comparators (only edited rows compare differently, and they
        // are out of every list while it is searched).
        for change in changes where change.wasIncluded {
            let keys = keyPath(
                of: change.index, in: oldStore, levels: tree.levels, definitions: definitions,
                dayCalendar: tree.dayCalendar
            )
            guard let updated = removing(
                row: change.index, keys: keys, from: roots, depth: 0,
                choiceOrders: choiceOrders, dirty: &dirty
            ) else { return nil }
            roots = updated
        }
        for change in changes where change.isIncluded {
            let keys = keyPath(
                of: change.index, in: newStore, levels: tree.levels, definitions: definitions,
                dayCalendar: tree.dayCalendar
            )
            roots = inserting(
                row: change.index, keys: keys, into: roots, depth: 0, path: [],
                levels: tree.levels, choiceOrders: choiceOrders
            )
        }

        // Recompute pass: only the keys a delta could not update exactly, bottom-up.
        if !dirty.isEmpty {
            var affected = Set<[LedgerGroupKey]>()
            for path in dirty.keys {
                for length in 1...path.count { affected.insert(Array(path.prefix(length))) }
            }
            roots = roots.map { recomputed($0, dirty: dirty, affected: affected) }
        }

        var ordered: [Int] = []
        ordered.reserveCapacity(newMatching.count)
        // As the builder does (U-061): an edit that empties every group still reports the
        // planned keys, not an empty grand total.
        var grand = roots.isEmpty ? aggregator.aggregate(rowIndices: []) : LedgerAggregates.empty
        for root in roots {
            ordered.append(contentsOf: root.allRowIndices())
            grand = grand.merging(root.aggregates)
        }
        return LedgerGroupTree(
            levels: tree.levels,
            roots: roots,
            orderedRowIndices: ordered,
            grandTotal: grand,
            dayCalendar: tree.dayCalendar
        )
    }

    // MARK: - Flat (no grouping levels)

    private func flatTree(
        after changes: [RowChange],
        from tree: LedgerGroupTree,
        newMatching: [Int]
    ) -> LedgerGroupTree {
        var grand = tree.grandTotal
        var refused = Set<AggregateKey>()
        for change in changes where change.wasIncluded {
            let removal = aggregator.removingWhereExact(row: change.index, from: grand, readingFrom: oldStore)
            grand = removal.aggregates
            refused.formUnion(removal.refused)
        }
        for change in changes where change.isIncluded {
            grand = aggregator.adding(row: change.index, to: grand)
        }
        if !refused.isEmpty {
            // Only the refusing keys pay for a pass over every row (IM-076).
            grand = grand.replacing(refused, with: aggregator.aggregate(rowIndices: newMatching, keys: refused))
        }
        return LedgerGroupTree(
            levels: [],
            roots: [],
            orderedRowIndices: newMatching,
            grandTotal: grand,
            dayCalendar: tree.dayCalendar
        )
    }

    // MARK: - Keys

    private func keyPath(
        of index: Int,
        in store: LedgerStore,
        levels: [LedgerGroupingField],
        definitions: [LedgerColumnDefinition?],
        dayCalendar: Calendar
    ) -> [LedgerGroupKey] {
        zip(levels, definitions).map { field, definition in
            let cell = definition.map { store.value(at: index, definition: $0) }
                ?? store.value(at: index, column: field.column)
            return LedgerGroupKey(cell, dayCalendar: dayCalendar)
        }
    }

    // MARK: - Removal

    /// The siblings with `row` taken out of the group its old keys name, or `nil` when the
    /// tree does not have that group or that leaf does not hold the row (BH-193).
    private func removing(
        row: Int,
        keys: [LedgerGroupKey],
        from nodes: [LedgerGroupNode],
        depth: Int,
        choiceOrders: [[ChoiceOptionID: Int]],
        dirty: inout DirtyKeys
    ) -> [LedgerGroupNode]? {
        guard let position = siblingIndex(of: keys[depth], in: nodes, choiceOrder: choiceOrders[depth]) else {
            return nil
        }
        let node = nodes[position]
        var updated = nodes

        if node.isLeaf {
            var rows = node.rowIndices
            guard let rowPosition = rows.firstIndex(of: row) else { return nil }
            rows.remove(at: rowPosition)
            if rows.isEmpty {
                updated.remove(at: position)
                return updated
            }
            let removal = aggregator.removingWhereExact(row: row, from: node.aggregates, readingFrom: oldStore)
            if !removal.refused.isEmpty { dirty[node.path, default: []].formUnion(removal.refused) }
            updated[position] = LedgerGroupNode(
                key: node.key, path: node.path, field: node.field, depth: node.depth,
                children: [], rowIndices: rows, descendantRowCount: rows.count,
                aggregates: removal.aggregates
            )
            return updated
        }

        guard let children = removing(
            row: row, keys: keys, from: node.children, depth: depth + 1,
            choiceOrders: choiceOrders, dirty: &dirty
        ) else { return nil }
        if children.isEmpty {
            updated.remove(at: position)
            return updated
        }
        let removal = aggregator.removingWhereExact(row: row, from: node.aggregates, readingFrom: oldStore)
        if !removal.refused.isEmpty { dirty[node.path, default: []].formUnion(removal.refused) }
        updated[position] = LedgerGroupNode(
            key: node.key, path: node.path, field: node.field, depth: node.depth,
            children: children, rowIndices: [], descendantRowCount: node.descendantRowCount - 1,
            aggregates: removal.aggregates
        )
        return updated
    }

    // MARK: - Insertion

    private func inserting(
        row: Int,
        keys: [LedgerGroupKey],
        into nodes: [LedgerGroupNode],
        depth: Int,
        path: [LedgerGroupKey],
        levels: [LedgerGroupingField],
        choiceOrders: [[ChoiceOptionID: Int]]
    ) -> [LedgerGroupNode] {
        let key = keys[depth]
        var updated = nodes

        guard let position = siblingIndex(of: key, in: nodes, choiceOrder: choiceOrders[depth]) else {
            // A group that did not exist: create the chain down to a one-row leaf, at the
            // position the full build's key ordering would have chosen.
            let node = makeChain(row: row, keys: keys, depth: depth, path: path, levels: levels)
            let at = lowerBound(for: key, in: nodes, choiceOrder: choiceOrders[depth])
            updated.insert(node, at: at)
            return updated
        }

        let node = nodes[position]
        if node.isLeaf {
            var rows = node.rowIndices
            rows.insert(row, at: newSorter.insertionIndex(for: row, in: rows))
            updated[position] = LedgerGroupNode(
                key: node.key, path: node.path, field: node.field, depth: node.depth,
                children: [], rowIndices: rows, descendantRowCount: rows.count,
                aggregates: aggregator.adding(row: row, to: node.aggregates)
            )
            return updated
        }

        let children = inserting(
            row: row, keys: keys, into: node.children, depth: depth + 1, path: node.path,
            levels: levels, choiceOrders: choiceOrders
        )
        updated[position] = LedgerGroupNode(
            key: node.key, path: node.path, field: node.field, depth: node.depth,
            children: children, rowIndices: [], descendantRowCount: node.descendantRowCount + 1,
            aggregates: aggregator.adding(row: row, to: node.aggregates)
        )
        return updated
    }

    private func makeChain(
        row: Int,
        keys: [LedgerGroupKey],
        depth: Int,
        path: [LedgerGroupKey],
        levels: [LedgerGroupingField]
    ) -> LedgerGroupNode {
        let key = keys[depth]
        let childPath = path + [key]
        if depth == levels.count - 1 {
            return LedgerGroupNode(
                key: key, path: childPath, field: levels[depth], depth: depth,
                children: [], rowIndices: [row], descendantRowCount: 1,
                aggregates: aggregator.aggregate(rowIndices: CollectionOfOne(row))
            )
        }
        let child = makeChain(row: row, keys: keys, depth: depth + 1, path: childPath, levels: levels)
        // The full build merges children into `.empty`; with one child that merge *is* the
        // child's accumulator set, so this matches it bit for bit.
        return LedgerGroupNode(
            key: key, path: childPath, field: levels[depth], depth: depth,
            children: [child], rowIndices: [], descendantRowCount: 1,
            aggregates: LedgerAggregates.empty.merging(child.aggregates)
        )
    }

    // MARK: - Dirty recompute

    private func recomputed(
        _ node: LedgerGroupNode,
        dirty: DirtyKeys,
        affected: Set<[LedgerGroupKey]>
    ) -> LedgerGroupNode {
        guard affected.contains(node.path) else { return node }
        if node.isLeaf {
            guard let keys = dirty[node.path] else { return node }
            return LedgerGroupNode(
                key: node.key, path: node.path, field: node.field, depth: node.depth,
                children: [], rowIndices: node.rowIndices,
                descendantRowCount: node.rowIndices.count,
                aggregates: node.aggregates.replacing(
                    keys, with: aggregator.aggregate(rowIndices: node.rowIndices, keys: keys)
                )
            )
        }
        let children = node.children.map { recomputed($0, dirty: dirty, affected: affected) }
        var aggregates = node.aggregates
        if let keys = dirty[node.path] {
            // The full build merges children into `.empty`; the same merge, for these keys.
            var merged = LedgerAggregates.empty
            for child in children { merged = merged.merging(child.aggregates, keys: keys) }
            aggregates = aggregates.replacing(keys, with: merged)
        }
        return LedgerGroupNode(
            key: node.key, path: node.path, field: node.field, depth: node.depth,
            children: children, rowIndices: [], descendantRowCount: node.descendantRowCount,
            aggregates: aggregates
        )
    }

    // MARK: - Sibling search

    /// The position of `key` among siblings the builder ordered, or `nil` when absent.
    ///
    /// Binary search over `LedgerGroupKey.compare`, which is a total order over distinct keys
    /// (BH-194, BH-195); a tie with a *different* key can only come from the `default` arm of
    /// the comparator, and that region is scanned linearly rather than trusted.
    private func siblingIndex(
        of key: LedgerGroupKey,
        in nodes: [LedgerGroupNode],
        choiceOrder: [ChoiceOptionID: Int]
    ) -> Int? {
        var low = 0
        var high = nodes.count
        while low < high {
            let mid = (low + high) / 2
            switch LedgerGroupKey.compare(nodes[mid].key, key, choiceOrder: choiceOrder) {
            case .orderedAscending:
                low = mid + 1
            case .orderedDescending:
                high = mid
            case .orderedSame:
                if nodes[mid].key == key { return mid }
                // Scan the tie region in both directions.
                var backward = mid - 1
                while backward >= 0,
                      LedgerGroupKey.compare(nodes[backward].key, key, choiceOrder: choiceOrder) == .orderedSame {
                    if nodes[backward].key == key { return backward }
                    backward -= 1
                }
                var forward = mid + 1
                while forward < nodes.count,
                      LedgerGroupKey.compare(nodes[forward].key, key, choiceOrder: choiceOrder) == .orderedSame {
                    if nodes[forward].key == key { return forward }
                    forward += 1
                }
                return nil
            }
        }
        return nil
    }

    /// The first sibling position that does not order before `key`.
    private func lowerBound(
        for key: LedgerGroupKey,
        in nodes: [LedgerGroupNode],
        choiceOrder: [ChoiceOptionID: Int]
    ) -> Int {
        var low = 0
        var high = nodes.count
        while low < high {
            let mid = (low + high) / 2
            if LedgerGroupKey.compare(nodes[mid].key, key, choiceOrder: choiceOrder) == .orderedAscending {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

/// Turns a set of in-place row edits into an incrementally updated ``LedgerView``.
///
/// The cached group trees for the same filter and sort are *not* updated here (IM-195):
/// the coordinator records the batch against each cached entry and replays it only when
/// that grouping is switched back to, so one edit pays for one tree rather than for every
/// tree in the cache.
enum LedgerIncrementalUpdater {

    /// One applied edit batch, kept so a cached tree can catch up later (IM-195).
    struct Batch: Sendable {
        let oldStore: LedgerStore
        let newStore: LedgerStore
        let changes: [LedgerGroupTreeEditor.RowChange]
    }

    struct Result {
        let view: LedgerView
        let batch: Batch
        /// True when the active tree could not be updated by delta and was rebuilt (BH-193).
        let rebuiltTree: Bool
    }

    static func update(
        view: LedgerView,
        newStore: LedgerStore,
        editedIndices: [Int]
    ) -> Result {
        let spec = view.spec
        let oldStore = view.store
        // Compiled once per batch, not once per row (V-061): `matches(rowIndex:node:)`
        // resolves every rule's column and builds its sets on each call.
        let oldFilter = LedgerFilterEvaluator(store: oldStore).compiled(spec.filter)
        let newFilter = LedgerFilterEvaluator(store: newStore).compiled(spec.filter)
        let oldSorter = LedgerSorter(store: oldStore, descriptors: spec.sort)
        let newSorter = LedgerSorter(store: newStore, descriptors: spec.sort)

        // A cutout row's `Cutout Area` cell reads its parent's policy (ADR-0018), so an edited
        // parent re-evaluates its cutout rows too — otherwise a filter, sort or aggregate over
        // that column would keep the value the parent's old policy gave.
        let affected = Set(editedIndices).union(
            newStore.cutoutRowIndices(ofParentsAt: editedIndices, alsoIn: oldStore)
        )
        let changes: [LedgerGroupTreeEditor.RowChange] = affected.sorted().map { index in
            LedgerGroupTreeEditor.RowChange(
                index: index,
                wasIncluded: oldFilter.matches(rowIndex: index, in: oldStore),
                isIncluded: newFilter.matches(rowIndex: index, in: newStore)
            )
        }

        // The filtered, sorted index list, repositioned in O(edits × log n + moved bytes).
        // Removals run first so the list is never searched while it holds a row whose sort
        // key already changed.
        var matching = view.matchingRowIndices
        for change in changes where change.wasIncluded {
            if let position = oldSorter.position(of: change.index, in: matching) {
                matching.remove(at: position)
            } else {
                // The list and the old comparator disagree (BH-193): take the row out by
                // identity rather than leave a duplicate behind.
                matching.removeAll { $0 == change.index }
            }
        }
        for change in changes where change.isIncluded {
            matching.insert(change.index, at: newSorter.insertionIndex(for: change.index, in: matching))
        }

        let editor = LedgerGroupTreeEditor(
            oldStore: oldStore,
            newStore: newStore,
            plan: spec.aggregation,
            sort: spec.sort
        )
        let incremental = editor.applyIncrementally(changes, to: view.tree, newMatching: matching)
        let tree = incremental
            ?? LedgerGroupBuilder(store: newStore, plan: spec.aggregation, dayCalendar: spec.dayCalendar)
                .build(rowIndices: matching, levels: spec.grouping)

        return Result(
            view: LedgerView(store: newStore, spec: spec, matchingRowIndices: matching, tree: tree),
            batch: Batch(oldStore: oldStore, newStore: newStore, changes: changes),
            rebuiltTree: incremental == nil
        )
    }

    /// Replays pending edit batches onto a cached tree, oldest first. `newMatching` is the
    /// current filtered, sorted list, valid for the *last* batch's store only.
    ///
    /// Only a grouped tree is replayed by delta: its leaves carry their own row lists, so
    /// every intermediate step is self-consistent. A flat tree's delta path recomputes a
    /// refused key over the matching list, and the intermediate lists are not kept, so a
    /// flat tree — one aggregate pass, no partition — is rebuilt from the final store
    /// instead. Any batch the editor cannot apply exactly (BH-193) also ends the replay in a
    /// rebuild from the final store; an intermediate store is never paired with the final
    /// list.
    static func replay(
        _ batches: [Batch],
        onto tree: LedgerGroupTree,
        spec: LedgerViewSpec,
        newMatching: [Int]
    ) -> LedgerGroupTree {
        guard let finalStore = batches.last?.newStore else { return tree }
        func rebuild() -> LedgerGroupTree {
            LedgerGroupBuilder(store: finalStore, plan: spec.aggregation, dayCalendar: spec.dayCalendar)
                .build(rowIndices: newMatching, levels: tree.levels)
        }
        // A tree cut into days by another calendar cannot be caught up by delta (T-047).
        guard !tree.levels.isEmpty, tree.dayCalendar == spec.dayCalendar else { return rebuild() }
        var current = tree
        for batch in batches {
            let editor = LedgerGroupTreeEditor(
                oldStore: batch.oldStore,
                newStore: batch.newStore,
                plan: spec.aggregation,
                sort: spec.sort
            )
            guard let next = editor.applyIncrementally(
                batch.changes, to: current, newMatching: newMatching
            ) else { return rebuild() }
            current = next
        }
        return current
    }
}
