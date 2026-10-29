import Foundation
import ZPDFContracts

/// What changed, so the view can update the part that changed.
///
/// Narrow on purpose. A table that is told "something happened" reloads 100 000 rows; a table
/// that is told "the filter changed, the columns did not" keeps its column layout, its scroll
/// position and its cached headers, and rebinds only the rows.
public struct LedgerChangeSet: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The underlying rows changed: an edit, an insert, a delete, or a new store.
    public static let rows = LedgerChangeSet(rawValue: 1 << 0)
    /// The column set or the visible column list changed.
    public static let columns = LedgerChangeSet(rawValue: 1 << 1)
    /// The grouping levels changed.
    public static let grouping = LedgerChangeSet(rawValue: 1 << 2)
    /// The filter tree changed.
    public static let filter = LedgerChangeSet(rawValue: 1 << 3)
    /// The sort descriptors changed.
    public static let sort = LedgerChangeSet(rawValue: 1 << 4)
    /// Subtotals or the grand total changed. Implied by most of the above, but stated separately
    /// so a footer can redraw without the body doing anything.
    public static let totals = LedgerChangeSet(rawValue: 1 << 5)

    public static let none: LedgerChangeSet = []
    public static let everything: LedgerChangeSet = [
        .rows, .columns, .grouping, .filter, .sort, .totals
    ]
}

/// A change to apply to a ledger view.
public enum LedgerMutation: Sendable {
    case setFilter(LedgerFilterNode)
    case setSort([LedgerSortDescriptor])
    case setGrouping([LedgerGroupingField])
    case setAggregation(LedgerAggregationPlan)
    case setVisibleColumns([ColumnID])
    case setSpec(LedgerViewSpec)
    /// A new store — rows edited, added or removed, or formulas recomputed.
    case replaceStore(LedgerStore)
    /// Rows edited **in place** — same count, same identities, new content — with the
    /// edited store built by ``LedgerStore/updatingRows(_:)``. The view is updated
    /// incrementally: a one-row mutation repositions one row and re-touches one group
    /// path, instead of re-filtering, re-sorting and re-aggregating 100 000 rows
    /// on every edit. Semantically identical to `replaceStore`; only the cost differs,
    /// and the regrouping invariance tests assert exactly that.
    case editRows(store: LedgerStore, editedIndices: [Int])
}

/// The result of applying a mutation.
public struct LedgerUpdate: Sendable {
    public let change: LedgerChangeSet
    public let view: LedgerView
}

/// Holds the current view and turns mutations into narrow change sets.
///
/// A plain value type with a `mutating` apply, not an actor: the aggregation core is pure and
/// synchronous, so the concurrency decision belongs to whoever owns the coordinator. A caller
/// that wants regrouping off the main actor puts the coordinator behind its own actor or hops a
/// task; nothing here forces `await` on a test that does not need one.
///
/// # Each mutation takes the cheapest valid path (IM-082)
///
/// A sort cannot change which rows match, so `setSort` re-sorts the matching list and
/// rebuilds the partition without re-running the filter. A new aggregation plan changes
/// neither membership nor order, so `setAggregation` rebuilds the partition over the
/// existing list. `setSpec` dispatches per changed field the same way, and a spec that only
/// changes the visible columns keeps the tree and the whole grouped-tree cache. Every path
/// produces the view ``LedgerStore/makeView(_:)`` would, which the differential tests assert.
public struct LedgerCoordinator: Sendable {
    public private(set) var view: LedgerView

    /// A group tree built for the current store, filter and sort, plus the edit batches it
    /// has not seen yet (IM-195). Edits are recorded here and replayed only when the
    /// grouping is switched back to, so one edit pays for the active tree alone.
    private struct CachedTree: Sendable {
        var tree: LedgerGroupTree
        var pending: [LedgerIncrementalUpdater.Batch]
        var pendingEditCount: Int
    }

