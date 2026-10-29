import Foundation

/// Builds an exact `Decimal` from a significand and a power-of-ten exponent.
///
/// Unit factors must be exact; going through `Double` would introduce binary rounding
/// into every stored conversion, which the numeric policy forbids.
@inline(__always)
internal func exactDecimal(_ significand: UInt64, _ exponent: Int) -> Decimal {
    Decimal(sign: .plus, exponent: exponent, significand: Decimal(significand))
}

/// A length display unit. Storage is always metres.
public enum LengthUnit: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Millimetre.
    case millimetre = "mm"
    /// Centimetre.
    case centimetre = "cm"
    /// Metre, the SI base unit for length.
    case metre = "m"
    /// Kilometre.
    case kilometre = "km"
    /// Inch.
    case inch = "in"
    /// Foot.
    case foot = "ft"
    /// Yard.
    case yard = "yd"
    /// Mile.
    case mile = "mi"

    /// Stable identity, equal to the unit symbol.
    public var id: String { rawValue }

    /// The symbol shown next to a value, for example `"m"`.
    public var symbol: String { rawValue }

    /// Exact number of metres in one unit.
    public var metresPerUnit: Decimal {
        switch self {
        case .millimetre: return exactDecimal(1, -3)
        case .centimetre: return exactDecimal(1, -2)
        case .metre: return 1
        case .kilometre: return 1000
        case .inch: return exactDecimal(254, -4)
        case .foot: return exactDecimal(3048, -4)
        case .yard: return exactDecimal(9144, -4)
        case .mile: return exactDecimal(1609344, -3)
        }
    }

    /// The dimension every length unit measures.
    public var dimension: QuantityDimension { .length }

    /// Whether the unit belongs to the metric family, which drives the imperial
    /// fraction controls in the inspector.
    public var isMetric: Bool {
        switch self {
        case .millimetre, .centimetre, .metre, .kilometre: return true
        case .inch, .foot, .yard, .mile: return false
        }
    }

    /// The matching area unit, used when a tool switches dimension.
    public var areaCounterpart: AreaUnit {
        switch self {
        case .millimetre: return .squareMillimetre
        case .centimetre: return .squareCentimetre
        case .metre: return .squareMetre
        case .kilometre: return .squareKilometre
        case .inch: return .squareInch
        case .foot: return .squareFoot
        case .yard: return .squareYard
        case .mile: return .squareMile
        }
    }

    /// A localized full name for menus and VoiceOver.
    public var displayName: String {
        switch self {
        case .millimetre: return NSLocalizedString("Millimetres", comment: "Length unit name")
        case .centimetre: return NSLocalizedString("Centimetres", comment: "Length unit name")
        case .metre: return NSLocalizedString("Metres", comment: "Length unit name")
        case .kilometre: return NSLocalizedString("Kilometres", comment: "Length unit name")
        case .inch: return NSLocalizedString("Inches", comment: "Length unit name")
        case .foot: return NSLocalizedString("Feet", comment: "Length unit name")
        case .yard: return NSLocalizedString("Yards", comment: "Length unit name")
        case .mile: return NSLocalizedString("Miles", comment: "Length unit name")
        }
    }
}

