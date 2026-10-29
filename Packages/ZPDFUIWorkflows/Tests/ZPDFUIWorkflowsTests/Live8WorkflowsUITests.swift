import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Live test 8, area l8-workflows: the workflow package's halves of L-54 (the sheet name
/// review shows a reading whole), L-57/L-93 (Revision Compare offers Add Revision…) and
/// L-58/L-60 (the batch sheet's one dismiss, its question shown whole, and a preview that asks
/// for the text a header needs).
@Suite("Live test 8 — workflow sheets (package)", .workflowsTierSerialised)
@MainActor
struct Live8WorkflowsUITests {

    // MARK: - L-54

    @Test("L-54: the sheet number field is as wide as the longest number read")
    func numberFieldFitsTheReading() {
        let number = "A-00-0-001-REV-B"
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measured = Double((number as NSString).size(withAttributes: [.font: font]).width)
        let width = SheetNameReviewModel.numberFieldWidth(for: ["A-101", number])
        // Old: a fixed 90 pt, so "DOKUMENTNUMMER A-00-0-001" showed as "DOKUME…".
        #expect(measured + SheetNameReviewModel.numberFieldPadding > 90, "the fixture must be wider than the old field")
        #expect(width >= measured + SheetNameReviewModel.numberFieldPadding)
        #expect(SheetNameReviewModel.numberFieldWidth(for: ["1"]) == SheetNameReviewModel.numberFieldMinimumWidth)
        #expect(SheetNameReviewModel.numberFieldWidth(for: [String(repeating: "W", count: 80)]) == SheetNameReviewModel.numberFieldMaximumWidth)

        let model = SheetNameReviewModel(
            rows: [SheetNameReviewRow(pageIndex: 0, pageLabel: "Page 1", number: number, title: "VII Takplan Demo", sourceText: "Read in your box", confidence: 1)],
            onAccept: { _ in },
            onCancel: {}
        )
        #expect(model.numberFieldWidth == width)
    }

    // MARK: - L-57 / L-93

    @Test("L-93: with fewer than two revisions Revision Compare says so and offers Add Revision…")
    func revisionCompareEmptyState() {
        // Old: "Select two revisions to compare" / "Choose a baseline and a comparison revision
        // above." over two empty pop-ups, with no way to add a revision.
        for count in [0, 1] {
            let state = RevisionCompareModel.emptyState(revisionCount: count, canAddRevision: true)
            #expect(state.title == "This drawing has no revision to compare with yet")
            #expect(state.actionTitle == "Add Revision…")
        }
        let withoutHook = RevisionCompareModel.emptyState(revisionCount: 0, canAddRevision: false)
        #expect(withoutHook.actionTitle == nil)
        #expect(withoutHook.message.contains("File ▸ Drawing Set ▸ Add Revision…"))
        let pair = RevisionCompareModel.emptyState(revisionCount: 2, canAddRevision: true)
        #expect(pair.title == "Select two revisions to compare")
        #expect(pair.actionTitle == nil)

        let model = RevisionCompareModel()
        #expect(model.onAddRevision == nil)
        var asked = 0
        model.onAddRevision = { asked += 1 }
        model.onAddRevision?()
        #expect(asked == 1)
        let overlay = RevisionOverlayModel()
        #expect(overlay.onAddRevision == nil)
    }

    // MARK: - L-58 / L-60

    @Test("L-58/L-60: the batch sheet's own Close is its one dismiss")
    func batchSheetHasOneDismiss() {
        // Old: the host added a Done bar under Close and Apply.
        #expect(BatchApplySheet.wantsHostDoneButton == false)
    }

    @Test("L-60: a question too long for the label column is shown above its field")
    func longPromptGoesAbove() {
        let headerPrompt = "Text for each sheet. {page}, {n}, {date}, {project} and {document} are filled in; {n=101} numbers from 101."
        // Old: always in the 92 pt label column — "Text for each…".
        #expect(BatchApplySheet.promptPlacement(for: headerPrompt) == .above)
        #expect(BatchApplySheet.promptPlacement(for: "Note") == .beside)
    }

    @Test("L-60: before the text a header needs is typed, the preview asks for the text")
    func previewAsksForTheText() {
        let model = BatchApplyModel()
        model.placementPrompt = "Text for each sheet."
        model.requiresPromptedText = true
        model.onPlan = { values in
            values.promptedText.isEmpty ? nil : BatchApplyModelTests.plan(placements: 3, total: 3)
        }
        model.preview()
        // Old: "Choose a scope to see how many will be placed." with All pages chosen.
        #expect(model.previewSentence == "Type the text for each sheet to see how many will be placed.")
        #expect(!model.canApply)
        model.promptedText = "Sheet {page}"
        model.preview()
        #expect(model.canApply)
        #expect(model.previewSentence != "Type the text for each sheet to see how many will be placed.")

        // A stamp's optional free text keeps the old sentence before any preview.
        let stamp = BatchApplyModel()
        stamp.placementPrompt = "Note"
        #expect(stamp.previewSentence == "Choose a scope to see how many will be placed.")
    }
}
