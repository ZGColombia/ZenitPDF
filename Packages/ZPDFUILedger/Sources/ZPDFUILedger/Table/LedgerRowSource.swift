import Foundation
import ZPDFUIPresentation

/// An index-addressable supply of ledger rows.
///
/// The Quantity Ledger table never asks for "all rows". It asks for the rows in the
/// window it is about to draw, by index. That is what keeps a 100 000 row ledger
/// responsive: the table's data source holds a row *count* and a fetch function, never an
/// array of view models.
///
/// Conformances are `@MainActor` because `NSTableView` calls them from the main thread
/// during layout. The work behind them is expected to be a dictionary lookup or an already
/// materialised database page, not a query.
@MainActor
public protocol LedgerRowProviding: AnyObject {

    /// Columns in display order, including hidden ones.
    var ledgerColumns: [LedgerColumn] { get }

    /// Number of rows currently addressable, after filtering and sorting.
    var ledgerRowCount: Int { get }

    /// Fetches one row by index, or `nil` when the index is out of range.
    func ledgerRow(at index: Int) -> LedgerRow?

    /// The display position of one markup's row, or `nil` when it is not in the view.
    ///
    /// Defaulted to a scan so an in-memory source stays valid, but a source over a real
    /// query must override it: revealing a markup from the canvas has a p95 budget of
    /// 100 ms at 100 000 rows (ADR-0003 §2.3), which a scan does not meet.
    func ledgerRowIndex(of markupID: UUID) -> Int?

    /// Band hint given ahead of a scroll. Advisory; ``ledgerRow(at:)`` must answer for any
    /// in-range index whether or not it was prefetched.
    func prefetchLedgerRows(in range: Range<Int>)
}

extension LedgerRowProviding {

    /// The identity of the row at an index, or `nil` when the index is out of range.
    public func ledgerRowID(at index: Int) -> UUID? {
        ledgerRow(at: index)?.markupID
    }

    /// Scanning fallback. Correct at any size, fast enough only for previews and tests.
    public func ledgerRowIndex(of markupID: UUID) -> Int? {
        for index in 0..<ledgerRowCount where ledgerRowID(at: index) == markupID {
            return index
        }
        return nil
    }

    /// Sources that hold every row already have nothing to prefetch.
    public func prefetchLedgerRows(in range: Range<Int>) {}
}

/// Adapts a ``LedgerPresenting`` presenter to ``LedgerRowProviding``.
///
/// Both sides are index-addressed, so this is a rename rather than a materialisation:
/// `ledgerRowCount` forwards to the presenter's count and `ledgerRow(at:)` forwards to its
/// row accessor. No array of rows exists on either side of the adapter (ADR-0003 §3.4).
@MainActor
public final class LedgerPresenterRowSource: LedgerRowProviding {

    /// The presenter the rows come from.
    public let presenter: any LedgerPresenting

    /// Whether the table takes its outline and every subtotal from the presenter's
    /// ``LedgerPresenting/rootGroups`` and ``LedgerPresenting/grandTotals`` (IM-014, IM-011).
    ///
    /// Follows ``LedgerPresenting/suppliesDisplayOrderedOutline`` unless a host sets it: on
    /// for the application's presenter, whose outline is the aggregation core's group tree,
    /// and for the preview mock, whose outline is `MockLedgerOutline`'s. Off, the source
    /// supplies no outline and the table lists the rows flat — it never folds them (R-129).
    public var usesPresenterGroupOutline: Bool {
        get { outlineOverride ?? presenter.suppliesDisplayOrderedOutline }
        set { outlineOverride = newValue }
    }

    private var outlineOverride: Bool?

    /// The table's rebuild, registered through ``watchLedgerGroupPlan(_:)``.
    var planChangeHandler: (@MainActor () -> Void)?
    /// Whether an observation of the presenter's outline is armed.
    var isWatchingOutline = false

    /// An explicit outline supplier, for a host that builds the plan from its own core
    /// projection. Wins over ``usesPresenterGroupOutline``; `nil` from it means "no outline",
    /// and the table lists the rows flat.
    public var groupPlanProvider: (@MainActor ([LedgerColumnID], [LedgerColumn]) -> LedgerGroupPlan?)?

    /// Wraps a presenter.
    public init(presenter: any LedgerPresenting) {
        self.presenter = presenter
    }

    public var ledgerColumns: [LedgerColumn] { presenter.columns }

    public var ledgerRowCount: Int { presenter.rowCount }

    public func ledgerRow(at index: Int) -> LedgerRow? { presenter.row(at: index) }

    public func ledgerRowIndex(of markupID: UUID) -> Int? { presenter.index(of: markupID) }

    public func prefetchLedgerRows(in range: Range<Int>) { presenter.prefetchRows(in: range) }
}
