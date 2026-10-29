import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// NL-DOCS-02 (ADR-0022): a page's `index` is its index in its
/// own PDF and never moves; the set order is separate. Reorder, save, reopen: every markup is
/// on the sheet it was drawn on and every sheet shows its own PDF page.
struct NextLevelDocumentsReorderTests {

    private func workspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-nl-docs-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func note(on page: ZPDFContracts.PageDescriptor, documentID: DocumentID) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .polylength,
            subject: "On \(page.label)",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Old output: after `.reorderPage(from: 0, to: 2)` A-103's `index` became 1, so the canvas
    /// drew PDF page 1 (A-102) under A-103's markup; after save and reopen the archive gave
    /// A-103's identity to the page at PDF index 1 (A-102), so the markup moved to A-102.
    @Test("Reorder keeps each sheet's PDF page, and survives save and reopen with markups on their sheets")
    func reorderSaveReopen() async throws {
        let directory = try workspace("reorder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let a103 = fixture.pages[2]
        #expect(a103.label == "A-103" && a103.index == 2)
        let markup = note(on: a103, documentID: fixture.documentID)
        _ = try await session.apply(.addMarkup(markup))

        let environment = try await AppCoreEnvironment.make(session: session, documentID: fixture.documentID)
        _ = try await environment.commands.perform(.reorderPage(from: 0, to: 2))

        let reordered = await session.pageDescriptors
        #expect(reordered.prefix(3).map(\.label) == ["A-102", "A-103", "A-101"])
        #expect(reordered.prefix(3).map(\.index) == [1, 2, 0], "each sheet keeps its own PDF page")
        let geometryDigest = await session.markup(markup.id)?.geometry
        #expect(geometryDigest == markup.geometry)

        let packageURL = directory.appendingPathComponent("Reorder.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Reorder", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        // A fresh open mints new identities in PDF order; adoption restores both.
        let fresh = fixture.pages.map { page -> ZPDFContracts.PageDescriptor in
            var copy = page
            copy.id = PageID(UUID())
            return copy
        }
        let adopted = TakeoffArchive.adoptingStoredPageIDs(fresh, stored: stored)
        #expect(adopted.prefix(3).map(\.label) == ["A-102", "A-103", "A-101"], "the set order is restored")
        #expect(adopted.map(\.index).sorted() == Array(0..<30))
        let restored = try TakeoffSession(documentID: DocumentID(UUID()), pages: adopted)
        try await restored.hydrate(markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs)
        let hydrated = try #require(await restored.markup(markup.id))
        let page = try #require(adopted.first { $0.id == hydrated.pageID })
        #expect(page.label == "A-103" && page.index == 2, "the markup is on the sheet it was drawn on")
        #expect(hydrated.geometry == markup.geometry)

        // Undo of the reorder restores the PDF order.
        await environment.commands.undo()
        #expect(await session.pageDescriptors.prefix(3).map(\.label) == ["A-101", "A-102", "A-103"])
    }

    @Test("An archive written before v13 has no positions and keeps its PDF order")
    func noPositionsKeepsOrder() {
        let documentID = DocumentID(UUID())
        let box = PageBoxes(media: PDFRect(x: 0, y: 0, width: 100, height: 100))
        let pages = (0..<3).map {
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: $0, label: "\($0 + 1)", boxes: box)
        }
        let stored = TakeoffArchive.StoredTakeoff(
            pageIDsByIndex: [:], scales: [], pageScaleIDs: [:], markups: [], hasSavedTakeoff: true
        )
        #expect(TakeoffArchive.adoptingStoredPageIDs(pages, stored: stored) == pages)
    }

    /// Old output: hydration stamped the session's document on the
    /// markup of a sheet this drawing no longer has, it showed in the ledger, and the next save
    /// deleted its page row and — by cascade — the markup itself.
    @Test("A stored markup on a page the drawing no longer has is refused, said, and kept in the file")
    func foreignMarkupIsRefusedAndKept() async throws {
        let directory = try workspace("foreign")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let onLast = note(on: fixture.pages[29], documentID: fixture.documentID)
        let onFirst = note(on: fixture.pages[0], documentID: fixture.documentID)
        _ = try await session.apply(.addMarkup(onLast))
        _ = try await session.apply(.addMarkup(onFirst))

        let packageURL = directory.appendingPathComponent("Foreign.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Foreign", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        // Reopened against a drawing of ten sheets: sheet 30 is not in it.
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery"); return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        let tenSheets = TakeoffArchive.adoptingStoredPageIDs(Array(fixture.pages.prefix(10)), stored: stored)
        let restored = try TakeoffSession(documentID: DocumentID(UUID()), pages: tenSheets)
        try await restored.hydrate(markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs)
        #expect(await restored.markup(onLast.id) == nil, "not re-parented into this drawing")
        #expect(await restored.markup(onFirst.id) != nil)
        #expect(await restored.refusedMarkupIDs == [onLast.id])
        let state = await restored.takeoffState()
        #expect(state.heldMarkupIDs == [onLast.id.rawValue.uuidString])

        try await TakeoffArchive.write(state, into: reopened)
        _ = try await reopened.save()
        try await reopened.close()
        guard case .opened(let again) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("second reopen required recovery"); return
        }
        let second = try #require(try await TakeoffArchive.read(from: again))
        try await again.close()
        #expect(Set(second.markups.map(\.id)) == [onLast.id, onFirst.id], "the refused markup survived the save")
    }
}
