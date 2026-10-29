import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Iteration 5, ui-presentation-measure: live finding L-06.
///
/// The calibration sheet draws every issue with ``CalibrationIssue/displaySeverity`` (the issue
/// list's `ZPDFInlineWarning`). Right after the two picks, before anything was typed, it drew
/// "Enter the real-world length of the picked dimension." in red. These tests read the draft the
/// way the sheet does — the bound draft with the length fields' pending text folded in — and check
/// what each issue would be drawn as.
@Suite("Iteration 5 calibration issue display (L-06)")
struct Iter5CalibrationIssueDisplayTests {

    private func pickedDraft(mode: CalibrationMode = .uniform) -> CalibrationDraft {
        var draft = CalibrationDraft(mode: mode)
        draft.primary = CalibrationAxisInput(
            start: PDFPointValue(x: 100, y: 100),
            end: PDFPointValue(x: 440, y: 100)
        )
        if mode == .separateAxes {
            draft.secondary = CalibrationAxisInput(
                start: PDFPointValue(x: 100, y: 100),
                end: PDFPointValue(x: 100, y: 400)
            )
        }
        return draft
    }

    /// What the sheet would draw for `draft` with `typed` in the length field.
    private func drawn(_ draft: CalibrationDraft, typed: String = "") -> [(CalibrationIssue, ZPDFSeverity)] {
        let validation = CalibrationValidator.validate(draft.resolvingPendingLengths(primary: typed))
        return validation.issues.map { ($0, $0.displaySeverity) }
    }

    /// Old output: `[(.missingPrimaryLength, .danger)]` — a red error before the person could type.
    @Test("Two points picked, nothing typed: the length prompt is guidance, not a red error, and Apply stays off")
    func pickedWithoutLengthIsNotAnError() {
        let draft = pickedDraft()
        let issues = drawn(draft)
        #expect(issues.map(\.0) == [.missingPrimaryLength])
        #expect(issues.first?.1 == .neutral, "drawn as \(String(describing: issues.first?.1))")
        #expect(!issues.contains { $0.1 == .danger })
        let validation = CalibrationValidator.validate(draft)
        #expect(!validation.canApply, "a missing length still holds Apply back")
        #expect(validation.applyAccessibilityValue == CalibrationIssue.missingPrimaryLength.message)
    }

    /// Old output: `.danger` for "Pick two points on the drawing before entering a length." on a
    /// fresh sheet.
    @Test("A fresh sheet shows no red error, only the next step")
    func freshSheetIsNotAnError() {
        let issues = drawn(CalibrationDraft())
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.1 == .neutral }, "\(issues.map { ($0.0.rawValue, $0.1.rawValue) })")
    }

    @Test("Separate axes and drawing scale: a value still to come is neutral too")
    func otherPendingInputsAreNeutral() {
        let separate = drawn(pickedDraft(mode: .separateAxes))
        #expect(Set(separate.map(\.0)) == [.missingPrimaryLength, .missingSecondaryLength])
        #expect(separate.allSatisfy { $0.1 == .neutral })

        let drawingScale = drawn(CalibrationDraft(mode: .drawingScale))
        #expect(drawingScale.map(\.0) == [.missingDrawingScale])
        #expect(drawingScale.first?.1 == .neutral)
    }

    @Test("A wrong length is still a red error the moment it is typed")
    func wrongInputStaysAnError() {
        let draft = pickedDraft()
        #expect(drawn(draft, typed: "0").map(\.0) == [.nonPositivePrimaryLength])
        #expect(drawn(draft, typed: "0").first?.1 == .danger)
        #expect(drawn(draft, typed: "12x").map(\.0) == [.unparseablePrimaryLength])
        #expect(drawn(draft, typed: "12x").first?.1 == .danger)
        // Identical points are a mistake, not a step still to come.
        var identical = draft
        identical.primary.end = identical.primary.start
        #expect(drawn(identical, typed: "5").contains { $0.0 == .identicalPrimaryPoints && $0.1 == .danger })
        // A valid length clears the prompt.
        #expect(drawn(draft, typed: "6").isEmpty)
    }

    @Test("Only the not-yet-given inputs are pending")
    func pendingInputSet() {
        let pending = CalibrationIssue.allCases.filter(\.isPendingInput)
        #expect(Set(pending) == [
            .missingPrimaryPoints, .missingSecondaryPoints,
            .missingPrimaryLength, .missingSecondaryLength, .missingDrawingScale
        ])
        #expect(pending.allSatisfy { $0.severity == .blocking })
    }
}
