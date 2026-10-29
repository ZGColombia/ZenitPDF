import Foundation
import ZPDFContracts

/// One node of the group tree.
///
/// A node is either interior (it has ``children``) or a leaf (it has ``rowIndices``), never both.
/// ``aggregates`` is present at every level and at every level it is exact: a leaf's aggregates
/// come from its rows, an interior node's from merging its children's accumulators.
public struct LedgerGroupNode: Hashable, Sendable {
    public let key: LedgerGroupKey
    /// Keys from the outermost level down to and including this node's own.
    public let path: [LedgerGroupKey]
    /// The grouping field this level used.
    public let field: LedgerGroupingField
    public let depth: Int
    public let children: [LedgerGroupNode]
    /// Rows directly in this group. Non-empty only for a leaf node.
    public let rowIndices: [Int]
    /// Rows anywhere beneath this node.
    public let descendantRowCount: Int
    public let aggregates: LedgerAggregates

    public var isLeaf: Bool { children.isEmpty }

    /// Every row index beneath this node, in display order.
    public func allRowIndices() -> [Int] {
        guard !isLeaf else { return rowIndices }
        var output: [Int] = []
        output.reserveCapacity(descendantRowCount)
        for child in children { output.append(contentsOf: child.allRowIndices()) }
        return output
    }
}

/// The grouped projection of a filtered, sorted row set.
public struct LedgerGroupTree: Hashable, Sendable {
    /// The grouping levels, outermost first. Empty for a flat ledger.
    public let levels: [LedgerGroupingField]
    public let roots: [LedgerGroupNode]
    /// Rows in display order. For a flat ledger this is the sorted, filtered index list; for a
    /// grouped one it is the concatenation of the leaves in group order.
    public let orderedRowIndices: [Int]
    /// The grand total: the merge of the roots' accumulators, or of every row when flat.
    public let grandTotal: LedgerAggregates
    /// The calendar the tree's date keys were cut into days with (T-047). The incremental
    /// editor keys an edited row with this same calendar, so its removal walk finds the leaf
    /// the builder filed the row under.
    public let dayCalendar: Calendar

    init(
        levels: [LedgerGroupingField],
        roots: [LedgerGroupNode],
        orderedRowIndices: [Int],
        grandTotal: LedgerAggregates,
        dayCalendar: Calendar
    ) {
        self.levels = levels
        self.roots = roots
        self.orderedRowIndices = orderedRowIndices
        self.grandTotal = grandTotal
        self.dayCalendar = dayCalendar
    }

    public var rowCount: Int { orderedRowIndices.count }
    public var isFlat: Bool { levels.isEmpty }
}

/// Builds a ``LedgerGroupTree``.
///
/// # Why subtotals are merged rather than recomputed
///
/// The obvious implementation walks the rows once per level. It is also the implementation in
/// which a parent subtotal and the sum of its children can differ — because they are two
/// independent computations over the same data, and any asymmetry between them (a rounding, a
/// skipped error row, a different mixed-dimension rule) shows up as a total that does not
/// reconcile. Here a leaf accumulates rows, and every level above it *merges accumulators*. The
/// parent literally is the sum of its children, and the grand total literally is the sum of the
/// roots, so QUALITY_BAR A5 and A7 cannot fail without the merge itself being wrong — which is a
/// single function with its own tests.
public struct LedgerGroupBuilder: Sendable {
    public let store: LedgerStore
    public let plan: LedgerAggregationPlan
    /// The calendar a date grouping level cuts days with (``LedgerViewSpec/dayCalendar``).
    public let dayCalendar: Calendar

    public init(
        store: LedgerStore,
        plan: LedgerAggregationPlan,
        dayCalendar: Calendar = LedgerViewSpec.defaultDayCalendar
    ) {
        self.store = store
        self.plan = plan
        self.dayCalendar = dayCalendar
    }

    public func build(rowIndices: [Int], levels: [LedgerGroupingField]) -> LedgerGroupTree {
        let aggregator = LedgerAggregator(store: store, plan: plan)
        guard !levels.isEmpty else {
            return LedgerGroupTree(
                levels: [],
                roots: [],
                orderedRowIndices: rowIndices,
                grandTotal: aggregator.aggregate(rowIndices: rowIndices),
                dayCalendar: dayCalendar
            )
        }
        let roots = buildLevel(
            rowIndices: rowIndices,
            levels: levels,
            depth: 0,
            path: [],
            aggregator: aggregator
        )
        var ordered: [Int] = []
        ordered.reserveCapacity(rowIndices.count)
        // No matching row means no root to merge (U-061). The flat path seeds every planned
        // key — Count 0, and the refusal of a missing configured column — so an empty grouped
        // view does the same, and the grand total does not depend on whether it is grouped.
        var grand = roots.isEmpty ? aggregator.aggregate(rowIndices: []) : LedgerAggregates.empty
        for root in roots {
            ordered.append(contentsOf: root.allRowIndices())
            grand = grand.merging(root.aggregates)
        }
        return LedgerGroupTree(
            levels: levels,
            roots: roots,
            orderedRowIndices: ordered,
            grandTotal: grand,
            dayCalendar: dayCalendar
        )
    }

    private func buildLevel(
        rowIndices: [Int],
        levels: [LedgerGroupingField],
        depth: Int,
        path: [LedgerGroupKey],
        aggregator: LedgerAggregator
    ) -> [LedgerGroupNode] {
        let field = levels[depth]
        let definition = store.columns.column(id: field.column)
        let choiceOrder = definition?.choiceRank ?? [:]

        // Partition, preserving the incoming row order inside each bucket so a sort survives a
        // regroup.
        var buckets: [LedgerGroupKey: [Int]] = [:]
        var order: [LedgerGroupKey] = []
        for index in rowIndices {
            let cell = definition.map { store.value(at: index, definition: $0) }
                ?? store.value(at: index, column: field.column)
            let key = LedgerGroupKey(cell, dayCalendar: dayCalendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(index)
        }
        order.sort { LedgerGroupKey.compare($0, $1, choiceOrder: choiceOrder) == .orderedAscending }

        let isLastLevel = depth == levels.count - 1
        var nodes: [LedgerGroupNode] = []
        nodes.reserveCapacity(order.count)
        for key in order {
            let members = buckets[key] ?? []
            let childPath = path + [key]
            if isLastLevel {
                nodes.append(
                    LedgerGroupNode(
                        key: key,
                        path: childPath,
                        field: field,
                        depth: depth,
                        children: [],
                        rowIndices: members,
                        descendantRowCount: members.count,
                        aggregates: aggregator.aggregate(rowIndices: members)
                    )
                )
            } else {
                let children = buildLevel(
                    rowIndices: members,
                    levels: levels,
                    depth: depth + 1,
                    path: childPath,
                    aggregator: aggregator
                )
                var merged = LedgerAggregates.empty
                for child in children { merged = merged.merging(child.aggregates) }
                nodes.append(
                    LedgerGroupNode(
                        key: key,
                        path: childPath,
                        field: field,
                        depth: depth,
                        children: children,
                        rowIndices: [],
                        descendantRowCount: members.count,
                        aggregates: merged
                    )
                )
            }
        }
        return nodes
    }
}
