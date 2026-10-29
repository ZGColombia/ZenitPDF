import Foundation
import ZPDFContracts

/// The `Decimal` arithmetic the formula engine needs beyond `+ - * /`.
///
/// # Rounding policy
///
/// Every rounding function in this engine uses **half away from zero**, never banker's rounding:
///
/// - `ROUND(2.5, 0) == 3`, `ROUND(-2.5, 0) == -3`
/// - `ROUND(0.125, 2) == 0.13` (banker's rounding would give `0.12`)
///
/// The reason is that a takeoff is a commercial document. Half-away-from-zero is what a quantity
/// surveyor checking a line by hand produces, and it is what every spreadsheet the trade already
/// uses produces. Banker's rounding is statistically nicer and commercially surprising, so it is
/// not offered — there is no mode switch to get it wrong with.
///
/// `ROUNDUP` and `ROUNDDOWN` are magnitude-directed (away from zero / toward zero); `CEILING` and
/// `FLOOR` are sign-directed (toward +inf / toward -inf). For positive values they coincide; for
/// negative values they deliberately do not.
///
/// None of these are applied implicitly. Stored values stay unrounded (spec 11.4); rounding only
/// happens because a formula asked for it, or at a view/export boundary.
public enum DecimalMath: Sendable {

    /// The largest absolute integer exponent `^` and `POW` accept.
    ///
    /// Exponentiation is repeated exact multiplication, so a large exponent is not slow, it is
    /// enormous: `10 ^ 200` has no `Decimal` representation. 64 is far past anything a takeoff
    /// formula needs and stays inside `Decimal`'s range for realistic bases.
    public static let maximumExponent = 64

    /// The digit counts the rounding functions accept.
    public static let roundingDigitRange = -18...18

    // MARK: - Integer probing

    /// True when the value has no fractional part.
    public static func isInteger(_ value: Decimal) -> Bool {
        var input = value
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded == value
    }

    /// Converts an integral `Decimal` to `Int`, or returns nil when it is fractional or too large.
    public static func integer(_ value: Decimal) -> Int? {
        guard isInteger(value) else { return nil }
        let number = NSDecimalNumber(decimal: value)
        let doubleValue = number.doubleValue
        guard doubleValue >= -9.007199254740992e15, doubleValue <= 9.007199254740992e15 else {
            return nil
        }
        return number.intValue
    }

    // MARK: - Rounding family

    /// One decimal step at the given digit count: `step(2) == 0.01`, `step(-2) == 100`.
    static func step(_ digits: Int) -> Decimal {
        Decimal(sign: .plus, exponent: -digits, significand: 1)
    }

    /// Half away from zero. The engine's `ROUND`.
    public static func roundHalfAwayFromZero(_ value: Decimal, digits: Int) -> Decimal {
        var input = value
        var output = Decimal.zero
        NSDecimalRound(&output, &input, digits, .plain)
        return output
    }

    /// Truncation toward zero. The engine's `ROUNDDOWN`.
    ///
    /// Derived from ``roundHalfAwayFromZero(_:digits:)`` rather than from an `NSRoundingMode`, so
    /// the sign semantics are ours and not Foundation's: half-away rounding moves a value by at
    /// most half a step, so if it grew in magnitude, backing off exactly one step lands on the
    /// truncation.
    public static func truncateTowardZero(_ value: Decimal, digits: Int) -> Decimal {
        let rounded = roundHalfAwayFromZero(value, digits: digits)
        guard DecimalMath.abs(rounded) > DecimalMath.abs(value) else { return rounded }
        return value < 0 ? rounded + step(digits) : rounded - step(digits)
    }

    /// Away from zero. The engine's `ROUNDUP`.
    public static func roundAwayFromZero(_ value: Decimal, digits: Int) -> Decimal {
        let truncated = truncateTowardZero(value, digits: digits)
        guard truncated != value else { return value }
        return value < 0 ? truncated - step(digits) : truncated + step(digits)
    }

    /// Toward +infinity. The engine's `CEILING`.
    public static func ceiling(_ value: Decimal, digits: Int) -> Decimal {
        value < 0 ? truncateTowardZero(value, digits: digits) : roundAwayFromZero(value, digits: digits)
    }

    /// Toward -infinity. The engine's `FLOOR`.
    public static func floor(_ value: Decimal, digits: Int) -> Decimal {
        value < 0 ? roundAwayFromZero(value, digits: digits) : truncateTowardZero(value, digits: digits)
    }

    // MARK: - Power and root

    /// Exact integer exponentiation by squaring.
    ///
    /// `Decimal` saturates to `NaN` instead of trapping, and a `NaN` `Decimal` compares as less
    /// than everything, so an overflowed `1000000 ^ 64` used to steer `>`, `IF`, `MAX` and
    /// `ROUND` silently (code review CR-24). The result is checked before it leaves.
    ///
    /// - Throws: ``FormulaEngineError`` with ``FormulaEngineErrorCode/exponentOutOfRange(_:)``,
    ///   ``FormulaEngineErrorCode/divisionByZero`` or
    ///   ``FormulaEngineErrorCode/numericOverflow(operation:)`` — never returns a NaN `Decimal`.
    public static func power(
        _ base: Decimal,
        _ exponent: Int,
        span: FormulaSourceSpan? = nil,
        subexpression: String? = nil
    ) throws -> Decimal {
        guard Swift.abs(exponent) <= maximumExponent else {
            throw FormulaEngineError(
                code: .exponentOutOfRange(Decimal(exponent)),
                span: span,
                subexpression: subexpression
            )
        }
        if exponent == 0 { return 1 }
        if exponent < 0 && base == 0 {
            throw FormulaEngineError(
                code: .divisionByZero,
                span: span,
                subexpression: subexpression
            )
        }
        var result = Decimal(1)
        var factor = base
        var remaining = Swift.abs(exponent)
        while remaining > 0 {
            if remaining & 1 == 1 { result *= factor }
            remaining >>= 1
            if remaining > 0 { factor *= factor }
        }
        let value = exponent < 0 ? 1 / result : result
        guard !value.isNaN else {
            throw FormulaEngineError(
                code: .numericOverflow(operation: "power"),
                span: span,
                subexpression: subexpression
            )
        }
        return value
    }

    /// Square root by Newton-Raphson over `Decimal`, seeded from the IEEE `Double` root.
    ///
    /// Deterministic: the seed is an exactly-specified `Double` operation, the iteration count is
    /// bounded, and the loop stops on a fixed point or a two-cycle rather than on a tolerance
    /// that would depend on magnitude.
    public static func squareRoot(
        _ value: Decimal,
        span: FormulaSourceSpan? = nil,
        subexpression: String? = nil
    ) throws -> Decimal {
        if value == 0 { return 0 }
        guard value > 0 else {
            throw FormulaEngineError(
                code: .negativeSquareRoot(value),
                span: span,
                subexpression: subexpression
            )
        }
        let seedDouble = NumericPolicy.double(from: value).squareRoot()
        var guess: Decimal
        if seedDouble.isFinite, seedDouble > 0, let seed = try? NumericPolicy.decimal(from: seedDouble) {
            guess = seed
        } else {
            guess = value > 1 ? value / 2 : value
        }
        var previous = Decimal.zero
        for _ in 0..<32 {
            let next = (guess + value / guess) / 2
            if next == guess || next == previous { return next }
            previous = guess
            guess = next
        }
        return guess
    }

    /// `abs` for `Decimal` without going through `Foundation`'s free function shadowing.
    public static func abs(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}
