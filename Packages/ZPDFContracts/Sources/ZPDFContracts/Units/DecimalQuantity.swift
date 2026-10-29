import Foundation

/// A dimensioned decimal value, always stored in the SI base unit of its dimension.
///
/// This is the currency of every aggregate in the product. Geometry is computed in `Double`;
/// the moment a number becomes something the ledger, an export or a price touches, it crosses
/// into `DecimalQuantity` through ``NumericPolicy/decimal(from:significantDigits:)`` and never
/// goes back.
///
/// Stored values are never rounded (spec 11.4). ``PrecisionMode`` is display metadata carried
/// alongside, applied at the view and export boundary only.
public struct DecimalQuantity: Codable, Hashable, Sendable {
    /// The magnitude, in the SI base unit named by ``QuantityDimension/baseUnitSymbol``:
    /// metre, square metre, cubic metre, radian, dimensionless, or a currency major unit.
    public let value: Decimal
    /// What the value is.
    public let dimension: QuantityDimension

    public init(value: Decimal, dimension: QuantityDimension) {
        self.value = value
        self.dimension = dimension
    }

    // MARK: - Convenience constructors

    public static func count(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .count)
    }

    public static func count(_ value: Int) -> DecimalQuantity {
        DecimalQuantity(value: Decimal(value), dimension: .count)
    }

    public static func ratio(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .ratio)
    }

    /// Metres.
    public static func length(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .length)
    }

    /// Square metres.
    public static func area(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .area)
    }

    /// Cubic metres.
    public static func volume(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .volume)
    }

    /// Radians.
    public static func angle(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .angle)
    }

    public static func money(_ value: Decimal, currencyCode: String) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .currency(currencyCode))
    }

    /// Builds a quantity from a value expressed in a display unit, converting to the SI base.
    public static func length(_ value: Decimal, in unit: LengthUnit) -> DecimalQuantity {
        .length(unit.toBase(value))
    }

    public static func area(_ value: Decimal, in unit: AreaUnit) -> DecimalQuantity {
        .area(unit.toBase(value))
    }

    public static func volume(_ value: Decimal, in unit: VolumeUnit) -> DecimalQuantity {
        .volume(unit.toBase(value))
    }

    public static func angle(_ value: Decimal, in unit: AngleUnit) -> DecimalQuantity {
        .angle(unit.toBase(value))
    }

    /// The dimensionless zero.
    public static let zero = DecimalQuantity(value: 0, dimension: .count)

    /// Zero in a given dimension. Needed because zero still has to be additive with its peers.
    public static func zero(_ dimension: QuantityDimension) -> DecimalQuantity {
        DecimalQuantity(value: 0, dimension: dimension)
    }

    // MARK: - Reading out

    /// The value re-expressed in a display unit. Throws if the dimension is not length.
    public func converted(to unit: LengthUnit) throws -> Decimal {
        try requireDimension(.length)
        return unit.fromBase(value)
    }

    public func converted(to unit: AreaUnit) throws -> Decimal {
        try requireDimension(.area)
        return unit.fromBase(value)
    }

    public func converted(to unit: VolumeUnit) throws -> Decimal {
        try requireDimension(.volume)
        return unit.fromBase(value)
    }

    public func converted(to unit: AngleUnit) throws -> Decimal {
        try requireDimension(.angle)
        return unit.fromBase(value)
    }

    private func requireDimension(_ expected: QuantityDimension) throws {
        guard dimension == expected else {
            throw UnitConversionError.dimensionMismatch(expected: expected, actual: dimension)
        }
    }

    public var isZero: Bool { value == 0 }
    public var isNegative: Bool { value < 0 }

    /// False when the magnitude is a `NaN` `Decimal`.
    ///
    /// `Decimal` saturates to `NaN` on overflow rather than trapping, and a `NaN` `Decimal`
    /// answers `false` to every comparison — so it is neither zero nor negative nor less than
    /// anything, and a corrupted total would sort silently among healthy ones. The arithmetic on
    /// this type refuses to produce one; this property is how a caller checks a value that
    /// arrived from elsewhere.
    public var isFinite: Bool { !value.isNaN }

    public var magnitude: DecimalQuantity {
        DecimalQuantity(value: value < 0 ? -value : value, dimension: dimension)
    }

    public var negated: DecimalQuantity {
        DecimalQuantity(value: -value, dimension: dimension)
    }

    // MARK: - Arithmetic

    /// Adds two quantities of the same dimension.
    /// - Throws: ``DimensionError/incompatibleDimensions(left:right:)`` otherwise. This is the
    ///   guard behind "incompatible dimensions are never added" (spec 11.4).
    ///
    /// The sum is exact or refused (R-172): `Decimal`'s `+` silently dropped the low digits of a
    /// sum needing more than 38, so a formula total could be rounded where the ledger, adding
    /// the same numbers through `NSDecimalAdd`, refused. Both now use
    /// ``NumericPolicy/exactSum(_:_:operation:)``.
    /// - Throws: ``NumericError/decimalOverflow(operation:)`` when the exact result does not
    ///   fit `Decimal`.
    public func adding(_ other: DecimalQuantity) throws -> DecimalQuantity {
        try dimension.requireAdditive(with: other.dimension)
        return DecimalQuantity(
            value: try NumericPolicy.exactSum(value, other.value, operation: "add"),
            dimension: dimension
        )
    }

    /// Subtracts a quantity of the same dimension, exactly or not at all (R-172).
    public func subtracting(_ other: DecimalQuantity) throws -> DecimalQuantity {
        try dimension.requireAdditive(with: other.dimension)
        return DecimalQuantity(
            value: try NumericPolicy.exactDifference(value, other.value, operation: "subtract"),
            dimension: dimension
        )
    }

    public func multiplied(by other: DecimalQuantity) throws -> DecimalQuantity {
        let resultDimension = try dimension.multiplied(by: other.dimension)
        return DecimalQuantity(
            value: try NumericPolicy.requireFinite(value * other.value, operation: "multiply"),
            dimension: resultDimension
        )
    }

    public func divided(by other: DecimalQuantity) throws -> DecimalQuantity {
        guard other.value != 0 else { throw DimensionError.divisionByZero }
        let resultDimension = try dimension.divided(by: other.dimension)
        return DecimalQuantity(
            value: try NumericPolicy.requireFinite(value / other.value, operation: "divide"),
            dimension: resultDimension
        )
    }

    /// Multiplies by a dimensionless scalar without changing the dimension.
    ///
    /// - Throws: ``NumericError/decimalOverflow(operation:)`` when the product overflows
    ///   `Decimal`, rather than returning a `NaN` quantity.
    public func scaled(by factor: Decimal) throws -> DecimalQuantity {
        DecimalQuantity(
            value: try NumericPolicy.requireFinite(value * factor, operation: "scale"),
            dimension: dimension
        )
    }

    /// Sums a homogeneous sequence. Returns the dimensioned zero for an empty input only when a
    /// dimension is supplied, because an empty sum has no dimension of its own.
    ///
    /// - Throws: ``DimensionError/emptySumHasNoDimension`` for an empty list with no dimension
    ///   (BH-493; it used to answer a count zero, which the next `adding(area)` then refused).
    public static func sum(
        _ quantities: [DecimalQuantity],
        dimension: QuantityDimension? = nil
    ) throws -> DecimalQuantity {
        guard let first = quantities.first else {
            guard let dimension else { throw DimensionError.emptySumHasNoDimension }
            return DecimalQuantity(value: 0, dimension: dimension)
        }
        var total = first
        for quantity in quantities.dropFirst() {
            total = try total.adding(quantity)
        }
        if let dimension, total.dimension != dimension {
            throw DimensionError.incompatibleDimensions(left: total.dimension, right: dimension)
        }
        return total
    }

    // MARK: - Throwing operators

    public static func + (lhs: DecimalQuantity, rhs: DecimalQuantity) throws -> DecimalQuantity {
        try lhs.adding(rhs)
    }

    public static func - (lhs: DecimalQuantity, rhs: DecimalQuantity) throws -> DecimalQuantity {
        try lhs.subtracting(rhs)
    }

    public static func * (lhs: DecimalQuantity, rhs: DecimalQuantity) throws -> DecimalQuantity {
        try lhs.multiplied(by: rhs)
    }

    public static func / (lhs: DecimalQuantity, rhs: DecimalQuantity) throws -> DecimalQuantity {
        try lhs.divided(by: rhs)
    }
}

