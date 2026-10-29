import Foundation
import Testing
@testable import ZPDFUIPresentation

/// CR-107 and CR-108 — the two cross-presenter links the mock harness claimed to have.
///
/// Every UI package is tested against ``MockPresenterEnvironment``. A link that is declared
/// there and never fires is worse than an absent one: the suites that depend on it pass whatever
/// the product does, so the regression they exist to catch cannot be caught.
///
/// Old output, against the code before the fix:
///
/// ```
/// ✘ Test "Selecting on the canvas reaches the ledger, not only the other way round" recorded an
///   issue at MockEnvironmentWiringTests.swift:39:9: Expectation failed:
///   (environment.ledger.selectedRowIDs → []) == ([markup.id] → [5A504446-…-0000000003E8])
/// ✘ Test "Zoom to Selection selects the markup everywhere, not only on the canvas" recorded an
///   issue at MockEnvironmentWiringTests.swift:87:9: Expectation failed:
///   (environment.ledger.selectedRowIDs → []) == ([markup.id] → [5A504446-…-0000000003E8])
/// ✘ Test "Turning the page moves the canvas onto that page's markups" recorded an issue at
///   MockEnvironmentWiringTests.swift:113:9: Expectation failed:
///   (environment.canvas.viewport.pageID → 5A504446-…-000000000065) == (second.id → …066)
/// ✘ Test "Turning the page moves the status bar's page readout" recorded an issue at
///   MockEnvironmentWiringTests.swift:127:9: Expectation failed:
///   (environment.status.snapshot.pageLabel → "A-101") == (second.label → "A-102")
/// ✘ Suite "Mock environment wiring" failed after 0.016 seconds with 12 issues.
/// ```
@MainActor
@Suite("Mock environment wiring")
struct MockEnvironmentWiringTests {

    private func makeEnvironment() -> MockPresenterEnvironment { MockPresenters.makeEnvironment() }

    // MARK: - CR-107: canvas → ledger

    @Test("Selecting on the canvas reaches the ledger, not only the other way round")
    func canvasSelectionReachesTheLedger() throws {
        let environment = makeEnvironment()
        let markup = try #require(environment.canvas.visibleMarkups.first)

        environment.canvas.select(markupIDs: [markup.id], additive: false)

        #expect(environment.canvas.selectedMarkupIDs == [markup.id])
        #expect(
            environment.ledger.selectedRowIDs == [markup.id],
            "canvas → ledger mirroring is wired in the environment and must actually fire"
        )
    }

    @Test("An additive canvas selection reports the whole selection, not the addition")
    func additiveSelectionReportsEverything() throws {
        let environment = makeEnvironment()
        let markups = environment.canvas.visibleMarkups
        try #require(markups.count >= 2)
        let first = markups[0].id, second = markups[1].id

        var reported: [Set<UUID>] = []
        let mirror = environment.canvas.onSelectionChange
        environment.canvas.onSelectionChange = { ids in
            reported.append(ids)
            mirror?(ids)
        }

        environment.canvas.select(markupIDs: [first], additive: false)
        environment.canvas.select(markupIDs: [second], additive: true)

        #expect(reported == [[first], [first, second]])
        #expect(environment.ledger.selectedRowIDs == [first, second])
    }

    @Test("Re-selecting what is already selected reports nothing")
    func anUnchangedSelectionIsSilent() throws {
        let environment = makeEnvironment()
        let markup = try #require(environment.canvas.visibleMarkups.first)
        environment.canvas.select(markupIDs: [markup.id], additive: false)

        var reports = 0
        environment.canvas.onSelectionChange = { _ in reports += 1 }
        environment.canvas.select(markupIDs: [markup.id], additive: false)

        #expect(reports == 0, "an assignment that changes nothing must not wake the ledger")
    }

    @Test("Zoom to Selection selects the markup everywhere, not only on the canvas")
    func zoomingToAMarkupSelectsItEverywhere() throws {
        let environment = makeEnvironment()
        let markup = try #require(environment.project.markups.first)

        environment.canvas.zoomTo(markupID: markup.id)

        #expect(environment.canvas.selectedMarkupIDs == [markup.id])
        #expect(environment.ledger.selectedRowIDs == [markup.id])
    }

    @Test("Clearing the selection still reaches the ledger")
    func clearingReachesTheLedger() throws {
        let environment = makeEnvironment()
        let markup = try #require(environment.canvas.visibleMarkups.first)
        environment.canvas.select(markupIDs: [markup.id], additive: false)
        #expect(!environment.ledger.selectedRowIDs.isEmpty)

        environment.canvas.clearSelection()
        #expect(environment.ledger.selectedRowIDs.isEmpty)
    }

    // MARK: - CR-108: document → canvas and status

    @Test("Turning the page moves the canvas onto that page's markups")
    func turningThePageMovesTheCanvas() throws {
        let environment = makeEnvironment()
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        let second = pages[1]

        environment.document.goToNextPage()

        #expect(environment.document.currentPageID == second.id)
        #expect(environment.canvas.viewport.pageID == second.id)
        #expect(environment.canvas.viewport.pageIndex == second.index)
        #expect(environment.canvas.visibleMarkups.allSatisfy { $0.pageID == second.id })
    }

    @Test("Turning the page moves the status bar's page readout")
    func turningThePageMovesTheStatusBar() throws {
        let environment = makeEnvironment()
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        let second = pages[1]

        environment.document.goToPage(id: second.id)

        #expect(environment.status.snapshot.pageLabel == second.label)
        #expect(environment.status.snapshot.pageIndex == second.index)
        #expect(environment.status.snapshot.pageCount == pages.count)
    }

    @Test("Revealing a search hit carries the canvas and the status bar with it")
    func revealingASearchHitMovesEverything() throws {
        let environment = makeEnvironment()
        let pages = environment.document.pages
        let firstPageID = pages[0].id
        // Any query whose hits reach a second sheet; the point is the page move, not the query.
        let query = try #require(
            environment.project.searchHits.first { $0.pageID != firstPageID }?.snippet
        )
        environment.search.query = query
        let offPage = try #require(environment.search.hits.first { $0.pageID != firstPageID })

        environment.search.selectHit(id: offPage.id)

        #expect(environment.document.currentPageID == offPage.pageID)
        #expect(environment.canvas.viewport.pageID == offPage.pageID)
        #expect(environment.status.snapshot.pageLabel != pages[0].label)
    }

    @Test("Asking for the page already showing changes nothing and announces nothing")
    func navigatingToTheCurrentPageIsSilent() throws {
        let environment = makeEnvironment()
        let current = try #require(environment.document.currentPageID)

        var announcements = 0
        let wiring = environment.document.onPageChange
        environment.document.onPageChange = { page in
            announcements += 1
            wiring?(page)
        }
        environment.document.goToPage(id: current)

        #expect(announcements == 0)
    }
}