    /// Group trees already built for the current store, filter and sort, keyed by their
    /// grouping levels — the grouped-index cache. Switching back to a
    /// recently used grouping is a dictionary hit (plus any pending edits replayed) instead
    /// of a 400 ms rebuild. Anything that changes which rows are in the view, or their order,
    /// or the aggregation plan, empties it.
    private var treeCache: [[LedgerGroupingField]: CachedTree] = [:]
    /// Insertion order of ``treeCache`` keys, oldest first, for eviction.
    private var treeCacheOrder: [[LedgerGroupingField]] = []
    /// Cached trees kept besides the active one. A tree is a few arrays of `Int` plus the
    /// accumulators, so this bounds memory without ever evicting the groupings a user is
    /// actually toggling between.
    private static let treeCacheLimit = 6
    /// Edited rows a cached tree may fall behind by before it is dropped rather than caught
    /// up: past this, replaying costs more than a rebuild would.
    static let pendingEditLimit = 256

    /// Edited rows past which one ``LedgerMutation/editRows(store:editedIndices:)`` batch
    /// rebuilds the view instead of updating it row by row (V-061): a thirty-second of the
    /// rows, and never fewer than ``pendingEditLimit``. Each delta costs O(n) array shifts, a
    /// rebuild O(n log n) once, so the crossover is a fraction of the row count.
    static func bulkEditLimit(rowCount: Int) -> Int {
        max(pendingEditLimit, rowCount / 32)
    }

    /// Work counters, for the tests that assert a mutation took the cheap path.
    struct Diagnostics: Hashable, Sendable {
        /// Full filter scans over the store.
        var filterScans = 0
        /// Full sorts of the matching list.
        var sorts = 0
        /// Group trees built from scratch by ``LedgerGroupBuilder``.
        var treeBuilds = 0
        /// Edit batches applied to a tree by the incremental editor, active or replayed.
        var incrementalTreeEdits = 0
        /// Groupings served from the cache.
        var cacheHits = 0
    }

    private(set) var diagnostics = Diagnostics()

    public init(store: LedgerStore, spec: LedgerViewSpec = LedgerViewSpec()) {
        self.view = LedgerView(
            store: store, spec: spec, matchingRowIndices: [],
            tree: LedgerGroupTree(
                levels: [], roots: [], orderedRowIndices: [], grandTotal: .empty,
                dayCalendar: spec.dayCalendar
            )
        )
        self.view = fullView(store: store, spec: spec)
    }