extension DecimalQuantity: Comparable {
    /// Ordering is only defined inside one dimension. Comparing across dimensions orders by the
    /// dimension first so that sorts stay total and deterministic; callers that care must check
    /// the dimension themselves.
    ///
    /// The dimension order is lexicographic over (length power, angle, currency code, ratio
    /// tag), and every component of ``QuantityDimension`` is in it, so two unequal dimensions
    /// always order one way: a count sorts before a ratio (BH-128 — before ADR-0014's tag was
    /// added here, `count(5) < ratio(3)` and `ratio(3) < count(5)` were both false while the
    /// two were not equal, which is not a strict weak ordering).
    public static func < (lhs: DecimalQuantity, rhs: DecimalQuantity) -> Bool {
        if lhs.dimension == rhs.dimension { return lhs.value < rhs.value }
        if lhs.dimension.lengthPower != rhs.dimension.lengthPower {
            return lhs.dimension.lengthPower < rhs.dimension.lengthPower
        }
        if lhs.dimension.angle != rhs.dimension.angle { return !lhs.dimension.angle }
        if lhs.dimension.currencyCode != rhs.dimension.currencyCode {
            return (lhs.dimension.currencyCode ?? "") < (rhs.dimension.currencyCode ?? "")
        }
        return !lhs.dimension.ratio && rhs.dimension.ratio
    }
}

extension DecimalQuantity: CustomStringConvertible {
    /// Diagnostic text only — never a user-facing string. Formatting and rounding happen in the
    /// view and export layers.
    public var description: String { "\(value) \(dimension.baseUnitSymbol)" }
}
