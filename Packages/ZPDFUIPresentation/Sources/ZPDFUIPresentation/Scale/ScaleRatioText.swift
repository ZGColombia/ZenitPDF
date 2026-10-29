import Foundation

/// The one way Zenit writes a drawing scale as `1:n` (L-38).
///
/// Live test 8 calibrated a separate X / Y scale, X 848.0 pt = 14,8 m and Y 839.6 pt = 15 m,
/// which is 1:49.47 × 1:50.64. The Calibrate sheet read "1:49,5" and "1:50,6"; the status strip
/// read "1:49 × 1:51 @ 1.00m"; the Inspector, the Scale Regions panel and the Bulk Scale sheet
/// read "1:49 × 1:51". Three formatters — whole numbers without a locale for names and
/// ``ScaleSummary/displayString``, precision by size in the current locale for the sheet, and
/// later a fixed two decimals for the strip — so one scale had three spellings. Every `1:n` a
/// person reads now comes from here: the sheet's ratio, the status strip, the summary's display
/// string and the generated scale names.
///
/// The rule is the Calibrate sheet's, because that is the number the person accepted when they
/// pressed Apply: two decimals below 1:10, one decimal below 1:100, none from 1:100 up, trailing
/// zeros trimmed, never grouped (a scale is written 1:1000, not 1:1 000). A stored nominal ratio
/// carries float noise (1:49.999 999 9) that this rounds away, so a preset 1:50 still reads 1:50.
public enum ScaleRatioText {

    /// PDF points in one metre: a point is 1/72 inch.
    public static let pagePointsPerMetre: Double = 72.0 / 0.0254

    /// The `n` in `1:n` for a factor in metres per page point, or `nil` for a factor that is not
    /// finite and positive.
    ///
    /// `userUnit` is the page's `/UserUnit`: a scale on a `/UserUnit 2` sheet carries twice the
    /// metres per page unit for the same nominal ratio, so the ratio is divided back by it
    /// (CR-128).
    public static func denominator(metresPerPoint: Double, userUnit: Double = 1) -> Double? {
        guard metresPerPoint.isFinite, metresPerPoint > 0 else { return nil }
        let unit = (userUnit.isFinite && userUnit > 0) ? userUnit : 1
        return metresPerPoint * pagePointsPerMetre / unit
    }

    /// How many fraction digits a denominator is written with: two below 10, one below 100,
    /// none from 100 up.
    public static func fractionDigits(for denominator: Double) -> Int {
        denominator >= 100 ? 0 : (denominator >= 10 ? 1 : 2)
    }

    /// `"49,5"` — a denominator in `locale`'s digits, by ``fractionDigits(for:)``, trailing zeros
    /// trimmed, never grouped.
    public static func number(_ denominator: Double, locale: Locale) -> String {
        denominator.formatted(
            .number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(0...fractionDigits(for: denominator)))
        )
    }

    /// `"1:49,5"` for one factor, or `nil` for a degenerate one (see
    /// ``denominator(metresPerPoint:userUnit:)``) — the caller decides what an uncalibrated page
    /// says.
    public static func ratio(metresPerPoint: Double, userUnit: Double = 1, locale: Locale) -> String? {
        denominator(metresPerPoint: metresPerPoint, userUnit: userUnit).map { "1:" + number($0, locale: locale) }
    }

    /// `"1:50"` for a uniform scale, `"1:49,5 × 1:50,6"` for a separate X / Y one.
    ///
    /// A degenerate factor reads `1:1`, so a damaged scale can never print `1:0` or an empty
    /// ratio.
    public static func ratio(
        metresPerPointX: Double,
        metresPerPointY: Double,
        isUniform: Bool,
        userUnit: Double = 1,
        locale: Locale
    ) -> String {
        let x = ratio(metresPerPoint: metresPerPointX, userUnit: userUnit, locale: locale) ?? "1:1"
        guard !isUniform else { return x }
        let y = ratio(metresPerPoint: metresPerPointY, userUnit: userUnit, locale: locale) ?? "1:1"
        return "\(x) × \(y)"
    }
}
