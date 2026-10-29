import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 4 re-fix, render-extract-search, U-081: the batch sheet shows, beside the
/// page count, that a `NOT` the index cannot run was not applied.
///
/// ``BatchApplySheet`` renders ``BatchApplyModel/scopeCautionSentence`` in the warning style
/// directly above ``BatchApplyModel/previewSentence``, so what this model says there is what
/// the person reads next to the count before pressing Apply. The resolution the host hands
/// back is shaped exactly as ``BatchSearchScopeResolver`` builds it from a real index
/// (`Iter4RBatchExclusionNoteTests` in ZPDFAppCore proves that half).
@Suite("Iter4R batch sheet: dropped exclusion beside the count", .workflowsTierSerialised)
struct Iter4RBatchExclusionNoteModelTests {

    @Test("U-081: 'ROOM OR NOT CORRIDOR' previews its count with the not-excluded note beside it")
    @MainActor
    func theNoteSitsBesideTheCount() async {
        let pages = (0..<8).map { _ in UUID() }
        let model = BatchApplyModel()
        model.searchResolveDebounce = .zero
        model.onPlan = { values in
            BatchSearchScopeModelTests.plan(
                scope: values.scope, matched: values.searchMatchedPageIDs, allPages: pages
            )
        }
        model.onResolveSearchScope = { term in
            // What the resolver returns for this term over a drawing where sheets 1 and 5 say ROOM.
            BatchSearchScopeResolution(
                term: term,
                pageIDs: [pages[1], pages[5]],
                droppedExclusions: term.contains("NOT CORRIDOR") ? ["CORRIDOR"] : []
            )
        }

        model.scopeChoice = .matchingSearchTerm
        model.searchTerm = "ROOM OR NOT CORRIDOR"
        model.preview()
        await BatchSearchScopeModelTests.settle(model)

        #expect(model.plan?.placementCount == 2)
        #expect((model.scopeSentence ?? "").contains("2 of 8"))
        let note = SearchExclusionNote.text(for: ["CORRIDOR"])
        #expect(note == "\u{201C}CORRIDOR\u{201D} was not excluded: put NOT between two words, as in room NOT corridor")
        // Old output: nil — the count "2 of 8" stood alone and read as ROOM pages without CORRIDOR.
        #expect(model.scopeCautionSentence == note + ".")
        // Qualified, not refused: the count is real, it answers a different question than typed.
        #expect(model.canApply)

        // A runnable exclusion drops the note with the resolution it belonged to.
        model.searchTerm = "ROOM NOT STAIR"
        model.preview()
        await BatchSearchScopeModelTests.settle(model)
        #expect(model.searchResolution?.term == "ROOM NOT STAIR")
        #expect(model.scopeCautionSentence == nil)
    }
}
