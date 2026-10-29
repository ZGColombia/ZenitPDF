import Foundation
import GRDB
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport

/// CR-121: a save keeps the page rows, so `ocr_token` — which cascades from `page` — survives.
///
/// `TakeoffArchive.write` used to `DELETE FROM page WHERE document_id = ?` and re-insert. The
/// cascade wiped every recognised token while `search_fts` kept its rows, so after the first
/// save every OCR hit had no token, no confidence, and was dropped as low-confidence.
@Suite("The archive keeps page rows across saves")
struct ArchivePageUpsertTests {

    private static func markup(documentID: DocumentID, pageID: PageID, subject: String) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: subject,
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100, y: 100),
                    PDFPoint(x: 200, y: 100),
                    PDFPoint(x: 200, y: 180),
                    PDFPoint(x: 100, y: 180)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    private static func token(pageKey: String, text: String) -> OCRTokenRecord {
        OCRTokenRecord(
            pageId: pageKey,
            token: text,
            normalizedToken: text.lowercased(),
            confidence: 0.93,
            boundsBlob: Data([0, 1, 2, 3]),
            lineIndex: 0,
            tokenIndex: 0
        )
    }

    private static func tokenCount(in package: ProjectPackage, pageKey: String) async throws -> Int {
        try await package.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ocr_token WHERE page_id = ?", arguments: [pageKey]
            ) ?? 0
        }
    }

    @Test("OCR tokens survive a second save of the same pages")
    func ocrTokensSurviveASave() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let pageKey = pageID.rawValue.uuidString
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        _ = try await session.apply(.addMarkup(Self.markup(documentID: fixture.documentID, pageID: pageID, subject: "Slab")))

        let packageURL = directory.url.appendingPathComponent("Tokens.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Tokens", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)

        // Recognition ran between the two saves.
        try await package.write { db in
            try Self.token(pageKey: pageKey, text: "Slab").insert(db)
        }
        #expect(try await Self.tokenCount(in: package, pageKey: pageKey) == 1)

        // An edit and a second save, with the same pages.
        _ = try await session.apply(.addMarkup(Self.markup(documentID: fixture.documentID, pageID: pageID, subject: "Deck")))
        try await TakeoffArchive.write(await session.takeoffState(), into: package)

        // Old output: 0 — `DELETE FROM page` cascaded into `ocr_token`.
        #expect(try await Self.tokenCount(in: package, pageKey: pageKey) == 1)

        // And the takeoff itself is still rewritten in full.
        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.markups.map(\.subject).sorted() == ["Deck", "Slab"])
        #expect(stored.scales.count == 1)
        #expect(stored.pageIDsByIndex[0] == pageID.rawValue)
        try await package.close()
    }

    @Test("Reordered pages are rewritten in place, and a page that left the document takes its tokens with it")
    func reorderedPagesAreRewrittenInPlace() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let documentID = fixture.documentID
        func page(_ index: Int) -> ZPDFContracts.PageDescriptor {
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "P\(index)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
        }
        let first = page(0)
        let second = page(1)
        let third = page(2)

        let packageURL = directory.url.appendingPathComponent("Reorder.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Reorder", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(
            TakeoffSession.TakeoffState(pages: [first, second, third], markups: [], scales: [], pageScaleIDs: [:]),
            into: package
        )
        try await package.write { db in
            try Self.token(pageKey: second.id.rawValue.uuidString, text: "Keep").insert(db)
            try Self.token(pageKey: third.id.rawValue.uuidString, text: "Gone").insert(db)
        }

        // Swap the first two — the UNIQUE(document_id, page_index) constraint — and drop the third.
        var swappedFirst = first
        swappedFirst.index = 1
        var swappedSecond = second
        swappedSecond.index = 0
        try await TakeoffArchive.write(
            TakeoffSession.TakeoffState(pages: [swappedSecond, swappedFirst], markups: [], scales: [], pageScaleIDs: [:]),
            into: package
        )

        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.pageIDsByIndex[0] == second.id.rawValue)
        #expect(stored.pageIDsByIndex[1] == first.id.rawValue)
        #expect(stored.pageIDsByIndex[2] == nil)
        #expect(try await Self.tokenCount(in: package, pageKey: second.id.rawValue.uuidString) == 1)
        #expect(try await Self.tokenCount(in: package, pageKey: third.id.rawValue.uuidString) == 0)
        try await package.close()
    }
}
