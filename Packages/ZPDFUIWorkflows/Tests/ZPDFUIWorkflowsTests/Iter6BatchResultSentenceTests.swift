import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// W-072: the Batch Apply sheet never showed its after-run sentence. `run()` left the running
/// state before it wrote the sentence, and the sheet rendered it only while running, so a short
/// run (BH-829) and a cancel were silent, and a short run's sheet fell back to "Choose a scope to
/// see how many will be placed." The model now carries the sentence the sheet shows after the
/// run, and a short or failed run offers Preview Again.
@Suite("Iteration 6 batch apply after-run sentence (W-072)", .workflowsTierSerialised)
@MainActor
struct Iter6BatchResultSentenceTests {

    /// Old output: no after-run sentence existed outside `isRunning`; previewSentence was
    /// "Choose a scope to see how many will be placed." with the scope already chosen.
    @Test("A short run's sentence is what the sheet shows after the run, and Preview Again is offered")
    func shortRunIsShown() async {
        let model = BatchApplyModel()
        let plan = BatchApplyModelTests.plan(placements: 12, total: 20)
        model.onPlan = { _ in plan }
        model.onRun = { plan, _ in
            BatchApplyReceipt(createdMarkupIDs: Array(plan.includedPages.prefix(7).map { _ in UUID() }))
        }
        model.preview()
        await model.run()

        #expect(!model.isRunning)
        let result = model.resultSentence ?? ""
        #expect(result.hasPrefix("Placed 7 of the 12 previewed; 5 could not be placed."))
        #expect(model.resultIsShortfall)
        #expect(model.needsFreshPreview)
        #expect(model.previewSentence == "Not counted since the last run.")
        #expect(!model.canApply)

        // Preview Again: a fresh count, Apply live again, and the short run still reported.
        model.preview()
        #expect(!model.needsFreshPreview)
        #expect(model.canApply)
        #expect(model.resultSentence == result)

        // A new choice is a new batch: the old run's sentence goes.
        model.anchorCorner = .topLeft
        #expect(model.resultSentence == nil)
        #expect(!model.resultIsShortfall)
    }

    /// Old output: "Batch cancelled. Nothing was placed." only in progressDetail, never shown.
    @Test("A cancelled run says so after it stops, keeps its plan, and needs no fresh preview")
    func cancelIsShown() async {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 12) }
        model.onRun = { _, _ in .cancelled }
        model.preview()
        await model.run()

        #expect(model.resultSentence == "Batch cancelled. Nothing was placed.")
        #expect(!model.resultIsShortfall)
        #expect(!model.needsFreshPreview)
        #expect(model.canApply)
    }

    @Test("A failed run shows its receipt's message, not a second sentence, and offers Preview Again")
    func failedRunOffersPreviewAgain() async {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 312) }
        model.onRun = { _, _ in
            BatchApplyReceipt(
                createdMarkupIDs: (0..<40).map { _ in UUID() },
                failureMessage: "The drawing could not be written to after 40 pages."
            )
        }
        model.preview()
        await model.run()

        #expect(model.resultSentence == nil)
        #expect(model.receipt?.failureMessage == "The drawing could not be written to after 40 pages.")
        #expect(model.needsFreshPreview)
        #expect(model.previewSentence == "Not counted since the last run.")
    }

    @Test("A complete run closes the sheet and leaves nothing to report")
    func completeRunCloses() async {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 4) }
        model.onRun = { plan, _ in BatchApplyReceipt(createdMarkupIDs: plan.includedPages.map { _ in UUID() }) }
        var closed = false
        model.onClose = { closed = true }
        model.preview()
        await model.run()

        #expect(closed)
        #expect(model.resultSentence == nil)
        #expect(!model.needsFreshPreview)
    }
}