    @discardableResult
    public mutating func apply(_ mutation: LedgerMutation) -> LedgerUpdate {
        var spec = view.spec

        switch mutation {
        case .setFilter(let filter):
            guard filter != spec.filter else { return unchanged() }
            spec.filter = filter
            clearTreeCache()
            view = fullView(store: view.store, spec: spec)
            return LedgerUpdate(change: [.filter, .rows, .totals], view: view)
        case .setSort(let sort):
            guard sort != spec.sort else { return unchanged() }
            spec.sort = sort
            // A sort reorders rows; it cannot change any total. `.totals` is deliberately
            // absent — and the filter is not re-run, because it cannot change either.
            clearTreeCache()
            view = resortedView(store: view.store, spec: spec, matching: view.matchingRowIndices)
            return LedgerUpdate(change: [.sort, .rows], view: view)
        case .setGrouping(let grouping):
            guard grouping != spec.grouping else { return unchanged() }
            // The filter and sort are untouched, so the filtered, sorted index list is
            // reused as-is and only the partition is (re)built — or fetched back from the
            // cache, where a previous toggle already paid for it.
            cacheTree(view.tree, for: spec.grouping)
            spec.grouping = grouping
            let tree = cachedTree(for: grouping, spec: spec)
                ?? buildTree(store: view.store, spec: spec, matching: view.matchingRowIndices)
            cacheTree(tree, for: grouping)
            view = LedgerView(
                store: view.store, spec: spec,
                matchingRowIndices: view.matchingRowIndices, tree: tree
            )
            return LedgerUpdate(change: [.grouping, .rows, .totals], view: view)
        case .setAggregation(let plan):
            guard plan != spec.aggregation else { return unchanged() }
            spec.aggregation = plan
            // Membership and order are untouched; only the accumulators change.
            clearTreeCache()
            view = LedgerView(
                store: view.store, spec: spec,
                matchingRowIndices: view.matchingRowIndices,
                tree: buildTree(store: view.store, spec: spec, matching: view.matchingRowIndices)
            )
            return LedgerUpdate(change: [.totals], view: view)
        case .setVisibleColumns(let columns):
            guard columns != spec.visibleColumns else { return unchanged() }
            // Which columns are on screen affects neither membership, order nor totals:
            // the projection carries over untouched, and the cache stays valid.
            spec.visibleColumns = columns
            view = LedgerView(
                store: view.store, spec: spec,
                matchingRowIndices: view.matchingRowIndices, tree: view.tree
            )
            return LedgerUpdate(change: [.columns], view: view)
        case .setSpec(let newSpec):
            guard newSpec != spec else { return unchanged() }
            var change = LedgerChangeSet.none
            if newSpec.filter != spec.filter { change.insert(.filter) }
            if newSpec.sort != spec.sort { change.insert(.sort) }
            if newSpec.grouping != spec.grouping { change.insert(.grouping) }
            if newSpec.aggregation != spec.aggregation { change.insert(.totals) }
            if newSpec.visibleColumns != spec.visibleColumns { change.insert(.columns) }
            // T-047: another day calendar re-cuts every date group, so it regroups — and every
            // cached tree was cut with the old one.
            let dayCalendarChanged = newSpec.dayCalendar != spec.dayCalendar
            if dayCalendarChanged { change.insert(.grouping) }
            if change.contains(.filter) || change.contains(.grouping) {
                change.formUnion([.rows, .totals])
            } else if change.contains(.sort) {
                change.insert(.rows)
            }
            // Per changed field, cheapest first: a filter change needs everything; a sort
            // change keeps the matching set; an aggregation or grouping change keeps the
            // order too; columns alone keep the tree and the cache.
            if change.contains(.filter) {
                clearTreeCache()
                view = fullView(store: view.store, spec: newSpec)
            } else if change.contains(.sort) {
                clearTreeCache()
                view = resortedView(store: view.store, spec: newSpec, matching: view.matchingRowIndices)
            } else if change.contains(.totals) || dayCalendarChanged {
                clearTreeCache()
                view = LedgerView(
                    store: view.store, spec: newSpec,
                    matchingRowIndices: view.matchingRowIndices,
                    tree: buildTree(store: view.store, spec: newSpec, matching: view.matchingRowIndices)
                )
            } else if change.contains(.grouping) {
                cacheTree(view.tree, for: spec.grouping)
                let tree = cachedTree(for: newSpec.grouping, spec: newSpec)
                    ?? buildTree(store: view.store, spec: newSpec, matching: view.matchingRowIndices)
                cacheTree(tree, for: newSpec.grouping)
                view = LedgerView(
                    store: view.store, spec: newSpec,
                    matchingRowIndices: view.matchingRowIndices, tree: tree
                )
            } else {
                view = LedgerView(
                    store: view.store, spec: newSpec,
                    matchingRowIndices: view.matchingRowIndices, tree: view.tree
                )
            }
            return LedgerUpdate(change: change, view: view)
        case .replaceStore(let newStore):
            clearTreeCache()
            view = fullView(store: newStore, spec: spec)
            return LedgerUpdate(change: [.rows, .totals], view: view)
        case .editRows(let newStore, let editedIndices):
            precondition(
                newStore.rowCount == view.store.rowCount,
                "editRows is for in-place edits; a row was added or removed — use replaceStore"
            )
            guard !editedIndices.isEmpty else { return unchanged() }
            // V-061: the delta path repositions each edited row in the matching list and in
            // its leaf, an O(n) array shift per row, so a select-all edit (Status, Price Rows,
            // Update Rates over 100 000 rows) was quadratic — seconds. Past the bound one
            // rebuild is cheaper, and the differential tests assert both paths give the same
            // view. Every cached tree was built for the old rows and would need the same
            // replay, so the cache goes too.
            if editedIndices.count > Self.bulkEditLimit(rowCount: newStore.rowCount) {
                clearTreeCache()
                view = fullView(store: newStore, spec: spec)
                return LedgerUpdate(change: [.rows, .totals], view: view)
            }
            let result = LedgerIncrementalUpdater.update(
                view: view,
                newStore: newStore,
                editedIndices: editedIndices
            )
            if result.rebuiltTree {
                diagnostics.treeBuilds += 1
            } else {
                diagnostics.incrementalTreeEdits += 1
            }
            // Every other cached tree just records the batch (IM-195); the active one is
            // current and carries nothing pending.
            for levels in treeCacheOrder where levels != spec.grouping {
                guard var entry = treeCache[levels] else { continue }
                entry.pending.append(result.batch)
                entry.pendingEditCount += result.batch.changes.count
                if entry.pendingEditCount > Self.pendingEditLimit {
                    treeCache[levels] = nil
                } else {
                    treeCache[levels] = entry
                }
            }
            treeCacheOrder.removeAll { treeCache[$0] == nil }
            if treeCache[spec.grouping] != nil {
                treeCache[spec.grouping] = CachedTree(tree: result.view.tree, pending: [], pendingEditCount: 0)
            }
            view = result.view
            return LedgerUpdate(change: [.rows, .totals], view: view)
        }
    }

