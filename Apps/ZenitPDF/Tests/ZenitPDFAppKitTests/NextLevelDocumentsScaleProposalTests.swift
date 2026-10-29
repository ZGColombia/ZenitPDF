import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// The open-time scale proposal is made per sheet — the sheet on
/// screen when the drawing opens and every sheet turned to — never for sheet 1 only. Old
/// behaviour: `ZenitPDFProjectDocument.swift:1115` read page 0 alone. Headless.
@MainActor
@Suite("Documents — per-sheet scale proposal", .appTierSerialised)
struct NextLevelDocumentsScaleProposalTests {

    @Test("Turning to sheet 3 offers sheet 3's own printed scale, and the sheet-1 offer comes down")
    func proposalFollowsTheSheet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("Scales.pdf", calibrate: false, fixture: fixture.url)
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let pages = harness.core.document.pages
        #expect(pages.count == 30)
        #expect(await AppTestSupport.wait(upTo: 20) {
            harness.document.pendingScaleProposals.values.contains { $0.pageID.rawValue == pages[0].id }
        }, "the sheet on screen at open is offered its scale")

        harness.shell.goToPage(id: pages[2].id)
        #expect(await AppTestSupport.wait(upTo: 20) {
            harness.document.pendingScaleProposals.values.contains { $0.pageID.rawValue == pages[2].id }
        }, "sheet 3 is offered its own scale")
        #expect(!harness.document.pendingScaleProposals.values.contains { $0.pageID.rawValue == pages[0].id },
                "an offer belongs to its sheet and leaves with it")
        let offer = try #require(harness.document.pendingScaleProposals.values.first { $0.pageID.rawValue == pages[2].id })
        #expect(offer.proposal.ratio.numerator == 1 && offer.proposal.ratio.denominator == 100, "SCALE 1:100, as printed")
    }
}
