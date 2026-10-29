import Foundation

/// The sheet sizes the corpus uses, in PDF points (72 per inch).
public enum FixturePageSize {

    /// Exact conversion factor: 1 inch is 25.4 mm by definition, so 1 mm is 72/25.4 pt.
    public static let pointsPerMillimetre: Double = 72.0 / 25.4
    public static let pointsPerInch: Double = 72.0

    /// US Letter, 8.5 × 11 in — exactly 612 × 792 pt.
    public static let letter = FixtureRect(x: 0, y: 0, width: 612, height: 792)

    /// ISO A4, 210 × 297 mm.
    public static let a4 = FixtureRect(
        x: 0,
        y: 0,
        width: 210 * pointsPerMillimetre,
        height: 297 * pointsPerMillimetre
    )

    /// ISO A1, 594 × 841 mm — a common Swedish construction sheet.
    public static let a1 = FixtureRect(
        x: 0,
        y: 0,
        width: 594 * pointsPerMillimetre,
        height: 841 * pointsPerMillimetre
    )

    /// ARCH D, 24 × 36 in — exactly 1728 × 2592 pt.
    public static let archD = FixtureRect(
        x: 0,
        y: 0,
        width: 24 * pointsPerInch,
        height: 36 * pointsPerInch
    )
}
