import Foundation
import ZPDFContracts

/// The one addition primitive in the aggregation path (QUALITY_BAR A1, A2).
///
/// `Decimal`'s `+` operator saturates: on overflow it yields `Decimal.nan`, and on a sum whose
/// exact result needs more than 38 significant digits it silently drops the low ones. Both are
/// invisible to a caller using `reduce(0, +)`. `NSDecimalAdd` reports the same conditions as a
/// `NSDecimalNumber.CalculationError`, and this type is the only place in the package that
/// inspects it. Everything that adds two ledger numbers goes through here, so "the total equals
/// the exact sum of its parts" is enforced in one function rather than promised in many.
public enum DecimalSummation: Sendable {

    /// Adds two decimals, refusing anything that is not exact.
    ///
    /// - Throws: ``LedgerAggregationError`` carrying the `NSDecimalAdd` result code. A
    ///   `lossOfPrecision`, `overflow` or `underflow` becomes a typed error that the ledger
    ///   surfaces as a cell state; it is never rounded away.
    public static func add(_ left: Decimal, _ right: Decimal) throws -> Decimal {
        // The contracts' one exact-addition primitive (R-172), so a formula's `+` and a
        // ledger subtotal can never disagree about what "exact" means.
        let (result, status) = NumericPolicy.add(left, right)
        guard status == .noError else {
            throw LedgerAggregationError(code: .inexactAddition(Self.reason(status)))
        }
        guard !result.isNaN else {
            throw LedgerAggregationError(code: .inexactAddition(.overflow))
        }
        return result
    }

    /// Subtracts with the same guarantees as ``add(_:_:)``.
    public static func subtract(_ left: Decimal, _ right: Decimal) throws -> Decimal {
        let (result, status) = NumericPolicy.subtract(left, right)
        guard status == .noError, !result.isNaN else {
            throw LedgerAggregationError(code: .inexactAddition(Self.reason(status)))
        }
        return result
    }

    /// Multiplies with the same guarantees. Used by the weighted total (spec 15.5).
    public static func multiply(_ left: Decimal, _ right: Decimal) throws -> Decimal {
        var result = Decimal()
        var lhs = left
        var rhs = right
        let status = NSDecimalMultiply(&result, &lhs, &rhs, .plain)
        guard status == .noError, !result.isNaN else {
            throw LedgerAggregationError(code: .inexactAddition(Self.reason(status)))
        }
        return result
    }

    /// Divides at a declared scale. Division is the one aggregate operation that cannot be
    /// exact in general (``LedgerAggregationPolicy/averageScale``), which is exactly why
    /// ``LedgerAggregationPolicy`` declares the scale and the rounding mode once and everything
    /// — cell, subtotal and export — uses this call.
    public static func divide(
        _ left: Decimal,
        by right: Decimal,
        scale: Int = LedgerAggregationPolicy.averageScale
    ) throws -> Decimal {
        guard right != 0 else { throw LedgerAggregationError(code: .divisionByZero) }
        var quotient = Decimal()
        var lhs = left
        var rhs = right
        let status = NSDecimalDivide(&quotient, &lhs, &rhs, LedgerAggregationPolicy.averageRounding)
        // `.lossOfPrecision` is expected here and only here: 1/3 has no finite decimal form.
        guard status == .noError || status == .lossOfPrecision, !quotient.isNaN else {
            throw LedgerAggregationError(code: .inexactAddition(Self.reason(status)))
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, scale, LedgerAggregationPolicy.averageRounding)
        return rounded
    }

    /// Sums a sequence left to right through ``add(_:_:)``.
    ///
    /// The result is independent of the order of the input because every step is exact
    /// (QUALITY_BAR A3); the loop is left to right only so that a failure reports a
    /// reproducible position.
    public static func sum(_ values: some Sequence<Decimal>) throws -> Decimal {
        var total = Decimal.zero
        for value in values {
            total = try add(total, value)
        }
        return total
    }

    private static func reason(
        _ status: NSDecimalNumber.CalculationError
    ) -> LedgerAggregationError.InexactReason {
        switch status {
        case .noError: .overflow
        case .lossOfPrecision: .lossOfPrecision
        case .underflow: .underflow
        case .overflow: .overflow
        case .divideByZero: .divideByZero
        @unknown default: .overflow
        }
    }
}

/// Declared, single-origin aggregation numerics (QUALITY_BAR A9).
///
/// `Average` is `sum / count` at this scale with this rounding mode, everywhere: in a cell, in a
/// subtotal, in the grand total and in every export. Changing either constant changes all six at
/// once, which is the point.
public enum LedgerAggregationPolicy: Sendable {
    /// Decimal places retained by `Average` and by any other quotient in the aggregation path.
    public static let averageScale = 12
    /// Rounding mode used by those quotients. `.plain` is half-away-from-zero.
    public static let averageRounding = NSDecimalNumber.RoundingMode.plain
}
