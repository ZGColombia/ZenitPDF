import Foundation
import ZPDFContracts

extension QuantityDimension {
    /// A human-readable name for the dimension, used verbatim in error messages.
    ///
    /// The contract's ``QuantityDimension/baseUnitSymbol`` gives the symbol; this adds the noun,
    /// because "cannot add m to m^2" reads worse than "cannot add length (m) to area (m^2)".
    public var formulaDescription: String {
        if let code = currencyCode {
            return lengthPower == 0
                ? "money (\(code))"
                : "unit price (\(baseUnitSymbol))"
        }
        if angle { return "angle (rad)" }
        switch lengthPower {
        // ADR-0014: a count and a ratio are both dimensionless and refuse to add, so the
        // message has to tell them apart or it reads "cannot add dimensionless (1) and
        // dimensionless (1)" (BH-155).
        case 0: return ratio ? "dimensionless ratio (1)" : "dimensionless count (1)"
        case 1: return "length (m)"
        case 2: return "area (m^2)"
        case 3: return "volume (m^3)"
        default: return "m^\(lengthPower)"
        }
    }
}

/// Every way the formula engine can refuse a formula (spec 15.4).
///
/// The engine never returns NaN, never returns infinity and never silently coerces a dimension.
/// Every refusal is one of these cases, carried inside a ``FormulaEngineError`` that also knows
/// where in the source it happened.
public enum FormulaEngineErrorCode: Hashable, Sendable {
    // Lexing and parsing
    case emptySource
    case unexpectedCharacter(Character)
    case unexpectedToken(String)
    case unexpectedEndOfInput
    case unterminatedColumnReference
    case unterminatedString
    case malformedNumber(String)
    case malformedColumnIdentifier(String)
    case trailingInput(String)
    /// The formula nests deeper than ``FormulaParser/maximumNestingDepth`` (BH-158).
    case nestingTooDeep(limit: Int)

    // Naming
    case unknownFunction(String)
    case unknownVariable(String)
    case unknownColumnName(String)
    case unknownColumnID(ColumnID)
    case duplicateColumnName(String)
    case duplicateColumnID(ColumnID)
    case argumentCountMismatch(function: String, expected: ClosedRange<Int>, actual: Int)
    case expectedUnitLiteral(function: String, argumentIndex: Int)
    case unknownUnit(String)
    case unsupportedGrammarVersion(stored: Int, supported: Int)

    // Types and dimensions
    case dimensionMismatch(operation: String, left: QuantityDimension, right: QuantityDimension)
    case dimensionRejected(DimensionError)
    case incompatibleUnits(from: String, to: String)
    /// `CONVERT(x, from, to)` where `x` is a measured quantity — always held in its SI base
    /// unit `base` — but `from` names another unit. Reading the base magnitude as `from` was a
    /// silent wrong result: `CONVERT(Area, ft2, m2)` on 10 m² gave 0.929 (R-136).
    case convertSourceNotBaseUnit(from: String, base: String)
    case typeMismatch(expected: String, actual: String)
    /// The exponent has a fractional part (`Length ^ 1.5`).
    case nonIntegerExponent(Decimal)
    /// A whole-number exponent outside ±``DecimalMath/maximumExponent``. The payload is a
    /// `Decimal` so a literal past `Int`'s range (`Area ^ 5000000000000000000`) keeps its value
    /// in the message instead of being reported as fractional (C-03).
    case exponentOutOfRange(Decimal)
    case invalidRoundingDigits(Decimal)
    case squareRootOfOddDimension(QuantityDimension)

    // Evaluation
    case divisionByZero
    case moduloByZero
    case negativeSquareRoot(Decimal)
    /// A `Decimal` operation saturated to NaN. `Decimal` never traps on overflow and a NaN
    /// compares as less than everything, so without this code `1000000 ^ 64` silently steered
    /// `>`, `IF`, `MAX` and `ROUND` (code review CR-24).
    case numericOverflow(operation: String)
    /// A blank value reached arithmetic or a comparison. The payload is the canonical text of the
    /// operand that was blank (U-071); the error's `subexpression` is the enclosing expression.
    case blankValue(String)
    /// A blank value was used as a true/false condition. Payload as for ``blankValue(_:)``.
    case blankCondition(String)
    /// `SUM`, `AVG` or `COUNT` was evaluated. They type-check, so a caller can refuse a formula
    /// that uses them, but no evaluation supplies a group of rows to range over (U-074). The
    /// payload is the function name.
    case aggregateNotEvaluable(String)
    case nestedAggregate(String)

    // Graph
    case cycleDetected(path: [String])
}