/// An area display unit. Storage is always square metres.
public enum AreaUnit: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Square millimetre.
    case squareMillimetre = "mm²"
    /// Square centimetre.
    case squareCentimetre = "cm²"
    /// Square metre, the SI base unit for area.
    case squareMetre = "m²"
    /// Hectare.
    case hectare = "ha"
    /// Square kilometre.
    case squareKilometre = "km²"
    /// Square inch.
    case squareInch = "in²"
    /// Square foot.
    case squareFoot = "ft²"
    /// Square yard.
    case squareYard = "yd²"
    /// Acre.
    case acre = "acre"
    /// Square mile.
    case squareMile = "mi²"

    /// Stable identity, equal to the unit symbol.
    public var id: String { rawValue }

    /// The symbol shown next to a value, for example `"m²"`.
    public var symbol: String { rawValue }

    /// Exact number of square metres in one unit.
    public var squareMetresPerUnit: Decimal {
        switch self {
        case .squareMillimetre: return exactDecimal(1, -6)
        case .squareCentimetre: return exactDecimal(1, -4)
        case .squareMetre: return 1
        case .hectare: return 10_000
        case .squareKilometre: return exactDecimal(1, 6)
        case .squareInch: return exactDecimal(64_516, -8)
        case .squareFoot: return exactDecimal(9_290_304, -8)
        case .squareYard: return exactDecimal(83_612_736, -8)
        case .acre: return exactDecimal(40_468_564_224, -7)
        case .squareMile: return exactDecimal(2_589_988_110_336, -6)
        }
    }

    /// The dimension every area unit measures.
    public var dimension: QuantityDimension { .area }

    /// A localized full name for menus and VoiceOver.
    public var displayName: String {
        switch self {
        case .squareMillimetre: return NSLocalizedString("Square Millimetres", comment: "Area unit name")
        case .squareCentimetre: return NSLocalizedString("Square Centimetres", comment: "Area unit name")
        case .squareMetre: return NSLocalizedString("Square Metres", comment: "Area unit name")
        case .hectare: return NSLocalizedString("Hectares", comment: "Area unit name")
        case .squareKilometre: return NSLocalizedString("Square Kilometres", comment: "Area unit name")
        case .squareInch: return NSLocalizedString("Square Inches", comment: "Area unit name")
        case .squareFoot: return NSLocalizedString("Square Feet", comment: "Area unit name")
        case .squareYard: return NSLocalizedString("Square Yards", comment: "Area unit name")
        case .acre: return NSLocalizedString("Acres", comment: "Area unit name")
        case .squareMile: return NSLocalizedString("Square Miles", comment: "Area unit name")
        }
    }
}

/// A volume display unit. Storage is always cubic metres.
public enum VolumeUnit: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Cubic centimetre.
    case cubicCentimetre = "cm³"
    /// Cubic metre, the SI base unit for volume.
    case cubicMetre = "m³"
    /// Cubic inch.
    case cubicInch = "in³"
    /// Cubic foot.
    case cubicFoot = "ft³"
    /// Cubic yard.
    case cubicYard = "yd³"
    /// Litre.
    case litre = "L"

    /// Stable identity, equal to the unit symbol.
    public var id: String { rawValue }

    /// The symbol shown next to a value, for example `"m³"`.
    public var symbol: String { rawValue }

    /// Exact number of cubic metres in one unit.
    public var cubicMetresPerUnit: Decimal {
        switch self {
        case .cubicCentimetre: return exactDecimal(1, -6)
        case .cubicMetre: return 1
        case .cubicInch: return exactDecimal(16_387_064, -12)
        case .cubicFoot: return exactDecimal(28_316_846_592, -12)
        case .cubicYard: return exactDecimal(764_554_857_984, -12)
        case .litre: return exactDecimal(1, -3)
        }
    }

    /// The dimension every volume unit measures.
    public var dimension: QuantityDimension { .volume }

    /// A localized full name for menus and VoiceOver.
    public var displayName: String {
        switch self {
        case .cubicCentimetre: return NSLocalizedString("Cubic Centimetres", comment: "Volume unit name")
        case .cubicMetre: return NSLocalizedString("Cubic Metres", comment: "Volume unit name")
        case .cubicInch: return NSLocalizedString("Cubic Inches", comment: "Volume unit name")
        case .cubicFoot: return NSLocalizedString("Cubic Feet", comment: "Volume unit name")
        case .cubicYard: return NSLocalizedString("Cubic Yards", comment: "Volume unit name")
        case .litre: return NSLocalizedString("Litres", comment: "Volume unit name")
        }
    }
}

