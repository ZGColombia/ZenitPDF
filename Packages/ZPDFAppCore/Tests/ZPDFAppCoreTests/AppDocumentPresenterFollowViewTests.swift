import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Continuous scrolling's page change (`AppDocumentPresenter.followView(toPage:settle:)`): the
/// page the person scrolled to becomes current without being navigated to, so it neither wipes
/// a batch selection nor starts a snap-index extraction and a scale offer for every sheet a
/// fling passes.
@MainActor
@Suite("Following the view to a page")
struct AppDocumentPresenterFollowViewTests {

    private static func environment(pages count: Int) async throws -> (AppCoreEnvironment, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = DocumentSearchIndexTests.pages(count: count, documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, pages)
    }

    @Test("A multi-selection in the Navigator survives the view following another page")
    func keepsMultiSelection() async throws {
        let (environment, pages) = try await Self.environment(pages: 4)
        let document = environment.document
        document.selectPage(id: pages[0].id.rawValue, mode: .replace)
        document.selectPage(id: pages[2].id.rawValue, mode: .toggle)
        let serial = document.navigationSerial
        #expect(document.selectedPageIDs == [pages[0].id.rawValue, pages[2].id.rawValue])

        document.followView(toPage: pages[1].id.rawValue, settle: false)
        #expect(document.currentPageID == pages[1].id.rawValue)
        #expect(document.selectedPageIDs == [pages[0].id.rawValue, pages[2].id.rawValue], "the batch scope is kept")
        #expect(document.navigationSerial == serial, "following the view is not a navigation")
        #expect(environment.canvas.viewport.pageID == pages[1].id.rawValue, "the canvas presenter follows")
        #expect(environment.markup.pageID == pages[1].id, "the tools follow")
    }

    @Test("A single selected page moves with the view, and navigation still counts")
    func movesSingleSelection() async throws {
        let (environment, pages) = try await Self.environment(pages: 3)
        let document = environment.document
        let serial = document.navigationSerial
        document.followView(toPage: pages[2].id.rawValue, settle: true)
        #expect(document.selectedPageIDs == [pages[2].id.rawValue])
        #expect(document.navigationSerial == serial)
        // Following the page that is already current is nothing at all.
        document.followView(toPage: pages[2].id.rawValue, settle: true)
        #expect(document.navigationSerial == serial)
        document.goToPage(id: pages[0].id.rawValue)
        #expect(document.navigationSerial == serial + 1, "a navigation moves the serial")
        document.selectPage(id: pages[1].id.rawValue, mode: .replace)
        #expect(document.navigationSerial == serial + 2)
    }

    @Test("Scrolling past sheets defers the snap index and the scale offer until the view rests")
    func scrollChangeDefersSnapIndexAndScaleOffer() async throws {
        let (environment, pages) = try await Self.environment(pages: 5)
        environment.pageFollowDwell = .milliseconds(150)
        var built: [UUID] = []
        environment.snapIndexSource = { page in
            built.append(page.id.rawValue)
            return AppCoreEnvironment.SnapIndexBuild()
        }
        var offered: [UUID] = []
        environment.afterPageChange = { page in offered.append(page.id) }
        // The first sheet's own build, started by installing the source.
        #expect(await Self.wait { built == [pages[0].id.rawValue] })

        let document = environment.document
        for index in 1...3 { document.followView(toPage: pages[index].id.rawValue, settle: false) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(built == [pages[0].id.rawValue], "no extraction for a sheet scrolled past")
        #expect(offered.isEmpty, "no scale offer for a sheet scrolled past")

        #expect(await Self.wait { offered == [pages[3].id.rawValue] }, "the sheet the view rests on is offered once")
        #expect(await Self.wait { built == [pages[0].id.rawValue, pages[3].id.rawValue] })

        // A press (settle) or a navigation runs both at once.
        document.followView(toPage: pages[4].id.rawValue, settle: true)
        #expect(offered.last == pages[4].id.rawValue)
        document.goToPage(id: pages[1].id.rawValue)
        #expect(offered.last == pages[1].id.rawValue)
        #expect(await Self.wait { built.contains(pages[4].id.rawValue) && built.contains(pages[1].id.rawValue) })
        #expect(!built.contains(pages[2].id.rawValue))
    }

    @Test("The dim set of any page follows the ledger filter's rule for the current one")
    func dimSetPerPage() async throws {
        let (environment, pages) = try await Self.environment(pages: 2)
        let canvas = environment.canvas
        let sample = ZenitSampleProject.shared.markups
        var onFirst = sample[0]
        onFirst.pageID = pages[0].id.rawValue
        onFirst.pageIndex = 0
        onFirst.hidden = false
        var onSecond = sample[1]
        onSecond.pageID = pages[1].id.rawValue
        onSecond.pageIndex = 1
        onSecond.hidden = false
        canvas.adoptMarkupsForTesting([onFirst, onSecond])
        let revision = canvas.filterRevision
        canvas.setFilterBehavior(.dimNonMatching)
        canvas.setFilterMatches([])
        #expect(canvas.filterRevision == revision + 2)
        #expect(canvas.dimmedMarkupIDs(onPage: pages[1].id.rawValue) == [onSecond.id])
        #expect(canvas.dimmedMarkupIDs(onPage: pages[0].id.rawValue) == canvas.dimmedMarkupIDs)
        canvas.setFilterMatches(nil)
        #expect(canvas.dimmedMarkupIDs(onPage: pages[1].id.rawValue).isEmpty)
    }

    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
