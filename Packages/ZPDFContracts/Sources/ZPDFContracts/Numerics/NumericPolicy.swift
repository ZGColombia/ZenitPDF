import Foundation

/// The one implementation of the numeric policy in spec 11.4.
///
/// - geometry is `Double`;
/// - aggregates and money are `Decimal`;
/// - the `Double` -> `Decimal` crossing happens at a *defined* significance, never implicitly;
/// - there is no internal display rounding — rounding happens in view and export code only;
/// - large `Double` sums use compensated (Kahan-Babuska-Neumaier) or pairwise summation before
///   they are normalised into `Decimal`.
public enum NumericPolicy: Sendable {

    /// Significant decimal digits used when a `Double` is normalised into a `Decimal`.
    ///
    /// 15 is the largest count for which every `Double` round-trips through a decimal string
    /// unambiguously in the direction that matters here (binary -> decimal), so it is the point
    /// where the conversion stops inventing digits the `Double` never had.
    public static let defaultSignificantDigits = 15

    /// The threshold above which callers must use ``kahanSum(_:)`` or ``pairwiseSum(_:)`` rather
    /// than a naive `reduce(0, +)`.
    public static let compensatedSummationThreshold = 64

    // MARK: - Summation

    /// Kahan-Babuska-Neumaier compensated summation.
    ///
    /// The Neumaier variant is used rather than plain Kahan because it stays correct when a
    /// later term is larger in magnitude than the running total — exactly the case when a
    /// polyline mixes millimetre-scale and kilometre-scale segments.
    public static func kahanSum(_ values: [Double]) -> Double {
        var sum = 0.0
        var compensation = 0.0
        for value in values {
            let candidate = sum + value
            if Swift.abs(sum) >= Swift.abs(value) {
                compensation += (sum - candidate) + value
            } else {
                compensation += (value - candidate) + sum
            }
            sum = candidate
        }
        return sum + compensation
    }

    /// Pairwise (cascade) summation. Deterministic, allocation-free, and independent of the
    /// order in which a caller happens to have built the array only up to the usual
    /// floating-point caveats — the recursion structure is fixed by the index range.
    public static func pairwiseSum(_ values: [Double]) -> Double {
        pairwiseSum(values, from: values.startIndex, to: values.endIndex)
    }

    private static func pairwiseSum(_ values: [Double], from low: Int, to high: Int) -> Double {
        let count = high - low
        if count == 0 { return 0.0 }
        if count <= 8 {
            var sum = 0.0
            for index in low..<high { sum += values[index] }
            return sum
        }
        let middle = low + count / 2
        return pairwiseSum(values, from: low, to: middle) + pairwiseSum(values, from: middle, to: high)
    }

    /// Sums with the policy's default strategy: pairwise below the threshold, Kahan–Babuska–Neumaier from it.
    public static func sum(_ values: [Double]) -> Double {
        values.count >= compensatedSummationThreshold ? kahanSum(values) : pairwiseSum(values)
    }

    // MARK: - Double -> Decimal

    /// Normalises a geometry `Double` into a `Decimal` at a defined significance.
    ///
    /// - Throws: ``NumericError/nonFiniteValue(_:)`` for NaN and infinities — the conversion
    ///   never silently produces `Decimal.nan`.
    public static func decimal(
        from value: Double,
        significantDigits: Int = NumericPolicy.defaultSignificantDigits
    ) throws -> Decimal {
        guard value.isFinite else { throw NumericError.nonFiniteValue(value) }
        guard (1...34).contains(significantDigits) else {
            throw NumericError.unsupportedSignificantDigits(significantDigits)
        }
        if value == 0 { return Decimal.zero }
        let text = String(format: "%.\(significantDigits - 1)e", value)
        guard let converted = Decimal(string: text, locale: nil) else {
            throw NumericError.notRepresentableAsDecimal(value)
        }
        return converted
    }

