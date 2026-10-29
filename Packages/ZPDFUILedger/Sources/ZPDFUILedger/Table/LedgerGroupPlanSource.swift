import Foundation
import Observation
import ZPDFUIPresentation

/// A row source that hands the table its outline and totals ready-made.
///
/// This is the table's only source of headings and subtotals (IM-011). The table used to
/// build the outline itself by folding rows, which read **every** row — in flat mode too, for
/// the grand totals — materialising the whole ledger through the presenter (IM-014), and
/// which was a second aggregation engine beside the core's. That fold is gone (R-129): a
/// source that knows the group structure — the presenter's core projection does — answers
/// here, and the table then touches only the rows it draws.
///
/// Returning `nil` is always allowed and means "no outline": the table then lists the
/// source's rows flat, in source order, with no headings and no subtotals.
@MainActor
public protocol LedgerGroupPlanProviding: AnyObject {

    /// The plan for a grouping over the source's current rows, or `nil`.
    ///
    /// The returned plan must index the source: ``LedgerGroupPlan/order`` has exactly
    /// ``LedgerRowProviding/ledgerRowCount`` entries, every group's
    /// ``LedgerGroupSlice/rowRange`` indexes into it, and
    /// ``LedgerGroupPlan/groupingColumns`` equals `groupingColumns`. A plan that breaks any
    /// of these is ignored and the table lists the rows flat.
    ///
    /// - Parameters:
    ///   - groupingColumns: Grouping levels, outermost first; empty for the flat ledger.
    ///   - columns: The table's columns, display columns included, for the subtotals.
    func ledgerGroupPlan(groupingColumns: [LedgerColumnID], columns: [LedgerColumn]) -> LedgerGroupPlan?

    /// Registers the table's rebuild, for a source whose plan can change without a host
    /// reload — a core-backed source that answered with a pending plan while the core
    /// regroups (IM-011). Default: ignored.
    func watchLedgerGroupPlan(_ onChange: @escaping @MainActor () -> Void)
}

extension LedgerGroupPlanProviding {

    /// Sources whose plan only changes when the host reloads have nothing to report.
    public func watchLedgerGroupPlan(_ onChange: @escaping @MainActor () -> Void) {}
}

/// Where a table's outline and subtotals came from (IM-011).
public enum LedgerPlanOrigin: Hashable, Sendable {
    /// The source's own outline — for a presenter-backed table, the aggregation core's.
    case supplied
    /// The source supplied no outline, so the table lists its rows flat, in source order,
    /// under no headings and no subtotals. The table never folds rows into an outline of its
    /// own (R-129).
    case unsupplied
}

/// A row source whose ``LedgerRowProviding/ledgerRowIndex(of:)`` is a lookup, not a scan.
///
/// The table resolves a selection through it rather than through an identity index built
/// by reading every row, which would materialise the ledger again the first time anything
/// is selected (IM-014).
@MainActor
public protocol LedgerIndexedRowProviding: LedgerRowProviding {}

extension LedgerPresenterRowSource: LedgerIndexedRowProviding {}

/// One group of an outline that was computed elsewhere, before it becomes a slice.
///
/// Ranges are not stored: the source's display order is the concatenation of the groups'
/// rows, so each group's range follows from the row counts of the groups before it.
public struct LedgerPrecomputedGroup: Hashable, Sendable {

    /// Heading text.
    public var title: String
    /// The column that produced this level.
    public var column: LedgerColumnID?
    /// The raw grouped value, which becomes the path component.
    public var value: String
    /// Number of rows beneath this group, descendants included.
    public var rowCount: Int
    /// Aggregates over those rows.
    public var subtotals: LedgerSubtotals
    /// Redundant colour cue.
    public var colorRGBA: ColorRGBA?
    /// Nested groups, empty for a leaf.
    public var children: [LedgerPrecomputedGroup]

    /// Creates a precomputed group.
    public init(
        title: String,
        column: LedgerColumnID?,
        value: String,
        rowCount: Int,
        subtotals: LedgerSubtotals,
        colorRGBA: ColorRGBA? = nil,
        children: [LedgerPrecomputedGroup] = []
    ) {
        self.title = title
        self.column = column
        self.value = value
        self.rowCount = rowCount
        self.subtotals = subtotals
        self.colorRGBA = colorRGBA
        self.children = children
    }

    /// A presenter's outline node, carried over without recomputing anything: its heading,
    /// its row count and its totals bridged into the table's subtotal record, recursively.
    public init(bridging node: LedgerGroupNode, columns: [LedgerColumn]) {
        self.init(
            title: node.title,
            column: node.groupingColumn,
            value: node.groupingValue ?? node.title,
            rowCount: node.totals.rowCount,
            subtotals: LedgerSubtotals.bridging(node.totals, columns: columns),
            colorRGBA: node.colorRGBA,
            children: node.children.map { LedgerPrecomputedGroup(bridging: $0, columns: columns) }
        )
    }
}

extension LedgerGroupPlan {

