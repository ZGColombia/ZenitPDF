import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

// The two packages each define a `DecimalQuantity`, a `QuantityDimension` and a set of
// display units, and they are deliberately not the same types: `ZPDFContracts` owns the
// frozen domain vocabulary and `ZPDFUIPresentation` owns what a view renders. Every
// crossing between them happens in this file, so there is exactly one place where a
// square metre can turn into a metre by mistake.

/// Contract-side spellings, disambiguated from the presentation types of the same name.
public enum Domain {
    public typealias Quantity = ZPDFContracts.DecimalQuantity
    public typealias Dimension = ZPDFContracts.QuantityDimension
    public typealias Length = ZPDFContracts.LengthUnit
    public typealias Area = ZPDFContracts.AreaUnit
    public typealias Volume = ZPDFContracts.VolumeUnit
    public typealias Angle = ZPDFContracts.AngleUnit
    public typealias Field = ZPDFContracts.MeasurementField
    public typealias Tool = ZPDFContracts.MeasurementTool
    public typealias Kind = ZPDFContracts.MarkupKind
    public typealias Status = ZPDFContracts.MarkupStatus
    public typealias CellValue = ZPDFContracts.LedgerCellValue
}

/// Presentation-side spellings.
public enum Shown {
    public typealias Quantity = ZPDFUIPresentation.DecimalQuantity
    public typealias Dimension = ZPDFUIPresentation.QuantityDimension
    public typealias Length = ZPDFUIPresentation.LengthUnit
    public typealias Area = ZPDFUIPresentation.AreaUnit
    public typealias Volume = ZPDFUIPresentation.VolumeUnit
    public typealias Field = ZPDFUIPresentation.MeasurementField
    public typealias Kind = ZPDFUIPresentation.MeasurementKind
    public typealias Markup = ZPDFUIPresentation.MarkupKind
    public typealias Status = ZPDFUIPresentation.MarkupStatus
    public typealias CellValue = ZPDFUIPresentation.LedgerCellValue
}

// MARK: - Dimensions

extension Shown.Dimension {

    /// The presentation dimension for a contract dimension.
    ///
    /// Both are `(lengthPower, angle, currencyCode, ratio)`, so the crossing is a field copy and
    /// cannot lose information. The ADR-0014 `ratio` tag used to be left behind, so a waste
    /// factor or a slope ratio crossed as a count: the Column Manager reopened a "Ratio /
    /// factor" column as "Count (pcs)", the standard plan summed its factors into totals and
    /// Explain added slope ratios to counts (S-089).
    public init(domain: Domain.Dimension) {
        self.init(
            lengthPower: domain.lengthPower,
            angle: domain.angle,
            currencyCode: domain.currencyCode,
            ratio: domain.ratio
        )
    }
}

extension Domain.Dimension {
    /// The contract dimension for a presentation dimension; the exact inverse of
    /// ``Shown/Dimension/init(domain:)``, `ratio` included (S-089).
    public init(shown: Shown.Dimension) {
        self.init(
            lengthPower: shown.lengthPower,
            angle: shown.angle,
            currencyCode: shown.currencyCode,
            ratio: shown.ratio
        )
    }
}

// MARK: - Quantities

extension Shown.Quantity {

    /// A contract quantity, still in SI base units. Nothing is rounded here: rounding is a
    /// display decision and belongs in ``QuantityFormatter``.
    public init(domain: Domain.Quantity) {
        self.init(value: domain.value, dimension: Shown.Dimension(domain: domain.dimension))
    }
}

extension Domain.Quantity {
    public init(shown: Shown.Quantity) {
        self.init(value: shown.value, dimension: Domain.Dimension(shown: shown.dimension))
    }
}

// MARK: - Units

extension Domain.Length {
    /// The contract length unit matching a presentation one. Total: the two enumerations
    /// carry the same eight cases.
    public init(shown: Shown.Length) {
        switch shown {
        case .millimetre: self = .millimetre
        case .centimetre: self = .centimetre
        case .metre: self = .metre
        case .kilometre: self = .kilometre
        case .inch: self = .inch
        case .foot: self = .foot
        case .yard: self = .yard
        case .mile: self = .mile
        }
    }
}

