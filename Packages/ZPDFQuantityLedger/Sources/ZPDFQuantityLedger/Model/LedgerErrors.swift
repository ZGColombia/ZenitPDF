import Foundation
import ZPDFContracts

/// Everything the aggregation core can refuse to do, as a value.
///
/// The ledger never answers a question it cannot answer exactly. Where a spreadsheet would show
/// `0`, a blank or a `#VALUE!` that the user has to decode, this type carries a code that the
/// view and every export render as the same explicit state (QUALITY_BAR A11, A14, A27).
public struct LedgerAggregationError: Error, Hashable, Sendable, CustomStringConvertible {

    /// Why `NSDecimalAdd` refused.
    public enum InexactReason: String, Hashable, Sendable {
        case lossOfPrecision
        case overflow
        case underflow
        case divideByZero
    }

    public enum Code: Hashable, Sendable {
        /// A `Decimal` operation could not be performed exactly.
        case inexactAddition(InexactReason)
        case divisionByZero
        /// The plan asked for a distinct count on an accumulator that was not tracking values.
        case distinctNotTracked
        /// A member cell was itself an error, so the aggregate cannot be a number.
        case cellError(LedgerCellError.Kind)
        /// A weighted total names a weight column that is not in the column set.
        case unknownWeightColumn(ColumnID)
        /// A weight cell was not a plain dimensionless number.
        case nonScalarWeight(ColumnID)
        /// `aggregateThenEvaluate` is declared but not implemented in this build. Refusing is the
        /// only honest answer: substituting `evaluateThenAggregate` would silently change totals.
        case unsupportedAggregationSemantics(ColumnID)
        /// A formula column references `SUM`/`COUNT`. Group-scoped formulas need a group at row
        /// evaluation time, which the 100 000-row store deliberately does not build per row.
        case aggregateFormulaUnsupported(ColumnID)
        case unknownColumn(ColumnID)
    }

    public let code: Code

    public init(code: Code) { self.code = code }

    public var description: String {
        switch code {
        case .inexactAddition(let reason): "decimal addition was not exact: \(reason.rawValue)"
        case .divisionByZero: "division by zero in an aggregate"
        case .distinctNotTracked: "distinct count was not planned for this column"
        case .cellError(let kind): "a member cell is in error: \(kind.rawValue)"
        case .unknownWeightColumn(let column): "unknown weight column \(column)"
        case .nonScalarWeight(let column): "weight column \(column) is not dimensionless"
        case .unsupportedAggregationSemantics(let column):
            "aggregateThenEvaluate is not implemented for column \(column)"
        case .aggregateFormulaUnsupported(let column):
            "formula column \(column) uses a group aggregate, which the store does not evaluate per row"
        case .unknownColumn(let column): "unknown column \(column)"
        }
    }
}

/// A cell that could not be produced. Distinct from an *empty* cell, always.
public struct LedgerCellError: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case formulaEvaluation
        case dimensionMismatch
        case divisionByZero
        case grammarVersionMismatch
        case aggregation
        /// A formula had nothing to compute from on this row: an input it reads is blank — a
        /// Length row has no area for `Area * (1 + [Waste])`, a row with no Pack size has no
        /// packs to order (V-058, ADR-0040).
        ///
        /// Not a refusal. The cell still says why it has no number, but a total leaves it out
        /// exactly as it leaves out an empty cell: a Gross total is the sum over the rows that
        /// have a gross. Overflow, division by zero and unit conflicts stay refusals, and so
        /// does a blank that is only blank because an input it reads was refused on this row
        /// (the store passes that refusal on instead of this kind).
        case missingInput
    }

    public let kind: Kind
    /// Diagnostic text. Never a user-facing string on its own — `Docs/Design/UX_COPY_STANDARD.md`
    /// owns the wording; this is what the copy layer is given to work with.
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(kind.rawValue): \(detail)" }

    /// True when the cell has no number because it had nothing to compute from, which a total
    /// treats like an empty cell (``Kind/missingInput``).
    public var isMissingInput: Bool { kind == .missingInput }
}

/// What ``LedgerStore/value(at:column:)`` returns.
///
/// Three states, not two: a value, nothing, or a reason there is nothing. Collapsing the third
/// into the second is how a `0` ends up in a total.
public enum LedgerCellResult: Hashable, Sendable {
    case value(LedgerCellValue)
    case error(LedgerCellError)

    public static let empty = LedgerCellResult.value(.empty)

    public var cellValue: LedgerCellValue? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var cellError: LedgerCellError? {
        if case .error(let error) = self { return error }
        return nil
    }

    /// True when the cell has no value and that is not a refusal: an empty cell, or a formula
    /// cell with nothing to compute from (``LedgerCellError/Kind/missingInput``, ADR-0040).
    ///
    /// W-063: the one reading of "no value" that totals, grouping, the Is empty filter and
    /// sorting share. Totals already left a "No input" cell out like an empty one; grouping
    /// filed it under "(error)", Is empty matched neither it nor its complement, and sorting
    /// put it in the error block.
    public var hasNoValue: Bool {
        switch self {
        case .value(.empty): true
        case .error(let error): error.isMissingInput
        case .value: false
        }
    }

    /// The dimensioned number this cell contributes to a sum, if it contributes one.
    public var quantity: DecimalQuantity? {
        switch self {
        case .value(.number(let quantity)): quantity
        case .value(.formulaResult(let quantity, _)): quantity
        case .value(.currency(let amount, let code)): DecimalQuantity.money(amount, currencyCode: code)
        default: nil
        }
    }
}
