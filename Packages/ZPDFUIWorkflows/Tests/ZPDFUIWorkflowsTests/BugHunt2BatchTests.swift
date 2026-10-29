import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// BH-305, BH-829, BH-830, BH-831, IM-143 and IM-144: the batch apply model tells the truth
/// about an unanswered search and a short run, re-previews itself, and refuses off-page insets.
@Suite("Batch apply, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2BatchTests {

    /// Old output: previewSentence == "No page matches this scope, so nothing will be placed."
    /// and scopeSentence == "Scope: Pages containing “FIRE” — 0 of 6 pages." under the caution
    /// that search is unavailable.
    @Test("An unavailable index never previews as 'no page matches'")
    func unavailableSearchIsNotZero() async {
        let pages = (0..<6).map { _ in UUID() }
        let model = BatchApplyModel()
        model.searchResolveDebounce = .zero
        model.onPlan = { values in
            BatchSearchScopeModelTests.plan(scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages)
        }
        model.onResolveSearchScope = { term in .unavailable(term: term, reason: "Search is unavailable.") }
        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        await BatchSearchScopeModelTests.settle(model)

        #expect(model.searchResolution?.isAvailable == false)
        #expect(!model.previewSentence.contains("No page matches"))
        #expect(model.previewSentence.contains("Nothing can be counted"))
        #expect(model.scopeSentence == nil)
        #expect(model.skipSentence == nil)
        #expect(model.canApply == false)
        // A real answer of none is still said as none.
        model.onResolveSearchScope = { term in BatchSearchScopeResolution(term: term, pageIDs: []) }
        model.searchTerm = "FIRE E"
        model.preview()
        await BatchSearchScopeModelTests.settle(model)
        #expect(model.previewSentence.contains("No page matches"))
    }

    /// Old output: progressDetail == "Placed 0. One Undo removes all of them." and onClose ran.
    @Test("A run that places fewer than previewed stays open and says so")
    func shortRunIsNotASuccess() async {
        for placed in [0, 7] {
            let model = BatchApplyModel()
            let plan = BatchApplyModelTests.plan(placements: 12, total: 20)
            model.onPlan = { _ in plan }
            model.onRun = { plan, _ in
                BatchApplyReceipt(createdMarkupIDs: Array(plan.includedPages.prefix(placed).map { _ in UUID() }))
            }
            var closed = false
            model.onClose = { closed = true }
            model.preview()
            await model.run()
            #expect(!closed, "placed \(placed) of 12")
            #expect(!model.progressDetail.contains("One Undo removes all of them"))
            #expect(model.progressDetail.contains(placed == 0 ? "Nothing was placed" : "Placed 7 of the 12 previewed"))
            #expect(model.plan == nil, "a fresh preview is required")
        }
    }

    @Test("A complete run still closes, and run-time skips of previewed pages count as accounted for")
    func completeRunCloses() async {
        let model = BatchApplyModel()
        let plan = BatchApplyModelTests.plan(placements: 4, total: 6)
        model.onPlan = { _ in plan }
        model.onRun = { plan, _ in
            BatchApplyReceipt(
                createdMarkupIDs: [UUID(), UUID(), UUID()],
                skippedPageIDs: [plan.includedPages[3].id]
            )
        }
        var closed = false
        model.onClose = { closed = true }
        model.preview()
        await model.run()
        #expect(closed)
    }

    /// Old output: after a navigator selection change the plan stayed nil — "Choose a scope to
    /// see how many will be placed." with Apply off — until an unrelated control was touched.
    @Test("A host-driven navigator selection re-previews by itself")
    func choicesRepreviewThemselves() async {
        let pages = (0..<5).map { _ in UUID() }
        let model = BatchApplyModel()
        model.previewCoalescing = .milliseconds(1)
        var planCalls = 0
        model.onPlan = { values in
            planCalls += 1
            return BatchSearchScopeModelTests.plan(scope: values.scope, matched: nil, allPages: pages)
        }
        model.scopeChoice = .navigatorSelection
        model.navigatorSelection = [pages[0], pages[2]]
        model.navigatorSelection = [pages[0], pages[2], pages[4]]
        #expect(model.plan == nil)
        for _ in 0..<200 where model.plan == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.plan?.placementCount == 3)
        #expect(planCalls == 1, "three quick choices, one coalesced preview")
    }

    /// Old output: insets of 5000 (or -36) previewed as "This will place 312 stamps" and
    /// Apply wrote markups whose centre was off every page.
    @Test("Negative or page-sized insets are refused before the count")
    func offPageInsetsAreRefused() {
        let model = BatchApplyModel(currentPageSize: PDFSizeValue(width: 842, height: 1191), pageCount: 12)
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 12) }
        model.preview()
        #expect(model.canApply)
        model.insetX = 5000
        model.preview()
        #expect(model.insetIssue != nil)
        #expect(model.canApply == false)
        #expect(model.previewSentence.contains("842"))
        model.insetX = -36
        model.preview()
        #expect(model.canApply == false)
        model.insetX = 36
        model.preview()
        #expect(model.insetIssue == nil)
        #expect(model.canApply)
        // Centred placement has no inset to check.
        model.insetX = -1
        model.anchorCorner = nil
        #expect(model.insetIssue == nil)
    }

    @Test("Scope defaults come from the current page and the page count")
    func seededDefaults() {
        let model = BatchApplyModel(currentPageSize: PDFSizeValue(width: 1191, height: 842), pageCount: 12)
        #expect(model.sizeWidthPoints == 1191)
        #expect(model.sizeHeightPoints == 842)
        #expect(model.rangeThrough == 12)
        #expect(model.maximumInsetPoints == 842)
        let unseeded = BatchApplyModel()
        #expect(unseeded.sizeWidthPoints == 2384)
        #expect(unseeded.rangeThrough == 1)
        #expect(unseeded.pageCount == nil)
    }
}
