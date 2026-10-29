import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Regression: measurements taken under a *calibrated* scale must remain summable.
///
/// Found by the CORE_LOOP acceptance test on a calibrated A1 drawing (2026-08-24).
/// A two-point calibration produces `metresPerPoint` by `Decimal` division, so the factor —
/// and `areaFactor`, its square — carry the full 38-digit mantissa. `ArealMeasure` used to
/// multiply the (policy-normalised) page-space area by that factor and store the raw
/// product, also 38 digits. Two such areas cannot be added exactly inside `Decimal`, so the
/// Quantity Ledger's exact-or-refuse addition (QUALITY_BAR A1) refused the `planArea`
/// grand total of two plain rectangles: the totals row on a real drawing read as a refusal.
///
/// The fix re-normalises the product at `NumericPolicy.defaultSignificantDigits`, the same
/// crossing every other produced value uses. These tests pin both halves: the significance
/// bound, and the summability that follows from it.
@Suite("Calibrated-scale normalisation")
struct CalibratedScaleNormalisationTests {

    /// A calibration as taken on a drawing: 5 000 mm across 283.46500000000015 pt of the
    /// sheet's 100 mm measurement-control ruler — a metres-per-point value with no finite
    /// decimal representation.
    static func calibratedScale() throws -> ScaleTransform {
        try ScaleTransform.calibratedTwoPoint(
            id: Fixture.scaleID,
            first: PDFPoint(x: 1051.6863311500001, y: 42.40709864999985),
            second: PDFPoint(x: 1335.1513311500003, y: 42.40709864999985),
            knownLength: 5000,
            knownLengthUnit: .millimetre,
            units: .metric
        )
    }

    @Test("Two areas measured under a calibrated scale add exactly in the ledger's arithmetic")
    func calibratedAreasStaySummable() throws {
        let scale = try Self.calibratedScale()
        let engine = MeasurementEngine()

        let slab = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon([(1745, 600), (2028.465, 600), (2028.465, 770.079), (1745, 770.079)]),
            scale: scale,
            parameters: .default
        )
        let opening = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon([(1802, 655), (1858.693, 655), (1858.693, 683.3465), (1802, 683.3465)]),
            scale: scale,
            parameters: .default
        )

        let slabArea = try #require(slab[.planArea]).value
        let openingArea = try #require(opening[.planArea]).value

        // The refusal this reproduces was `NSDecimalAdd` reporting `.lossOfPrecision`.
        // Adding the two stored values with the same operator the aggregation core uses
        // must be exact now.
        var sum = Decimal()
        var lhs = slabArea
        var rhs = openingArea
        let status = NSDecimalAdd(&sum, &lhs, &rhs, .plain)
        #expect(status == .noError, "stored areas must add exactly (got \(status.rawValue))")

        // And the values themselves are right: 283.465 × 170.079 pt² at (5 m / 283.465 pt)²
        // is 15.0 m² − within Double geometry noise − and 56.693 × 28.3465 pt² is 0.5 m².
        #expect(abs(NSDecimalNumber(decimal: slabArea).doubleValue - 15.0) < 1e-9)
        #expect(abs(NSDecimalNumber(decimal: openingArea).doubleValue - 0.5) < 1e-9)
        #expect(abs(NSDecimalNumber(decimal: sum).doubleValue - 15.5) < 1e-9)
    }

    @Test("An exact-scale area is not disturbed by the normalisation")
    func exactScaleStaysExact() throws {
        // 0.1 m per point: the integration fixtures' scale, whose products are short and
        // exact. Normalising must be the identity here — 518.4 stays 518.4, no drift.
        let engine = MeasurementEngine()
        let result = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon([(72, 72), (360, 72), (360, 252), (72, 252)]),
            scale: Fixture.uniform(Decimal(string: "0.1")!),
            parameters: .default
        )
        #expect(try #require(result[.planArea]).value == Decimal(string: "518.4"))
    }
}
