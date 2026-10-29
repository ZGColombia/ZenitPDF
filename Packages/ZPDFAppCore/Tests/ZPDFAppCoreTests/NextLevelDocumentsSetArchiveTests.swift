import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// NL-DOCS-04 foundation (ADR-0027 (documents)): one project, one set, three drawings. Each
/// drawing's takeoff is stored under its own document row; reopening restores the set order, every
/// markup on its sheet, and a ledger over the whole set.
struct NextLevelDocumentsSetArchiveTests {

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func length(on page: ZPDFContracts.PageDescriptor, points: Double, documentID: DocumentID) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .polylength,
            subject: "Wall on \(page.label)",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 100 + points, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test("Three drawings in one project: order, markups on each, ledger over the set, sources untouched")
    @MainActor
    func threeDrawingsRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-nl-docs-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory.appendingPathComponent("a"))
        let b = try await OpenedFixture.open(.mixedPageSizes, in: directory.appendingPathComponent("b"))
        let c = try await OpenedFixture.open(.titleBlockSheet, in: directory.appendingPathComponent("c"))
        let shaBefore = try [a.url, b.url, c.url].map(sha256)

        let packageURL = directory.appendingPathComponent("Set.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Set", originalPDF: a.url)
        let rowA = try await TakeoffArchive.documentRows(of: package)[0]
        let rowB = try await package.addDocument(originalPDF: b.url, displayName: "B", pageCount: b.pages.count)
        let rowC = try await package.addDocument(originalPDF: c.url, displayName: "C", pageCount: c.pages.count)

        // B dropped at position 0, C at position 2: B's pages, A's first page, C, then the rest of A.
        let setPages = b.pages + [a.pages[0]] + c.pages + Array(a.pages.dropFirst())
        let session = try TakeoffSession(documentID: a.documentID, pages: setPages, units: .metric)
        // 100 pt = 1 m on one sheet of each drawing; lengths of 200, 300 and 400 pt → 2 + 3 + 4 = 9 m.
        let measured: [(ZPDFContracts.PageDescriptor, Double, DocumentID)] = [
            (a.pages[3], 200, a.documentID), (b.pages[1], 300, b.documentID), (c.pages[0], 400, c.documentID)
        ]
        for (page, points, documentID) in measured {
            _ = try await session.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre
            )
            _ = try await session.apply(.addMarkup(length(on: page, points: points, documentID: documentID)))
        }
        let before = await session.orderedMarkups.map(\.id)

        try await TakeoffArchive.writeSet(
            await session.takeoffState(), into: package,
            documentRows: [a.documentID: rowA, b.documentID: rowB, c.documentID: rowC]
        )
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery"); return
        }
        #expect(try await TakeoffArchive.documentRows(of: reopened) == [rowB, rowA, rowC], "drawings in set order")
        let stored = try await TakeoffArchive.readSet(from: reopened)
        try await reopened.close()

        // A fresh open mints new page identities per drawing.
        func fresh(_ fixture: OpenedFixture) -> [ZPDFContracts.PageDescriptor] {
            fixture.pages.map { var page = $0; page.id = PageID(UUID()); return page }
        }
        let adopted = TakeoffArchive.adoptingStoredSet(
            [(rowA, fresh(a)), (rowB, fresh(b)), (rowC, fresh(c))], stored: stored
        )
        #expect(adopted.pages.map(\.id) == setPages.map(\.id), "every sheet back, in the dropped order")
        let takeoff = try #require(adopted.takeoff)
        let restored = try TakeoffSession(documentID: DocumentID(UUID()), pages: adopted.pages, units: .metric)
        try await restored.hydrate(markups: takeoff.markups, scales: takeoff.scales, pageScaleIDs: takeoff.pageScaleIDs)
        #expect(Set(await restored.orderedMarkups.map(\.id)) == Set(before))
        for (page, _, _) in measured {
            let onPage = await restored.orderedMarkups.filter { $0.pageID == page.id }
            #expect(onPage.count == 1, "one markup on \(page.label) of its own drawing")
        }
        #expect(await restored.refusedMarkupIDs.isEmpty)

        let environment = try await AppCoreEnvironment.make(session: restored, documentID: DocumentID(UUID()))
        await environment.refresh()
        let total = try #require(environment.ledger.grandTotals.total("planLength"))
        #expect(total.value == Decimal(9), "2 m + 3 m + 4 m over the whole set")
        #expect(try [a.url, b.url, c.url].map(sha256) == shaBefore, "no source drawing was written")
    }
}
