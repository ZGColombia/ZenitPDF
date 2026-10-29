import Foundation
import Testing
import ZPDFUIMeasurement
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// CR-179's shell half: the page id the panel cannot infer.
///
/// `ScaleRegionsPanelModel` discards a draft that belongs to another page, but it can only do
/// that if it knows which page it is on. `setRegions(_:)` without an id infers the page from the
/// regions it was handed — which works for every page that has at least one and fails for the
/// page that has none: an empty list says "no regions", never "a different page". Turning from a
/// half-drawn boundary to an empty sheet is exactly the case the inference cannot see, so the
/// draft survived, the boundary tool stayed armed over the wrong sheet, and Create would have
/// filed the region against the page it was drawn on while the duplicate-name check ran against
/// the page on screen.
///
/// The sample project is the right fixture by construction: page one carries "Stair Detail
/// 1:20", page three carries "Footing Detail 1:10", and **page two carries none**.
@MainActor
@Suite("Scale Regions across a page turn", .shellTierSerialised)
struct ScaleRegionPageTurnTests {

    /// A panel with a draft on the page the shell is currently showing, and a count of the
    /// canvas disarms it has asked for.
    @MainActor
    private final class Harness {
        let environment: ProjectShellEnvironment
        private(set) var armCount = 0
        private(set) var disarmCount = 0

        init() {
            environment = ProjectShellEnvironment.mock()
            environment.scaleRegions.onBeginPolygon = { [weak self] in self?.armCount += 1 }
            environment.scaleRegions.onCancelPolygonDrawing = { [weak self] in self?.disarmCount += 1 }
        }

