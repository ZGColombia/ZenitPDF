import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The History feed (ADR-0007 §2–§3): every command lands in the
/// append-only `measurement_audit` table, an undo appends a compensating entry, and the
/// presenter republishes the trail the pane renders.
@Suite("History feed")
struct HistoryFeedTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, page, documentID)
    }

    private func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("history.sqlite")
        )
        return (database, directory)
    }

    private static func markup(documentID: DocumentID, pageID: PageID) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    @Test("Draw and undo appear in the trail: created, then compensated — never an edit")
    @MainActor
    func drawAndUndoProduceVisibleEntries() async throws {
        let (environment, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        #expect(environment.history.isAttached)

        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let record = Self.markup(documentID: documentID, pageID: page.id)
        try await environment.commands.perform(.addMarkup(record))
        await environment.history.settle()

        // The trail so far: the calibration, then the drawn markup — oldest first.
        var actions = environment.history.events.map(\.action)
        #expect(actions == ["scale_changed", "markup_created"], "trail so far: \(actions)")
        let created = try #require(environment.history.events.last)
        #expect(created.markupID == record.id.rawValue)
        #expect(created.markupSubject == "Slab")
        #expect(created.pageLabel == "A-101")
        #expect(!created.changes.isEmpty, "a measured markup's entry carries its values")
        #expect(created.changes.allSatisfy { $0.before == nil }, "created from nothing")

        // One ⌘Z: the trail gains a compensating entry; nothing is edited or removed.
        await environment.commands.undo()
        await environment.history.settle()
        actions = environment.history.events.map(\.action)
        #expect(actions == ["scale_changed", "markup_created", "compensated"], "after undo: \(actions)")
        let compensated = try #require(environment.history.events.last)
        #expect(compensated.markupID == record.id.rawValue)
        #expect(compensated.note?.contains("compensates") == true)

        // Redo compensates the compensation — the chain stays append-only, and the
        // entry says "recompensated" so the pane reads "Redone", never a second
        // "Undone" with the values reversed (found live 2026-08-24).
        await environment.commands.redo()
        await environment.history.settle()
        #expect(environment.history.events.count == 4)
        #expect(environment.history.events.last?.action == "recompensated")

        // And undoing the redo is an undo again: the labels alternate, forever.
        await environment.commands.undo()
        await environment.history.settle()
        #expect(environment.history.events.last?.action == "compensated")
        await environment.commands.redo()
        await environment.history.settle()
        #expect(environment.history.events.last?.action == "recompensated")

        // The pane's surface: the ledger presenter exposes the same trail through
        // LedgerAuditPresenting, which is what the History tab casts for.
        let audit = environment.ledger as any LedgerAuditPresenting
        #expect(audit.auditEvents(matching: LedgerAuditFilter()).count == 6)
        #expect(audit.auditActions.contains("markup_created"))
        #expect(audit.auditPageLabels == ["A-101"])
        let filtered = audit.auditEvents(matching: LedgerAuditFilter(action: "markup_created"))
        #expect(filtered.count == 1)
        let derivation = try #require(audit.derivation(for: record.id.rawValue) as LedgerDerivationModel?)
        #expect(derivation.history.count == 5,
                "the markup's own history: created, undone, redone, undone, redone")
        await database.closeForTesting()
    }

    @Test("Promoting a quick takeoff migrates the whole trail into the project database")
    @MainActor
    func migrationCarriesTheTrail() async throws {
        let (environment, page, documentID) = try await makeEnvironment()
        let (quick, quickDir) = try await makeDatabase()
        let (packageDB, packageDir) = try await makeDatabase()
        defer {
            try? FileManager.default.removeItem(at: quickDir)
            try? FileManager.default.removeItem(at: packageDir)
        }

        environment.history.attach(database: quick, projectID: documentID.rawValue.uuidString)
        try await environment.commands.calibrate(
            page: try #require(await environment.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        try await environment.commands.perform(
            .addMarkup(Self.markup(documentID: documentID, pageID: page.id))
        )
        await environment.history.settle()
        #expect(environment.history.events.count == 2)

        let newProjectID = UUID().uuidString
        environment.history.migrate(to: packageDB, projectID: newProjectID)
        await environment.history.settle()
        #expect(environment.history.events.map(\.action) == ["scale_changed", "markup_created"])

        // The rows are really in the package database, not just on screen.
        let stored = try await packageDB.read { db in
            try MeasurementAuditStore.auditTrail(project: newProjectID, in: db)
        }
        #expect(stored.count == 2)
        await quick.closeForTesting()
        await packageDB.closeForTesting()
    }
}

private extension ProjectDatabaseActor {
    /// Closes without making the test care about the throwing signature.
    func closeForTesting() async {
        try? await close()
    }
}
