import Foundation
import ZPDFContracts

/// One lexical item of the formula grammar.
public enum FormulaTokenKind: Hashable, Sendable {
    /// A numeric literal. Always parsed with '.' as the decimal separator, never a locale's.
    case number(Decimal)
    /// A bare identifier: a built-in variable, a function name or an unbracketed column name.
    case identifier(String)
    /// A bracketed reference: the inner text of `[...]`, already trimmed.
    case bracketReference(String)
    /// A double-quoted string, used for unit names in `CONVERT`.
    case string(String)
    /// `true` or `false`.
    case boolean(Bool)
    /// Any operator, symbolic (`+`, `<=`) or keyword (`and`, `not`).
    case op(FormulaOperator)
    case leftParenthesis
    case rightParenthesis
    case comma
    case endOfInput
}

/// A token with its source extent and the exact text it was lexed from.
public struct FormulaToken: Hashable, Sendable {
    public let kind: FormulaTokenKind
    public let span: FormulaSourceSpan
    public let text: String

    public init(kind: FormulaTokenKind, span: FormulaSourceSpan, text: String) {
        self.kind = kind
        self.span = span
        self.text = text
    }
}