extension Domain.Area {
    public init(shown: Shown.Area) {
        switch shown {
        case .squareMillimetre: self = .squareMillimetre
        case .squareCentimetre: self = .squareCentimetre
        case .squareMetre: self = .squareMetre
        case .hectare: self = .hectare
        case .squareKilometre: self = .squareKilometre
        case .squareInch: self = .squareInch
        case .squareFoot: self = .squareFoot
        case .squareYard: self = .squareYard
        case .acre: self = .acre
        case .squareMile: self = .squareMile
        }
    }
}

extension Domain.Volume {
    public init(shown: Shown.Volume) {
        switch shown {
        case .cubicCentimetre: self = .cubicCentimetre
        case .cubicMetre: self = .cubicMetre
        case .cubicInch: self = .cubicInch
        case .cubicFoot: self = .cubicFoot
        case .cubicYard: self = .cubicYard
        case .litre: self = .litre
        }
    }
}

/// The output units and precision a takeoff is presented in.
///
/// One value rather than five loose properties, so the measurement palette, the ledger and
/// the status bar cannot disagree about what "m²" means on the same screen.
/// How a length in feet or inches is written (NL-MEASURE-10).
public enum ImperialLengthStyle: String, Hashable, Sendable, CaseIterable, Codable {
    /// `12'-6 1/2"` — feet, inches and a fraction at ``DisplayUnitSelection/imperialPrecision``.
    case feetInches
    /// `12.50 ft` — decimal feet at ``DisplayUnitSelection/metricDecimalPlaces``; never marks.
    case decimalFeet
    /// `150.00 in` — decimal inches at ``DisplayUnitSelection/metricDecimalPlaces``.
    case decimalInches
}

public struct DisplayUnitSelection: Hashable, Sendable {

    /// Output unit for length-dimensioned fields.
    public var length: ZPDFUIPresentation.LengthUnit
    /// Output unit for area-dimensioned fields.
    public var area: ZPDFUIPresentation.AreaUnit
    /// Output unit for volume-dimensioned fields.
    public var volume: ZPDFUIPresentation.VolumeUnit
    /// How a slope is written.
    public var slope: SlopeDisplayMode
    /// Fraction denominator used when ``length`` is imperial.
    public var imperialPrecision: ImperialPrecision
    /// Decimal places used when ``length`` is metric, and for decimal feet or inches.
    public var metricDecimalPlaces: Int
    /// How a foot or inch length is written (NL-MEASURE-10). Only consulted when ``length`` is
    /// the foot or the inch; `.decimalFeet` and `.decimalInches` also set that unit.
    public var imperialLengthStyle: ImperialLengthStyle = .feetInches

    /// Whether lengths render as feet, inches and a fraction rather than as a decimal.
    public var usesFeetInchesMarks: Bool {
        (length == .foot || length == .inch) && imperialLengthStyle == .feetInches
    }

    /// This selection with lengths written in `style`: decimal feet moves the length unit to the
    /// foot, decimal inches to the inch; area and volume stay as they are.
    public func withImperialLengthStyle(_ style: ImperialLengthStyle) -> DisplayUnitSelection {
        var next = self
        next.imperialLengthStyle = style
        switch style {
        case .decimalFeet: next.length = .foot
        case .decimalInches: next.length = .inch
        case .feetInches: if next.length.isMetric { next.length = .foot }
        }
        return next
    }

    /// Creates a selection.
    public init(
        length: ZPDFUIPresentation.LengthUnit = .metre,
        area: ZPDFUIPresentation.AreaUnit = .squareMetre,
        volume: ZPDFUIPresentation.VolumeUnit = .cubicMetre,
        slope: SlopeDisplayMode = .percent,
        imperialPrecision: ImperialPrecision = .sixteenth,
        metricDecimalPlaces: Int = 2
    ) {
        self.length = length
        self.area = area
        self.volume = volume
        self.slope = slope
        self.imperialPrecision = imperialPrecision
        self.metricDecimalPlaces = max(0, min(9, metricDecimalPlaces))
    }

