import Foundation
import Testing
import ZPDFUIPresentation

/// Live test 8, L-38: one scale, three spellings. The live calibration was X 848.0 pt = 14,8 m
/// and Y 839.6 pt = 15 m — 1:49.47 × 1:50.64. The Calibrate sheet read "1:49,5" / "1:50,6", the
/// status strip "1:49 × 1:51 @ 1.00m" (after the first fix "1:49,47 × 1:50,64 @ 1,00 m"), and the
/// Inspector / Scale Regions / Bulk Scale "1:49 × 1:51". ``ScaleRatioText`` is the one rule now.
@Suite("Live test 8 — one ratio rule for every 1:n (L-38)")
struct L8ScaleRatioTextTests {

    static let swedish = Locale(identifier: "sv_SE")
    static let posix = Locale(identifier: "en_US_POSIX")

    /// Metres per point of a line `points` long that stands for `metres`.
    static func factor(points: Double, metres: Double) -> Double { metres / points }

    @Test("The live X/Y calibration reads 1:49,5 × 1:50,6 — the Calibrate sheet's numbers")
    func liveCalibration() throws {
        let sx = Self.factor(points: 848.0, metres: 14.8)
        let sy = Self.factor(points: 839.6, metres: 15)
        let x = try #require(ScaleRatioText.denominator(metresPerPoint: sx))
        let y = try #require(ScaleRatioText.denominator(metresPerPoint: sy))
        #expect(abs(x - 49.47) < 0.01 && abs(y - 50.64) < 0.01, "the live scale is 1:49.47 × 1:50.64 (\(x), \(y))")
        // Old: names and display strings "1:49 × 1:51"; the first fix's strip "1:49,47 × 1:50,64".
        #expect(ScaleRatioText.ratio(metresPerPointX: sx, metresPerPointY: sy, isUniform: false, locale: Self.swedish)
                == "1:49,5 × 1:50,6")
        #expect(ScaleRatioText.ratio(metresPerPointX: sx, metresPerPointY: sy, isUniform: false, locale: Self.posix)
                == "1:49.5 × 1:50.6")
        #expect(ScaleRatioText.ratio(metresPerPoint: sx, locale: Self.swedish) == "1:49,5")
        #expect(ScaleRatioText.ratio(metresPerPoint: sy, locale: Self.swedish) == "1:50,6")
    }

    @Test("Precision by size: two decimals under 1:10, one under 1:100, none from 1:100")
    func precisionBySize() {
        func text(_ n: Double) -> String { ScaleRatioText.number(n, locale: Self.swedish) }
        #expect(text(2.5) == "2,5")
        #expect(text(7.126) == "7,13")
        #expect(text(28.3465) == "28,3")
        #expect(text(49.4999999) == "49,5")
        #expect(text(49.9999999) == "50", "the float noise of a nominal 1:50 is rounded away")
        // 0.1 m per point: the first fix's strip read "1:283,46" while the sheet read "1:283".
        #expect(text(0.1 * ScaleRatioText.pagePointsPerMetre) == "283")
        #expect(text(1000) == "1000", "a scale is written 1:1000, never with the locale's grouping space")
        #expect(text(12_500) == "12500")
    }

    @Test("A degenerate factor has no ratio; a separate scale never prints 1:0")
    func degenerate() {
        #expect(ScaleRatioText.ratio(metresPerPoint: 0, locale: Self.posix) == nil)
        #expect(ScaleRatioText.ratio(metresPerPoint: .nan, locale: Self.posix) == nil)
        #expect(ScaleRatioText.ratio(metresPerPoint: -1, locale: Self.posix) == nil)
        #expect(ScaleRatioText.ratio(metresPerPointX: 0, metresPerPointY: 0, isUniform: false, locale: Self.posix) == "1:1 × 1:1")
    }

    @Test("The page's /UserUnit divides the factor back (CR-128)")
    func userUnit() {
        let hundredOnUnitTwo = 2 * 100 / ScaleRatioText.pagePointsPerMetre
        #expect(ScaleRatioText.ratio(metresPerPoint: hundredOnUnitTwo, userUnit: 2, locale: Self.posix) == "1:100")
        #expect(ScaleRatioText.ratio(metresPerPoint: hundredOnUnitTwo, locale: Self.posix) == "1:200")
    }
}
