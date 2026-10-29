import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Live finding LT-5: after typing the known length, the first activation of the commit button
/// was spent writing the text field back and a second was needed to set the scale.
///
/// These tests drive the model the sheet's Apply runs on — `resolvingPendingLengths` feeding
/// `makeScaleSummary`, exactly as `CalibrationSheet.apply()` does — so "typed but not yet
/// committed, then one activation" is asserted without putting a sheet on anybody's screen.
@Suite("Calibration pending length")
struct CalibrationPendingLengthTests {

    /// Two points 100 pt apart and no committed length: the state the sheet is in the instant
    /// before the person clicks Apply, with what they typed still sitting in the field.
    private func draftAwaitingLength(
        mode: CalibrationMode = .uniform,
        unit: String = LengthUnit.metre.rawValue,
        knownLength: Double? = nil
    ) -> CalibrationDraft {
        CalibrationDraft(
            mode: mode,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 100, y: 0),
                knownLength: knownLength
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0),
                end: PDFPointValue(x: 0, y: 100)
            ),
            unitIdentifier: unit,
            name: "Plan"
        )
    }

    /// What `CalibrationSheet.apply()` does, in one call.
    private func activateApply(
        _ draft: CalibrationDraft,
        pendingPrimary: String = "",
        pendingSecondary: String = ""
    ) -> ScaleSummary? {
        CalibrationValidator.makeScaleSummary(
            from: draft.resolvingPendingLengths(primary: pendingPrimary, secondary: pendingSecondary)
        )
    }

    // MARK: The reported defect

    @Test("LT-5: one activation sets the scale from text the field has not committed")
    func oneActivationAppliesPendingText() {
        let draft = draftAwaitingLength()

        // The second-click situation, pinned so this test states what it defends against: the
        // draft alone — the last-committed binding value — cannot be applied at all.
        #expect(CalibrationValidator.makeScaleSummary(from: draft) == nil)
        #expect(CalibrationValidator.validate(draft).issues.contains(.missingPrimaryLength))

        // One activation, reading the field's current text.
        let scale = activateApply(draft, pendingPrimary: "5")
        #expect(scale != nil, "One activation with pending text set no scale")
        // 5 m over 100 pt is 0.05 m per point, the same scale a committed 5 would give.
        #expect(abs((scale?.sx ?? 0) - 0.05) < 1e-12)
        #expect(scale?.isUniform == true)
        #expect(scale?.unit == .metre)
    }

    @Test("LT-5: the resolved draft is what Apply is allowed to commit")
    func resolvedDraftIsValid() {
        let resolved = draftAwaitingLength().resolvingPendingLengths(primary: "5")
        let validation = CalibrationValidator.validate(resolved)
        #expect(validation.canApply, "Issues: \(validation.issues.map(\.rawValue))")
        #expect(resolved.primary.knownLength == 5)
    }

    @Test("LT-5: pending text wins over a length the field has stopped showing")
    func pendingTextOverridesStaleCommittedValue() {
        // 5 was committed on an earlier edit; the person has since typed 8 and not left the
        // field. Applying 5 would be the tool committing a number nobody is looking at.
        let draft = draftAwaitingLength(knownLength: 5)
        let scale = activateApply(draft, pendingPrimary: "8")
        #expect(abs((scale?.sx ?? 0) - 0.08) < 1e-12)
    }

    @Test("Return and click take the same path, because both read the same text")
    func submitAndClickAgree() {
        let draft = draftAwaitingLength()
        // onSubmit commits the field first, so the length is already in the draft.
        let viaReturn = activateApply(draft.resolvingPendingLengths(primary: "5"))
        // A click arrives with the text still pending.
        let viaClick = activateApply(draft, pendingPrimary: "5")
        #expect(viaReturn?.sx == viaClick?.sx)
        #expect(viaClick?.sx != nil)
    }

    // MARK: Refusals

    @Test("Text that is not a length blocks instead of falling back to the committed value")
    func unusableTextBlocks() {
        // The dangerous shape: a committed 5 still in the draft while the field shows nonsense.
        // Falling back to 5 would put a scale nobody typed under every quantity in the project.
        let draft = draftAwaitingLength(knownLength: 5)
        let resolved = draft.resolvingPendingLengths(primary: "abc")
        #expect(resolved.primary.knownLength == nil)
        // IM-017: it blocks as unreadable text, not as a missing length the person did type.
        #expect(CalibrationValidator.validate(resolved).issues.contains(.unparseablePrimaryLength))
        #expect(activateApply(draft, pendingPrimary: "abc") == nil)
    }

    @Test("A pending zero is refused like a committed zero")
    func pendingZeroBlocks() {
        let draft = draftAwaitingLength()
        let resolved = draft.resolvingPendingLengths(primary: "0")
        #expect(resolved.primary.knownLength == 0)
        #expect(CalibrationValidator.validate(resolved).issues.contains(.nonPositivePrimaryLength))
        #expect(activateApply(draft, pendingPrimary: "0") == nil)
    }

    @Test("Empty pending text means nothing is pending, so the committed length stands")
    func emptyPendingTextChangesNothing() {
        let draft = draftAwaitingLength(knownLength: 5)
        #expect(draft.resolvingPendingLengths(primary: "").primary.knownLength == 5)
        #expect(draft.resolvingPendingLengths(primary: "   ").primary.knownLength == 5)
        #expect(abs((activateApply(draft)?.sx ?? 0) - 0.05) < 1e-12)
    }

    @Test("A pending length with no unit cannot be read")
    func unresolvableUnitIsUnusable() {
        let draft = draftAwaitingLength(unit: "furlong")
        #expect(draft.resolvedUnit == nil)
        #expect(CalibrationPendingLength.reading("5", unit: nil) == .unusable)
        #expect(activateApply(draft, pendingPrimary: "5") == nil)
    }

    // MARK: Units

    @Test("A decimal point is read whatever the machine's locale")
    func decimalPointIsPortable() {
        let draft = draftAwaitingLength()
        let scale = activateApply(draft, pendingPrimary: "5.5")
        #expect(abs((scale?.sx ?? 0) - 0.055) < 1e-12)
    }

    @Test("Millimetres pending are converted like millimetres committed")
    func metricUnitConversion() {
        let draft = draftAwaitingLength(unit: LengthUnit.millimetre.rawValue)
        // 5000 mm over 100 pt is 0.05 m per point.
        let scale = activateApply(draft, pendingPrimary: "5000")
        #expect(abs((scale?.sx ?? 0) - 0.05) < 1e-12)
    }

    @Test("An imperial entry is read the way the field's own echo reads it")
    func imperialPendingText() {
        let draft = draftAwaitingLength(unit: LengthUnit.foot.rawValue)
        // 12' 6" is 12.5 ft. Over 100 pt that is 12.5 * 0.3048 / 100 m per point.
        let expected = 12.5 * 0.3048 / 100
        let scale = activateApply(draft, pendingPrimary: "12' 6\"")
        #expect(abs((scale?.sx ?? 0) - expected) < 1e-12)

        switch CalibrationPendingLength.reading("12' 6\"", unit: .foot) {
        case .length(let feet): #expect(abs(feet - 12.5) < 1e-9)
        default: Issue.record("Imperial entry was not read as a length")
        }
    }

    // MARK: Axes

    @Test("The Y field's text is only folded in when the draft has a Y axis")
    func secondaryPendingTextIsModeAware() {
        let uniform = draftAwaitingLength(knownLength: 5)
        #expect(uniform.resolvingPendingLengths(secondary: "9").secondary.knownLength == nil)

        let separate = draftAwaitingLength(mode: .separateAxes, knownLength: 5)
        #expect(separate.resolvingPendingLengths(secondary: "9").secondary.knownLength == 9)
    }

    @Test("LT-5: one activation sets an axis-separated scale from both pending fields")
    func separateAxesFromPendingText() {
        let draft = draftAwaitingLength(mode: .separateAxes)
        #expect(CalibrationValidator.makeScaleSummary(from: draft) == nil)

        let scale = activateApply(draft, pendingPrimary: "5", pendingSecondary: "10")
        #expect(abs((scale?.sx ?? 0) - 0.05) < 1e-12)
        #expect(abs((scale?.sy ?? 0) - 0.10) < 1e-12)
        #expect(scale?.isUniform == false)
    }

    // MARK: The primitive

    @Test("Nothing typed is not the same as nonsense typed")
    func readingDistinguishesEmptyFromUnusable() {
        #expect(CalibrationPendingLength.reading("", unit: .metre) == .none)
        #expect(CalibrationPendingLength.reading("  \n ", unit: .metre) == .none)
        #expect(CalibrationPendingLength.reading("abc", unit: .metre) == .unusable)
        #expect(CalibrationPendingLength.reading("5", unit: .metre) == .length(5))
    }

    @Test("The field's idle rendering round-trips back through the reader")
    func metricStringRoundTrips() {
        let rendered = CalibrationLengthField.metricString(12.5)
        #expect(!rendered.isEmpty)
        switch CalibrationPendingLength.reading(rendered, unit: .metre) {
        case .length(let value): #expect(abs(value - 12.5) < 1e-9)
        default: Issue.record("The field rendered \(rendered), which it cannot read back")
        }
    }
}