/// A formula failure with a message, a source span and the offending sub-expression.
///
/// `subexpression` is the canonical rendering of the AST node that failed, not a slice of the raw
/// text, so a dimension error reports `Length + Area` even when the user wrote
/// `  length   +[ Area ]`.
public struct FormulaEngineError: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: FormulaEngineErrorCode
    public let span: FormulaSourceSpan?
    public let subexpression: String?
    public let message: String

    public init(
        code: FormulaEngineErrorCode,
        span: FormulaSourceSpan? = nil,
        subexpression: String? = nil,
        message: String? = nil
    ) {
        self.code = code
        self.span = span
        self.subexpression = subexpression
        self.message = message ?? FormulaEngineError.defaultMessage(
            for: code,
            subexpression: subexpression
        )
    }

    public var description: String {
        guard let span else { return message }
        return "\(message) [offset \(span.start)]"
    }

    /// " in `<enclosing>`" when the blank operand is part of a larger expression, else nothing.
    private static func blankContext(_ operand: String, _ subexpression: String?) -> String {
        guard let subexpression, subexpression != operand else { return "" }
        return " in `\(subexpression)`"
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func defaultMessage(
        for code: FormulaEngineErrorCode,
        subexpression: String?
    ) -> String {
        let context = subexpression.map { " in `\($0)`" } ?? ""
        switch code {
        case .emptySource:
            return "The formula is empty."
        case .unexpectedCharacter(let character):
            return "The character '\(character)' is not part of the formula grammar."
        case .unexpectedToken(let text):
            return "Unexpected `\(text)`\(context)."
        case .unexpectedEndOfInput:
            return "The formula ended while more input was expected."
        case .unterminatedColumnReference:
            return "A column reference is missing its closing ']'."
        case .unterminatedString:
            return "A quoted unit name is missing its closing '\"'."
        case .malformedNumber(let text):
            return "`\(text)` is not a valid number. The decimal separator is always '.'."
        case .malformedColumnIdentifier(let text):
            return "`\(text)` is not a valid column identifier."
        case .trailingInput(let text):
            return "The formula ends after a complete expression, but `\(text)` follows."
        case .nestingTooDeep(let limit):
            return "The formula nests more than \(limit) levels deep (parentheses, operators or function calls inside one another). Split it across formula columns."
        case .unknownFunction(let name):
            return "`\(name)` is not one of the built-in formula functions."
        case .unknownVariable(let name):
            return "`\(name)` is neither a measurement field nor a known column."
        case .unknownColumnName(let name):
            return "There is no column named `\(name)`."
        case .unknownColumnID(let id):
            return "There is no column with id \(id.description)."
        case .duplicateColumnName(let name):
            return "More than one column is named `\(name)`, so a formula cannot tell which one it means. Rename one of them, or refer to it as `[col:<id>]`."
        case .duplicateColumnID(let id):
            return "Two columns share the id \(id.description)."
        case .argumentCountMismatch(let function, let expected, let actual):
            let range = expected.lowerBound == expected.upperBound
                ? "\(expected.lowerBound)"
                : "\(expected.lowerBound) to \(expected.upperBound)"
            return "\(function) takes \(range) arguments, but \(actual) were given."
        case .expectedUnitLiteral(let function, let index):
            return "\(function) argument \(index + 1) must be a unit name such as m, ft or m2."
        case .unknownUnit(let symbol):
            return "`\(symbol)` is not a known unit."
        case .unsupportedGrammarVersion(let stored, let supported):
            return "The formula was written for grammar version \(stored); this build understands \(supported)."
        case .dimensionMismatch(let operation, let left, let right):
            return "Cannot \(operation) \(left.formulaDescription) and \(right.formulaDescription)\(context)."
        case .dimensionRejected(let error):
            return "The dimensional algebra rejected this expression\(context): \(error)."
        case .incompatibleUnits(let from, let to):
            return "CONVERT cannot go from `\(from)` to `\(to)`: they measure different dimensions."
        case .convertSourceNotBaseUnit(let from, let base):
            return "A measured quantity is always held in `\(base)`, so CONVERT has to read it from `\(base)`, not `\(from)`\(context)."
        case .typeMismatch(let expected, let actual):
            return "Expected \(expected) but found \(actual)\(context)."
        case .nonIntegerExponent(let value):
            return "Exponents must be whole numbers; `\(value)` is not\(context)."
        case .exponentOutOfRange(let exponent):
            return "The exponent \(exponent) is outside the supported range \(-DecimalMath.maximumExponent)...\(DecimalMath.maximumExponent)."
        case .invalidRoundingDigits(let value):
            return "The digit count for a rounding function must be a whole number in -18...18; `\(value)` is not."
        case .squareRootOfOddDimension(let dimension):
            return "SQRT needs an even length power; \(dimension.formulaDescription) has no square root in this algebra."
        case .divisionByZero:
            return "Division by zero\(context)."
        case .moduloByZero:
            return "Remainder by zero\(context)."
        case .numericOverflow(let operation):
            return "The result of \(operation) is too large for a Decimal\(context)."
        case .negativeSquareRoot(let value):
            return "SQRT of the negative value \(value) is not a real number."
        case .blankValue(let operand):
            return "`\(operand)` is blank\(blankContext(operand, subexpression)) and cannot be used in a calculation. Use COALESCE(\(operand), 0) to give it a value."
        case .blankCondition(let operand):
            return "`\(operand)` is blank\(blankContext(operand, subexpression)) and cannot be used as true or false. Use COALESCE(\(operand), false) to give it a value."
        case .aggregateNotEvaluable(let function):
            return "\(function) ranges over a group of rows and cannot be evaluated in a row formula\(context). The Quantity Ledger's group and grand totals already sum each column."
        case .nestedAggregate(let text):
            return "Aggregate functions cannot be nested\(context.isEmpty ? " (`\(text)`)" : context)."
        case .cycleDetected(let path):
            return "Circular column reference: \(path.joined(separator: " -> "))."
        }
    }
}
