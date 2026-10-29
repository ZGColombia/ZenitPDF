// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

/// Deterministic formatting used by the mock sample data.
///
/// Real presenters format through a locale-aware `NumberFormatter`. The mocks format
/// through this fixed helper so that previews and unit tests produce byte-identical
/// strings on every machine, whatever the user's locale is.
public enum SampleFormatting {

    /// Rounds a decimal half-away-from-zero to a fixed number of fraction digits.
    public static func rounded(_ value: Decimal, fractionDigits: Int) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, fractionDigits, .plain)
        return output
    }

    /// Formats a decimal with a fixed number of fraction digits and a `.` separator.
    public static func string(_ value: Decimal, fractionDigits: Int) -> String {
        let rounded = Self.rounded(value, fractionDigits: fractionDigits)
        return String(format: "%.\(fractionDigits)f", NSDecimalNumber(decimal: rounded).doubleValue)
    }

    /// The number of fraction digits the sample data shows for a dimension.
    public static func fractionDigits(for dimension: QuantityDimension) -> Int {
        if dimension.currencyCode != nil { return 2 }
        if dimension.angle { return 1 }
        // BH-780: a ratio is dimensionless like a count but not a number of things; 0.25 of a
        // waste factor printed "0".
        if dimension.ratio { return 2 }
        switch dimension.lengthPower {
        case 0: return 0
        default: return 2
        }
    }

    /// Formats a quantity for display, without a unit symbol.
    public static func string(_ quantity: DecimalQuantity) -> String {
        string(quantity.value, fractionDigits: fractionDigits(for: quantity.dimension))
    }

    /// A deterministic UUID derived from an integer seed.
    ///
    /// The `5A504446` prefix spells `ZPDF` in ASCII, which makes sample identifiers
    /// obvious in a debugger and guarantees they never collide with real ones.
    public static func sampleID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5A504446-0000-4000-8000-%012X", index)) ?? UUID()
    }

    /// A fixed instant used as the origin for every sample timestamp: 2026-03-02 09:00 UTC.
    public static let sampleEpoch = Date(timeIntervalSince1970: 1_772_442_000)

    /// A deterministic timestamp `days` days and `hours` hours after ``sampleEpoch``.
    public static func sampleDate(days: Int, hours: Int = 0) -> Date {
        sampleEpoch.addingTimeInterval(Double(days) * 86_400 + Double(hours) * 3_600)
    }
}
#endif
