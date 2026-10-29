import Foundation
import ZPDFContracts

/// The guards a compiled closure applies at evaluation time.
///
/// Every one of them throws a ``FormulaEngineError`` carrying the sub-expression that failed, so
/// a runtime dimension clash reads the same as a compile-time one.
enum FormulaRuntimeChecks {

    /// `operand` is the node whose value is checked and `text` the enclosing expression. A
    /// blank names the operand — the thing a COALESCE has to wrap — and keeps the enclosing
    /// expression as context. It used to name the enclosing expression, so the advice to wrap
    /// `[Waste] * 2` in COALESCE failed the same way from inside the COALESCE (U-071). The
    /// operand is rendered only when the error is thrown.
    static func requireNumber(
        _ value: FormulaValue,
        _ operand: FormulaNode,
        in text: String,
        _ span: FormulaSourceSpan
    ) throws -> DecimalQuantity {
        switch value {
        case .number(let quantity):
            return quantity
        case .blank:
            throw FormulaEngineError(code: .blankValue(operand.canonicalText), span: span, subexpression: text)
        case .boolean:
            throw FormulaEngineError(
                code: .typeMismatch(expected: "a number", actual: "a true/false value"),
                span: span,
                subexpression: text
            )
        }
    }

    /// The true/false counterpart of ``requireNumber(_:_:in:_:)``; a blank here is reported as
    /// ``FormulaEngineErrorCode/blankCondition(_:)``, whose advice is a true/false fallback.
    static func requireBoolean(
        _ value: FormulaValue,
        _ operand: FormulaNode,
        in text: String,
        _ span: FormulaSourceSpan
    ) throws -> Bool {
        switch value {
        case .boolean(let flag):
            return flag
        case .blank:
            throw FormulaEngineError(code: .blankCondition(operand.canonicalText), span: span, subexpression: text)
        case .number:
            throw FormulaEngineError(
                code: .typeMismatch(expected: "a true/false value", actual: "a number"),
                span: span,
                subexpression: text
            )
        }
    }

    /// Lines two operands up for an additive operation according to the plan the compiler made.
    static func align(
        _ left: DecimalQuantity,
        _ right: DecimalQuantity,
        _ coercion: AdditiveCoercion
    ) -> (DecimalQuantity, DecimalQuantity) {
        switch coercion {
        case .none, .deferred:
            return (left, right)
        case .adoptLeftFromRight:
            return (DecimalQuantity(value: left.value, dimension: right.dimension), right)
        case .adoptRightFromLeft:
            return (left, DecimalQuantity(value: right.value, dimension: left.dimension))
        }
    }

    /// Lines two operands up when either may be a literal-only value at run time (BH-153).
    ///
    /// A literal-only dimensionless value adopts its partner's dimension, as it would have at
    /// compile time had the partner's dimension been known; two literals, or two values from
    /// columns, are left as they are for the dimension check to judge.
    static func alignLiterals(
        _ left: DecimalQuantity,
        _ leftLiteral: Bool,
        _ right: DecimalQuantity,
        _ rightLiteral: Bool
    ) -> (DecimalQuantity, DecimalQuantity) {
        let leftFlexible = leftLiteral && left.dimension.isDimensionless
        let rightFlexible = rightLiteral && right.dimension.isDimensionless
        if leftFlexible && !rightFlexible { return (adopt(left, to: right.dimension), right) }
        if rightFlexible && !leftFlexible { return (left, adopt(right, to: left.dimension)) }
        return (left, right)
    }

    /// Applies ADR-0014 literal transparency to a product or quotient computed at run time:
    /// a dimensionless result keeps the tag of the operand that is not a literal, and two
    /// literals give a plain count (BH-542, BH-154).
    static func literalTransparent(
        _ result: DecimalQuantity,
        _ left: DecimalQuantity,
        _ leftLiteral: Bool,
        _ right: DecimalQuantity,
        _ rightLiteral: Bool
    ) -> DecimalQuantity {
        guard result.dimension.isDimensionless else { return result }
        let leftFlexible = leftLiteral && left.dimension.isDimensionless
        let rightFlexible = rightLiteral && right.dimension.isDimensionless
        var dimension = result.dimension
        switch (leftFlexible, rightFlexible) {
        case (true, true): dimension.ratio = false
        case (true, false): dimension.ratio = right.dimension.ratio
        case (false, true): dimension.ratio = left.dimension.ratio
        case (false, false): return result
        }
        return dimension == result.dimension
            ? result
            : DecimalQuantity(value: result.value, dimension: dimension)
    }

