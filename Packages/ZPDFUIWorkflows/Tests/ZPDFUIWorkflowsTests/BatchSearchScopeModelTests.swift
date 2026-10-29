import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The batch sheet's half of the search-term scope: a resolution that is asynchronous, may
/// be unavailable, and must never be shown against a term nobody asked about.
///
/// Everything here is driven through ``BatchApplyModel/preview()``, which is what the sheet
/// calls on every keystroke. Nothing calls the private resolution path directly, because the
/// claims are about what a person typing in the field sees.
@Suite("Batch apply: the search-term scope", .workflowsTierSerialised)
struct BatchSearchScopeModelTests {

    /// A plan whose counts are taken from the pages the request actually carries, so the
    /// model's own plumbing — not a fixture — decides the number under test.
    static func plan(
        scope: BatchPageScope,
        matched: Set<UUID>?,
        allPages: [UUID]
    ) -> BatchApplyPlan {
        let inScope: Set<UUID>
        switch scope {
        case .matchingSearchTerm: inScope = matched ?? []
        case .navigatorSelection(let ids): inScope = Set(ids)
        default: inScope = Set(allPages)
        }
        let decisions = allPages.enumerated().map { index, id in
            BatchPageDecision(
                id: id,
                index: index,
                label: "A-\(index + 1)",
                verdict: inScope.contains(id) ? .included : .outOfScope,
                anchorPoint: inScope.contains(id) ? PDFPointValue(x: 10, y: 10) : nil
            )
        }
        return BatchApplyPlan(
            scope: scope,
            anchor: .centered,
            skipsPagesAlreadyCarrying: true,
            decisions: decisions,
            itemNoun: .stamp,
            itemName: "Reviewed"
        )
    }

    /// A model over `pageCount` pages whose resolver answers from `matches`, recording every
    /// term it was asked about.
    @MainActor
    static func makeModel(
        pageCount: Int,
        matches: [String: Set<UUID>],
        pages: [UUID],
        asked: Asked
    ) -> BatchApplyModel {
        let model = BatchApplyModel()
        model.searchResolveDebounce = .zero
        model.onPlan = { values in
            plan(scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages)
        }
        model.onResolveSearchScope = { term in
            asked.terms.append(term)
            return BatchSearchScopeResolution(term: term, pageIDs: matches[term] ?? [])
        }
        return model
    }

    /// A box for what the resolver was asked, so a test can assert the query was not run.
    @MainActor
    final class Asked {
        var terms: [String] = []
    }

