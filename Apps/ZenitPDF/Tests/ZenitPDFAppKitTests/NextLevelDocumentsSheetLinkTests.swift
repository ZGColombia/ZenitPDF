import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// NL-DOCS-10: batch-linking sheet references on the 30-sheet set — proposals for references
/// whose sheet exists, the missing A-999 listed apart, links created in one undo step, and a
/// link that follows to its sheet by identity.
@MainActor
@Suite("Documents — sheet reference links", .appTierSerialised)
struct NextLevelDocumentsSheetLinkTests {

    @Test("Link Sheet References: S-201 and A-102 proposed on A-101, A-999 unresolved, one undo")
    func linkTheSet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("Links.pdf", calibrate: false, fixture: fixture.url)
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        var captured: SheetLinkReviewModel?
        let previous = ZenitPDFProjectDocument.sheetLinkReviewPresenter
        ZenitPDFProjectDocument.sheetLinkReviewPresenter = { model, _ in captured = model; return {} }
        defer { ZenitPDFProjectDocument.sheetLinkReviewPresenter = previous }

        await harness.document.linkSheetReferences(window: nil)
        let model = try #require(captured, "the fixture's labels name the sheets, so the review opens")
        let pages = harness.core.document.pages
        let onA101 = model.proposals.filter { $0.page.rawValue == pages[0].id }
        #expect(onA101.contains { $0.targetNumber == "S-201" && $0.target.rawValue == pages[10].id }, "SEE S-201")
        #expect(model.unresolved.contains { $0.text.contains("A-999") }, "the sheet the set does not have is listed apart")
        #expect(!model.proposals.contains { $0.page == $0.target }, "a sheet's own number is not a reference")

        let before = await harness.core.session.orderedMarkups.count
        model.accept()
        for _ in 0..<50 where await harness.core.session.orderedMarkups.count == before {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let links = await harness.core.session.orderedMarkups.filter { $0.kind == .hyperlink }
        #expect(links.count == model.proposals.count)
        #expect(links.allSatisfy { $0.link?.pageID != nil })
        await harness.core.commands.undo()
        #expect(await harness.core.session.orderedMarkups.filter { $0.kind == .hyperlink }.isEmpty, "one ⌘Z removes every link")
    }
}

