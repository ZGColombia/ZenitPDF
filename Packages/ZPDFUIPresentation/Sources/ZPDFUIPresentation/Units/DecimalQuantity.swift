import Foundation

/// A dimension-tagged decimal value, always stored in SI base units.
///
/// Geometry is computed in `Double` inside the core engines; everything that is
/// aggregated, priced or exported crosses into `Decimal` here. Nothing in this type
/// rounds for display — rounding belongs to the view and the export layer.
public struct DecimalQuantity: Codable, Hashable, Sendable {

    /// The magnitude in the SI base unit implied by ``dimension``.
    public var value: Decimal
    /// The dimension of ``value``.
    public var dimension: QuantityDimension

    /// Creates a quantity.
    public init(value: Decimal, dimension: QuantityDimension) {
        self.value = value
        self.dimension = dimension
    }

    /// A zero quantity in the given dimension.
    public static func zero(_ dimension: QuantityDimension) -> DecimalQuantity {
        DecimalQuantity(value: 0, dimension: dimension)
    }

    /// A count.
    public static func count(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .count)
    }

    /// A length in metres.
    public static func metres(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .length)
    }

    /// An area in square metres.
    public static func squareMetres(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .area)
    }

    /// A volume in cubic metres.
    public static func cubicMetres(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .volume)
    }

    /// An angle in radians.
    public static func radians(_ value: Decimal) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .angle)
    }

    /// A monetary amount in the given ISO 4217 currency.
    public static func money(_ value: Decimal, code: String) -> DecimalQuantity {
        DecimalQuantity(value: value, dimension: .currency(code))
    }

    /// Adds a compatible quantity.
    ///
    /// - Throws: ``QuantityError/incompatibleDimensions(_:_:)`` when the dimensions differ.
    public func adding(_ other: DecimalQuantity) throws -> DecimalQuantity {
        guard dimension.isCompatible(with: other.dimension) else {
            throw QuantityError.incompatibleDimensions(dimension, other.dimension)
        }
        return DecimalQuantity(value: value + other.value, dimension: dimension)
    }

    /// Subtracts a compatible quantity, used for cutout net areas.
    ///
    /// - Throws: ``QuantityError/incompatibleDimensions(_:_:)`` when the dimensions differ.
    public func subtracting(_ other: DecimalQuantity) throws -> DecimalQuantity {
        guard dimension.isCompatible(with: other.dimension) else {
            throw QuantityError.incompatibleDimensions(dimension, other.dimension)
        }
        return DecimalQuantity(value: value - other.value, dimension: dimension)
    }

    /// Sums a sequence of quantities that must all share one dimension.
    ///
    /// - Parameters:
    ///   - quantities: The values to add.
    ///   - dimension: The dimension the running total starts in, so that an empty
    ///     sequence still returns a correctly typed zero.
    /// - Throws: ``QuantityError/incompatibleDimensions(_:_:)`` on the first mismatch.
    public static func sum<S: Sequence>(
        _ quantities: S,
        in dimension: QuantityDimension
    ) throws -> DecimalQuantity where S.Element == DecimalQuantity {
        var total = DecimalQuantity.zero(dimension)
        for quantity in quantities {
            total = try total.adding(quantity)
        }
        return total
    }

    /// The value converted into a length display unit.
    ///
    /// - Throws: ``QuantityError/unitDimensionMismatch(expected:actual:)`` when this is not a length.
    public func converted(to unit: LengthUnit) throws -> Decimal {
        guard dimension == .length else {
            throw QuantityError.unitDimensionMismatch(expected: .length, actual: dimension)
        }
        return value / unit.metresPerUnit
    }

    /// The value converted into an area display unit.
    ///
    /// - Throws: ``QuantityError/unitDimensionMismatch(expected:actual:)`` when this is not an area.
    public func converted(to unit: AreaUnit) throws -> Decimal {
        guard dimension == .area else {
            throw QuantityError.unitDimensionMismatch(expected: .area, actual: dimension)
        }
        return value / unit.squareMetresPerUnit
    }

    /// The value converted into a volume display unit.
    ///
    /// - Throws: ``QuantityError/unitDimensionMismatch(expected:actual:)`` when this is not a volume.
    public func converted(to unit: VolumeUnit) throws -> Decimal {
        guard dimension == .volume else {
            throw QuantityError.unitDimensionMismatch(expected: .volume, actual: dimension)
        }
        return value / unit.cubicMetresPerUnit
    }
}

extension DecimalQuantity: Comparable {

    /// Orders two quantities. Quantities of different dimensions are ordered by
    /// dimension first so that sorting a mixed ledger column stays deterministic.
    public static func < (lhs: DecimalQuantity, rhs: DecimalQuantity) -> Bool {
        if lhs.dimension == rhs.dimension { return lhs.value < rhs.value }
        if lhs.dimension.lengthPower != rhs.dimension.lengthPower {
            return lhs.dimension.lengthPower < rhs.dimension.lengthPower
        }
        if lhs.dimension.angle != rhs.dimension.angle { return !lhs.dimension.angle }
        // BH-798: a count and a ratio share lengthPower 0 and differ only in the ratio tag.
        // Without this line neither was less than the other whatever their values, which broke
        // strict weak ordering (5 count < 3 ratio false, 3 ratio < 5 count false, yet 5 != 3).
        if lhs.dimension.ratio != rhs.dimension.ratio { return !lhs.dimension.ratio }
        return (lhs.dimension.currencyCode ?? "") < (rhs.dimension.currencyCode ?? "")
    }
}
