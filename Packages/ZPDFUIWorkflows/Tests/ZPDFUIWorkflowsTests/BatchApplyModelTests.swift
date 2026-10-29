import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The scoped batch apply sheet's state, driven without a window.
///
/// The claims here are the safety ones: the person cannot apply a count they have not been
/// shown, changing the scope invalidates the count they *were* shown, and a cancelled run
/// reports that nothing was placed.
@Suite("Batch apply model", .workflowsTierSerialised)
struct BatchApplyModelTests {

    static func plan(placements: Int, skipped: Int = 0, total: Int? = nil) -> BatchApplyPlan {
        let totalPages = total ?? (placements + skipped)
        var decisions: [BatchPageDecision] = []
        for index in 0..<totalPages {
            let verdict: BatchPageDecision.Verdict
            if index < placements {
                verdict = .included
            } else if index < placements + skipped {
                verdict = .skippedAlreadyPresent
            } else {
                verdict = .outOfScope
            }
            decisions.append(BatchPageDecision(
                id: UUID(),
                index: index,
                label: "A-\(index + 1)",
                verdict: verdict,
                anchorPoint: verdict == .included ? PDFPointValue(x: 10, y: 10) : nil
            ))
        }
        return BatchApplyPlan(
            scope: .allPages,
            anchor: .corner(.bottomRight, insetX: 36, insetY: 36),
            skipsPagesAlreadyCarrying: true,
            decisions: decisions,
            itemNoun: .stamp,
            itemName: "Reviewed"
        )
    }

    @Test("Apply is refused until the scope has been previewed")
    @MainActor
    func applyNeedsAPreview() async {
        let model = BatchApplyModel()
        var ran = false
        model.onRun = { _, _ in ran = true; return BatchApplyReceipt() }
        #expect(model.canApply == false)
        #expect(model.previewSentence.contains("Choose a scope"))

        await model.run()
        #expect(ran == false, "nothing may run before a count has been shown")

        model.onPlan = { _ in Self.plan(placements: 312) }
        model.preview()
        #expect(model.canApply)
        #expect(model.previewSentence.contains("312"))
        await model.run()
        #expect(ran)
    }

    @Test("Changing the scope drops the count the person was shown")
    @MainActor
    func changingTheScopeInvalidatesThePreview() {
        let model = BatchApplyModel()
        model.onPlan = { values in
            if case .pageRange = values.scope { return Self.plan(placements: 12, total: 312) }
            return Self.plan(placements: 312)
        }
        model.preview()
        #expect(model.plan?.placementCount == 312)

        // The exact way a person previews 12 and applies 312, if the plan survived the change.
        model.scopeChoice = .pageRange
        #expect(model.plan == nil)
        #expect(model.canApply == false)
        model.preview()
        #expect(model.plan?.placementCount == 12)
    }

    @Test("An empty scope cannot be applied, and says so")
    @MainActor
    func emptyScopeIsRefused() {
        let model = BatchApplyModel()
        model.onPlan = { _ in Self.plan(placements: 0, total: 40) }
        model.preview()
        #expect(model.canApply == false)
        #expect(model.previewSentence.contains("No page matches"))
    }

    @Test("The skip rule is previewed, not discovered afterwards")
    @MainActor
    func skipsArePreviewed() {
        let model = BatchApplyModel()
        model.onPlan = { _ in Self.plan(placements: 15, skipped: 5) }
        model.preview()
        let skip = model.skipSentence
        #expect(skip?.contains("5") == true)
        #expect(skip?.contains("Reviewed") == true)
        #expect(model.plan?.placementCount == 15)
    }

    @Test("A cancelled run reports that nothing was placed and leaves the sheet open")
    @MainActor
    func cancelledRunReportsNothingPlaced() async {
        let model = BatchApplyModel()
        var closed = false
        model.onClose = { closed = true }
        model.onPlan = { _ in Self.plan(placements: 200) }
        model.onRun = { _, _ in .cancelled }
        model.preview()
        await model.run()

        #expect(model.receipt?.wasCancelled == true)
        #expect(model.receipt?.placementCount == 0)
        #expect(model.progressDetail.contains("Nothing was placed"))
        #expect(closed == false, "a cancelled batch leaves the sheet where the person left it")
    }

    @Test("Scope and anchor values become the request the engine is given")
    @MainActor
    func choicesBecomeARequest() {
        let model = BatchApplyModel()
        model.scopeChoice = .matchingSize
        model.sizeWidthPoints = 1191
        model.sizeHeightPoints = 842
        model.anchorCorner = .topLeft
        model.insetX = 24
        model.insetY = 18

        guard case .matchingSize(let width, let height, let tolerance) = model.scope else {
            Issue.record("expected a size scope")
            return
        }
        #expect(width == 1191)
        #expect(height == 842)
        #expect(tolerance == 2)

        guard case .corner(let corner, let insetX, let insetY) = model.anchor else {
            Issue.record("expected a corner anchor")
            return
        }
        #expect(corner == .topLeft)
        #expect(insetX == 24)
        #expect(insetY == 18)

        model.anchorCorner = nil
        #expect(model.anchor == .centered)
    }

    @Test("A late progress report cannot resurrect a finished batch")
    @MainActor
    func lateProgressIsDropped() {
        let model = BatchApplyModel()
        model.report(fraction: 0.6, detail: "Preparing 120 of 200")
        #expect(model.progressFraction == nil, "nothing is running, so nothing is reported")
        #expect(model.progressDetail.isEmpty)
    }
}
