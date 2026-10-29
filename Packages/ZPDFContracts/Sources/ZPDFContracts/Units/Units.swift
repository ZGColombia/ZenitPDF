import Foundation

/// A display unit with an exact or documented conversion factor to its SI base unit.
public protocol DisplayUnit: RawRepresentable, CaseIterable, Codable, Hashable, Sendable
where RawValue == String {
    /// Factor from this unit to the SI base unit of its family.
    static var conversionFactors: [Self: Decimal] { get }
    /// The dimension every member of this family carries.
    static var dimension: QuantityDimension { get }
    /// Human-facing symbol, for example `m²`.
    var symbol: String { get }
    /// True when the factor is an exact decimal by international definition. Angle units are the
    /// only family where this is false, because pi is irrational.
    var isExactByDefinition: Bool { get }
    /// Converts between two units of the same family.
    ///
    /// A protocol requirement rather than only an extension member, so a family that can do
    /// better than "out to the base unit and back" — ``AngleUnit`` can, for every pair that does
    /// not involve the radian — is dispatched to even through a generic `Unit: DisplayUnit`.
    func convert(_ value: Decimal, to other: Self) -> Decimal
}

extension DisplayUnit {
    /// Factor from this unit to the SI base unit.
    ///
    /// The table is a dictionary, so a case without an entry compiles; the fallback of `1`
    /// would then store a value in the new unit as if it were already the base unit (BH-500).
    /// ``casesWithoutConversionFactor`` names such cases, and `UnitConversionTests` requires
    /// it to be empty for every family, so the omission fails a test instead of a takeoff.
    public var factorToBase: Decimal { Self.conversionFactors[self] ?? 1 }

    /// Every case of this family that ``conversionFactors`` does not cover. Empty for a
    /// complete table, which is the only acceptable state.
    public static var casesWithoutConversionFactor: [Self] {
        allCases.filter { conversionFactors[$0] == nil }
    }

    /// Converts a value expressed in this unit into the SI base unit.
    public func toBase(_ value: Decimal) -> Decimal { value * factorToBase }

    /// Converts a value expressed in the SI base unit into this unit.
    public func fromBase(_ value: Decimal) -> Decimal { value / factorToBase }

    /// Converts between two units of the same family, via the SI base unit.
    ///
    /// Exact for every family whose factors are exact decimals. ``AngleUnit`` overrides it,
    /// because routing degree/gradian/turn through the radian would drag pi into a conversion
    /// that is defined by exact integers.
    public func convert(_ value: Decimal, to other: Self) -> Decimal {
        if self == other { return value }
        return other.fromBase(toBase(value))
    }
}

// MARK: - Length

/// Display units for length (spec 11.3). SI base unit: metre.
///
/// The imperial factors are the exact international definitions: 1 in = 0.0254 m, 1 ft = 0.3048 m,
/// 1 yd = 0.9144 m, 1 mi = 1609.344 m. They are built from integer significands and powers of ten
/// so that no factor is ever born from a binary floating-point literal.
public enum LengthUnit: String, DisplayUnit {
    case millimetre = "mm"
    case centimetre = "cm"
    case metre = "m"
    case kilometre = "km"
    case inch = "in"
    case foot = "ft"
    case yard = "yd"
    case mile = "mi"

    public static let dimension = QuantityDimension.length

    public static let conversionFactors: [LengthUnit: Decimal] = [
        .millimetre: NumericPolicy.exact(1, -3),
        .centimetre: NumericPolicy.exact(1, -2),
        .metre: NumericPolicy.exact(1, 0),
        .kilometre: NumericPolicy.exact(1, 3),
        .inch: NumericPolicy.exact(254, -4),
        .foot: NumericPolicy.exact(3048, -4),
        .yard: NumericPolicy.exact(9144, -4),
        .mile: NumericPolicy.exact(1_609_344, -3)
    ]

    public var symbol: String { rawValue }
    public var isExactByDefinition: Bool { true }

