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

/// Loop iteration 4, render-extract-search: the set compare report lists a sheet whose
/// comparison failed as `failed`, never `unchanged` (U-079), and its Pairing column reads the
/// evidence stored with each pair instead of guessing from the labels (U-080).
@MainActor
@Suite("Iter4 set compare report", .appTierSerialised)
struct Iter4SetCompareReportTests {

    @Test("U-080: the Pairing column follows the stored evidence")
    func pairingTextFollowsEvidence() {
        typealias Document = ZenitPDFProjectDocument
        // Old output: every pair read "Same sheet number" unless its labels differed, whatever
        // decided it — a position fallback of two unnumbered sheets and a pair a person chose alike.
        #expect(Document.setComparePairingText(.position, renamed: false) == "Same place and paper size, no number — check")
        #expect(Document.setComparePairingText(.manual, renamed: true) == "Paired by you")
        #expect(Document.setComparePairingText(.manual, renamed: false) == "Paired by you")
        #expect(Document.setComparePairingText(.label, renamed: false) == "Same sheet number")
        #expect(Document.setComparePairingText(.label, renamed: true) == "Sheet number with a revision mark — check")
        #expect(Document.setComparePairingText(nil, renamed: false) == "Same sheet number", "a pair stored without evidence keeps the label reading")
    }

    @Test("U-079: a failed row is counted in the header and says why in the CSV")
    func failedRowsAreCounted() {
        typealias Row = ZenitPDFProjectDocument.SetCompareRow
        let rows = [
            Row(setSheet: "A-101", revisionSheet: "A-101", status: .unchanged, differences: 0, affectedMeasurements: 0, evidence: "Same sheet number"),
            Row(setSheet: "A-102", revisionSheet: "A-102", status: .failed, differences: 0, affectedMeasurements: 0,
                evidence: ZenitPDFProjectDocument.setCompareFailureText(pairing: "Same sheet number", error: CompareFault.coreGraphicsFailure(operation: "render"))),
        ]
        #expect(ZenitPDFProjectDocument.setCompareFailureNote(rows) == "1 sheets could not be compared and are listed as failed, not as unchanged.")
        #expect(ZenitPDFProjectDocument.setCompareFailureNote(Array(rows.prefix(1))) == nil)
        let csv = ZenitPDFProjectDocument.setCompareCSV(rows)
        #expect(csv.contains("\nA-102,A-102,failed,0,0,Same sheet number; not compared: CoreGraphics failed during render\n"))
        #expect(ZenitPDFProjectDocument.isSetCompareCancellation(CancellationError()))
        #expect(ZenitPDFProjectDocument.isSetCompareCancellation(CompareFault.cancelled))
        #expect(!ZenitPDFProjectDocument.isSetCompareCancellation(CompareFault.coreGraphicsFailure(operation: "render")))
    }

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func writeRevisionB(from fixture: URL, to url: URL) async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: fixture)
        let labels = try await provider.pageLabels(of: opened.handle).allLabels()
        let pages = (0..<30).map { ComposedPage(document: opened.handle, pageIndex: $0, label: labels[$0]) }
        _ = try await provider.composeDocument(pages, to: DocumentDestination(url: url))
        await provider.close(opened.handle)
    }

    @Test("U-079 / U-080: a comparison that throws is a failed row, a cancel adds none, and a hand-made pair reads 'Paired by you'")
    func reportRowsFromTheDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("it4-set-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("RevSet.pdf", calibrate: false, fixture: fixture.url)
        defer {
            harness.controller.window?.close()
            harness.document.close()
        }
        // A revision is kept with the project, so the project needs a package first.
        try await save(harness.document, to: directory.appendingPathComponent("Rev.zpdfproj"))
        let revB = directory.appendingPathComponent("Rev B.pdf")
        try await writeRevisionB(from: fixture.url, to: revB)

        var captured: (model: SheetMatchReviewModel, rowID: String)?
        let previous = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { model, rowID, _ in captured = (model, rowID); return {} }
        defer { ZenitPDFProjectDocument.sheetMatchReviewPresenter = previous }
        var added = false
        harness.document.addRevision(fromDroppedFile: revB) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added && captured != nil })
        let review = try #require(captured)
        // Sheet 5 is paired by hand with its own match: the pair is the same, its evidence manual.
        review.model.setPartner(5, forSetIndex: 5)
        review.model.accept(revisionID: review.rowID)
        let summaryID = try #require(harness.document.newestRevision?.id)
        let pages = harness.core.document.pages
        #expect(await AppTestSupport.wait { harness.document.revisionSheetPairEvidence[summaryID]?[pages[5].id] == .manual })

        // Every comparison fails with a fault that is not a cancel.
        let failing = await harness.document.setCompareRows(only: [pages[0].id, pages[5].id], compareSheet: { _ in
            throw CompareFault.coreGraphicsFailure(operation: "render")
        })
        #expect(failing.complete)
        // Old output: both rows `unchanged`, 0 differences, evidence "Same sheet number".
        #expect(failing.rows.map(\.status) == [.failed, .failed])
        #expect(failing.rows[0].evidence == "Same sheet number; not compared: CoreGraphics failed during render")
        #expect(failing.rows[1].evidence == "Paired by you; not compared: CoreGraphics failed during render")

        // A cancel inside a sheet's comparison ends the run, incomplete, with no row for it.
        let cancelled = await harness.document.setCompareRows(only: [pages[0].id, pages[5].id], compareSheet: { _ in
            throw CompareFault.cancelled
        })
        #expect(!cancelled.complete)
        #expect(cancelled.rows.isEmpty, "old output: an 'unchanged' row for the sheet the cancel cut off")

        // The document's own comparator reaches GeometryService, which a test process cannot
        // launch: every comparison fails, and the row says so.
        let viaService = await harness.document.setCompareRows(only: [pages[0].id])
        #expect(viaService.rows.map(\.status) == [.failed], "old output: unchanged — a sheet nobody compared")
        #expect(viaService.rows.first?.evidence.hasPrefix("Same sheet number; not compared: ") == true)

        // A real comparison, in process over the document's compare provider: compared (so not
        // failed), and the manual pair says it was made by hand.
        let compareProvider = try #require(harness.document.compareProvider)
        let inProcess = RevisionComparator(source: InProcessRevisionDocumentSource(provider: compareProvider))
        let compared = await harness.document.setCompareRows(
            only: [pages[0].id, pages[5].id], compareSheet: { try await inProcess.compare($0) }
        )
        #expect(compared.complete)
        #expect(compared.rows.allSatisfy { $0.status == .changed || $0.status == .unchanged }, "\(compared.rows.map(\.status))")
        // Old output: "Same sheet number" for both.
        #expect(compared.rows.map(\.evidence) == ["Same sheet number", "Paired by you"])
    }
}
