import Foundation
import ZPDFContracts

/// What the compiler knows about an expression's result before any row exists.
///
/// # Why `flexible` exists
///
/// A numeric literal is dimensionless, but `Area > 10` and `Length * 2` have to work or the
/// grammar is unusable. So a value that came from literals *only* is marked flexible: when it
/// meets a dimensioned value in an additive position it adopts that dimension. A dimensionless
/// value that came from a *column* or a *variable* (`Count`, `Slope`) is not flexible and will not
/// adopt anything — `Area + Count` is still an error. That keeps the headline guarantee intact:
/// two concretely dimensioned values are only added when their dimensions are equal.
public enum FormulaStaticType: Hashable, Sendable {
    /// A number whose dimension is known at compile time.
    case number(QuantityDimension, flexible: Bool)
    /// A number whose dimension is only known per row, because a column declared no dimension.
    /// These are the cases where dimensional analysis has to wait for evaluation.
    case dynamicNumber
    case boolean

    public static func number(_ dimension: QuantityDimension) -> FormulaStaticType {
        .number(dimension, flexible: false)
    }

    /// A dimensionless literal-derived number.
    public static let literalNumber = FormulaStaticType.number(.count, flexible: true)

    public var isNumeric: Bool {
        switch self {
        case .number, .dynamicNumber: true
        case .boolean: false
        }
    }

    public var dimension: QuantityDimension? {
        if case .number(let dimension, _) = self { return dimension }
        return nil
    }

    public var isFlexible: Bool {
        if case .number(_, let flexible) = self { return flexible }
        return false
    }

    /// The type a reference to a column holding this value has: the same, minus flexibility.
    /// A value read from a column is never a literal, whatever formula produced it (BH-152).
    var readThroughColumn: FormulaStaticType {
        if case .number(let dimension, _) = self { return .number(dimension, flexible: false) }
        return self
    }

    public var describedName: String {
        switch self {
        case .number(let dimension, _): dimension.formulaDescription
        case .dynamicNumber: "a number of unknown dimension"
        case .boolean: "a true/false value"
        }
    }
}

/// How the compiler has to line two operands up before an additive operation.
enum AdditiveCoercion: Hashable, Sendable {
    /// Dimensions already agree.
    case none
    /// The left operand is a dimensionless literal: relabel it with the right's dimension.
    case adoptLeftFromRight
    /// Mirror of ``adoptLeftFromRight``.
    case adoptRightFromLeft
    /// At least one dimension is only known per row; check it there.
    case deferred
}

enum FormulaTypeRules {

    /// Resolves `a + b`, `a - b`, `a % b`, a comparison, or the branches of `IF`/`MIN`/`MAX`.
    ///
    /// - Throws: ``FormulaEngineError`` naming both dimensions and the sub-expression when two
    ///   concrete, unequal dimensions meet.
    static func additive(
        _ left: FormulaStaticType,
        _ right: FormulaStaticType,
        operation: String,
        node: FormulaNode
    ) throws -> (type: FormulaStaticType, coercion: AdditiveCoercion) {
        if case .boolean = left {
            throw typeError(expected: "a number", actual: left, node: node)
        }
        if case .boolean = right {
            throw typeError(expected: "a number", actual: right, node: node)
        }
        switch (left, right) {
        case (.number(let a, let flexibleA), .number(let b, let flexibleB)):
            if a == b {
                return (.number(a, flexible: flexibleA && flexibleB), .none)
            }
            if flexibleA && a.isDimensionless {
                return (.number(b, flexible: false), .adoptLeftFromRight)
            }
            if flexibleB && b.isDimensionless {
                return (.number(a, flexible: false), .adoptRightFromLeft)
            }
            throw FormulaEngineError(
                code: .dimensionMismatch(operation: operation, left: a, right: b),
                span: node.span,
                subexpression: node.canonicalText
            )
        case (.number(let a, let flexibleA), .dynamicNumber):
            return flexibleA && a.isDimensionless
                ? (.dynamicNumber, .adoptLeftFromRight)
                : (.dynamicNumber, .deferred)
        case (.dynamicNumber, .number(let b, let flexibleB)):
            return flexibleB && b.isDimensionless
                ? (.dynamicNumber, .adoptRightFromLeft)
                : (.dynamicNumber, .deferred)
        case (.dynamicNumber, .dynamicNumber):
            return (.dynamicNumber, .deferred)
        case (.boolean, _), (_, .boolean):
            throw typeError(expected: "a number", actual: left, node: node)
        }
    }

