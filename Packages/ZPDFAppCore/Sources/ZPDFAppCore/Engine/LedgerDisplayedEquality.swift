import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The SI values a measured ledger cell shows as one number: every value that rounds, at the
/// displayed precision and in the displayed unit, to the number a given value rounds to.
///
/// Bounds are SI. A band never holds values of two signs, except the zero band, which holds
/// both and neither end.
struct LedgerDisplayBand: Hashable, Sendable {
    let lower: Decimal
    let upper: Decimal
    let includesLower: Bool
    let includesUpper: Bool

    func contains(_ value: Decimal) -> Bool {
        (includesLower ? value >= lower : value > lower) && (includesUpper ? value <= upper : value < upper)
    }
}

extension QuantityFormatter {

    /// The band of SI values ``text(_:)`` writes as the same number it writes for `si`, for a
    /// length, area, volume or angle; `nil` for any other dimension, whose text is not a rounded
    /// decimal of a measured quantity, and for a feet-and-inches value that shows as `0'-0"`
    /// (only zero does).
    ///
    /// It mirrors ``text(_:)`` rule for rule: the value converted into the selected unit, then
    /// rounded half away from zero on its magnitude — to ``DisplayUnitSelection/metricDecimalPlaces``
    /// through `LedgerDisplayRounding`, or, for feet and inches, to the fraction of an inch
    /// ``DisplayUnitSelection/imperialPrecision`` names. `X033DisplayedEqualityTests` holds the
    /// two to each other value by value.
    func displayBand(ofSI si: Decimal, dimension: Shown.Dimension) -> LedgerDisplayBand? {
        guard dimension.currencyCode == nil, dimension.angle || (1...3).contains(dimension.lengthPower) else { return nil }
        let shown = converted(Shown.Quantity(value: si, dimension: dimension))
        let magnitude = shown < 0 ? -shown : shown
        let negative = shown < 0
        // The step one displayed digit is worth, in the converted unit, and the magnitude the
        // display rounds `si` to.
        let step: Decimal
        let rounded: Decimal
        if dimension.lengthPower == 1, !dimension.angle, units.usesFeetInchesMarks {
            let denominator = Decimal(max(1, units.imperialPrecision.denominator))
            // `converted` is in inches when the length unit is the inch; `imperialText` counts
            // steps of 1/denominator inch either way, through `Double`, as here.
            let stepsPerUnit = units.length == .inch ? denominator : denominator * 12
            step = 1 / stepsPerUnit
            let steps = ((magnitude as NSDecimalNumber).doubleValue * (stepsPerUnit as NSDecimalNumber).doubleValue).rounded()
            guard steps.isFinite else { return nil }
            // A value below the smallest fraction shows "< 1/16\"", zero shows 0'-0": two texts.
            if steps == 0 {
                guard magnitude > 0 else { return nil }
                return band(magnitudeFrom: 0, to: step / 2, negative: negative, includesFrom: false, dimension: dimension)
            }
            rounded = Decimal(steps) * step
        } else {
            let places = max(0, min(12, units.metricDecimalPlaces))
            step = Self.powerOfTen(-places)
            rounded = LedgerDisplayRounding.round(magnitude, places: places)
        }
        let half = step / 2
        guard rounded > 0 else {
            // The zero band: everything that shows 0.00, from either side (no negative zero).
            return LedgerDisplayBand(
                lower: toBase(-half, dimension: dimension), upper: toBase(half, dimension: dimension),
                includesLower: false, includesUpper: false
            )
        }
        return band(magnitudeFrom: rounded - half, to: rounded + half, negative: negative, includesFrom: true, dimension: dimension)
    }

    /// `[from, to)` on the magnitude — half away from zero rounds `from` up and `to` up again —
    /// mapped to SI on the value's side of zero.
    private func band(
        magnitudeFrom from: Decimal,
        to: Decimal,
        negative: Bool,
        includesFrom: Bool,
        dimension: Shown.Dimension
    ) -> LedgerDisplayBand {
        let low = toBase(from, dimension: dimension)
        let high = toBase(to, dimension: dimension)
        return negative
            ? LedgerDisplayBand(lower: -high, upper: -low, includesLower: false, includesUpper: includesFrom)
            : LedgerDisplayBand(lower: low, upper: high, includesLower: includesFrom, includesUpper: false)
    }

    /// The inverse of ``converted(_:)``: a value in the selected unit, back in SI.
    private func toBase(_ value: Decimal, dimension: Shown.Dimension) -> Decimal {
        if dimension.angle { return Domain.Angle.degree.convert(value, to: .radian) }
        switch dimension.lengthPower {
        case 1: return Domain.Length(shown: units.length).toBase(value)
        case 2: return Domain.Area(shown: units.area).toBase(value)
        case 3: return Domain.Volume(shown: units.volume).toBase(value)
        default: return value
        }
    }

    private static func powerOfTen(_ exponent: Int) -> Decimal {
        Decimal(sign: .plus, exponent: exponent, significand: 1)
    }
}

extension LedgerSpecBuilder {

    /// "is" / "is not" on a measured column, compared with what its cells show (X-033).
    ///
    /// The filter builder converts the number a person types out of the column's display unit
    /// into SI, and the core compares `Decimal`s exactly. A measured cell holds its value to 15
    /// significant digits and shows it to two decimals, so "Plan Area is 12.35" matched no row
    /// and "is not 12.35" every row — the way "Created is 1 September" matched only midnight
    /// until the seam made a date equality the whole day (BH-041). A measured equality is now
    /// the band of values ``QuantityFormatter/displayBand(ofSI:dimension:)`` says show as the
    /// typed number.
    ///
    /// Only a column whose cells are measured or computed — a built-in column that reads a
    /// measurement field, or a formula — and whose text is a rounded length, area, volume or
    /// angle. A typed number column and a count stay exact: what they show is what was typed.
    /// `nil` leaves the rule to the core's exact comparison.
    static func displayedEquality(
        column: LedgerColumnDefinition,
        op: ZPDFQuantityLedger.LedgerFilterOperator,
        value: ZPDFQuantityLedger.LedgerFilterValue,
        formatter: QuantityFormatter
    ) -> LedgerFilterNode? {
        guard op == .equals || op == .notEquals,
              case .number(let si) = value,
              column.kind == .formula || column.standard?.measurementField != nil,
              let dimension = column.dimension,
              let band = formatter.displayBand(ofSI: si, dimension: Shown.Dimension(domain: dimension)) else { return nil }
        func rule(_ op: ZPDFQuantityLedger.LedgerFilterOperator, _ value: ZPDFQuantityLedger.LedgerFilterValue) -> LedgerFilterNode {
            .rule(ZPDFQuantityLedger.LedgerFilterRule(column: column.id, op: op, value: value))
        }
        var parts = [rule(.between, .numberRange(lower: band.lower, upper: band.upper))]
        if !band.includesLower { parts.append(.not(rule(.equals, .number(band.lower)))) }
        if !band.includesUpper { parts.append(.not(rule(.equals, .number(band.upper)))) }
        let shows: LedgerFilterNode = .and(parts)
        guard op == .notEquals else { return shows }
        // "is not" is the exact complement over every cell that is not a refusal (CR-58): an
        // empty or No input cell is kept, a refused one is not — Is empty ∪ Is not empty is
        // exactly the cells that are not refusals.
        return .and([.not(shows), .or([rule(.isEmpty, .none), rule(.isNotEmpty, .none)])])
    }
}