    /// Relabels a dimensionless literal result onto a known dimension.
    static func adopt(_ quantity: DecimalQuantity, to dimension: QuantityDimension) -> DecimalQuantity {
        quantity.dimension == dimension
            ? quantity
            : DecimalQuantity(value: quantity.value, dimension: dimension)
    }

    /// Turns a contract ``DimensionError`` into an engine error that names the sub-expression.
    /// Applies the compile-time count/ratio tag to a dimensionless runtime result (ADR-0014).
    ///
    /// The static rules let a bare literal be transparent to the tag (`Slope * 100` is a ratio),
    /// which the runtime algebra on two `DecimalQuantity` values cannot know. Only the tag on a
    /// dimensionless result is relabelled; a length power, angle or currency that disagrees
    /// with the static type is left as the algebra produced it, so a data mismatch stays visible.
    static func retagged(_ quantity: DecimalQuantity, to staticDimension: QuantityDimension?) -> DecimalQuantity {
        guard let staticDimension,
              staticDimension != quantity.dimension,
              staticDimension.isDimensionless,
              quantity.dimension.isDimensionless
        else { return quantity }
        return DecimalQuantity(value: quantity.value, dimension: staticDimension)
    }

    static func wrap(
        _ error: any Error,
        operation: String,
        _ text: String,
        _ span: FormulaSourceSpan
    ) -> any Error {
        if let engineError = error as? FormulaEngineError { return engineError }
        // `DecimalQuantity` arithmetic funnels every result through `NumericPolicy.requireFinite`;
        // an overflow surfaces as the engine's own typed code rather than a foreign error (CR-24).
        if let numeric = error as? NumericError, case .decimalOverflow = numeric {
            return FormulaEngineError(
                code: .numericOverflow(operation: operation),
                span: span,
                subexpression: text
            )
        }
        guard let dimensionError = error as? DimensionError else { return error }
        switch dimensionError {
        case .incompatibleDimensions(let left, let right):
            return FormulaEngineError(
                code: .dimensionMismatch(operation: operation, left: left, right: right),
                span: span,
                subexpression: text
            )
        case .divisionByZero:
            return FormulaEngineError(code: .divisionByZero, span: span, subexpression: text)
        default:
            return FormulaEngineError(
                code: .dimensionRejected(dimensionError),
                span: span,
                subexpression: text
            )
        }
    }

    /// Lines up a list of values where some came from dimensionless literals.
    static func alignList(
        _ values: [DecimalQuantity],
        flexible: [Bool],
        _ text: String,
        _ span: FormulaSourceSpan
    ) throws -> [DecimalQuantity] {
        var reference: QuantityDimension?
        for (index, value) in values.enumerated() where !(flexible[index] && value.dimension.isDimensionless) {
            reference = value.dimension
            break
        }
        guard let reference else { return values }
        var aligned: [DecimalQuantity] = []
        aligned.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let candidate = flexible[index] && value.dimension.isDimensionless
                ? adopt(value, to: reference)
                : value
            guard candidate.dimension == reference else {
                throw FormulaEngineError(
                    code: .dimensionMismatch(
                        operation: "combine",
                        left: reference,
                        right: candidate.dimension
                    ),
                    span: span,
                    subexpression: text
                )
            }
            aligned.append(candidate)
        }
        return aligned
    }

    /// `a % b` over `Decimal`, truncating toward zero like every other language the trade meets.
    static func remainder(
        _ lhs: Decimal,
        _ rhs: Decimal,
        _ text: String,
        _ span: FormulaSourceSpan
    ) throws -> Decimal {
        guard rhs != 0 else {
            throw FormulaEngineError(code: .moduloByZero, span: span, subexpression: text)
        }
        let quotient = DecimalMath.truncateTowardZero(lhs / rhs, digits: 0)
        return lhs - rhs * quotient
    }

    /// Validates a rounding digit count coming from an evaluated expression.
    static func roundingDigits(
        _ value: FormulaValue,
        _ operand: FormulaNode,
        in text: String,
        _ span: FormulaSourceSpan
    ) throws -> Int {
        let quantity = try requireNumber(value, operand, in: text, span)
        guard quantity.dimension.isDimensionless,
              let digits = DecimalMath.integer(quantity.value),
              DecimalMath.roundingDigitRange.contains(digits)
        else {
            throw FormulaEngineError(
                code: .invalidRoundingDigits(quantity.value),
                span: span,
                subexpression: text
            )
        }
        return digits
    }
}
