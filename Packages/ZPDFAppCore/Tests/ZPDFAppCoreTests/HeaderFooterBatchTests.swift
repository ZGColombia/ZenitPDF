import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-PDF-20: headers, footers and sheet numbers as the batch apply's second client.
@Suite("Batch headers, footers and sheet numbers")
struct HeaderFooterBatchTests {

    @Test("A header on 60 sheets is one undo, its fields filled per sheet and frozen")
    @MainActor
    func headerOnSixtySheets() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 60)
        let producer = try #require(environment.headerFooterBatchProducer(
            template: "{project} · {page} · {date}",
            now: StampAndBatchApplyTests.placementInstant,
            author: "Estimator"
        ))
        let plan = environment.planBatchApply(
            producer, request: BatchApplyRequest(scope: .allPages, anchor: .corner(.topLeft, insetX: 24, insetY: 18))
        )
        #expect(plan.placementCount == 60)
        let receipt = await environment.runBatchApply(producer, plan: plan)
        #expect(receipt.placementCount == 60)
        await environment.refresh()
        let records = await environment.session.orderedMarkups
        #expect(records.count == 60)
        // Page 7 (index 6) reads its own label; the date is the batch's one instant.
        let seventh = try #require(records.first { $0.pageID == pages[6].id })
        #expect(seventh.kind == .text)
        #expect(seventh.caption == "Harbour Works · A-007 · 2026-08-25")
        #expect(seventh.printable)

        // One undo removes all sixty.
        await environment.commands.undo()
        await environment.refresh()
        #expect(environment.snapshot.markups.isEmpty)
        #expect(environment.commands.undoManager.canUndo == false)
    }

    @Test("Sheet numbering runs from the start value with its prefix, and a second pass skips sheets that have it")
    @MainActor
    func numberingAndSkip() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 5)
        let producer = try #require(environment.headerFooterBatchProducer(
            template: "Sheet {n}", numberPrefix: "S-", numberStart: 101,
            now: StampAndBatchApplyTests.placementInstant, author: "Estimator"
        ))
        let request = BatchApplyRequest(scope: .allPages, anchor: .corner(.bottomRight, insetX: 24, insetY: 18))
        _ = await environment.runBatchApply(producer, plan: environment.planBatchApply(producer, request: request))
        await environment.refresh()
        let records = await environment.session.orderedMarkups
        let captions = pages.compactMap { page in records.first { $0.pageID == page.id }?.caption }
        #expect(captions == ["Sheet S-101", "Sheet S-102", "Sheet S-103", "Sheet S-104", "Sheet S-105"])

        let again = environment.planBatchApply(producer, request: request)
        #expect(again.placementCount == 0, "every sheet already carries its number")
    }

    @Test("An empty template is refused rather than placing blank text")
    @MainActor
    func emptyTemplateIsRefused() async throws {
        let (environment, _, _) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 1)
        #expect(environment.headerFooterBatchProducer(template: "   ") == nil)
    }
}
