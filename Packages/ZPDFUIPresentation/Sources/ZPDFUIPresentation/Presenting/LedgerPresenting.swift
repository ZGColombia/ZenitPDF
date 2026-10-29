import Foundation
import Observation

/// Presents the Quantity Ledger: columns, grouped rows, totals, filters and selection.
@MainActor
public protocol LedgerPresenting: ZenitPresenting {

    /// Every column, in display order, including hidden ones.
    var columns: [LedgerColumn] { get }
    /// Top-level groups when a grouping is active.
    var rootGroups: [LedgerGroupNode] { get }
    /// Number of rows in current sort order, after filtering and ignoring grouping.
    ///
    /// This is what the flat table's data source answers "how many rows?" with. It is a
    /// count, never an array: a 100 000-row takeoff with forty visible columns is two
    /// million cells, and a table only ever draws about forty rows at a time
    /// (ADR-0003 §2.1, §3.4).
    var rowCount: Int { get }
    /// Monotonic revision, bumped on every projection swap.
    ///
    /// The one observable cue that *always* moves when row content changes. Row count and
    /// totals do not: a subject rename keeps both identical, and a table that reloads only
    /// on those cues shows the old text until the next unrelated reload (found 2026-08-24
    /// while verifying ledger hydration).
    var contentRevision: Int { get }
    /// Totals over every row that passes the filter.
    var grandTotals: LedgerTotals { get }
    /// Columns the ledger is grouped by, outermost first. Empty means a flat ledger.
    var groupingColumns: [LedgerColumnID] { get }
    /// The active filter tree.
    var filter: LedgerFilterGroup { get }
    /// How the canvas treats markups that fail ``filter``.
    var canvasFilterBehavior: LedgerCanvasFilterBehavior { get }
    /// Selected rows, kept in sync with the canvas selection.
    var selectedRowIDs: Set<UUID> { get }
    /// Active sort, outermost first.
    var sortDescriptors: [LedgerSortDescriptor] { get }
    /// Whether a background query is in flight, so the table can show a quiet progress state.
    var isLoading: Bool { get }
    /// How many rows the ledger holds **before** ``filter`` narrows it.
    ///
    /// The denominator of the filter builder's live count and of every export's
    /// "12 of 40 rows" label. A requirement rather than an extension member on purpose:
    /// the shell holds presenters as `any LedgerPresenting`, and a statically dispatched
    /// helper would hand a filtered pane the filtered number as its own total — which is
    /// the "export that filters rows but carries the unfiltered total" failure of
    /// QUALITY_BAR A35, read backwards.
    var unfilteredRowCount: Int { get }
    /// Whether a filter is currently narrowing what is on screen.
    var isFiltered: Bool { get }

