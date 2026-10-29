import Foundation
import ZPDFUIPresentation

/// Renders a stored SI length as a display string, and a scale factor as a `1:n` ratio.
///
/// Nothing rounds internally: rounding happens only at the view boundary — which is
/// exactly here. The formatter never mutates the value it is given.
///
/// The shipping readers are the loupe's coordinate readout (``MeasurementLoupe``, a length pair)
/// and the scale sheet's ratio (``ratioString(metresPerPagePoint:locale:)``). The area, volume, money,
/// angle and slope branches served only the live caption that no screen ever showed, and were
/// removed with it (R-141).
public struct MeasurementValueFormatter: Hashable, Sendable {

    /// Output unit for lengths.
    public var lengthUnit: LengthUnit
    /// Fraction precision applied to imperial lengths.
    public var imperialPrecision: ImperialPrecision
    /// Pad decimals to their full count, so a live readout keeps its width while it changes.
    ///
    /// Trimmed output turned 12.500 into `12.5` and 12.513 into `12.513`, so the readout grew
    /// and shrank while the pointer moved even though it uses tabular figures to avoid exactly
    /// that (IM-210).
    public var padsFractionDigits: Bool = false

    public init(
        lengthUnit: LengthUnit = .metre,
        imperialPrecision: ImperialPrecision = .sixteenth
    ) {
        self.lengthUnit = lengthUnit
        self.imperialPrecision = imperialPrecision
    }

    /// The same formatter with ``padsFractionDigits`` on, for readouts that change while the
    /// person watches them.
    public var forLiveReadout: MeasurementValueFormatter {
        var copy = self
        copy.padsFractionDigits = true
        return copy
    }

    /// The suffix to put after ``lengthValueString(metres:)``, or an empty string when there is
    /// none: `12' 6 1/2"` carries its own marks, and composing it with `ft` gave
    /// `12' 6 1/2" ft` (BH-262).
    public var lengthSuffix: String { usesImperialFractions ? "" : lengthUnit.symbol }

    /// Formats a length held in metres without its unit suffix. Imperial lengths come back as
    /// `12' 6 1/2"`.
    public func lengthValueString(metres: Decimal) -> String {
        if usesImperialFractions {
            return ImperialLengthFormatter.string(
                metres: doubleValue(metres),
                precision: imperialPrecision,
                showsFeet: lengthUnit == .foot
            )
        }
        let perUnit = lengthUnit.metresPerUnit
        let digits = lengthUnit == .millimetre ? 0 : 3
        return decimalString(doubleValue(metres / perUnit), fractionDigits: digits)
    }

    /// Formats a length held in metres with its unit suffix, where it has one.
    public func lengthString(metres: Decimal) -> String {
        let value = lengthValueString(metres: metres)
        let suffix = lengthSuffix
        return suffix.isEmpty ? value : "\(value) \(suffix)"
    }

    /// Formats a scale factor as a `1:n` ratio string, through ``ScaleRatioText`` — the rule the
    /// status strip, the Inspector, the Scale Regions panel and the generated scale names use, so
    /// the ratio the Calibrate sheet shows is the ratio the rest of the app shows (L-38).
    ///
    /// `locale` is the document's; the app's documents are formatted in the current locale.
    public static func ratioString(metresPerPagePoint: Double, locale: Locale = .current) -> String {
        ScaleRatioText.ratio(metresPerPoint: metresPerPagePoint, locale: locale)
            ?? NSLocalizedString("Not calibrated", comment: "Scale ratio for an uncalibrated page")
    }

    // MARK: - Private

    /// Feet-and-inches display only applies to inch and foot. Yards and miles are decimal:
    /// nobody writes a mile as a vulgar fraction of an inch.
    private var usesImperialFractions: Bool { lengthUnit == .inch || lengthUnit == .foot }

    /// A decimal in the user's locale, grouped, rounded half-even.
    ///
    /// Through `FloatingPointFormatStyle`, which Foundation caches, rather than a
    /// `NumberFormatter` built and configured on every call (IM-113).
    private func decimalString(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-∞" : "∞") }
        let maximum = max(0, fractionDigits)
        let minimum = padsFractionDigits ? maximum : 0
        return value.formatted(
            .number
                .precision(.fractionLength(minimum...maximum))
                .grouping(.automatic)
                .rounded(rule: .toNearestOrEven)
                .locale(.current)
        )
    }

    private func doubleValue(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
