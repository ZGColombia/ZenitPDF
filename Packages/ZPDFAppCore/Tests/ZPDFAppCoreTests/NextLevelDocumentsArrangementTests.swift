import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// Round 2 documents: a drawing's sheets inserted into a project (NL-DOCS-04), sheets removed
/// from the set and put back (NL-DOCS-07), and a sheet's view — rotation and crop — which
/// changes no quantity (NL-DOCS-07/16). Every expected value is hand-derived: 100 pt = 1 m.
struct NextLevelDocumentsArrangementTests {

    private func length(on page: ZPDFContracts.PageDescriptor, points: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            // Deliberately a stranger's identity: the session stamps the page's own drawing.
            documentID: DocumentID(UUID()),
            pageID: page.id,
            kind: .measurement,
            tool: .polylength,
            subject: "Wall on \(page.label)",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 100 + points, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private func calibrate(_ session: TakeoffSession, _ page: ZPDFContracts.PageDescriptor) async throws {
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
    }

    @MainActor
    private func planLength(_ session: TakeoffSession) async throws -> Decimal? {
        let environment = try await AppCoreEnvironment.make(session: session, documentID: DocumentID(UUID()))
        await environment.refresh()
        return environment.ledger.grandTotals.total("planLength")?.value
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-nl-docs-arrange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Inserting a drawing's sheets: set order, markups stamped with their drawing, ledger over both, one undo")
    @MainActor
    func insertDrawing() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await OpenedFixture.open(.mixedPageSizes, in: root.appendingPathComponent("a"))
        let b = try await OpenedFixture.open(.titleBlockSheet, in: root.appendingPathComponent("b"))
        let session = try TakeoffSession(documentID: a.documentID, pages: a.pages, units: .metric)

        let inserted = try await session.apply(.insertPages(b.pages, at: 1))
        let expected = [a.pages[0].id] + b.pages.map(\.id) + a.pages.dropFirst().map(\.id)
        #expect(await session.pageOrderIDs == expected, "B's sheets after A's first")

        try await calibrate(session, a.pages[0])
        try await calibrate(session, b.pages[0])
        _ = try await session.apply(.addMarkup(length(on: a.pages[0], points: 250)))   // 2.5 m
        _ = try await session.apply(.addMarkup(length(on: b.pages[0], points: 150)))   // 1.5 m
        let stamped = await session.orderedMarkups.map(\.documentID)
        #expect(stamped == [a.documentID, b.documentID], "each markup carries its page's drawing")
        #expect(try await planLength(session) == Decimal(4), "2.5 m + 1.5 m")

        // Undo of the insertion (the markups on B are undone first in a real stack; here the
        // B markup is removed by hand to reach the insertion's state).
        let bMarkup = await session.orderedMarkups[1].id
        _ = try await session.apply(.removeMarkup(bMarkup))
        let redo = try await session.revert(inserted.inverse)
        #expect(await session.pageOrderIDs == a.pages.map(\.id))
        _ = try await session.revert(redo)
        #expect(await session.pageOrderIDs == expected, "redo brings B's sheets back with the same identities")
    }

    @Test("Remove from Set keeps the sheet and its markups aside; the ledger drops it; undo and a reopen are exact")
    @MainActor
    func removeFromSet() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await OpenedFixture.open(.set30SheetsTitleBlocks, in: root.appendingPathComponent("a"))
        let pages = Array(a.pages.prefix(3))
        let session = try TakeoffSession(documentID: a.documentID, pages: pages, units: .metric)
        for page in pages { try await calibrate(session, page) }
        _ = try await session.apply(.addMarkup(length(on: pages[0], points: 200)))   // 2 m
        _ = try await session.apply(.addMarkup(length(on: pages[1], points: 300)))   // 3 m
        _ = try await session.apply(.addMarkup(length(on: pages[2], points: 400)))   // 4 m
        #expect(try await planLength(session) == Decimal(9))

        let removal = try await session.apply(.setPagesExcluded([pages[1].id], excluded: true))
        #expect(await session.pageOrderIDs == [pages[0].id, pages[2].id])
        #expect(try await planLength(session) == Decimal(6), "2 m + 4 m: the removed sheet's 3 m leaves the ledger")
        #expect(await session.excludedPageDescriptors.map(\.id) == [pages[1].id])
        let state = await session.takeoffState()
        #expect(state.setAsideMarkups.count == 1, "the 3 m markup is kept, set aside")

        // ⌘Z brings the sheet and its 3 m back in place.
        let redo = try await session.revert(removal.inverse)
        #expect(await session.pageOrderIDs == pages.map(\.id))
        #expect(try await planLength(session) == Decimal(9))
        _ = try await session.revert(redo)
        #expect(try await planLength(session) == Decimal(6))

        // Save, reopen: still removed, still 6 m; Restore to Set brings back 9 m.
        let packageURL = root.appendingPathComponent("Set.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Set", originalPDF: a.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery"); return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        #expect(stored.excludedPageIDs == [pages[1].id])

        let fresh = pages.map { page -> ZPDFContracts.PageDescriptor in var copy = page; copy.id = PageID(UUID()); return copy }
        let adopted = TakeoffArchive.adoptingStoredPageIDs(fresh, stored: stored)
        let restored = try TakeoffSession(documentID: a.documentID, pages: adopted, units: .metric)
        try await restored.hydrate(markups: stored.markups, scales: stored.scales, pageScaleIDs: stored.pageScaleIDs)
        await restored.restoreArrangement(excluded: stored.excludedPageIDs, views: stored.pageViews)
        #expect(await restored.pageOrderIDs == [pages[0].id, pages[2].id])
        #expect(try await planLength(restored) == Decimal(6))
        #expect(await restored.refusedMarkupIDs.isEmpty, "the set-aside markup is not refused")
        _ = try await restored.apply(.setPagesExcluded([pages[1].id], excluded: false))
        #expect(await restored.pageOrderIDs == pages.map(\.id), "restored where it was")
        #expect(try await planLength(restored) == Decimal(9), "its scale came back with it: 3 m again")
    }

    @Test("The last sheet cannot be removed from the set")
    func lastSheetStays() async throws {
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: page.documentID, pages: [page])
        await #expect(throws: DocumentCommandError.self) {
            try await session.apply(.setPagesExcluded([page.id], excluded: true))
        }
        #expect(await session.pageOrderIDs == [page.id])
    }

    @Test("A sheet's view rotation and crop change no quantity, undo in one step, and survive a reopen")
    @MainActor
    func viewRotationAndCrop() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await OpenedFixture.open(.titleBlockSheet, in: root.appendingPathComponent("a"))
        let page = a.pages[0]
        let session = try TakeoffSession(documentID: a.documentID, pages: [page], units: .metric)
        try await calibrate(session, page)
        _ = try await session.apply(.addMarkup(length(on: page, points: 425)))   // 4.25 m
        let before = try await planLength(session)
        #expect(before == Decimal(string: "4.25"))

        let crop = PDFRect(x: 50, y: 60, width: 300, height: 200)
        let change = try await session.apply(.setPageViews([page.id: PageViewSettings(rotation: 450, crop: crop)]))
        #expect(await session.pageView(of: page.id) == PageViewSettings(rotation: 90, crop: crop), "450° is a quarter turn")
        #expect(try await planLength(session) == before, "the view changes no quantity")
        let redo = try await session.revert(change.inverse)
        #expect(await session.pageView(of: page.id).isIdentity)
        _ = try await session.revert(redo)

        let packageURL = root.appendingPathComponent("View.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "View", originalPDF: a.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery"); return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        try await reopened.close()
        #expect(stored.pageViews[page.id] == PageViewSettings(rotation: 90, crop: crop))
    }

    @Test("Quarter turns normalise: -90 → 270, 180 → 180, 45 → 90 (rounds), 360 → 0")
    func normalisation() {
        #expect(PageViewSettings.normalised(-90) == 270)
        #expect(PageViewSettings.normalised(180) == 180)
        #expect(PageViewSettings.normalised(45) == 90)
        #expect(PageViewSettings.normalised(360) == 0)
        #expect(PageViewSettings.crop(fromJSON: #"{"x":1,"y":2,"width":0,"height":4}"#) == nil, "an empty crop is no crop")
    }
}