    /// True for the four imperial/US customary members.
    public var isImperial: Bool {
        switch self {
        case .inch, .foot, .yard, .mile: true
        case .millimetre, .centimetre, .metre, .kilometre: false
        }
    }

    /// The area unit produced by squaring this length unit, where one exists.
    public var squared: AreaUnit? {
        switch self {
        case .millimetre: .squareMillimetre
        case .centimetre: .squareCentimetre
        case .metre: .squareMetre
        case .kilometre: .squareKilometre
        case .inch: .squareInch
        case .foot: .squareFoot
        case .yard: .squareYard
        case .mile: .squareMile
        }
    }

    /// The volume unit produced by cubing this length unit, where one exists.
    public var cubed: VolumeUnit? {
        switch self {
        case .centimetre: .cubicCentimetre
        case .metre: .cubicMetre
        case .inch: .cubicInch
        case .foot: .cubicFoot
        case .yard: .cubicYard
        case .millimetre, .kilometre, .mile: nil
        }
    }
}

// MARK: - Area

/// Display units for area (spec 11.3). SI base unit: square metre.
public enum AreaUnit: String, DisplayUnit {
    case squareMillimetre = "mm2"
    case squareCentimetre = "cm2"
    case squareMetre = "m2"
    case hectare = "ha"
    case squareKilometre = "km2"
    case squareInch = "in2"
    case squareFoot = "ft2"
    case squareYard = "yd2"
    case acre = "acre"
    case squareMile = "mi2"

    public static let dimension = QuantityDimension.area

    public static let conversionFactors: [AreaUnit: Decimal] = [
        .squareMillimetre: NumericPolicy.exact(1, -6),
        .squareCentimetre: NumericPolicy.exact(1, -4),
        .squareMetre: NumericPolicy.exact(1, 0),
        .hectare: NumericPolicy.exact(1, 4),
        .squareKilometre: NumericPolicy.exact(1, 6),
        .squareInch: NumericPolicy.exact(64_516, -8),
        .squareFoot: NumericPolicy.exact(9_290_304, -8),
        .squareYard: NumericPolicy.exact(83_612_736, -8),
        .acre: NumericPolicy.exact(40_468_564_224, -7),
        .squareMile: NumericPolicy.exact(2_589_988_110_336, -6)
    ]

    public var symbol: String {
        switch self {
        case .squareMillimetre: "mm²"
        case .squareCentimetre: "cm²"
        case .squareMetre: "m²"
        case .hectare: "ha"
        case .squareKilometre: "km²"
        case .squareInch: "in²"
        case .squareFoot: "ft²"
        case .squareYard: "yd²"
        case .acre: "acre"
        case .squareMile: "mi²"
        }
    }

    public var isExactByDefinition: Bool { true }
}

// MARK: - Volume

/// Display units for volume (spec 11.3). SI base unit: cubic metre.
public enum VolumeUnit: String, DisplayUnit {
    case cubicCentimetre = "cm3"
    case cubicMetre = "m3"
    case cubicInch = "in3"
    case cubicFoot = "ft3"
    case cubicYard = "yd3"
    case litre = "l"

    public static let dimension = QuantityDimension.volume

    public static let conversionFactors: [VolumeUnit: Decimal] = [
        .cubicCentimetre: NumericPolicy.exact(1, -6),
        .cubicMetre: NumericPolicy.exact(1, 0),
        .cubicInch: NumericPolicy.exact(16_387_064, -12),
        .cubicFoot: NumericPolicy.exact(28_316_846_592, -12),
        .cubicYard: NumericPolicy.exact(764_554_857_984, -12),
        .litre: NumericPolicy.exact(1, -3)
    ]

    public var symbol: String {
        switch self {
        case .cubicCentimetre: "cm³"
        case .cubicMetre: "m³"
        case .cubicInch: "in³"
        case .cubicFoot: "ft³"
        case .cubicYard: "yd³"
        case .litre: "L"
        }
    }

    public var isExactByDefinition: Bool { true }
}

// MARK: - Angle

