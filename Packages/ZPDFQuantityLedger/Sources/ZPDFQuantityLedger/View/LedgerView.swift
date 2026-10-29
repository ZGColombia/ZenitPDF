import Foundation
import ZPDFContracts

/// Everything that decides what the ledger shows: filter, sort, grouping, aggregates, columns.
///
/// A value type, so a saved view (spec 15.6) is just this struct encoded, and two views built
/// from equal specs over the same store are equal.
public struct LedgerViewSpec: Hashable, Sendable {
    public var filter: LedgerFilterNode
    public var sort: [LedgerSortDescriptor]
    public var grouping: [LedgerGroupingField]
    public var aggregation: LedgerAggregationPlan
    /// Columns to show, in order. Empty means every visible column of the set.
    public var visibleColumns: [ColumnID]
    /// The calendar whose days a date grouping level groups by (T-047).
    ///
    /// A date cell is an instant; a person groups by the day it falls on. Grouping by
    /// `Created` keyed on the instant made one single-row group per markup, each headed by
    /// the same day. The builder and the incremental editor both key a date on
    /// `dayCalendar.startOfDay(for:)`, so a full build and an edit agree on the day, and the
    /// day is the one the heading prints — midnight in this calendar's time zone.
    public var dayCalendar: Calendar

    public init(
        filter: LedgerFilterNode = .all,
        sort: [LedgerSortDescriptor] = [],
        grouping: [LedgerGroupingField] = [],
        aggregation: LedgerAggregationPlan = LedgerAggregationPlan(),
        visibleColumns: [ColumnID] = [],
        dayCalendar: Calendar = LedgerViewSpec.defaultDayCalendar
    ) {
        self.filter = filter
        self.sort = sort
        self.grouping = grouping
        self.aggregation = aggregation
        self.visibleColumns = visibleColumns
        self.dayCalendar = dayCalendar
    }

    /// Gregorian days in the time zone the process runs in — the zone the ledger's date cells
    /// and group headings are printed in.
    public static var defaultDayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

/// A computed projection of a store under a spec.
///
/// Holds indices, never copied cells: at 100 000 rows the whole projection is a few arrays of
/// `Int` plus the group tree, and the cells are still produced on demand by
/// ``LedgerStore/value(at:column:)``.
public struct LedgerView: Sendable {
    public let store: LedgerStore
    public let spec: LedgerViewSpec
    /// Rows that pass the filter, in sorted order, before grouping.
    public let matchingRowIndices: [Int]
    public let tree: LedgerGroupTree

    /// Rows in final display order.
    public var orderedRowIndices: [Int] { tree.orderedRowIndices }
    public var rowCount: Int { tree.orderedRowIndices.count }
    public var grandTotal: LedgerAggregates { tree.grandTotal }

    /// The columns this view shows, in order. A column listed twice appears once, at its
    /// first position (BH-617): every consumer keys by column id.
    public var columns: [LedgerColumnDefinition] {
        guard !spec.visibleColumns.isEmpty else {
            return store.columns.columns.filter(\.isVisible).sorted { $0.order < $1.order }
        }
        var seen = Set<ColumnID>()
        return spec.visibleColumns.compactMap { id in
            seen.insert(id).inserted ? store.columns.column(id: id) : nil
        }
    }

    public func row(displayRow: Int) -> LedgerRowView {
        store.row(at: tree.orderedRowIndices[displayRow])
    }
}

extension LedgerStore {

    /// Applies a spec: filter, then sort, then group.
    ///
    /// The order matters for cost, not for the answer. Filtering first shrinks the set the sort
    /// has to order; grouping last partitions an already-ordered set, and because each partition
    /// preserves the incoming order, grouping never disturbs the sort. QUALITY_BAR A22 asserts
    /// the other order gives the same visible rows and the same subtotals.
    public func makeView(_ spec: LedgerViewSpec) -> LedgerView {
        let all = Array(0..<rowCount)
        let filtered = LedgerFilterEvaluator(store: self).filter(all, with: spec.filter)
        let sorted = LedgerSorter(store: self, descriptors: spec.sort).sorted(filtered)
        let tree = LedgerGroupBuilder(store: self, plan: spec.aggregation, dayCalendar: spec.dayCalendar)
            .build(rowIndices: sorted, levels: spec.grouping)
        return LedgerView(store: self, spec: spec, matchingRowIndices: sorted, tree: tree)
    }
}