    /// Metres, square metres, cubic metres, slope in percent.
    public static let metric = DisplayUnitSelection()

    /// Feet, square feet, cubic yards, slope as `n:1`, sixteenths.
    public static let imperial = DisplayUnitSelection(
        length: .foot,
        area: .squareFoot,
        volume: .cubicYard,
        slope: .ratioNToOne,
        imperialPrecision: .sixteenth
    )

    /// The contract-side policy the measurement engine and the ledger column set take.
    public var domainPolicy: DisplayUnitPolicy {
        DisplayUnitPolicy(
            length: Domain.Length(shown: length),
            area: Domain.Area(shown: area),
            volume: Domain.Volume(shown: volume),
            angle: .degree,
            slopeForm: slopeForm,
            precision: precision
        )
    }

    /// The contract precision mode: fractions for an imperial length, decimals otherwise.
    public var precision: PrecisionMode {
        guard usesFeetInchesMarks,
              let denominator = ImperialFractionDenominator(rawValue: imperialPrecision.denominator)
        else {
            return .decimalPlaces(metricDecimalPlaces)
        }
        return .imperialFraction(denominator)
    }

    private var slopeForm: SlopeForm {
        switch slope {
        case .percent: .percent
        case .degrees: .degrees
        case .ratioOneToN: .ratioOneToN
        case .ratioNToOne: .ratioNToOne
        case .decimal: .decimalRatio
        case .riseOverRun: .riseOverRun
        }
    }

    /// The unit symbol a field of this dimension is displayed in.
    public func symbol(for dimension: Shown.Dimension) -> String {
        if let code = dimension.currencyCode { return code }
        if dimension.angle { return "°" }
        switch dimension.lengthPower {
        case 1: return length.symbol
        case 2: return area.symbol
        case 3: return volume.symbol
        default: return ""
        }
    }
}

// MARK: - Formatting

/// Turns an SI-base quantity into the text a cell, a field or the status bar shows.
///
/// `Sendable` and free of stored formatter objects, so the same formatter can be used from
/// the session actor (to fill a `LedgerRow`'s `displayValues`) and from the main actor
/// (to fill a live measurement field) and produce byte-identical text. That identity is
/// what makes QUALITY_BAR A25 — "the same number on screen and in the CSV" — structural.
public struct QuantityFormatter: Sendable {

    /// The units and precision in force.
    public let units: DisplayUnitSelection
    /// The locale decimal separators come from.
    public let localeIdentifier: String
    /// The ledger package's number locale for ``localeIdentifier``, resolved once.
    ///
    /// The screen renders through the same type every exporter does — `LedgerNumberLocale`,
    /// after `LedgerDisplayRounding` — so the ledger cell, the app CSV and the workbook share
    /// one formatter, and no cell allocates a `NumberFormatter` (IM-012, IM-096).
    private let numberLocale: LedgerNumberLocale

    /// Creates a formatter.
    public init(units: DisplayUnitSelection = .metric, localeIdentifier: String = "en_US_POSIX") {
        self.units = units
        self.localeIdentifier = localeIdentifier
        self.numberLocale = LedgerNumberLocale.forLocale(Locale(identifier: localeIdentifier))
    }

    /// The value converted out of SI base units into the selected display unit.
    ///
    /// Exact: every conversion factor in `ZPDFContracts.Units` is a `Decimal` and the
    /// division is a `Decimal` division, so a foot is 0.3048 m and not 0.30480000000000002.
    public func converted(_ quantity: Shown.Quantity) -> Decimal {
        let dimension = quantity.dimension
        if dimension.currencyCode != nil { return quantity.value }
        if dimension.angle {
            return Domain.Angle.radian.convert(quantity.value, to: .degree)
        }
        switch dimension.lengthPower {
        case 1: return Domain.Length(shown: units.length).fromBase(quantity.value)
        case 2: return Domain.Area(shown: units.area).fromBase(quantity.value)
        case 3: return Domain.Volume(shown: units.volume).fromBase(quantity.value)
        default: return quantity.value
        }
    }

