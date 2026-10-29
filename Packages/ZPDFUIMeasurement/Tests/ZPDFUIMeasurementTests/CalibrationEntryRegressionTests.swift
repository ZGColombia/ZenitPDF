import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// The two latent calibration-sheet defects and the parser they share.
///
/// Both are latent only because the shipping prompt is still an `NSAlert`; the SwiftUI sheet
/// these drive is the one that replaces it, and a scale is the number every quantity in the
/// project is multiplied by. Everything here runs on the pure value types, so no sheet is put
/// on anybody's screen.
@Suite("Calibration entry")
@MainActor
struct CalibrationEntryRegressionTests {

    // MARK: - CR-164: a zero is a zero

    /// Old output: `.accepted(1e-06)`. `commit()` clamped the typed value into
    /// `allowedRange` — `min(max(0, 0.000_001), 1_000_000)` — so a typed 0 became one
    /// millionth of a metre. The field then rendered it at four decimals as "0", the person saw
    /// a zero, and the validator's `nonPositivePrimaryLength` block never fired because
    /// 0.000001 > 0. Apply lit up on a scale a million times too small.
    @Test("A typed zero reaches the validator as a zero rather than a clamped millionth")
    func zeroIsNotClampedToAPositiveNumber() {
        #expect(
            CalibrationLengthField.commitOutcome(text: "0", unit: .metre) == .outOfRange(0)
        )
        #expect(
            CalibrationLengthField.commitOutcome(text: "-5", unit: .metre) == .outOfRange(-5)
        )

        // The consequence, at the seam the sheet's Apply actually runs through.
        let draft = CalibrationDraft(
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0),
                knownLength: 0
            ),
            name: "Plan"
        )
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.nonPositivePrimaryLength))
        #expect(!validation.canApply)
        #expect(CalibrationValidator.makeScaleSummary(from: draft) == nil)
    }

    /// The clamped value the old code produced would have sailed through the same check, which
    /// is why the defect was invisible: the validator was doing its job on a number nobody typed.
    @Test("The value the old clamp produced would have passed every block")
    func theClampedValueWasUnblockable() {
        let clamped = CalibrationLengthField.allowedRange.lowerBound
        let draft = CalibrationDraft(
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0),
                knownLength: clamped
            ),
            unitIdentifier: LengthUnit.metre.rawValue,
            name: "Plan",
            confirmsExtremeScale: true
        )
        #expect(!CalibrationValidator.validate(draft).issues.contains(.nonPositivePrimaryLength))
        #expect(CalibrationValidator.validate(draft).canApply, "this is what Apply used to light up on")
        // And it rendered as a flat zero in the field, so nothing on screen said otherwise.
        #expect(CalibrationLengthField.metricString(clamped) == "0")
    }

    /// A number too large for a calibration is refused the same way, and still carried through
    /// exactly as typed so the sheet blocks on what the person is looking at.
    @Test("An absurd length is refused rather than clamped down to the ceiling")
    func aboveTheRangeIsRefusedNotClamped() {
        #expect(
            CalibrationLengthField.commitOutcome(text: "1000001", unit: .metre)
                == .outOfRange(1_000_001)
        )
        #expect(CalibrationLengthField.commitOutcome(text: "5", unit: .metre) == .accepted(5))
        #expect(CalibrationLengthField.commitOutcome(text: "", unit: .metre) == .cleared)
        #expect(CalibrationLengthField.commitOutcome(text: "abc", unit: .metre) == .unusable)
        #expect(CalibrationLengthField.commitOutcome(text: "5", unit: nil) == .unusable)
    }

    // MARK: - CR-165: a bare number means the unit in the popup

    /// Old output: `.length(1.0)`. With feet chosen, "12" went to
    /// `ImperialLengthFormatter.parseInches`, which reads a bare number as inches, and 12 inches
    /// converted back into feet is one foot. A 12-foot dimension calibrated the sheet at a
    /// twelfth of the intended scale, with nothing on screen to say so.
    @Test("A bare number under a feet popup is feet, not inches")
    func bareNumberUsesTheChosenImperialUnit() {
        #expect(CalibrationPendingLength.reading("12", unit: .foot) == .length(12))
        #expect(CalibrationPendingLength.reading("12.5", unit: .foot) == .length(12.5))
        #expect(CalibrationPendingLength.reading("12,5", unit: .foot) == .length(12.5))
        #expect(CalibrationPendingLength.reading("36", unit: .inch) == .length(36))
    }

    /// The scale the whole project is measured at, before and after.
    @Test("The scale a bare feet entry produces is the one the person meant")
    func bareFeetEntryProducesTheIntendedScale() {
        let draft = CalibrationDraft(
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0)
            ),
            unitIdentifier: LengthUnit.foot.rawValue,
            name: "Plan"
        )
        let scale = CalibrationValidator.makeScaleSummary(
            from: draft.resolvingPendingLengths(primary: "12")
        )
        // 12 ft over 100 pt is 12 * 0.3048 / 100 m per point. The old reading gave a twelfth
        // of that, 0.0003048, and called it the same calibration.
        #expect(abs((scale?.sx ?? 0) - (12 * 0.3048 / 100)) < 1e-12)
        #expect(abs((scale?.sx ?? 0) - (1 * 0.3048 / 100)) > 1e-6, "this is the old, wrong scale")
    }

    /// Anything that carries a unit of its own still goes through the imperial parser, and the
    /// field's own echo still round-trips.
    @Test("Marked and mixed imperial entries are still read as feet and inches")
    func markedEntriesStillParseAsImperial() {
        #expect(CalibrationPendingLength.reading("12' 6\"", unit: .foot) == .length(12.5))
        #expect(CalibrationPendingLength.reading("12 ft 6 in", unit: .foot) == .length(12.5))

        switch CalibrationPendingLength.reading("6 1/2", unit: .inch) {
        case let .length(value): #expect(abs(value - 6.5) < 1e-9)
        default: Issue.record("a mixed-number inch entry stopped parsing")
        }

        // "12 6" says two things and joins neither of them; it is refused, not read as 126.
        #expect(CalibrationPendingLength.reading("12 6", unit: .foot) == .unusable)
    }

    @Test("What counts as a bare number")
    func bareNumberRecognition() {
        #expect(ImperialLengthFormatter.isBareNumber("12"))
        #expect(ImperialLengthFormatter.isBareNumber("12.5"))
        #expect(ImperialLengthFormatter.isBareNumber("12,5"))
        #expect(ImperialLengthFormatter.isBareNumber("-3"))
        #expect(!ImperialLengthFormatter.isBareNumber("12'"))
        #expect(!ImperialLengthFormatter.isBareNumber("12\""))
        #expect(!ImperialLengthFormatter.isBareNumber("6 1/2"))
        #expect(!ImperialLengthFormatter.isBareNumber("12 ft"))
        #expect(!ImperialLengthFormatter.isBareNumber("1 200"))
        #expect(!ImperialLengthFormatter.isBareNumber("nan"))
        #expect(!ImperialLengthFormatter.isBareNumber(""))
    }

    // MARK: - CR-184: the calibration field reads what every other field reads

    /// Old output: `CalibrationPendingLength.reading("nan", unit: .metre)` returned
    /// `.length(nan)` through the `Double(string)` fallback at the end of `parseDecimal`. The
    /// validator's `!(value > 0)` is true for NaN so it did block — but only by accident of
    /// IEEE comparison, and `ImperialLengthFormatter.parseInches("nan")` returned NaN inches
    /// with no such guard behind it.
    @Test("Not a number is not a length, in either unit system")
    func nonFiniteEntriesAreRefused() {
        for text in ["nan", "NaN", "inf", "-inf", "Infinity"] {
            #expect(CalibrationPendingLength.reading(text, unit: .metre) == .unusable, "\(text)")
            #expect(CalibrationPendingLength.reading(text, unit: .foot) == .unusable, "\(text)")
            #expect(ImperialLengthFormatter.parseInches(text) == nil, "\(text)")
        }
    }

    /// One grammar: the calibration entry and the design system's numeric field agree about
    /// every text, which is what CR-184 asked for. The field's own `parse` is internal to
    /// `ZPDFDesignSystem`, so this asserts against the shared parser it forwards to.
    @Test("The calibration entry and the numeric field read the same text the same way")
    func theTwoFieldsAgree() {
        for text in ["12,5", "12.5", "1 200", "1,234", "1,200.50", "nan", "abc", "-3.25", "0"] {
            let field = ZPDFDecimalParser.double(text, allowingExponent: true)
            let calibration: Double? = {
                if case let .length(value) = CalibrationPendingLength.reading(text, unit: .metre) {
                    return value
                }
                return nil
            }()
            #expect(field == calibration, "\(text): field \(String(describing: field)), calibration \(String(describing: calibration))")
        }
    }
}