    /// Builds a plan from an outline computed elsewhere, without reading a single row.
    ///
    /// The source's display order must already be group order — the concatenation of the
    /// leaves, outermost level first — which is what the aggregation core's group tree
    /// produces. ``order`` is then the identity, and each group covers the next
    /// `rowCount` positions.
    ///
    /// - Returns: `nil` when the counts do not add up — a parent whose children cover a
    ///   different number of rows, or roots that do not cover `rowCount` — so a
    ///   malformed outline can never mis-assign rows to headings.
    public static func precomputed(
        rowCount: Int,
        groups: [LedgerPrecomputedGroup],
        grandSubtotals: LedgerSubtotals,
        groupingColumns: [LedgerColumnID]
    ) -> LedgerGroupPlan? {
        guard rowCount >= 0 else { return nil }
        let separator = LedgerGroupingEngine.pathSeparator

        func slices(
            _ nodes: [LedgerPrecomputedGroup],
            start: Int,
            depth: Int,
            parentPath: String
        ) -> (slices: [LedgerGroupSlice], end: Int)? {
            var cursor = start
            var result: [LedgerGroupSlice] = []
            result.reserveCapacity(nodes.count)
            for node in nodes {
                guard node.rowCount >= 0 else { return nil }
                let range = cursor..<(cursor + node.rowCount)
                let path = parentPath.isEmpty ? node.value : parentPath + separator + node.value
                var children: [LedgerGroupSlice] = []
                if !node.children.isEmpty {
                    guard let nested = slices(node.children, start: cursor, depth: depth + 1, parentPath: path),
                          nested.end == range.upperBound else { return nil }
                    children = nested.slices
                }
                result.append(LedgerGroupSlice(
                    path: path,
                    title: node.title,
                    column: node.column,
                    value: node.value,
                    depth: depth,
                    rowRange: range,
                    children: children,
                    subtotals: node.subtotals,
                    isExpanded: true,
                    colorRGBA: node.colorRGBA
                ))
                cursor = range.upperBound
            }
            return (result, cursor)
        }

        guard let built = slices(groups, start: 0, depth: 0, parentPath: "") else { return nil }
        guard groups.isEmpty || built.end == rowCount else { return nil }
        return LedgerGroupPlan(
            order: Array(0..<rowCount),
            groups: built.slices,
            grandSubtotals: grandSubtotals,
            groupingColumns: groupingColumns
        )
    }
}

extension LedgerSubtotals {

    /// Carries a presenter's ``LedgerTotals`` into the table's subtotal record.
    ///
    /// Only what the totals actually say is carried: a summed quantity becomes a quantity
    /// result; a refused column becomes a refusal. Nothing is recomputed, so the number a
    /// heading shows is the number the core computed (QUALITY_BAR A25).
    ///
    /// The contract has one refusal set, ``LedgerTotals/incompatibleColumns``, and says which
    /// refusal it is in the cell's own words. A refusal whose words are the mixed-units phrase
    /// is a unit conflict; any other refusal ("Cannot total") is a failure, and is carried as
    /// ``LedgerAggregateResult/Value/failed`` so the heading does not send the person hunting
    /// for a unit disagreement that is not there (CR-54).
    public static func bridging(_ totals: LedgerTotals, columns: [LedgerColumn]) -> LedgerSubtotals {
        var results: [LedgerColumnID: LedgerAggregateResult] = [:]
        for column in columns {
            let aggregate = column.aggregate ?? .sum
            if totals.incompatibleColumns.contains(column.id) {
                let words = totals.displayValue(column.id)
                let isFailure = !words.isEmpty && words != LedgerTotals.incompatiblePlaceholder
                results[column.id] = LedgerAggregateResult(
                    column: column.id, aggregate: aggregate,
                    value: isFailure ? .failed : .mixedUnits
                )
            } else if let quantity = totals.quantities[column.id] {
                results[column.id] = LedgerAggregateResult(
                    column: column.id, aggregate: aggregate, value: .quantity(quantity)
                )
            }
        }
        return LedgerSubtotals(rowCount: totals.rowCount, results: results)
    }
}

extension LedgerPresenterRowSource: LedgerGroupPlanProviding {

