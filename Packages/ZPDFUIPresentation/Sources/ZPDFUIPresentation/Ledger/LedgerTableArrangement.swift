import Foundation

/// The arrangement the ledger's table shows — column order and visibility as the person left
/// them — read and set through the table itself (W-029).
///
/// The table keeps that arrangement on its own: it lays a presenter's columns out in the mockup
/// default and then follows the person's hides, shows and moves, never the presenter's order. So a
/// job template that rearranged the *presenter's* columns was wiped by the next refresh and never
/// reached the table, and a template captured from the presenter recorded the column definitions'
/// visibility rather than what the person had arranged. This is the route that does reach it.
public struct LedgerTableArrangement: Sendable {

    /// The table's columns in display order, hidden ones included.
    public let read: @MainActor @Sendable () -> [LedgerColumn]
    /// Replaces the table's arrangement, exactly as a person dragging headers would.
    public let apply: @MainActor @Sendable ([LedgerColumn]) -> Void

    public init(
        read: @escaping @MainActor @Sendable () -> [LedgerColumn],
        apply: @escaping @MainActor @Sendable ([LedgerColumn]) -> Void
    ) {
        self.read = read
        self.apply = apply
    }
}

/// A ledger presenter that reads and sets the table's arrangement through
/// ``LedgerTableArrangement``, installed by whoever builds the table over it.
///
/// Reached by a conditional cast from `any LedgerPresenting`, like ``LedgerColumnManaging``.
@MainActor
public protocol LedgerTableArrangementHosting: LedgerPresenting {
    /// The table's arrangement, or `nil` while no table shows this presenter.
    var tableArrangement: LedgerTableArrangement? { get set }
}
