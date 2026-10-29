import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Feature 33's application half: every open drawing is a search source for every *other*
/// drawing, and a hit from another drawing switches tabs before it reveals.
@MainActor
@Suite(.appTierSerialised)
struct ProjectSearchWiringTests {

    @Test("Two tabs wire each other as external search sources, never themselves")
    func tabsWireEachOther() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "SourceA.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "SourceB.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })

        // The real presenters replace the placeholders asynchronously; the window rewires on
        // each replacement, so once both are real, both must see exactly the other.
        await first.settleTextIndexing()
        await second.settleTextIndexing()
        #expect(await AppTestSupport.wait {
            (first.searchPresenter as? AppSearchPresenter)?.externalSources.isEmpty == false
                && (second.searchPresenter as? AppSearchPresenter)?.externalSources.isEmpty == false
        }, "the fan-out sources were never installed")

        let firstSources = try #require(first.searchPresenter as? AppSearchPresenter).externalSources
        let secondSources = try #require(second.searchPresenter as? AppSearchPresenter).externalSources
        #expect(firstSources.map(\.documentID) == [second.documentIdentity],
                "the first drawing's only source is the second drawing")
        #expect(secondSources.map(\.documentID) == [first.documentIdentity],
                "the second drawing's only source is the first drawing")

        // Closing a tab drops it from the survivor's sources — results must never point at
        // a tab that no longer exists.
        controller.requestCloseTab(id: second.documentIdentity)
        #expect(await AppTestSupport.wait {
            (first.searchPresenter as? AppSearchPresenter)?.externalSources.isEmpty == true
        }, "the closed drawing was left wired as a source")

        first.close()
    }

    @Test("Choosing a hit from another drawing fronts that drawing's tab")
    func foreignHitSwitchesTab() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "RevealA.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "RevealB.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })
        #expect(controller.activeDocument === second, "the newly attached tab starts in front")

        // A hit that lives in the *first* drawing, chosen while the second is in front. The
        // page id is the first drawing's own — the hit was produced by that drawing's index.
        let firstCore = try #require(first.core)
        let pageID = try #require(await firstCore.session.firstPageID)
        let hit = ZPDFUIPresentation.SearchHit(
            id: UUID(),
            documentID: first.documentIdentity,
            documentTitle: "RevealA",
            pageID: pageID.rawValue,
            pageIndex: 0,
            pageLabel: "1",
            source: .pdfText,
            snippet: "fixture",
            sourceDocumentID: first.documentIdentity,
            sourceDocumentTitle: "RevealA"
        )
        // Through the presenter's own reveal hook — the same closure a click in the results
        // list fires — so the whole chain is exercised: presenter, document, window.
        await second.settleTextIndexing()
        let presenter = try #require(second.searchPresenter as? AppSearchPresenter)
        presenter.onReveal?(hit)

        #expect(controller.activeDocument === first,
                "a foreign hit must front the drawing it belongs to")

        first.close()
        second.close()
    }
}