    /// The presenter's own outline: the ledger's one aggregation path (IM-011).
    ///
    /// An explicit ``groupPlanProvider`` wins. Otherwise, while ``usesPresenterGroupOutline``
    /// is on, this **always** answers, so the table never falls back to folding rows for a
    /// presenter that supplies its outline:
    ///
    ///   * the grouping the table asks for is handed to the presenter when it differs from the
    ///     presenter's, so the core partitions — the table only ever asks, it never groups;
    ///   * when the presenter's outline is that grouping, it becomes the plan through
    ///     ``LedgerGroupPlan/precomputed(rowCount:groups:grandSubtotals:groupingColumns:)``;
    ///   * until then — the core's rebuild is asynchronous — the plan is the ungrouped rows
    ///     under the core's grand totals (``pendingPlan(from:groupingColumns:columns:)``),
    ///     which the table draws as a plain list. The presenter's next projection bumps its
    ///     `contentRevision`, the host reloads, and the core's groups replace it.
    ///
    /// Off (a presenter that does not supply its outline), it returns `nil` and the table
    /// lists the rows flat.
    public func ledgerGroupPlan(groupingColumns: [LedgerColumnID], columns: [LedgerColumn]) -> LedgerGroupPlan? {
        if let groupPlanProvider { return groupPlanProvider(groupingColumns, columns) }
        guard usesPresenterGroupOutline else { return nil }
        if presenter.groupingColumns != groupingColumns {
            presenter.setGrouping(groupingColumns)
        }
        if let plan = Self.plan(from: presenter, groupingColumns: groupingColumns, columns: columns) {
            return plan
        }
        watchForOutline()
        return Self.pendingPlan(from: presenter, groupingColumns: groupingColumns, columns: columns)
    }

    public func watchLedgerGroupPlan(_ onChange: @escaping @MainActor () -> Void) {
        planChangeHandler = onChange
    }

    /// Rebuilds the table once the presenter publishes its next outline, so a pending plan
    /// resolves itself even where no host reloads on the presenter's `contentRevision`.
    /// Observation fires before the change lands, so the rebuild is deferred to the next
    /// main-actor turn, after the presenter has adopted the whole projection.
    private func watchForOutline() {
        guard planChangeHandler != nil, !isWatchingOutline else { return }
        isWatchingOutline = true
        let presenter = self.presenter
        withObservationTracking {
            _ = presenter.contentRevision
            _ = presenter.rootGroups
            _ = presenter.rowCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWatchingOutline = false
                self.planChangeHandler?()
            }
        }
    }

    /// The grouping levels the presenter can partition by: those naming one of its own
    /// columns. A display-only column (the synthesised `Unit`) is no column of the core's, and
    /// the core drops that level exactly as it refuses a sort on it (BH-102).
    public static func honouredGrouping(
        _ groupingColumns: [LedgerColumnID],
        presenter: any LedgerPresenting
    ) -> [LedgerColumnID] {
        let known = Set(presenter.columns.map(\.id))
        return groupingColumns.filter { known.contains($0) }
    }

    /// Converts a presenter's outline into a plan without reading a row.
    ///
    /// - Returns: `nil` when the presenter's outline is not yet the requested grouping — its
    ///   nodes at depth *d* were not made on the *d*-th honoured level, or a level is missing
    ///   or extra — or when its node counts do not cover its rows.
    public static func plan(
        from presenter: any LedgerPresenting,
        groupingColumns: [LedgerColumnID],
        columns: [LedgerColumn]
    ) -> LedgerGroupPlan? {
        let grand = LedgerSubtotals.bridging(presenter.grandTotals, columns: columns)
        let honoured = honouredGrouping(groupingColumns, presenter: presenter)
        guard !honoured.isEmpty else {
            guard presenter.rootGroups.isEmpty else { return nil }
            return LedgerGroupPlan(
                order: Array(0..<presenter.rowCount),
                groups: [],
                grandSubtotals: grand,
                groupingColumns: groupingColumns
            )
        }
        guard outline(presenter.rootGroups, matches: honoured, depth: 0),
              presenter.rowCount == 0 || !presenter.rootGroups.isEmpty else { return nil }
        return LedgerGroupPlan.precomputed(
            rowCount: presenter.rowCount,
            groups: presenter.rootGroups.map { LedgerPrecomputedGroup(bridging: $0, columns: columns) },
            grandSubtotals: grand,
            groupingColumns: groupingColumns
        )
    }

    /// The plan shown while the core regroups: every row, in the presenter's order, under the
    /// core's grand totals. Grouping never changes a grand total, so the totals bar is right
    /// from the first frame; only the headings wait for the core.
    public static func pendingPlan(
        from presenter: any LedgerPresenting,
        groupingColumns: [LedgerColumnID],
        columns: [LedgerColumn]
    ) -> LedgerGroupPlan {
        LedgerGroupPlan(
            order: Array(0..<presenter.rowCount),
            groups: [],
            grandSubtotals: LedgerSubtotals.bridging(presenter.grandTotals, columns: columns),
            groupingColumns: groupingColumns
        )
    }

    /// Whether every node at `depth` was made on `levels[depth]`, inner levels have children
    /// and the last level has none.
    private static func outline(_ nodes: [LedgerGroupNode], matches levels: [LedgerColumnID], depth: Int) -> Bool {
        guard depth < levels.count else { return nodes.isEmpty }
        let isLast = depth == levels.count - 1
        for node in nodes {
            guard node.groupingColumn == levels[depth] else { return false }
            if isLast {
                guard node.children.isEmpty else { return false }
            } else if node.totals.rowCount > 0 {
                guard !node.children.isEmpty,
                      outline(node.children, matches: levels, depth: depth + 1) else { return false }
            }
        }
        return true
    }
}
