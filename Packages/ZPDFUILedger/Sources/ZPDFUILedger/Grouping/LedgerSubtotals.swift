import Foundation
import ZPDFUIPresentation

/// The result of one aggregate over one column.
///
/// `mixedUnits` and `failed` are first-class outcomes, not errors: a column whose rows disagree
/// about their dimension has no total, and a column one of whose cells is itself an error has
/// no total either. The table must say which in words rather than print a number that would be
/// wrong — and must not say "mixed units" about a failure, which sends the user hunting for a
/// unit disagreement that is not there (CR-54).
public struct LedgerAggregateResult: Hashable, Sendable {

    /// What the aggregate produced.
    public enum Value: Hashable, Sendable {
        /// A dimensioned total — a count is a quantity of dimension `count`.
        case quantity(DecimalQuantity)
        /// The contributing rows had incompatible dimensions, so nothing was summed.
        case mixedUnits
        /// The aggregate could not be computed: a member cell was in error, an addition was
        /// not exact, or a weighted total had no usable weight (CR-54).
        case failed
        /// The column has no aggregate, or no row contributed a value.
        case unavailable
    }

    /// The column the aggregate belongs to.
    public let column: LedgerColumnID
    /// Which aggregate was applied.
    public let aggregate: LedgerAggregate
    /// The outcome.
    ///
    /// There is no contributing-row count (W-069): a total bridged from the aggregation core
    /// (``LedgerSubtotals/bridging(_:columns:)``) arrives as a value and a group row count only,
    /// and the field that once carried one was `nil` in every shipping result (R-130).
    public let value: Value

    /// Creates an aggregate result.
    public init(
        column: LedgerColumnID,
        aggregate: LedgerAggregate,
        value: Value
    ) {
        self.column = column
        self.aggregate = aggregate
        self.value = value
    }

    /// Whether the aggregate was refused because the dimensions did not agree.
    public var isMixedUnits: Bool { value == .mixedUnits }

    /// Whether the aggregate failed outright — a member cell in error, an inexact addition, a
    /// missing weight. Never true for a unit disagreement; that is ``isMixedUnits``.
    public var isFailed: Bool { value == .failed }

    /// Whether the cell must render an explicit refusal rather than a number: mixed units or a
    /// failure. The two read differently, and neither is ever a blank or a zero.
    public var isRefusal: Bool { isMixedUnits || isFailed }

    /// The quantity, when there is one.
    public var quantity: DecimalQuantity? {
        if case let .quantity(quantity) = value { return quantity }
        return nil
    }

    /// The localized text a failed total shows.
    ///
    /// "Mixed units" is a different statement — see ``LedgerTotals/incompatiblePlaceholder`` —
    /// and the export writes the failure as its own `#ERROR` token; this is the screen's
    /// spelling of the same state.
    public static var failedPlaceholder: String {
        NSLocalizedString(
            "Error",
            comment: "Shown instead of a total when a member cell failed or the total could not be computed exactly"
        )
    }

    /// Text for the totals cell.
    ///
    /// Mixed units render as the localized "Mixed units" phrase from the presentation
    /// layer, so the ledger, the export and VoiceOver all say the same thing; a failure
    /// renders as ``failedPlaceholder``.
    public func displayText(
        policy: LedgerUnitPolicy = .metric,
        rounding: LedgerRounding = .exact,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        switch value {
        case let .quantity(quantity):
            return LedgerNumberFormatting.display(quantity, policy: policy, rounding: rounding, locale: locale)
        case .mixedUnits:
            return LedgerTotals.incompatiblePlaceholder
        case .failed:
            return Self.failedPlaceholder
        case .unavailable:
            return ""
        }
    }

    /// A spoken description for the totals row, never colour-only and never a bare number.
    public func accessibilityText(
        columnTitle: String,
        policy: LedgerUnitPolicy = .metric,
        rounding: LedgerRounding = .exact
    ) -> String {
        if isMixedUnits {
            let format = NSLocalizedString(
                "%1$@: mixed units, no total",
                comment: "VoiceOver text for a ledger total refused because dimensions disagree"
            )
            return String(format: format, columnTitle)
        }
        if isFailed {
            let format = NSLocalizedString(
                "%1$@: error, no total",
                comment: "VoiceOver text for a ledger total refused because a member cell failed"
            )
            return String(format: format, columnTitle)
        }
        let text = displayText(policy: policy, rounding: rounding)
        guard !text.isEmpty else {
            let format = NSLocalizedString(
                "%1$@: no total",
                comment: "VoiceOver text for a ledger column that has no aggregate"
            )
            return String(format: format, columnTitle)
        }
        let format = NSLocalizedString(
            "%1$@ %2$@ %3$@",
            comment: "VoiceOver text for a ledger total: column title, aggregate name, value"
        )
        return String(format: format, columnTitle, aggregate.displayName, text)
    }
}

/// Every aggregate for one group of rows, or for the whole ledger.
public struct LedgerSubtotals: Hashable, Sendable {

    /// Number of rows the record covers.
    public let rowCount: Int
    /// One result per column that declares an aggregate. A refused total is a result whose
    /// ``LedgerAggregateResult/value`` is ``LedgerAggregateResult/Value/mixedUnits`` or
    /// ``LedgerAggregateResult/Value/failed`` — the one representation (W-069; two parallel
    /// refusal sets used to restate it, and nothing read them).
    public let results: [LedgerColumnID: LedgerAggregateResult]

    /// Creates a subtotal record.
    public init(
        rowCount: Int,
        results: [LedgerColumnID: LedgerAggregateResult]
    ) {
        self.rowCount = rowCount
        self.results = results
    }

    /// An empty record.
    public static let empty = LedgerSubtotals(rowCount: 0, results: [:])

    /// The aggregate for a column, when it has one.
    public func result(_ column: LedgerColumnID) -> LedgerAggregateResult? { results[column] }
}