    private func unchanged() -> LedgerUpdate {
        LedgerUpdate(change: .none, view: view)
    }

    // MARK: - Pipeline steps

    /// Filter, sort, group — the same three steps as ``LedgerStore/makeView(_:)``, counted.
    private mutating func fullView(store: LedgerStore, spec: LedgerViewSpec) -> LedgerView {
        diagnostics.filterScans += 1
        let filtered = LedgerFilterEvaluator(store: store).filter(Array(0..<store.rowCount), with: spec.filter)
        return resortedView(store: store, spec: spec, matching: filtered)
    }

    /// Sort and group an already-filtered list.
    private mutating func resortedView(store: LedgerStore, spec: LedgerViewSpec, matching: [Int]) -> LedgerView {
        diagnostics.sorts += 1
        let sorted = LedgerSorter(store: store, descriptors: spec.sort).sorted(matching)
        return LedgerView(
            store: store, spec: spec, matchingRowIndices: sorted,
            tree: buildTree(store: store, spec: spec, matching: sorted)
        )
    }

    private mutating func buildTree(store: LedgerStore, spec: LedgerViewSpec, matching: [Int]) -> LedgerGroupTree {
        diagnostics.treeBuilds += 1
        return LedgerGroupBuilder(store: store, plan: spec.aggregation, dayCalendar: spec.dayCalendar)
            .build(rowIndices: matching, levels: spec.grouping)
    }

    // MARK: - Tree cache

    private mutating func clearTreeCache() {
        treeCache.removeAll(keepingCapacity: true)
        treeCacheOrder.removeAll(keepingCapacity: true)
    }

    /// The cached tree for `levels`, caught up on every edit it missed (IM-195), or `nil`.
    private mutating func cachedTree(for levels: [LedgerGroupingField], spec: LedgerViewSpec) -> LedgerGroupTree? {
        guard let entry = treeCache[levels] else { return nil }
        diagnostics.cacheHits += 1
        guard !entry.pending.isEmpty else { return entry.tree }
        diagnostics.incrementalTreeEdits += entry.pending.count
        let tree = LedgerIncrementalUpdater.replay(
            entry.pending, onto: entry.tree, spec: spec, newMatching: view.matchingRowIndices
        )
        treeCache[levels] = CachedTree(tree: tree, pending: [], pendingEditCount: 0)
        return tree
    }

    private mutating func cacheTree(_ tree: LedgerGroupTree, for levels: [LedgerGroupingField]) {
        if treeCache[levels] == nil {
            treeCacheOrder.append(levels)
            if treeCacheOrder.count > Self.treeCacheLimit {
                let evicted = treeCacheOrder.removeFirst()
                treeCache[evicted] = nil
            }
        }
        treeCache[levels] = CachedTree(tree: tree, pending: [], pendingEditCount: 0)
    }
}
