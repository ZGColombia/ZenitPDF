import Foundation
import ZPDFContracts

/// The formatting metadata that travels with every exported value, and the single rounding
/// boundary of the whole product.
///
/// # Why this type exists
///
/// A CSV writer, an XLSX writer, a JSON writer and a PDF renderer that each hold a `Decimal` and
/// each decide how to present it will, eventually, disagree — one converts to the display unit
/// before rounding and another after, one rounds the already-rounded on-screen string, one uses
/// a different rounding mode. The user then has four numbers for one quantity and no way to tell
/// which is right. So exporters are not given a number and a hint; they are given this, and they
/// call ``displayDecimal(_:)``.
///
/// # Round once
///
/// ``displayDecimal(_:)`` converts from the SI base value to the display unit and then applies
/// the precision **exactly once**. It never accepts an already-rounded input, which is what makes
/// double rounding impossible rather than merely discouraged: `0.4449` at two decimals is `0.44`,
/// and there is no path through this type that produces the `0.45` you get by rounding to three
/// decimals first (QUALITY_BAR A30, A31).
public struct LedgerValueFormatting: Hashable, Sendable {
    public let dimension: QuantityDimension?
    public let displayUnit: AnyDisplayUnit?
    public let precision: PrecisionMode?
    public let currencyCode: String?

    public init(
        dimension: QuantityDimension? = nil,
        displayUnit: AnyDisplayUnit? = nil,
        precision: PrecisionMode? = nil,
        currencyCode: String? = nil
    ) {
        self.dimension = dimension
        self.displayUnit = displayUnit
        self.precision = precision
        self.currencyCode = currencyCode
    }

    public static let plain = LedgerValueFormatting()

    /// Formatting for one column.
    public init(column: LedgerColumnDefinition) {
        self.dimension = column.dimension
        self.displayUnit = column.displayUnit
        self.precision = column.precision
        self.currencyCode = column.dimension?.currencyCode
    }

    /// This formatting for a row whose markup has display units of its own (NL-MEASURE-10,
    /// ADR-0035 §1.3): a length, area, volume or angle column takes the override's unit of that
    /// family and the override's precision — exactly what ``LedgerColumnSet/standard(displayPolicy:)``
    /// would give the column in a project set to those units. A count, a ratio, a currency and a
    /// dimensionless column have no unit to override and are returned unchanged. Only the
    /// rendering changes: the SI value, and every total it enters, is untouched.
    public func overriding(_ policy: DisplayUnitPolicy) -> LedgerValueFormatting {
        guard let dimension, dimension.currencyCode == nil,
              dimension.angle || (1...3).contains(dimension.lengthPower) else { return self }
        return LedgerValueFormatting(
            dimension: dimension,
            displayUnit: LedgerColumnSet.displayUnit(for: dimension, policy: policy),
            precision: policy.precision,
            currencyCode: currencyCode
        )
    }

    /// The unit symbol an export writes in its unit column (spec 15.8).
    public var unitSymbol: String { displayUnit?.symbol ?? dimension?.baseUnitSymbol ?? "" }

    /// The exact SI base value re-expressed in the display unit, unrounded.
    public func converted(_ base: Decimal) -> Decimal {
        switch displayUnit {
        case .length(let unit): unit.fromBase(base)
        case .area(let unit): unit.fromBase(base)
        case .volume(let unit): unit.fromBase(base)
        case .angle(let unit): unit.fromBase(base)
        case .count, .currency, nil: base
        }
    }

    /// Convert, then round. **Once.** The only rounding call an exporter or a cell renderer makes.
    ///
    /// A value that rounds to zero is the unsigned zero (IM-079): `-0.004` at two places is
    /// `0`, never a negative zero a formatter could print as `-0.00`. This is the product's
    /// single rounding entry point; ``LedgerDisplayRounding/round(_:places:)`` delegates here.
    public func displayDecimal(_ base: Decimal) -> Decimal {
        let converted = converted(base)
        guard let precision else { return Self.unsignedZero(converted) }
        return Self.unsignedZero(precision.apply(to: converted))
    }

    /// `value`, with any zero — however its sign or exponent is stored — as plain `0`.
    static func unsignedZero(_ value: Decimal) -> Decimal {
        value.isZero ? .zero : value
    }

    /// The display decimal of an aggregate, or `nil` when the aggregate is a refusal or empty —
    /// in which case the export writes ``LedgerReport/mixedDimensionsToken`` or its error token
    /// instead of a number.
    public func displayDecimal(of aggregate: AggregateValue) -> Decimal? {
        switch aggregate {
        case .quantity(let quantity): displayDecimal(quantity.value)
        case .currency(let amount, _): displayDecimal(amount)
        case .integer(let value): Decimal(value)
        case .empty, .mixedDimensions, .failed: nil
        }
    }

    /// The exact, unrounded value an export's raw column carries (spec 15.8: raw *and* display).
    public func rawDecimal(of aggregate: AggregateValue) -> Decimal? { aggregate.decimal }
}