/// Display units for angle. SI base unit: radian.
///
/// Unlike the length family, these factors are **not** exact decimals: pi is irrational. The
/// stored `Decimal` factors use a 37-digit truncation of pi, which is well beyond the precision
/// any drawing can carry, but the contract records them as approximate so nothing downstream
/// asserts exactness against them.
public enum AngleUnit: String, DisplayUnit {
    case radian = "rad"
    case degree = "deg"
    case gradian = "gon"
    case turn = "turn"

    public static let dimension = QuantityDimension.angle

    /// pi truncated to 37 decimal places, assembled from two exact 19-digit chunks so the
    /// constant never passes through a `Double` or a failable string parse.
    public static let pi: Decimal =
        NumericPolicy.exact(3_141_592_653_589_793_238, -18)
        + NumericPolicy.exact(4_626_433_832_795_028_842, -37)

    public static let conversionFactors: [AngleUnit: Decimal] = [
        .radian: NumericPolicy.exact(1, 0),
        .degree: AngleUnit.pi / 180,
        .gradian: AngleUnit.pi / 200,
        .turn: AngleUnit.pi * 2
    ]

    public var symbol: String {
        switch self {
        case .radian: "rad"
        case .degree: "°"
        case .gradian: "gon"
        case .turn: "turn"
        }
    }

    /// Only the radian is exact; the rest depend on pi.
    public var isExactByDefinition: Bool { self == .radian }

    /// How many of this unit make one full turn, for the three units whose relationship to a
    /// turn is an exact integer. The radian is absent on purpose: 2pi is not one.
    private static let unitsPerTurn: [AngleUnit: Decimal] = [
        .degree: 360,
        .gradian: 400,
        .turn: 1
    ]

    /// Converts between two angle units, exactly whenever the definition is exact.
    ///
    /// Degree, gradian and turn are defined against a full turn by exact integers — 360, 400 and
    /// 1 — so converting among them is a ratio of two integers and must come back exact. The
    /// inherited base-unit route does not: it multiplies by `pi/360` and divides by `2*pi`, and
    /// the 38-digit truncation of pi does not cancel, so `360 deg -> turn` returned
    /// `0.99999999999999999999999999999999999998` instead of `1`. Only a conversion that really
    /// involves the radian goes through pi.
    public func convert(_ value: Decimal, to other: AngleUnit) -> Decimal {
        if self == other { return value }
        if let mine = Self.unitsPerTurn[self], let theirs = Self.unitsPerTurn[other] {
            return value * theirs / mine
        }
        return other.fromBase(toBase(value))
    }

    /// The `Double` factor, which is what geometry code should use.
    public var radiansPerUnit: Double {
        switch self {
        case .radian: 1.0
        case .degree: Double.pi / 180.0
        case .gradian: Double.pi / 200.0
        case .turn: 2.0 * Double.pi
        }
    }
}

/// The unit family a value belongs to, used where a single field must name any unit.
public enum UnitFamily: String, Codable, Hashable, Sendable, CaseIterable {
    case count
    case length
    case area
    case volume
    case angle
    case currency
}

/// A unit selection that spans families, for display policy on a tool, column or markup.
public enum AnyDisplayUnit: Codable, Hashable, Sendable {
    case count
    case length(LengthUnit)
    case area(AreaUnit)
    case volume(VolumeUnit)
    case angle(AngleUnit)
    case currency(String)

    public var family: UnitFamily {
        switch self {
        case .count: .count
        case .length: .length
        case .area: .area
        case .volume: .volume
        case .angle: .angle
        case .currency: .currency
        }
    }

    public var symbol: String {
        switch self {
        case .count: ""
        case .length(let unit): unit.symbol
        case .area(let unit): unit.symbol
        case .volume(let unit): unit.symbol
        case .angle(let unit): unit.symbol
        case .currency(let code): code
        }
    }

    public var dimension: QuantityDimension {
        switch self {
        case .count: .count
        case .length: .length
        case .area: .area
        case .volume: .volume
        case .angle: .angle
        case .currency(let code): .currency(code)
        }
    }
}