    /// The unit symbol for a quantity.
    public func symbol(_ quantity: Shown.Quantity) -> String { units.symbol(for: quantity.dimension) }

    /// The formatted number, without a unit.
    public func text(_ quantity: Shown.Quantity) -> String {
        let converted = converted(quantity)
        // Feet-and-inches notation is for the foot and the inch only. Every non-metric unit
        // used to be sent here, and `imperialText` reads its input as feet — so 36 in printed
        // as `36'-0"`, and yards and miles were 3× and 5280× wrong. Yards and miles are
        // decimal, as the presentation layer's own formatter already renders them (BH-005).
        if quantity.dimension.lengthPower == 1, usesImperialMarks {
            let feet = units.length == .inch ? converted / 12 : converted
            return imperialText(feet, showsFeet: units.length == .foot)
        }
        let dimensionless = quantity.dimension.lengthPower == 0
            && !quantity.dimension.angle
            && quantity.dimension.currencyCode == nil
        let places = dimensionless
            ? countDecimalPlaces(converted)
            : units.metricDecimalPlaces
        return decimalText(converted, places: places)
    }

    /// The formatted number with its unit, which is what a ledger cell and a live field show.
    public func textWithUnit(_ quantity: Shown.Quantity) -> String {
        let body = text(quantity)
        // `1'-6 1/2"` already carries its own marks; appending `ft` or `in` printed a length
        // with two units (`36'-0" in`).
        if quantity.dimension.lengthPower == 1, usesImperialMarks { return body }
        let symbol = self.symbol(quantity)
        return symbol.isEmpty ? body : "\(body) \(symbol)"
    }

    /// Whether lengths render as feet, inches and a fraction rather than as a decimal. Decimal
    /// feet (`12.50 ft`) and decimal inches never do (NL-MEASURE-10).
    private var usesImperialMarks: Bool { units.usesFeetInchesMarks }

    /// A formatter for one markup's own display units (NL-MEASURE-10): `policy`'s length, area
    /// and volume and its precision, in this formatter's locale — the one formatter type, built
    /// per row, so a per-markup override renders through the same code as everything else
    /// (QUALITY_BAR A25). A fraction precision means feet and inches; a decimal precision on a
    /// foot or inch length means decimal feet or inches.
    public func overriding(_ policy: DisplayUnitPolicy) -> QuantityFormatter {
        var next = units
        // The reverse of the total `Domain.*(shown:)` maps, so the two can never disagree.
        next.length = Shown.Length.allCases.first { Domain.Length(shown: $0) == policy.length } ?? next.length
        next.area = Shown.Area.allCases.first { Domain.Area(shown: $0) == policy.area } ?? next.area
        next.volume = Shown.Volume.allCases.first { Domain.Volume(shown: $0) == policy.volume } ?? next.volume
        switch policy.precision {
        case .decimalPlaces(let places):
            next.metricDecimalPlaces = max(0, min(9, places))
            if next.length == .foot { next.imperialLengthStyle = .decimalFeet }
            if next.length == .inch { next.imperialLengthStyle = .decimalInches }
        case .imperialFraction(let denominator):
            next.imperialLengthStyle = .feetInches
            if let precision = ImperialPrecision.allCases.first(where: { $0.denominator == denominator.rawValue }) {
                next.imperialPrecision = precision
            }
        }
        return QuantityFormatter(units: next, localeIdentifier: localeIdentifier)
    }

