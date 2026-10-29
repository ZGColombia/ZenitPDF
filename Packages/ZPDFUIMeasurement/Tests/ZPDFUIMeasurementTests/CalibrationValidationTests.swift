import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Covers the blocked states of two-point and axis-separated calibration.
@Suite("Calibration input validation")
struct CalibrationValidationTests {

    private func uniformDraft(
        start: PDFPointValue = PDFPointValue(x: 100, y: 100),
        end: PDFPointValue = PDFPointValue(x: 440, y: 100),
        knownLength: Double? = 6,
        unit: String = LengthUnit.metre.rawValue,
        name: String = "Plan"
    ) -> CalibrationDraft {
        CalibrationDraft(
            mode: .uniform,
            primary: CalibrationAxisInput(start: start, end: end, knownLength: knownLength),
            unitIdentifier: unit,
            name: name
        )
    }

    // MARK: Happy path

    @Test("A valid uniform draft can be applied")
    func validUniformDraft() {
        let validation = CalibrationValidator.validate(uniformDraft())
        #expect(validation.canApply, "Issues: \(validation.issues.map(\.rawValue))")
        #expect(validation.preview != nil)
        #expect(validation.preview?.isUniform == true)
    }

    @Test("The preview scale is the known length over the PDF distance")
    func previewScaleMatchesInput() {
        let draft = uniformDraft(
            start: PDFPointValue(x: 0, y: 0),
            end: PDFPointValue(x: 100, y: 0),
            knownLength: 5
        )
        let preview = CalibrationValidator.validate(draft).preview
        #expect(abs((preview?.sx ?? 0) - 0.05) < 1e-12)
        #expect(abs((preview?.sy ?? 0) - (preview?.sx ?? -1)) < 1e-12)
    }

    @Test("A validated draft produces a usable scale summary")
    func makesScaleSummary() {
        let scale = CalibrationValidator.makeScaleSummary(from: uniformDraft())
        #expect(scale != nil)
        #expect(scale?.unit == .metre)
        #expect(scale?.isUniform == true)
        #expect(scale?.locked == false)
        #expect(scale?.name == "Plan")
    }

    // MARK: Blocked states

    @Test("Identical points are blocked")
    func identicalPointsBlocked() {
        let point = PDFPointValue(x: 200, y: 200)
        let validation = CalibrationValidator.validate(uniformDraft(start: point, end: point))
        #expect(validation.issues.contains(.identicalPrimaryPoints))
        #expect(!validation.canApply)
        #expect(validation.preview == nil)
    }

    @Test("Nearly identical points are blocked too")
    func nearlyIdenticalPointsBlocked() {
        let validation = CalibrationValidator.validate(
            uniformDraft(start: PDFPointValue(x: 200, y: 200), end: PDFPointValue(x: 200.4, y: 200))
        )
        #expect(validation.issues.contains(.identicalPrimaryPoints))
        #expect(!validation.canApply)
    }

