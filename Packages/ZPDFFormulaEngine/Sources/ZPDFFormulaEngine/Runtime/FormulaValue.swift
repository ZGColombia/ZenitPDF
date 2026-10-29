import Foundation
import ZPDFContracts

/// The result of evaluating a formula, or of reading one cell.
///
/// There is no NaN and no infinity. Anything that would produce one is a typed error instead.
public enum FormulaValue: Hashable, Sendable {
    /// A dimensioned number in SI base units.
    case number(DecimalQuantity)
    case boolean(Bool)
    /// An empty cell or an absent measurement field. Blank is *not* zero: using it in arithmetic
    /// is an error, and `COALESCE` is how a formula says what it should have been.
    case blank

    public var isBlank: Bool { self == .blank }

    public var quantity: DecimalQuantity? {
        if case .number(let quantity) = self { return quantity }
        return nil
    }

    public var booleanValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    /// A short name used in type-mismatch messages.
    public var typeName: String {
        switch self {
        case .number: "a number"
        case .boolean: "a true/false value"
        case .blank: "a blank"
        }
    }

    /// Bridges to the frozen ``LedgerCellValue`` for storage in a formula column.
    public func ledgerCellValue(grammarVersion: Int = FormulaGrammar.version) -> LedgerCellValue {
        switch self {
        case .number(let quantity):
            .formulaResult(value: quantity, grammarVersion: grammarVersion)
        case .boolean(let value):
            .checkbox(value)
        case .blank:
            .empty
        }
    }

    /// Reads a stored cell of `column` with the dimension ``FormulaColumnDescriptor`` types that
    /// column with, so the value a formula reads at run time agrees with the type it was
    /// compiled against.
    ///
    /// Only a currency column that declares a money dimension differs from ``init(_:)``: its
    /// cell stores a bare amount and a code, and the declared dimension says whether that amount
    /// is money or a rate such as SEK/m² (S-088). Read as plain money, `Area * [Rate]` came out
    /// as SEK·m² on every row.
    public init(_ cell: LedgerCellValue, in column: LedgerColumnDefinition) {
        if case .currency(let amount, let code) = cell,
           let declared = column.declaredMoneyDimension,
           declared.currencyCode == code {
            self = .number(DecimalQuantity(value: amount, dimension: declared))
        } else {
            self.init(cell)
        }
    }

    /// Reads a stored ledger cell back into an engine value.
    public init(_ cell: LedgerCellValue) {
        switch cell {
        case .empty, .text, .date, .choice:
            self = .blank
        case .number(let quantity):
            self = .number(quantity)
        case .currency(let amount, let code):
            self = .number(DecimalQuantity.money(amount, currencyCode: code))
        case .checkbox(let value):
            self = .boolean(value)
        case .formulaResult(let value, _):
            self = .number(value)
        }
    }
}

extension LedgerColumnDefinition {
    /// The money dimension a currency column declares — plain money or a rate per length power —
    /// or nil when it is not a currency column or declared none. The formula catalog and the
    /// cell reader both read it, so the compile-time type and the run-time value cannot drift.
    var declaredMoneyDimension: QuantityDimension? {
        guard kind == .currency, let dimension, dimension.currencyCode != nil else { return nil }
        return dimension
    }
}