    /// A slope rendered in the selected form.
    ///
    /// Takes the ratio `rise / run`, which is the dimensionless field the engine produces,
    /// and never re-derives it from an angle: a round trip through radians is where a 1:12
    /// ramp becomes 1:11.999.
    public func slopeText(ratio: Decimal) -> String {
        let doubleRatio = (ratio as NSDecimalNumber).doubleValue
        switch units.slope {
        case .percent:
            return decimalText(ratio * 100, places: 1) + " %"
        case .decimal:
            return decimalText(ratio, places: 4)
        case .degrees:
            let degrees = Foundation.atan(doubleRatio) * 180 / Double.pi
            return decimalText(Decimal(degrees), places: 1) + "°"
        case .ratioOneToN:
            guard doubleRatio != 0 else { return "1:∞" }
            return "1:" + decimalText(Decimal(1 / doubleRatio), places: 2)
        case .ratioNToOne:
            return decimalText(ratio, places: 2) + ":1"
        case .riseOverRun:
            return decimalText(ratio, places: 3) + " / 1"
        }
    }

    // MARK: Number rendering


    private func decimalText(_ value: Decimal, places: Int) -> String {
        // Rounded here, in `Decimal`, by the ledger package's one display rule —
        // `LedgerDisplayRounding.round`, `NSDecimalRound(.plain)`, half away from zero, no
        // negative zero — which is the rule the XLSX, JSON and PDF exporters apply, *before*
        // the formatter sees the number. The formatter used to round on its own, half-even, so
        // the screen and the app's CSV said 0.12 where the export said 0.13 and 1.00 where it
        // said 1.01, and a one-row group's pre-rounded header disagreed with its own row
        // (CR-53). One rounding, one rule, cited from one place.
        let rounded = LedgerDisplayRounding.round(value, places: places)
        guard rounded.isFinite, !rounded.isNaN else { return "\(rounded)" }
        return numberLocale.string(rounded, decimalPlaces: places)
    }

    /// How many decimals a dimensionless value needs to survive display, capped so a
    /// repeating ratio does not print thirty digits.
    private func countDecimalPlaces(_ value: Decimal) -> Int {
        let exponent = -value.exponent
        return max(0, min(6, exponent))
    }

    /// Feet and inches with a fraction, at the selected denominator.
    ///
    /// The fraction is reduced, and a fraction that rounds up to a whole inch carries into
    /// the inches rather than printing `11 16/16"`.
    private func imperialText(_ feet: Decimal, showsFeet: Bool = true) -> String {
        let denominator = max(1, units.imperialPrecision.denominator)
        let negative = feet < 0
        let magnitude = abs((feet as NSDecimalNumber).doubleValue)

        // Count in the smallest unit the precision can express, then carry upwards. Rounding
        // the inches and the fraction separately is what produces `11 16/16"`.
        let scaled = (magnitude * 12 * Double(denominator)).rounded()
        // `Int(_:)` traps on NaN, infinity and anything past `Int.max`. A NaN length (Decimal
        // arithmetic that overflowed, a formula column's result) or an astronomically large
        // one used to crash the app the moment it was drawn in feet (BH-420). It renders the
        // way the decimal branch would render it instead.
        guard feet.isFinite, !feet.isNaN, scaled.isFinite, scaled < Double(Int.max / 2) else {
            if feet.isNaN || magnitude.isNaN { return "NaN" }
            return negative ? "-∞" : "∞"
        }
        let steps = Int(scaled)
        let wholeFeet = showsFeet ? steps / (denominator * 12) : 0
        let wholeInches = showsFeet ? (steps / denominator) % 12 : steps / denominator
        let fraction = steps % denominator

        if steps == 0, magnitude > 0 {
            // Below the smallest representable fraction, but not zero: say so rather than
            // printing 0'-0" for a real length.
            return (negative ? "-" : "") + "< 1/\(denominator)\""
        }

        var text = showsFeet ? "\(wholeFeet)'-\(wholeInches)" : "\(wholeInches)"
        if fraction > 0 {
            var numerator = fraction
            var base = denominator
            while numerator % 2 == 0, base % 2 == 0 {
                numerator /= 2
                base /= 2
            }
            text += " \(numerator)/\(base)"
        }
        return (negative ? "-" : "") + text + "\""
    }
}