        /// Arms the boundary tool and draws a triangle on the page currently showing.
        @discardableResult
        func drawDraftOnCurrentPage() throws -> PageDescriptor {
            let page = try #require(environment.document.currentPage)
            #expect(environment.scaleRegions.beginRegion())
            #expect(environment.scaleRegions.isAwaitingPolygon)
            #expect(environment.scaleRegions.completePolygon(
                [
                    PDFPointValue(x: 100, y: 100),
                    PDFPointValue(x: 400, y: 100),
                    PDFPointValue(x: 400, y: 400)
                ],
                pageID: page.id,
                pageLabel: page.label
            ))
            #expect(environment.scaleRegions.draft != nil)
            return page
        }
    }

    /// The page index of the sheet the sample project gives no Scale Regions.
    private func emptyPageIndex(_ environment: ProjectShellEnvironment) throws -> Int {
        let pages = environment.document.pages
        let index = try #require(
            pages.firstIndex { page in
                environment.document.scaleRegions(onPage: page.id).isEmpty
            },
            "the fixture needs a page with no Scale Regions on it"
        )
        return index
    }

    /// Old output, against the code before the fix — `refreshScaleRegions` calling
    /// `setRegions(onPage)` with no id, and no refresh on a page turn at all:
    ///
    /// ```
    /// ✘ Test "A page turn to a sheet with no regions throws the draft away" recorded an issue
    ///   at ScaleRegionPageTurnTests.swift:95:9: Expectation failed:
    ///   (environment.scaleRegions.draft → ScaleRegionDraft(id: 3910F90B-…, boundary: […],
    ///   pageID: 5A504446-0000-4000-8000-000000000065, pageLabel: "A-101",
    ///   name: "Scale Region 2", …)) == nil
    /// ✘ Test "A page turn to a sheet with no regions throws the draft away" recorded an issue
    ///   at ScaleRegionPageTurnTests.swift:100:9: Expectation failed:
    ///   (harness.disarmCount → 0) == 1
    /// ✘ Test "A page turn to a sheet with no regions throws the draft away" recorded an issue
    ///   at ScaleRegionPageTurnTests.swift:104:9: Expectation failed:
    ///   (environment.scaleRegions.regions → [ScaleRegionSummary(… name: "Stair Detail 1:20",
    ///   pageID: 5A504446-…-000000000065 …)]).isEmpty → false
    /// ✘ Test "A page turn to a sheet that has regions also throws the draft away" recorded an
    ///   issue at ScaleRegionPageTurnTests.swift:124:9: Expectation failed:
    ///   (environment.scaleRegions.draft → ScaleRegionDraft(… pageID: …065 …)) == nil
    /// ✘ Test run with 4 tests in 1 suite failed after 0.010 seconds with 5 issues.
    /// ```
    ///
    /// The third line is the wider half the same turn exposed: with no refresh on a page
    /// command at all, the panel was still *listing* page one's "Stair Detail 1:20" while page
    /// two was on the canvas.
    @Test("A page turn to a sheet with no regions throws the draft away")
    func aTurnToAnEmptyPageDiscardsTheDraft() throws {
        let harness = Harness()
        let environment = harness.environment
        let drawnOn = try harness.drawDraftOnCurrentPage()
        let empty = try emptyPageIndex(environment)
        try #require(environment.document.pages[empty].id != drawnOn.id)

        // Turn to the sheet that has no regions at all.
        environment.perform(.firstPage)
        for _ in 0..<empty { environment.perform(.nextPage) }
        #expect(environment.document.currentPageID == environment.document.pages[empty].id)

        #expect(
            environment.scaleRegions.draft == nil,
            "a boundary drawn on another sheet is still armed over this one"
        )
        #expect(!environment.scaleRegions.isAwaitingPolygon)
        #expect(
            harness.disarmCount == 1,
            "the canvas was left holding the boundary tool for a draft that no longer exists"
        )
        #expect(environment.scaleRegions.regions.isEmpty, "this sheet has no regions")
    }

    /// The same turn, the other direction: a sheet that *does* have regions could always infer
    /// its own page, so this half has always worked. It is pinned so the id being passed cannot
    /// break it.
    @Test("A page turn to a sheet that has regions also throws the draft away")
    func aTurnToAPopulatedPageDiscardsTheDraft() throws {
        let harness = Harness()
        let environment = harness.environment
        let drawnOn = try harness.drawDraftOnCurrentPage()
        let pages = environment.document.pages
        let populated = try #require(
            pages.firstIndex { $0.id != drawnOn.id && !environment.document.scaleRegions(onPage: $0.id).isEmpty },
            "the fixture needs a second page that does have regions"
        )

        environment.perform(.lastPage)
        #expect(environment.document.currentPageID == pages[populated].id)

        #expect(environment.scaleRegions.draft == nil)
        #expect(harness.disarmCount == 1)
        #expect(!environment.scaleRegions.regions.isEmpty)
    }

    @Test("Staying on the same page keeps the draft and disarms nothing")
    func stayingOnThePageKeepsTheDraft() throws {
        let harness = Harness()
        let environment = harness.environment
        try harness.drawDraftOnCurrentPage()

        // Previous at the first sheet is a no-op, and every other refresh is idempotent.
        environment.perform(.previousPage)
        environment.refreshScaleRegions()
        environment.perform(.scaleRegions)

        #expect(environment.scaleRegions.draft != nil, "a refresh threw away a draft on this very page")
        #expect(harness.disarmCount == 0)
        #expect(harness.armCount == 1)
    }

    /// The mechanism, at the seam, without the shell: an empty list carries no page, so the id
    /// is the only thing that can say which sheet the panel is on.
    @Test("An empty region list carries no page, so the id is what discards the draft")
    func anEmptyListCannotInferThePage() {
        let pages = ZenitSampleProject.shared.pages
        let drawnOn = pages[0], turnedTo = pages[1]

        func makeModel() -> (ScaleRegionsPanelModel, () -> Int) {
            let model = ScaleRegionsPanelModel()
            var disarms = 0
            model.onBeginPolygon = {}
            model.onCancelPolygonDrawing = { disarms += 1 }
            model.setRegions([], pageID: drawnOn.id)
            model.beginRegion()
            _ = model.completePolygon(
                [
                    PDFPointValue(x: 0, y: 0),
                    PDFPointValue(x: 10, y: 0),
                    PDFPointValue(x: 10, y: 10)
                ],
                pageID: drawnOn.id,
                pageLabel: drawnOn.label
            )
            return (model, { disarms })
        }

        // Without the id: an empty list is indistinguishable from "the same page, now cleared".
        let (inferring, inferringDisarms) = makeModel()
        inferring.setRegions([])
        #expect(inferring.draft != nil, "the control: inference cannot see a turn to an empty page")
        #expect(inferringDisarms() == 0)

        // With it, which is what the shell now passes.
        let (told, toldDisarms) = makeModel()
        told.setRegions([], pageID: turnedTo.id)
        #expect(told.draft == nil)
        #expect(toldDisarms() == 1)

        // `setCurrentPage` is the same statement with no list to hand.
        let (announced, announcedDisarms) = makeModel()
        announced.setCurrentPage(turnedTo.id)
        #expect(announced.draft == nil)
        #expect(announcedDisarms() == 1)
    }
}