    /// Replaces the grouping.
    func setGrouping(_ columns: [LedgerColumnID])
    /// Replaces the filter tree.
    func setFilter(_ filter: LedgerFilterGroup)
    /// Changes how the canvas treats filtered-out markups.
    func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior)
    /// Shows or hides a column.
    func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID)
    /// Resizes a column.
    func setColumnWidth(_ width: Double, columnID: LedgerColumnID)
    /// Pins or unpins a column.
    func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID)
    /// Moves a column to a new position in display order.
    func moveColumn(_ columnID: LedgerColumnID, to index: Int)
    /// Expands or collapses one group.
    func toggleGroup(id: LedgerGroupNode.ID)
    /// Replaces or extends the row selection, which also drives the canvas selection.
    func select(rowIDs: Set<UUID>, additive: Bool)
    /// Sorts by one column, replacing the current sort.
    func sort(by columnID: LedgerColumnID, ascending: Bool)
    /// Sorts by several levels at once, outermost first (IM-099). The default forwards the
    /// first level to ``sort(by:ascending:)``; a presenter whose sorter takes levels
    /// implements it fully.
    func sort(by descriptors: [LedgerSortDescriptor])
    /// Why the last rebuild of the projection failed, while the pane keeps showing the last
    /// good result, or `nil` (IM-056 / BH-102). Default: `nil`.
    var lastRebuildError: String? { get }
    /// Why the last requested sort was not applied, or `nil`. Default: `nil`.
    var unappliedSortMessage: String? { get }
    /// Clears ``lastRebuildError`` when the person dismisses its banner. Default: no-op.
    func dismissRebuildError()
    /// The pane's visible columns in on-screen order, so an "as on screen" export carries
    /// them (IM-027). Default: ignored.
    var onScreenColumnOrder: [LedgerColumnID] { get set }
    /// Totals for one group, or the grand totals when `groupID` is `nil`.
    func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals
    /// Whether ``rootGroups`` and ``grandTotals`` are the ledger's complete outline, addressed
    /// by display position (IM-011). Default: `false`.
    ///
    /// `true` promises three things, so a table can draw its group headings and every
    /// subtotal from this outline without reading a single row, and the numbers on screen are
    /// the aggregation core's rather than a second fold's:
    ///
    ///   * display order is group order — the rows of the leaves, concatenated in outline
    ///     order — so each group covers the next `totals.rowCount` positions;
    ///   * every node's `totals.rowCount` counts its descendants' rows, and the roots cover
    ///     ``rowCount``;
    ///   * every node's totals and ``grandTotals`` carry every column the table totals,
    ///     including the display `Value` column's merged total.
    ///
    /// The application's presenter publishes the aggregation core's outline; the preview mock
    /// publishes ``MockLedgerOutline``'s. A presenter that keeps the default supplies no
    /// outline, and the table then lists its rows flat, in display order, with no headings
    /// and no subtotals: the table never folds rows into an outline of its own (R-129).
    var suppliesDisplayOrderedOutline: Bool { get }

    /// The row at one display position, or `nil` when the index is out of range or the
    /// window holding it has not loaded yet.
    ///
    /// Must be O(1) amortised: the table calls it once per visible row per layout pass.
    /// A `nil` return is the table's cue to draw a placeholder of the correct height and
    /// report the row as busy, never to block the main thread fetching it.
    func row(at index: Int) -> LedgerRow?

    /// The display position of one markup's row, or `nil` when the row is not in the
    /// current filtered view.
    ///
    /// Selection travels by identity, never by index, because indices move under sort,
    /// filter and grouping. This is the lookup that turns an identity back into a scroll
    /// position without walking the rows before it (ADR-0003 §2.3, `ledgerJumpP95Ms`).
    func index(of markupID: UUID) -> Int?

    /// The rows for a set of markup identities whatever the filter: a row the current filter
    /// hides is still answered, in store order (W-042).
    ///
    /// For a surface that shows a markup's stored values — the Inspector's Custom Data — rather
    /// than the table's view. ``rows(withIDs:)`` resolves through ``index(of:)``, which is `nil`
    /// for a filtered-out row, so a selected markup the filter dims showed a dash for every
    /// value it has. Default: ``rows(withIDs:)``, which is the whole answer for a presenter that
    /// does not filter.
    func unfilteredRows(withIDs markupIDs: Set<UUID>) -> [LedgerRow]

    /// Band hint a scrolling table gives ahead of itself, so the rows it is about to draw
    /// are already built when it asks for them.
    ///
    /// Advisory: a conforming presenter may ignore it, and ``row(at:)`` must still answer
    /// for any in-range index whether or not it was prefetched.
    func prefetchRows(in range: Range<Int>)
}

extension LedgerPresenting {

    /// Presenters without a multi-level sorter apply the outermost level (IM-099).
    public func sort(by descriptors: [LedgerSortDescriptor]) {
        guard let first = descriptors.first else { return }
        sort(by: first.column, ascending: first.ascending)
    }

    /// Presenters that cannot fail a rebuild have nothing to report.
    public var lastRebuildError: String? { nil }

    /// Presenters that apply every sort have nothing to report.
    public var unappliedSortMessage: String? { nil }

    /// Nothing to dismiss by default.
    public func dismissRebuildError() {}

    /// A presenter has to opt in to having its outline drawn positionally (IM-011).
    public var suppliesDisplayOrderedOutline: Bool { false }

    /// Ignored by presenters that do not export (the mocks).
    public var onScreenColumnOrder: [LedgerColumnID] {
        get { [] }
        set { }
    }

    /// A presenter that publishes no separate pre-filter count is reporting its own row
    /// count, which is correct for every unfiltered presenter and for the mocks.
    public var unfilteredRowCount: Int { rowCount }

    /// Derived from the rule tree, so a presenter gets the honest answer for free.
    public var isFiltered: Bool { !filter.isEmpty }

    /// The columns that are currently on screen, in display order.
    public var visibleColumns: [LedgerColumn] { columns.filter(\.visible) }

    /// Looks up one column by identity.
    public func column(_ id: LedgerColumnID) -> LedgerColumn? {
        columns.first { $0.id == id }
    }

    /// Every group node in the outline, flattened depth-first.
    public var allGroups: [LedgerGroupNode] {
        rootGroups.flatMap { [$0] + $0.allDescendants }
    }

    /// Whether the filtered ledger has any rows at all.
    public var isEmpty: Bool { rowCount == 0 }

    /// The rows for a set of markup identities, in display order.
    ///
    /// Resolved through ``index(of:)`` so that pulling three rows out of a hundred
    /// thousand costs three lookups rather than a scan.
    public func rows(withIDs markupIDs: Set<UUID>) -> [LedgerRow] {
        markupIDs
            .compactMap { index(of: $0) }
            .sorted()
            .compactMap { row(at: $0) }
    }

    /// A presenter that does not filter answers every row from its view (W-042).
    public func unfilteredRows(withIDs markupIDs: Set<UUID>) -> [LedgerRow] {
        rows(withIDs: markupIDs)
    }
}
