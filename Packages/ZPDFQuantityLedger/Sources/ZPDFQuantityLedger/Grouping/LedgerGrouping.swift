import Foundation
import ZPDFContracts

/// What one grouping level groups by.
///
/// Anything the ledger can show, it can group by — the built-ins of spec 15.5 and any custom
/// column, including a formula column.
public struct LedgerGroupingField: Hashable, Sendable {
    public let column: ColumnID

    public init(column: ColumnID) { self.column = column }
}

/// The value a group is keyed on.
///
/// ``none`` is a real case, not an absence: QUALITY_BAR A8 requires that a row with a null key
/// lands in an explicit "(none)" group rather than disappearing from the partition. ``error`` is
/// the same idea for a row whose key cell is a formula failure.
public enum LedgerGroupKey: Hashable, Sendable {
    case text(String)
    case number(DecimalQuantity)
    case currency(amount: Decimal, code: String)
    case date(Date)
    case boolean(Bool)
    case choice(ChoiceOptionID)
    case none
    case error

    /// A stable, locale-independent token. Used for ordering and as the export identity of the
    /// group; the human-readable label is the view's business.
    public var token: String {
        switch self {
        case .text(let text): "t:\(text)"
        case .number(let quantity): "n:\(quantity.value)@\(quantity.dimension.ledgerToken)"
        case .currency(let amount, let code): "c:\(amount)@\(code)"
        case .date(let date): "d:\(date.timeIntervalSinceReferenceDate)"
        case .boolean(let flag): "b:\(flag)"
        case .choice(let id): "o:\(id.rawValue.uuidString)"
        case .none: "(none)"
        case .error: "(error)"
        }
    }

    /// Rank for the documented group ordering: values first in ``LedgerOrdering``'s type order,
    /// then "(none)", then "(error)". Nulls last means a user scanning subtotals sees the real
    /// groups before the leftovers.
    var orderRank: Int {
        switch self {
        case .number: 0
        case .currency: 1
        case .boolean: 2
        case .date: 3
        case .choice: 4
        case .text: 5
        case .none: 6
        case .error: 7
        }
    }

    /// The key a cell groups under. A date is keyed on the day it falls on in `dayCalendar`,
    /// never on the instant (T-047): two markups created the same day at different times are
    /// one group, as the heading — which prints the day — already said they were.
    ///
    /// A formula cell with nothing to compute from ("No input", ADR-0040) groups under
    /// "(none)" with the empty cells, not under "(error)" (W-063): totals already leave it out
    /// like an empty cell, and a heading must not call a cell an error that says "No input".
    init(_ cell: LedgerCellResult, dayCalendar: Calendar) {
        if cell.hasNoValue {
            self = .none
            return
        }
        switch cell {
        case .error:
            self = .error
        case .value(let value):
            switch value {
            case .empty: self = .none
            case .text(let text): self = text.isEmpty ? .none : .text(text)
            case .number(let quantity): self = .number(quantity)
            case .formulaResult(let quantity, _): self = .number(quantity)
            case .currency(let amount, let code): self = .currency(amount: amount, code: code)
            case .date(let date): self = .date(dayCalendar.startOfDay(for: date))
            case .checkbox(let flag): self = .boolean(flag)
            case .choice(let id): self = .choice(id)
            }
        }
    }

    static func compare(
        _ left: LedgerGroupKey,
        _ right: LedgerGroupKey,
        choiceOrder: [ChoiceOptionID: Int]
    ) -> ComparisonResult {
        guard left.orderRank == right.orderRank else {
            return left.orderRank < right.orderRank ? .orderedAscending : .orderedDescending
        }
        switch (left, right) {
        case (.text(let a), .text(let b)):
            return LedgerOrdering.compareText(a, b)
        case (.number(let a), .number(let b)):
            return LedgerOrdering.compareQuantities(a, b)
        case (.currency(let leftAmount, let leftCode), .currency(let rightAmount, let rightCode)):
            if leftCode != rightCode { return LedgerOrdering.compareIdentifiers(leftCode, rightCode) }
            if leftAmount == rightAmount { return .orderedSame }
            return leftAmount < rightAmount ? .orderedAscending : .orderedDescending
        case (.date(let a), .date(let b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case (.boolean(let a), .boolean(let b)):
            if a == b { return .orderedSame }
            return b ? .orderedAscending : .orderedDescending
        case (.choice(let a), .choice(let b)):
            // BH-195: the sorter's rule — unknown options after every known one — so the
            // order is total and the editor's sibling search agrees with the builder.
            return LedgerOrdering.compareChoices(a, b, choiceOrder: choiceOrder)
        default:
            return .orderedSame
        }
    }
}

extension QuantityDimension {
    /// The dimension's identity in a group token and in a distinct-count canonical text.
    ///
    /// `baseUnitSymbol` is `1` for a count and for a ratio alike — the tag is not a unit — but
    /// ADR-0014 declares the two distinct and non-additive, so a `5` count and a `5` ratio must
    /// not collapse into one group or one distinct value (BH-615). The ratio tag is spelled
    /// into the token; every other dimension's token is its base unit symbol as before.
    var ledgerToken: String {
        ratio ? "\(baseUnitSymbol):ratio" : baseUnitSymbol
    }
}
