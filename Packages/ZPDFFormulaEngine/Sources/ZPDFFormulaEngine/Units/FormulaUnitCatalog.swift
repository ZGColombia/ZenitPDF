import Foundation
import ZPDFContracts

extension AnyDisplayUnit {
    /// The SI base unit of this unit's family — the unit a ``DecimalQuantity`` of that
    /// dimension holds its magnitude in.
    ///
    /// `count` and a currency are their own base. `CONVERT` uses this to refuse a measured
    /// operand whose stated source unit is anything else (R-136).
    var formulaBaseUnit: AnyDisplayUnit {
        switch self {
        case .count: .count
        case .length: .length(.metre)
        case .area: .area(.squareMetre)
        case .volume: .volume(.cubicMetre)
        case .angle: .angle(.radian)
        case .currency: self
        }
    }

    /// Converts a magnitude from this unit into `other`, staying inside the family.
    ///
    /// Delegates to the unit family's own `convert`, rather than doing
    /// `value * fromFactor / toFactor` here, so that a family which can convert exactly does.
    /// ``AngleUnit`` is the one that can: degree, gradian and turn are defined against a full
    /// turn by exact integers, and multiplying by `pi/180` then dividing by `2*pi` does not
    /// cancel — `CONVERT(360, deg, turn)` came back as
    /// `0.99999999999999999999999999999999999998` under the factor form.
    ///
    /// - Returns: `nil` when the two units are not in the same family, which the compiler has
    ///   already rejected by the time this runs.
    func formulaConvert(_ value: Decimal, to other: AnyDisplayUnit) -> Decimal? {
        switch (self, other) {
        case (.count, .count): value
        case (.length(let from), .length(let to)): from.convert(value, to: to)
        case (.area(let from), .area(let to)): from.convert(value, to: to)
        case (.volume(let from), .volume(let to)): from.convert(value, to: to)
        case (.angle(let from), .angle(let to)): from.convert(value, to: to)
        case (.currency(let from), .currency(let to)) where from == to: value
        default: nil
        }
    }

    /// The token a formula writes to name this unit, for example `ft2`.
    public var formulaToken: String {
        switch self {
        case .count: "1"
        case .length(let unit): unit.rawValue
        case .area(let unit): unit.rawValue
        case .volume(let unit): unit.rawValue
        case .angle(let unit): unit.rawValue
        case .currency(let code): code
        }
    }
}

/// Resolves the unit names `CONVERT` accepts.
///
/// The name set is exactly the raw values of the contract's unit enums — `mm cm m km in ft yd mi`,
/// `mm2 cm2 m2 ha km2 in2 ft2 yd2 acre mi2`, `cm3 m3 in3 ft3 yd3 l`, `rad deg gon turn` — plus the
/// dimensionless `1`. They are unique across families, so one flat table is enough, and matching
/// is case-insensitive so `FT2` works. Three-letter uppercase ISO 4217 codes resolve to currency.
public enum FormulaUnitCatalog: Sendable {

    /// Resolves a unit name, or nil when the grammar does not know it.
    public static func unit(named text: String) -> AnyDisplayUnit? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let unit = table[trimmed.lowercased()] { return unit }
        if QuantityDimension.isValidCurrencyCode(trimmed) { return .currency(trimmed) }
        return nil
    }

    private static let table: [String: AnyDisplayUnit] = {
        var table: [String: AnyDisplayUnit] = ["1": .count, "count": .count]
        for unit in LengthUnit.allCases { table[unit.rawValue.lowercased()] = .length(unit) }
        for unit in AreaUnit.allCases { table[unit.rawValue.lowercased()] = .area(unit) }
        for unit in VolumeUnit.allCases { table[unit.rawValue.lowercased()] = .volume(unit) }
        for unit in AngleUnit.allCases { table[unit.rawValue.lowercased()] = .angle(unit) }
        return table
    }()
}