    /// Lets the debounced resolution land. `.zero` debounce still crosses a suspension
    /// point, so the assertion has to wait for the task rather than assume it ran.
    @MainActor
    static func settle(_ model: BatchApplyModel) async {
        for _ in 0..<200 where model.isResolvingScope {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("A term resolves to its pages, and the preview says which term it counted")
    @MainActor
    func aTermResolvesAndThePreviewNamesIt() async {
        let pages = (0..<12).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(
            pageCount: 12,
            matches: ["FIRE": Set(pages[0...3].map { $0 })],
            pages: pages,
            asked: asked
        )

        model.scopeChoice = .matchingSearchTerm
        model.preview()
        // Before a term there is nothing to resolve and nothing to promise.
        #expect(model.isResolvingScope == false)
        #expect(model.previewSentence.contains("Type the text"))
        #expect(model.canApply == false)

        model.searchTerm = "FIRE"
        model.preview()
        await Self.settle(model)

        #expect(asked.terms == ["FIRE"])
        #expect(model.plan?.placementCount == 4)
        #expect(model.canApply)
        let scope = model.scopeSentence ?? ""
        #expect(scope.contains("FIRE"))
        #expect(scope.contains("4 of 12"))
        #expect(model.previewSentence.contains("4"))
    }

    @Test("Apply is refused while the index is still being asked")
    @MainActor
    func nothingCanBeAppliedMidResolution() async {
        let pages = (0..<8).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(pageCount: 8, matches: ["FIRE": Set(pages)], pages: pages, asked: asked)
        model.searchResolveDebounce = .milliseconds(50)

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()

        #expect(model.isResolvingScope)
        #expect(model.plan == nil)
        #expect(model.canApply == false)
        // The sentence says the index is being asked, not that nothing matched. A person who
        // reads "no page matches" here changes a term that was right.
        #expect(model.previewSentence.contains("Finding the pages"))
        #expect(model.previewSentence.contains("No page matches") == false)
        #expect(model.scopeSentence == nil)

        await Self.settle(model)
        #expect(model.canApply)
    }

    @Test("A resolution for a term the person has moved on from is never shown")
    @MainActor
    func aStaleResolutionIsDiscarded() async {
        let pages = (0..<10).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(
            pageCount: 10,
            matches: ["FIRE": Set(pages[0...5].map { $0 }), "FIRE E": Set(pages[0...0].map { $0 })],
            pages: pages,
            asked: asked
        )
        model.searchResolveDebounce = .milliseconds(30)

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        // The next keystroke lands before the first resolution does.
        model.searchTerm = "FIRE E"
        model.preview()
        await Self.settle(model)

        // The debounce swallowed the first query outright, and whatever else happened the
        // count on screen belongs to the term in the field.
        #expect(asked.terms.last == "FIRE E")
        #expect(model.searchResolution?.term == "FIRE E")
        #expect(model.plan?.placementCount == 1)
        #expect((model.scopeSentence ?? "").contains("1 of 10"))
    }

    @Test("A term the drawing does not contain previews as none and refuses Apply")
    @MainActor
    func aZeroPageScopeSaysSoAndPlacesNothing() async {
        let pages = (0..<20).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(pageCount: 20, matches: [:], pages: pages, asked: asked)
        var ran = false
        model.onRun = { _, _ in ran = true; return BatchApplyReceipt() }

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "BALUSTRADE"
        model.preview()
        await Self.settle(model)

        #expect(model.plan?.placementCount == 0)
        #expect(model.previewSentence.contains("No page matches this scope"))
        #expect((model.scopeSentence ?? "").contains("0 of 20"))
        #expect(model.canApply == false)
        await model.run()
        #expect(ran == false, "a scope that resolved to zero pages must place nothing")
    }

    @Test("With no index behind the sheet the scope says search is unavailable, not that nothing matched")
    @MainActor
    func anUnavailableIndexIsNotAnEmptyResult() async {
        let pages = (0..<6).map { _ in UUID() }
        let model = BatchApplyModel()
        model.searchResolveDebounce = .zero
        model.onPlan = { values in
            Self.plan(scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages)
        }
        // Deliberately no `onResolveSearchScope`, which is what a drawing whose text index
        // failed to open looks like from here.

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        await Self.settle(model)

        #expect(model.searchResolution?.isAvailable == false)
        #expect(model.canApply == false)
        let caution = model.scopeCautionSentence ?? ""
        #expect(caution.contains("unavailable"))
    }

    @Test("A capped search says the count may be short")
    @MainActor
    func truncationIsStatedRatherThanHidden() async {
        let pages = (0..<40).map { _ in UUID() }
        let model = BatchApplyModel()
        model.searchResolveDebounce = .zero
        model.onPlan = { values in
            Self.plan(scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages)
        }
        model.onResolveSearchScope = { term in
            BatchSearchScopeResolution(
                term: term,
                pageIDs: Set(pages[0..<30]),
                wasTruncated: true,
                includesRecognisedText: true
            )
        }

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        await Self.settle(model)

        #expect(model.plan?.placementCount == 30)
        // Truncation is reported ahead of the OCR note, because a count that may be short is
        // the more consequential of the two for a batch about to be applied.
        #expect((model.scopeCautionSentence ?? "").contains("result limit"))
        #expect(model.canApply, "a capped count is still a real count; it is qualified, not refused")
    }

    @Test("Leaving the search scope drops its resolution rather than carrying the count over")
    @MainActor
    func changingScopeDropsTheResolution() async {
        let pages = (0..<15).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(
            pageCount: 15, matches: ["FIRE": Set(pages[0...2].map { $0 })], pages: pages, asked: asked
        )

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        await Self.settle(model)
        #expect(model.plan?.placementCount == 3)

        model.scopeChoice = .allPages
        #expect(model.plan == nil, "the count the person was shown does not survive the change")
        model.preview()
        #expect(model.plan?.placementCount == 15)
        #expect(model.searchResolution == nil)
        #expect(model.scopeCautionSentence == nil)
    }

    @Test("Retyping the same term does not re-query the index")
    @MainActor
    func anAnswerAlreadyOnHandIsReused() async {
        let pages = (0..<9).map { _ in UUID() }
        let asked = Asked()
        let model = Self.makeModel(
            pageCount: 9, matches: ["FIRE": Set(pages[0...1].map { $0 })], pages: pages, asked: asked
        )

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "FIRE"
        model.preview()
        await Self.settle(model)
        #expect(asked.terms == ["FIRE"])

        // Trailing whitespace is the same question, and so is a plain re-preview.
        model.searchTerm = "FIRE  "
        model.preview()
        await Self.settle(model)
        model.skipPagesAlreadyCarrying = false
        model.preview()
        await Self.settle(model)

        #expect(asked.terms == ["FIRE"], "one query, not one per keystroke")
        #expect(model.plan?.placementCount == 2)
    }

    // MARK: - The navigator-selection scope

    @Test("The navigator scope previews the whole selection, and an empty one as zero")
    @MainActor
    func theNavigatorScopePreviewsTheWholeSelection() {
        let pages = (0..<10).map { _ in UUID() }
        let model = BatchApplyModel()
        model.onPlan = { values in
            Self.plan(scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages)
        }

        model.scopeChoice = .navigatorSelection
        model.navigatorSelection = [pages[1], pages[4], pages[7]]
        model.preview()
        #expect(model.plan?.placementCount == 3)
        #expect((model.scopeSentence ?? "").contains("3 of 10"))
        #expect(model.canApply)

        model.navigatorSelection = []
        model.preview()
        #expect(model.plan?.placementCount == 0)
        #expect(model.previewSentence.contains("No page matches this scope"))
        #expect(model.canApply == false)
    }
}