    @Test("A half-picked line is blocked")
    func missingPointsBlocked() {
        var draft = uniformDraft()
        draft.primary.end = nil
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.missingPrimaryPoints))
        #expect(!validation.canApply)
    }

    @Test("A zero length is blocked")
    func zeroLengthBlocked() {
        let validation = CalibrationValidator.validate(uniformDraft(knownLength: 0))
        #expect(validation.issues.contains(.nonPositivePrimaryLength))
        #expect(!validation.canApply)
    }

    @Test("A negative length is blocked")
    func negativeLengthBlocked() {
        let validation = CalibrationValidator.validate(uniformDraft(knownLength: -3))
        #expect(validation.issues.contains(.nonPositivePrimaryLength))
        #expect(!validation.canApply)
    }

    @Test("A missing length is blocked")
    func missingLengthBlocked() {
        let validation = CalibrationValidator.validate(uniformDraft(knownLength: nil))
        #expect(validation.issues.contains(.missingPrimaryLength))
        #expect(!validation.canApply)
    }

    @Test("A non-finite length is blocked")
    func nonFiniteLengthBlocked() {
        let validation = CalibrationValidator.validate(uniformDraft(knownLength: .infinity))
        #expect(validation.issues.contains(.nonPositivePrimaryLength))
        #expect(!validation.canApply)
    }

    @Test("An unusable unit is blocked and produces no preview")
    func invalidUnitBlocked() {
        let draft = uniformDraft(unit: "furlong")
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.invalidUnit))
        #expect(!validation.canApply)
        #expect(validation.preview == nil)
        #expect(CalibrationValidator.makeScaleSummary(from: draft) == nil)
    }

    // MARK: Extreme scale

    @Test("An extreme scale needs an explicit confirmation")
    func extremeScaleNeedsConfirmation() {
        var draft = uniformDraft(
            start: PDFPointValue(x: 0, y: 0),
            end: PDFPointValue(x: 100, y: 0),
            knownLength: 5,
            unit: LengthUnit.kilometre.rawValue
        )
        var validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.extremeScale))
        #expect(CalibrationIssue.extremeScale.severity == .requiresConfirmation)
        #expect(!validation.canApply)

        draft.confirmsExtremeScale = true
        validation = CalibrationValidator.validate(draft)
        // BH-251: the ticked issue stays listed (its checkbox stays on screen) but no longer
        // holds Apply back.
        #expect(validation.issues.contains(.extremeScale))
        #expect(validation.isConfirmed(.extremeScale))
        #expect(validation.confirmationIssues.isEmpty)
        #expect(validation.canApply)
    }

    @Test("A normal architectural scale is not flagged as extreme")
    func plausibleScaleNotExtreme() {
        let draft = uniformDraft(
            start: PDFPointValue(x: 0, y: 0),
            end: PDFPointValue(x: 340, y: 0),
            knownLength: 6
        )
        #expect(!CalibrationValidator.validate(draft).issues.contains(.extremeScale))
    }

    // MARK: Separate axes

    @Test("Perpendicular axes validate and report a zero residual")
    func perpendicularAxesValidate() {
        let draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 200, y: 0),
                knownLength: 4
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 0, y: 200),
                knownLength: 4
            ),
            name: "Stretched plan"
        )
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.canApply, "Issues: \(validation.issues.map(\.rawValue))")
        #expect(abs((validation.preview?.axisAngleDegrees ?? 0) - 90) < 1e-9)
        #expect(abs(validation.preview?.residual ?? -1) < 1e-12)
    }

    @Test("Near-parallel axes are a hard block, not a tick-box")
    func nearParallelIsHardBlock() {
        var draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 200, y: 0),
                knownLength: 4
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 40),
                end: PDFPointValue(x: 200, y: 46),
                knownLength: 4
            ),
            name: "Bad axes"
        )
        var validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.nearParallelAxes))
        #expect(!validation.canApply)

        draft.confirmsNearParallelAxes = true
        validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.nearParallelAxes))
        #expect(!validation.canApply)
        #expect(CalibrationValidator.makeScaleSummary(from: draft) == nil)
    }

    @Test("Oblique axes can be confirmed past")
    func obliqueAxesNeedConfirmation() {
        var draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 200, y: 0),
                knownLength: 4
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 173.205, y: 100),
                knownLength: 4
            ),
            name: "Oblique"
        )
        var validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.obliqueAxes))
        #expect(!validation.canApply)

        draft.confirmsNearParallelAxes = true
        validation = CalibrationValidator.validate(draft)
        #expect(validation.isConfirmed(.obliqueAxes))
        #expect(validation.confirmationIssues.isEmpty)
        #expect(validation.canApply)
    }

    @Test("A reversed second line still counts as parallel")
    func axisAngleFoldsDirection() {
        let draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0),
                knownLength: 2
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 100, y: 50),
                end: PDFPointValue(x: 0, y: 50),
                knownLength: 2
            )
        )
        #expect(abs(CalibrationValidator.axisAngleDegrees(draft) ?? -1) < 1e-9)
        #expect(CalibrationValidator.validate(draft).issues.contains(.nearParallelAxes))
    }

    @Test("The residual reports the stretch between the two axes")
    func residualReportsStretch() {
        let draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0),
                knownLength: 5
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 0, y: 100),
                knownLength: 4
            ),
            name: "Stretched"
        )
        let preview = CalibrationValidator.validate(draft).preview
        #expect(abs((preview?.sx ?? 0) - 0.05) < 1e-12)
        #expect(abs((preview?.sy ?? 0) - 0.04) < 1e-12)
        #expect(abs((preview?.residual ?? -1) - 0.2) < 1e-12)
        #expect(preview?.isUniform == false)
    }

    @Test("Separate axis mode blocks on a missing second line")
    func separateAxesNeedBothLines() {
        let draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 200, y: 0),
                knownLength: 4
            ),
            name: "Half done"
        )
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.missingSecondaryPoints))
        #expect(validation.issues.contains(.missingSecondaryLength))
        #expect(!validation.canApply)
    }

    // MARK: Advisories

    @Test("A short baseline warns but does not block")
    func shortBaselineIsAdvisory() {
        let validation = CalibrationValidator.validate(
            uniformDraft(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 12, y: 0),
                knownLength: 0.2
            )
        )
        #expect(validation.issues.contains(.shortPrimaryBaseline))
        #expect(validation.canApply)
    }

    /// IM-204: the old advisory warned that an unnamed scale would be hard to find, about a
    /// scale that was always going to be named "Scale 1:n". No advisory now; the generated
    /// name is the one the sheet's placeholder shows.
    @Test("An unnamed scale raises no advisory and gets the generated name")
    func unnamedScaleGetsGeneratedName() {
        let draft = uniformDraft(name: "   ")
        let validation = CalibrationValidator.validate(draft)
        #expect(!validation.issues.contains { $0.severity == .advisory }, "Issues: \(validation.issues.map(\.rawValue))")
        #expect(validation.canApply)

        let scale = CalibrationValidator.makeScaleSummary(from: draft)
        #expect(validation.preview != nil)
        #expect(scale?.name == validation.preview.map(CalibrationValidator.generatedName(for:)))
        #expect(scale?.name.hasPrefix("Scale ") == true)
    }

    @Test("Issues are sorted blocking first, advisory last")
    func issuesAreSorted() {
        var draft = uniformDraft(knownLength: 0, name: "")
        // 8 pt: past the 4 pt identical-point floor, short enough for the baseline advisory.
        draft.primary.end = PDFPointValue(x: 108, y: 100)
        let issues = CalibrationValidator.validate(draft).issues
        #expect(issues.first?.severity == .blocking)
        #expect(issues.last?.severity == .advisory)
    }

    // MARK: Pick steps

    @Test("The pick step advances through the uniform flow")
    func uniformPickFlow() {
        var draft = CalibrationDraft()
        #expect(draft.nextPickStep == .primaryStart)
        draft.primary.start = PDFPointValue(x: 1, y: 1)
        #expect(draft.nextPickStep == .primaryEnd)
        draft.primary.end = PDFPointValue(x: 50, y: 1)
        #expect(draft.nextPickStep == .done)
    }

    @Test("The pick step advances through the separate axis flow")
    func separateAxisPickFlow() {
        var draft = CalibrationDraft(mode: .separateAxes)
        #expect(draft.nextPickStep == .xAxisStart)
        draft.primary.start = PDFPointValue(x: 1, y: 1)
        draft.primary.end = PDFPointValue(x: 50, y: 1)
        #expect(draft.nextPickStep == .yAxisStart)
        draft.secondary.start = PDFPointValue(x: 1, y: 1)
        #expect(draft.nextPickStep == .yAxisEnd)
        draft.secondary.end = PDFPointValue(x: 1, y: 50)
        #expect(draft.nextPickStep == .done)
    }

    @Test("The fraction precision control only appears for imperial units")
    func imperialPrecisionVisibility() {
        #expect(!uniformDraft(unit: LengthUnit.metre.rawValue).showsImperialPrecision)
        #expect(uniformDraft(unit: LengthUnit.foot.rawValue).showsImperialPrecision)
        #expect(!uniformDraft(unit: "furlong").showsImperialPrecision)
    }
}
