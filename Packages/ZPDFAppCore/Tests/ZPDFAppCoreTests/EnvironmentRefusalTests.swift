import Foundation
import Testing
import ZPDFContracts
import ZPDFTestingSupport
@testable import ZPDFAppCore

/// CR-10 and CR-15: two `try?` that used to swallow a refusal now put it in the warning tray.
@Suite("Refusals are spoken")
struct EnvironmentRefusalTests {

    private static func page(documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
    }

    private static func polygon(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        tool: MeasurementTool,
        ring: [PDFPoint],
        locked: Bool = false
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: tool == .area ? .measurement : .polygon,
            tool: tool,
            subject: "Slab",
            author: "test",
            locked: locked,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: CR-10

    @Test("A cutout the session refuses is reported in the tray")
    @MainActor
    func refusedCutoutIsReported() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let parentID = MarkupID(UUID())
        // The lock arrives with the file: no command locks a record.
        try await session.hydrate(
            markups: [Self.polygon(
                id: parentID, documentID: documentID, pageID: page.id, tool: .area,
                ring: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)],
                locked: true
            )],
            scales: [],
            pageScaleIDs: [:]
        )
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        #expect(environment.document.warnings.isEmpty)

        let cutout = Self.polygon(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, tool: .polygonCutout,
            ring: [PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 10), PDFPoint(x: 30, y: 30), PDFPoint(x: 10, y: 30)]
        )
        await environment.commitCutout(parent: parentID, record: cutout)

        // Old behaviour: `try? await commands.perform(.addCutout(…))` — nothing on the canvas,
        // nothing in the tray, the area kept its gross value with no word about why.
        let warning = try #require(
            environment.document.warnings.first { $0.id == AppCoreEnvironment.commitFailureWarningID }
        )
        #expect(warning.message.contains("locked"))
        #expect(environment.status.warnings.map(\.id) == [warning.id], "the tray the views read")
        #expect(await session.orderedMarkups.count == 1)
    }

    // MARK: CR-15

    @Test("A refresh whose snapshot cannot be built says so, and clears on the next success")
    @MainActor
    func failedRefreshIsReportedAndClearsOnSuccess() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let before = environment.snapshot

        await environment.refresh { _ in throw DocumentCommandError.ledgerFailed("boom") }
        // Old behaviour: `guard let snapshot = try? await … else { return }` — the presenters
        // stayed on the previous snapshot with nothing said.
        let warning = try #require(
            environment.document.warnings.first { $0.id == AppCoreEnvironment.refreshFailureWarningID }
        )
        #expect(warning.message.contains("boom"))
        #expect(environment.snapshot.documentID == before.documentID, "the previous snapshot stays on screen")

        await environment.refresh()
        #expect(!environment.document.warnings.contains { $0.id == AppCoreEnvironment.refreshFailureWarningID })
    }
}