/// How a slope is presented. The stored slope is always the dimensionless ratio
/// `rise / run`; this only changes the rendering.
public enum SlopeDisplayMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// `1:n`, the run normalised to one.
    case ratioOneToN
    /// `n:1`, the rise normalised to one.
    case ratioNToOne
    /// The raw decimal ratio, for example `0.25`.
    case decimal
    /// The ratio as a percentage, for example `25%`.
    case percent
    /// The slope angle in degrees.
    case degrees
    /// An explicit `rise/run` pair in the active length unit.
    case riseOverRun

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the slope display picker.
    public var displayName: String {
        switch self {
        case .ratioOneToN: return NSLocalizedString("Ratio 1:n", comment: "Slope display mode")
        case .ratioNToOne: return NSLocalizedString("Ratio n:1", comment: "Slope display mode")
        case .decimal: return NSLocalizedString("Decimal", comment: "Slope display mode")
        case .percent: return NSLocalizedString("Percent", comment: "Slope display mode")
        case .degrees: return NSLocalizedString("Degrees", comment: "Slope display mode")
        case .riseOverRun: return NSLocalizedString("Rise over Run", comment: "Slope display mode")
        }
    }
}

/// Fraction precision for imperial length display.
///
/// Display rounding never changes the stored SI value.
public enum ImperialPrecision: Int, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Round to whole units.
    case whole = 1
    /// Round to 1/2.
    case half = 2
    /// Round to 1/4.
    case quarter = 4
    /// Round to 1/8.
    case eighth = 8
    /// Round to 1/16.
    case sixteenth = 16
    /// Round to 1/32.
    case thirtySecond = 32
    /// Round to 1/64.
    case sixtyFourth = 64

    /// Stable identity.
    public var id: Int { rawValue }

    /// The fraction denominator, `1` for whole units.
    public var denominator: Int { rawValue }

    /// A localized label such as `"1/16"`.
    public var displayName: String {
        guard rawValue > 1 else {
            return NSLocalizedString("Whole", comment: "Imperial fraction precision: no fraction")
        }
        let format = NSLocalizedString(
            "1/%d",
            comment: "Imperial fraction precision, for example one sixteenth"
        )
        return String(format: format, rawValue)
    }
}

/// How an angle is presented. Storage is always radians.
public enum AngleDisplayUnit: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Degrees.
    case degrees = "°"
    /// Radians.
    case radians = "rad"
    /// Gradians.
    case gradians = "gon"

    /// Stable identity, equal to the unit symbol.
    public var id: String { rawValue }

    /// The symbol shown next to a value.
    public var symbol: String { rawValue }

    /// A localized full name for menus and VoiceOver.
    public var displayName: String {
        switch self {
        case .degrees: return NSLocalizedString("Degrees", comment: "Angle unit name")
        case .radians: return NSLocalizedString("Radians", comment: "Angle unit name")
        case .gradians: return NSLocalizedString("Gradians", comment: "Angle unit name")
        }
    }

    /// How many of this unit make up one radian.
    ///
    /// Written out to sixteen significant digits so `Decimal` aggregates keep the same value the
    /// `Double` view formatter shows; `Decimal` has no `pi`, and going through `Double` here would
    /// put a binary rounding step inside an exact-decimal total.
    public var unitsPerRadian: Decimal {
        switch self {
        case .degrees: return Decimal(string: "57.29577951308232") ?? 57
        case .radians: return 1
        case .gradians: return Decimal(string: "63.66197723675813") ?? 64
        }
    }

    /// Converts a stored angle in radians into this unit.
    public func fromRadians(_ radians: Decimal) -> Decimal {
        self == .radians ? radians : radians * unitsPerRadian
    }

    /// Converts a stored angle in radians into this unit.
    public func fromRadians(_ radians: Double) -> Double {
        switch self {
        case .degrees: return radians * 180 / .pi
        case .radians: return radians
        case .gradians: return radians * 200 / .pi
        }
    }
}
