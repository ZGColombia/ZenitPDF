import Foundation
import GRDB
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFTestingSupport

/// Persistence fixes, the application-core half: the History feed, Review and
/// Ledger Snapshots keep writing after a save (R-186); two copies of a never-saved project name
/// their pages alike (K-03); a malformed money cell is refused (R-193); a hidden PDF layer stays
/// hidden across save and reopen (R-205).
@MainActor
@Suite("Iteration 1 — persistence through the application core")
struct Iter1PersistenceAppCoreTests {

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func page(_ index: Int, documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index)",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
    }

    private static func lengthMarkup(documentID: DocumentID, page: PageID) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .length,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - R-186

    @Test("R-186: an audit entry, a review reply and a ledger snapshot made after the first save are all saved")
    func historyReviewAndSnapshotsSurviveASave() async throws {
        let directory = try Self.temporaryDirectory("Iter1HistoryAfterSave")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try ZPDFFixtures.make(.titleBlockSheet, in: directory.appendingPathComponent("source")).url
        let packageURL = directory.appendingPathComponent("History.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "History", originalPDF: pdf)
        let projectID = await package.manifest.projectId

        let documentID = DocumentID(UUID())
        let page = Self.page(0, documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        // What the document does at mount: fetch the handle once.
        environment.history.attach(database: await package.database, projectID: projectID)

        // The first ⌘S.
        try await package.save()

        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let record = Self.lengthMarkup(documentID: documentID, page: page.id)
        _ = try await environment.commands.perform(.addMarkup(record))
        #expect(environment.review.addReply("Checked on site", to: record.id.rawValue) != nil)
        // Old output: throws "the database handle is closed".
        _ = try await environment.takeLedgerSnapshot(named: "Bid 1")
        await environment.history.settle()
        await environment.review.settle()

        try await package.save()
        try await package.close()

        let reopened = try await ProjectPackage.open(at: packageURL, resolving: .discard)
        let counts = try await reopened.read { db in
            (
                audit: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement_audit WHERE project_id = ?", arguments: [projectID]) ?? 0,
                review: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_entry") ?? 0,
                snapshots: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ledger_snapshot WHERE project_id = ?", arguments: [projectID]) ?? 0
            )
        }
        try await reopened.close()
        // Old output: 0, 0, 0 — every write after the first save went to a closed handle and
        // was discarded by the presenters' catch.
        #expect(counts.audit > 0, "the calibration and the markup are in the audit trail")
        #expect(counts.review == 1)
        #expect(counts.snapshots == 1)
    }

    // MARK: - K-03

    @Test("K-03: two copies of a never-saved project give their pages the same ids, every open")
    func copiesOfAnUnsavedProjectAgreeOnPageIDs() async throws {
        let directory = try Self.temporaryDirectory("Iter1StablePages")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try ZPDFFixtures.make(.titleBlockSheet, in: directory.appendingPathComponent("source")).url
        let original = directory.appendingPathComponent("Takeoff.zpdfproj", isDirectory: true)
        let created = try await ProjectPackage.create(at: original, displayName: "Takeoff", originalPDF: pdf)
        try await created.close()
        let copy = directory.appendingPathComponent("Takeoff copy.zpdfproj", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        // What the load pipeline does for each copy: fresh pages, minted at random, then adopted.
        func adoptedIDs(_ url: URL) async throws -> [PageID] {
            let package = try await ProjectPackage.open(at: url, resolving: .discard)
            let documentID = DocumentID(UUID())
            let fresh = [Self.page(0, documentID: documentID), Self.page(1, documentID: documentID)]
            #expect(try await TakeoffArchive.read(from: package) == nil, "precondition: never saved")
            let stored = try await TakeoffArchive.unsavedTakeoff(of: package)
            let ids = TakeoffArchive.adoptingStoredPageIDs(fresh, stored: stored).map(\.id)
            try await package.close()
            return ids
        }
        let first = try await adoptedIDs(original)
        let second = try await adoptedIDs(copy)
        let again = try await adoptedIDs(original)
        // Old output: every open kept its random ids, so first != second != again, and a markup
        // from one copy named a page the other did not have.
        #expect(first == second)
        #expect(first == again)
        #expect(Set(first).count == 2, "two pages, two ids")
    }

    @Test("K-03: a stored page id still wins, and a drawing of a set with no takeoff gets stable ids")
    func storedIDsWinAndSetDrawingsAreStable() {
        let documentID = DocumentID(UUID())
        let stored = UUID()
        var takeoff = TakeoffArchive.StoredTakeoff(
            pageIDsByIndex: [0: stored], scales: [], pageScaleIDs: [:], markups: [], hasSavedTakeoff: true
        )
        takeoff.documentRowID = "doc-row"
        let adopted = TakeoffArchive.adoptingStoredPageIDs(
            [Self.page(0, documentID: documentID), Self.page(1, documentID: documentID)], stored: takeoff
        )
        #expect(adopted[0].id == PageID(stored), "a saved page keeps the id it was saved under")
        #expect(adopted[1].id == PageID(StablePageIdentity.pageID(documentId: "doc-row", pageIndex: 1)))

        // Two copies of a set whose second drawing was added and never saved.
        func setIDs() -> [PageID] {
            let second = DocumentID(UUID())
            return TakeoffArchive.adoptingStoredSet(
                [("second-row", [Self.page(0, documentID: second)])],
                stored: [("second-row", nil)]
            ).pages.map(\.id)
        }
        // Old output: the drawing's freshly minted random ids, different on every call.
        #expect(setIDs() == setIDs())
        #expect(setIDs() == [PageID(StablePageIdentity.pageID(documentId: "second-row", pageIndex: 0))])
    }

    // MARK: - R-193

    @Test("R-193: malformed money cells are refused and leave the ledger unchanged; a clean one applies exactly")
    func malformedMoneyIsRefused() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(0, documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let record = Self.lengthMarkup(documentID: documentID, page: page.id)
        _ = try await environment.commands.perform(.addMarkup(record))
        let unitCost = try #require(await session.ledgerColumns.columnID(standard: .unitCost))

        let receipt = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: record.id.rawValue, columnKey: "unitCost", text: "1.250.00"),
            SpreadsheetCellEdit(markupID: record.id.rawValue, columnKey: "unitCost", text: "12-5"),
            SpreadsheetCellEdit(markupID: record.id.rawValue, columnKey: "unitCost", text: "1e3e3"),
            SpreadsheetCellEdit(markupID: record.id.rawValue, columnKey: "unitCost", text: "5e"),
        ])
        // Old output: applied == 4, the last write leaving `.currency(amount: 5, …)`.
        #expect(receipt.applied == 0)
        #expect(receipt.refused.count == 4)
        #expect(await session.markup(record.id)?.customValues[unitCost] == nil)

        let clean = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: record.id.rawValue, columnKey: "unitCost", text: "1250.00"),
        ])
        #expect(clean.applied == 1)
        guard case let .currency(amount, _)? = await session.markup(record.id)?.customValues[unitCost] else {
            Issue.record("no unit cost applied"); return
        }
        #expect(amount == Decimal(string: "1250"))
    }

    // MARK: - R-205

    @Test("R-205: a hidden PDF layer is stored in layer_override and restored on reopen; back to default removes it")
    func layerVisibilitySurvivesReopen() async throws {
        let directory = try Self.temporaryDirectory("Iter1LayerOverrides")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.threeLayers, in: directory.appendingPathComponent("source"))
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(fixture.url), password: nil, limits: .standard)
        let tree = try #require(try await provider.layerTree(of: opened.handle))
        await provider.close(opened.handle)
        let packageURL = directory.appendingPathComponent("Layers.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Layers", originalPDF: fixture.url)

        let model = DocumentLayerVisibility()
        model.adopt(tree: tree)
        let archive = LayerOverrideArchive(package: package)
        await model.attach(archive: archive)
        #expect(model.overrides.isEmpty, "nothing stored yet")
        let walls = try #require(model.items.first { $0.name == "Walls" })
        let grid = try #require(model.items.first { $0.name == "Grid" })
        model.setVisible(false, layerID: walls.id)   // Walls ships on: hidden is an override
        model.setVisible(true, layerID: grid.id)     // Grid ships off: shown is an override
        await archive.settle()
        try await package.save()
        try await package.close()

        func reopenedModel() async throws -> (DocumentLayerVisibility, Int, ProjectPackage) {
            let reopened = try await ProjectPackage.open(at: packageURL, resolving: .discard)
            let restored = DocumentLayerVisibility()
            restored.adopt(tree: tree)
            var changes = 0
            restored.onVisibilityChange = { changes += 1 }
            await restored.attach(archive: LayerOverrideArchive(package: reopened))
            return (restored, changes, reopened)
        }
        let (restored, changes, reopened) = try await reopenedModel()
        // Old output: [:] and no change — nothing ever wrote `layer_override`, so every hidden
        // layer came back on at the next open.
        #expect(restored.overrides == [walls.id: false, grid.id: true])
        #expect(changes == 1, "the restored state reaches the canvas and snap index like a toggle")
        #expect(restored.items.first { $0.id == walls.id }?.isVisible == false)

        // Back to the document default: the rows go, and the next open is the native render.
        let reopenedArchive = try #require(restored.archive)
        restored.setVisible(true, layerID: walls.id)
        restored.setVisible(false, layerID: grid.id)
        await reopenedArchive.settle()
        let rows = try await reopened.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM layer_override") ?? -1 }
        #expect(rows == 0)
        try await reopened.close()
        let (clean, cleanChanges, last) = try await reopenedModel()
        #expect(clean.overrides.isEmpty)
        #expect(cleanChanges == 0)
        #expect(clean.matchesDocumentDefault)
        try await last.close()
    }
}