    /// Widens a `Decimal` back to `Double` for geometry maths. Lossy by construction, which is
    /// why it is spelled out rather than implicit.
    public static func double(from value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// The decimal exponents `Decimal` can actually hold.
    ///
    /// `Decimal` stores a 128-bit significand and a *signed 8-bit* exponent. Outside this range
    /// `Decimal(sign:exponent:significand:)` does not trap and does not return `nil`: it yields
    /// `Decimal.nan` above the range and collapses to `0` below it. Both are silent, which is
    /// why ``exact(_:_:)`` checks it.
    public static let decimalExponentRange = -128...127

    /// Builds an exact `Decimal` from an integer significand and a power of ten.
    ///
    /// Used for every unit conversion factor in this package so that no factor is ever born from
    /// a binary floating-point literal. `exact(254, -4)` is exactly `0.0254`, not `0.0254` as a
    /// `Double` happens to be.
    ///
    /// - Precondition: `exponent` is inside ``decimalExponentRange``. Every call site in the
    ///   product passes a literal, so an out-of-range exponent is a source-level mistake rather
    ///   than a data condition. An exponent that comes from data must be range-checked against
    ///   ``decimalExponentRange`` first.
    public static func exact(_ significand: UInt64, _ exponent: Int) -> Decimal {
        precondition(
            decimalExponentRange.contains(exponent),
            "NumericPolicy.exact: exponent \(exponent) is outside Decimal's range \(decimalExponentRange)"
        )
        return Decimal(sign: .plus, exponent: exponent, significand: Decimal(significand))
    }

    /// Rejects a `Decimal` that overflowed.
    ///
    /// `Decimal` arithmetic saturates to `NaN` instead of trapping, and a `NaN` `Decimal`
    /// compares as neither less than nor greater than anything — so an overflowed total sorts as
    /// an ordinary value and only reveals itself as the text "NaN" at the export boundary. Every
    /// arithmetic entry point on ``DecimalQuantity`` funnels through this.
    ///
    /// - Throws: ``NumericError/decimalOverflow(operation:)``.
    public static func requireFinite(_ value: Decimal, operation: String) throws -> Decimal {
        guard !value.isNaN else { throw NumericError.decimalOverflow(operation: operation) }
        return value
    }

    // MARK: - Exact addition (the one primitive, R-172)

    /// `left + right` through `NSDecimalAdd`, with the status it reports.
    ///
    /// `Decimal`'s `+` saturates to `NaN` on overflow and, on a sum whose exact result needs more
    /// than 38 significant digits, silently drops the low digits. `NSDecimalAdd` reports both.
    /// This is the one place the status is read: ``exactSum(_:_:operation:)`` turns it into a
    /// ``NumericError``, and the ledger's `DecimalSummation` into its own typed cell state, so
    /// a formula total and a ledger subtotal follow one exact-or-refuse rule.
    public static func add(
        _ left: Decimal,
        _ right: Decimal
    ) -> (value: Decimal, status: NSDecimalNumber.CalculationError) {
        var result = Decimal()
        var lhs = left
        var rhs = right
        let status = NSDecimalAdd(&result, &lhs, &rhs, .plain)
        return (result, status)
    }

    /// `left - right`, with the status of the addition that computes it.
    ///
    /// It is `left + (-right)` through `NSDecimalAdd`, never `NSDecimalSubtract`: measured on
    /// this toolchain, `NSDecimalSubtract` rounds a difference that needs more than 38 digits and
    /// reports `.noError` — 38 nines minus 7.7 came back as …92 (the exact value is …91.3), with
    /// no status — while `NSDecimalAdd` of the negated operand reports `.lossOfPrecision` for the
    /// same pair. Negating a `Decimal` flips its sign and is exact.
    public static func subtract(
        _ left: Decimal,
        _ right: Decimal
    ) -> (value: Decimal, status: NSDecimalNumber.CalculationError) {
        add(left, -right)
    }

    /// The exact sum, or a refusal.
    ///
    /// - Throws: ``NumericError/decimalOverflow(operation:)`` when the result overflowed or would
    ///   have had to be rounded to fit `Decimal`'s 38-digit mantissa. The rounded value is never
    ///   returned.
    public static func exactSum(_ left: Decimal, _ right: Decimal, operation: String = "add") throws -> Decimal {
        let (value, status) = add(left, right)
        guard status == .noError, !value.isNaN else { throw NumericError.decimalOverflow(operation: operation) }
        return value
    }

    /// The exact difference, or a refusal, under the same rule as ``exactSum(_:_:operation:)``.
    public static func exactDifference(_ left: Decimal, _ right: Decimal, operation: String = "subtract") throws -> Decimal {
        let (value, status) = subtract(left, right)
        guard status == .noError, !value.isNaN else { throw NumericError.decimalOverflow(operation: operation) }
        return value
    }

    // MARK: - Rounding (view and export boundary only)

    /// Rounds a `Decimal` to a number of decimal places, bankers-free (`.plain` half-up away
    /// from zero). **Call this at the view or export boundary only.** Stored SI values are never
    /// rounded (spec 11.4, 11.5).
    public static func rounded(_ value: Decimal, decimalPlaces: Int) -> Decimal {
        var input = value
        var output = Decimal.zero
        NSDecimalRound(&output, &input, decimalPlaces, .plain)
        return output
    }

    /// Rounds a `Decimal` to the nearest 1/denominator, for imperial fraction display.
    /// **View and export boundary only.**
    public static func roundedToFraction(_ value: Decimal, denominator: Int) -> Decimal {
        guard denominator > 0 else { return value }
        let scale = Decimal(denominator)
        var scaled = value * scale
        var whole = Decimal.zero
        NSDecimalRound(&whole, &scaled, 0, .plain)
        return whole / scale
    }
}
