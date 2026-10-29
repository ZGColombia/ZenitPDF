import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// NL-DOCS-11: a revision matched by sheet number, reviewed before it is trusted, kept with the
/// project, and compared sheet by sheet from the card. Rev B of the 30-sheet set has one sheet
/// inserted (X-999 at position 3) and one renamed with a revision mark (A-102 → A-102-B).
@MainActor
@Suite("Documents — revisions matched by sheet", .appTierSerialised)
struct NextLevelDocumentsRevisionMatchTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Writes Rev B from the fixture itself: 31 sheets, labels as described.
    private func writeRevisionB(from fixture: URL, to url: URL) async throws -> [String] {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: fixture)
        let labels = try await provider.pageLabels(of: opened.handle).allLabels()
        var pages: [ComposedPage] = []
        var written: [String] = []
        for index in 0..<30 {
            if index == 3 {
                pages.append(ComposedPage(document: opened.handle, pageIndex: 5, label: "X-999"))
                written.append("X-999")
            }
            let label = index == 1 ? "A-102-B" : labels[index]
            pages.append(ComposedPage(document: opened.handle, pageIndex: index, label: label))
            written.append(label)
        }
        _ = try await provider.composeDocument(pages, to: DocumentDestination(url: url))
        await provider.close(opened.handle)
        return written
    }

    @Test("The matcher on the set: 29 exact, 1 renamed with its evidence, 1 added, none dropped")
    func matcherCounts() {
        let set = (0..<30).map { (pageID: "p\($0)", label: String(format: "S-%03d", $0), explicit: true, size: CGSize(width: 2592, height: 1728), pdfIndex: $0) }
        var revision = set.map { (label: $0.label, explicit: true, size: $0.size) }
        revision[1].label = "S-001-B"
        revision.insert((label: "X-999", explicit: true, size: CGSize(width: 2592, height: 1728)), at: 3)
        let matching = ZenitPDFProjectDocument.matchSheets(set: set, revision: revision)
        #expect(matching.pairs.filter { $0.basis == .exactLabel }.count == 29)
        #expect(matching.pairs.filter { $0.basis == .normalisedLabel }.map(\.old) == [1])
        #expect(matching.addedInNew == [3])
        #expect(matching.removedFromOld.isEmpty)
        #expect(matching.newIndex(forOldIndex: 3) == 4, "S-003 moved one place down past the inserted sheet")
    }

    @Test("Dropping Rev B: the review shows every pair and its evidence, a correction is kept, reopen restores it, the card compares the right sheet")
    func reviewKeepAndCompare() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nl-docs-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("RevSet.pdf", calibrate: false, fixture: fixture.url)
        let package = directory.appendingPathComponent("Rev.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)
        let revB = directory.appendingPathComponent("Rev B.pdf")
        let labelsB = try await writeRevisionB(from: fixture.url, to: revB)
        #expect(labelsB.count == 31)

        var captured: (model: SheetMatchReviewModel, rowID: String)?
        let previous = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { model, rowID, _ in captured = (model, rowID); return {} }
        defer { ZenitPDFProjectDocument.sheetMatchReviewPresenter = previous }

        var added = false
        harness.document.addRevision(fromDroppedFile: revB) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added && captured != nil })
        let review = try #require(captured)
        #expect(review.model.rows.count == 30)
        #expect(review.model.rows.filter { $0.basis == .exactLabel }.count == 29)
        let renamed = try #require(review.model.guessedRows.first)
        #expect(renamed.setLabel == "A-102" && review.model.revisionLabels[renamed.partner ?? -1] == "A-102-B")
        #expect(SheetMatchReviewModel.evidenceText(renamed.basis).contains("revision mark"))
        #expect(review.model.addedRevisionPages == [3], "X-999 is added")

        // A correction: sheet 5 (A-105 in the set) is paired by hand with revision page 6 — its match anyway, now manual.
        review.model.setPartner(6, forSetIndex: 5)
        #expect(review.model.rows[5].basis == .manualOverride)
        review.model.accept(revisionID: review.rowID)
        let summaryID = try #require(harness.document.newestRevision?.id)
        let pages = harness.core.document.pages
        #expect(await AppTestSupport.wait { harness.document.revisionSheetPairs[summaryID]?[pages[3].id] == 4 })

        // The card: A-104 (set position 3) compares with revision page 4, not 3 (X-999).
        #expect(harness.document.prepareCompareWithPreviousRevision(pageID: pages[3].id))
        let compare = try #require(harness.document.comparePresenter)
        #expect(compare.comparisonRevisionID == summaryID)
        #expect(harness.document.revisionPages[summaryID]?.pageIndex == 4)

        // Set compare report (NL-DOCS-13) on three sheets, with the pairing that decided each.
        // The document's own comparator reaches GeometryService, which a test process cannot
        // launch, so every comparison here fails — and the report says so (U-079). Until U-079
        // a failed comparison was printed as "unchanged, 0 differences", which is what this block
        // asserted and why it passed.
        let (rows, complete) = await harness.document.setCompareRows(only: [pages[0].id, pages[1].id, pages[3].id])
        #expect(complete)
        #expect(rows.map(\.setSheet) == ["A-101", "A-102", "A-104"])
        #expect(rows.map(\.status) == [.failed, .failed, .failed])
        #expect(rows.map(\.differences) == [0, 0, 0])
        #expect(rows[1].revisionSheet == "A-102-B")
        #expect(rows[1].evidence.hasPrefix("Sheet number with a revision mark — check; not compared: "))
        let csv = ZenitPDFProjectDocument.setCompareCSV(rows)
        #expect(csv.hasPrefix("Sheet,Revision sheet,Status,Differences,Affected measurements,Pairing\nA-101,A-101,failed,0,0,\"Same sheet number; not compared: "))
        // Compared for real, in process over the document's compare provider: no row fails and
        // A-102 is reported renamed. (Rev B is PDFKit's re-composition of the same sheets, and the
        // comparison still finds differences in it — see the iteration-4 report; not asserted.)
        let compareProvider = try #require(harness.document.compareProvider)
        let inProcess = RevisionComparator(source: InProcessRevisionDocumentSource(provider: compareProvider))
        let compared = await harness.document.setCompareRows(
            only: [pages[0].id, pages[1].id, pages[3].id], compareSheet: { try await inProcess.compare($0) }
        )
        #expect(compared.complete)
        #expect(!compared.rows.contains { $0.status == .failed })
        #expect(compared.rows.map(\.status)[1] == .renamed)
        #expect(compared.rows.map(\.evidence) == ["Same sheet number", "Sheet number with a revision mark — check", "Same sheet number"])
        let reportURL = directory.appendingPathComponent("compare.pdf")
        try ZenitPDFProjectDocument.writeSetComparePDF(rows, title: "Set compare: Rev B", complete: complete, to: reportURL)
        #expect(CGPDFDocument(reportURL as CFURL)?.numberOfPages == 1)

        // Carry Forward (NL-DOCS-12): a 2.5 m wall on A-104 lands on Rev B's A-104 (page 4),
        // re-measured; the old sheet leaves the set (kept); one ⌘Z undoes all of it.
        let core = harness.core
        _ = try await core.commands.calibrate(
            page: PageID(pages[3].id), first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: PageID(pages[3].id), kind: .measurement,
            tool: .polylength, subject: "Wall",
            geometry: MeasurementGeometry(pageID: PageID(pages[3].id), points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 350, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        _ = try await core.commands.perform(.addMarkup(wall))
        var reported: CarryForwardReport?
        let previousReport = ZenitPDFProjectDocument.carryForwardReportPresenter
        ZenitPDFProjectDocument.carryForwardReportPresenter = { report, _, _ in reported = report }
        defer { ZenitPDFProjectDocument.carryForwardReportPresenter = previousReport }
        let report = try #require(await harness.document.carryForward([PageID(pages[3].id)], window: nil))
        #expect(reported != nil)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.oldValue == Decimal(string: "2.5") && report.rows.first?.newValue == Decimal(string: "2.5"))
        // NL-DOCS-12 (iteration 1, appcore): the carry compares each old sheet with its revision.
        // A test process has no geometry service, so no comparison can be made, and a carry that
        // cannot compare flags the measurement for review instead of claiming it unchanged (it
        // read `.unchanged` only because nothing was compared). The value is carried exactly.
        #expect(report.rows.first?.delta == 0 && report.rows.first?.classification == .needsReview)
        let slipped = await core.session.pageDescriptors
        #expect(slipped.count == 30)
        #expect(slipped[3].index == 4 && slipped[3].documentID != pages3DrawingID(harness), "Rev B's A-104 stands where A-104 stood")
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(string: "2.5"), "the carried wall counts once")
        await core.commands.undo()
        await core.refresh()
        #expect(await core.session.pageDescriptors.map(\.id.rawValue) == pages.map(\.id), "one ⌘Z restores the set")
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(string: "2.5"))

        // Kept with the project, with the confirmed evidence.
        try await Task.sleep(nanoseconds: 300_000_000)
        try await save(harness.document, to: package, .saveOperation)
        harness.controller.window?.close()
        harness.document.close()
        let reopenedPackage = try await ProjectPackage.open(at: package, resolving: .recover)
        let stored = try await reopenedPackage.read { db -> [RevisionSheetRecord] in
            let id = try String.fetchOne(db, sql: "SELECT id FROM revision_entry LIMIT 1") ?? ""
            return try DocumentSetStore.sheets(revision: id, in: db)
        }
        try await reopenedPackage.close()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(stored.count == 31)
        #expect(stored.first { $0.revisionPageIndex == 6 }?.evidence == "manual")
        #expect(stored.first { $0.revisionPageIndex == 3 }?.evidence == "added")
        #expect(stored.first { $0.revisionPageIndex == 2 }?.evidence == "label", "A-102-B → A-102, by number with a mark")
    }

    private func pages3DrawingID(_ harness: Fix2Harness) -> DocumentID? { harness.document.drawing?.documentID }
}