    /// Resolves `a * b` and `a / b`.
    static func multiplicative(
        _ left: FormulaStaticType,
        _ right: FormulaStaticType,
        isDivision: Bool,
        node: FormulaNode
    ) throws -> FormulaStaticType {
        guard left.isNumeric else { throw typeError(expected: "a number", actual: left, node: node) }
        guard right.isNumeric else { throw typeError(expected: "a number", actual: right, node: node) }
        guard case .number(let a, let flexibleA) = left,
              case .number(let b, let flexibleB) = right
        else { return .dynamicNumber }
        do {
            var dimension = isDivision ? try a.divided(by: b) : try a.multiplied(by: b)
            // A bare literal is transparent to the count/ratio tag (ADR-0014): `Slope * 100` is
            // still a slope ratio and `Count / 2` is still a count, whereas the algebra alone
            // would say `ratio x count = count` and `count / count = ratio`. Only the tag on a
            // dimensionless result is touched; a literal never changes a length power.
            let literalA = flexibleA && a.isDimensionless
            let literalB = flexibleB && b.isDimensionless
            if dimension.isDimensionless, literalA != literalB {
                dimension.ratio = literalA ? b.ratio : a.ratio
            }
            // Two literals make a literal, which is a plain count whatever the algebra says:
            // `1 / 2` is the number one half, not a share (BH-154). Typing it a flexible ratio
            // made `1 + 1/2` a *non*-flexible ratio and refused `Length + (1 + 1/2)`.
            if literalA && literalB {
                dimension.ratio = false
            }
            return .number(dimension, flexible: flexibleA && flexibleB)
        } catch let error as DimensionError {
            throw FormulaEngineError(
                code: .dimensionRejected(error),
                span: node.span,
                subexpression: node.canonicalText
            )
        }
    }

    /// Resolves the dimension of `base ^ exponent` for a whole-number exponent.
    static func power(
        _ base: FormulaStaticType,
        exponent: Int,
        node: FormulaNode
    ) throws -> FormulaStaticType {
        guard base.isNumeric else { throw typeError(expected: "a number", actual: base, node: node) }
        guard Swift.abs(exponent) <= DecimalMath.maximumExponent else {
            throw FormulaEngineError(
                code: .exponentOutOfRange(Decimal(exponent)),
                span: node.span,
                subexpression: node.canonicalText
            )
        }
        guard case .number(let dimension, let flexible) = base else { return .dynamicNumber }
        return .number(try powerDimension(dimension, exponent, node: node), flexible: flexible)
    }

    static func powerDimension(
        _ dimension: QuantityDimension,
        _ exponent: Int,
        node: FormulaNode
    ) throws -> QuantityDimension {
        if exponent == 0 { return .count }
        // A factor squared is a factor and a count squared is a count: keep the tag (ADR-0014).
        if dimension.isDimensionless { return dimension }
        do {
            var result = QuantityDimension.count
            for _ in 0..<Swift.abs(exponent) {
                result = try result.multiplied(by: dimension)
            }
            if exponent < 0 {
                result = try QuantityDimension.count.divided(by: result)
            }
            return result
        } catch let error as DimensionError {
            throw FormulaEngineError(
                code: .dimensionRejected(error),
                span: node.span,
                subexpression: node.canonicalText
            )
        }
    }

    /// Resolves `SQRT(x)`: the length power has to be even and there must be no angle or currency.
    static func squareRoot(
        _ dimension: QuantityDimension,
        node: FormulaNode
    ) throws -> QuantityDimension {
        guard !dimension.angle, dimension.currencyCode == nil, dimension.lengthPower % 2 == 0 else {
            throw FormulaEngineError(
                code: .squareRootOfOddDimension(dimension),
                span: node.span,
                subexpression: node.canonicalText
            )
        }
        // The root of a factor is a factor and the root of a count a count: keep the tag, as
        // `x ^ n` does (ADR-0014 §2.5; BH-543 — the memberwise init dropped it).
        if dimension.isDimensionless { return dimension }
        return QuantityDimension(lengthPower: dimension.lengthPower / 2)
    }

    static func typeError(
        expected: String,
        actual: FormulaStaticType,
        node: FormulaNode
    ) -> FormulaEngineError {
        FormulaEngineError(
            code: .typeMismatch(expected: expected, actual: actual.describedName),
            span: node.span,
            subexpression: node.canonicalText
        )
    }
}
