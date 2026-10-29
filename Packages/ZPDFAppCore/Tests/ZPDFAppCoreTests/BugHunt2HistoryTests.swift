import Foundation
import GRDB
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Bug hunt 2, the History trail (BH-010, BH-011, BH-087, BH-108, BH-109, BH-110, BH-111,
/// BH-443, BH-445, BH-446).
@MainActor
@Suite("Bug hunt 2: the History trail")
struct BugHunt2HistoryTests {

    private func makeEnvironment(
        documentID: DocumentID = DocumentID(UUID()),
        pageID: PageID = PageID(UUID())
    ) async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor, DocumentID) {
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let second = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 1,
            label: "A-102",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page, second])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page, documentID)
    }

    private func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-bh2-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("h.sqlite"))
        return (database, directory)
    }

    private static func area(
        id: MarkupID = MarkupID(UUID()),
        documentID: DocumentID,
        pageID: PageID,
        tool: MeasurementTool = .area,
        subject: String,
        ring: [PDFPoint]
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: tool == .polygonCutout ? .polygon : .measurement,
            tool: tool,
            subject: subject,
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    private static let outer = [
        PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)
    ]
    private static let hole = [
        PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 10), PDFPoint(x: 30, y: 30), PDFPoint(x: 10, y: 30)
    ]

    private func calibrate(_ environment: AppCoreEnvironment, page: ZPDFContracts.PageDescriptor) async throws {
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
    }

    // MARK: BH-010, BH-011

    @Test("A cutout's parent gets its own trail row, and deleting the parent records its cutouts")
    func cutoutFamilyIsRecorded() async throws {
        let (environment, _, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        try await calibrate(environment, page: page)

        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.area(id: parentID, documentID: documentID, pageID: page.id, subject: "Slab", ring: Self.outer)
        ))
        try await environment.commands.perform(.addCutout(
            parent: parentID,
            cutout: Self.area(id: cutoutID, documentID: documentID, pageID: page.id, tool: .polygonCutout, subject: "Opening", ring: Self.hole)
        ))
        await environment.history.settle()

        // Old output: one `markup_created` row for the cutout and nothing for the parent whose
        // net area the cutout rewrote.
        let cutoutStep = environment.history.events.filter { $0.markupID == cutoutID.rawValue && $0.action == "markup_created" }
        let group = try #require(cutoutStep.first?.undoGroup)
        let parentRow = environment.history.events.first {
            $0.undoGroup == group && $0.markupID == parentID.rawValue
        }
        #expect(parentRow?.action == "markup_modified")
        // Hand-derived: 10 m over 100 pt ⇒ 0.1 m/pt; the hole is 20 × 20 pt = 4 m², the
        // parent 100 × 80 pt = 80 m², so net goes from 80 to 76 m².
        let netChange = parentRow?.changes.first { $0.field == "netArea" }
        #expect(netChange?.before.flatMap { Decimal(string: $0) } == 80)
        #expect(netChange?.after.flatMap { Decimal(string: $0) } == 76)

        // Deleting the parent takes the cutout with it — old output: one deleted row.
        try await environment.commands.perform(.removeMarkup(parentID))
        await environment.history.settle()
        let deleted = environment.history.events.filter { $0.action == "markup_deleted" }
        #expect(Set(deleted.compactMap(\.markupID)) == [parentID.rawValue, cutoutID.rawValue])
        #expect(Set(deleted.compactMap(\.undoGroup)).count == 1, "one step, one undo group")
    }

    // MARK: BH-087, BH-110

    @Test("A subject rename is filed under the new subject")
    func renameIsFiledUnderTheNewSubject() async throws {
        let (environment, _, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)

        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.area(id: id, documentID: documentID, pageID: page.id, subject: "Doors", ring: Self.outer)
        ))
        try await environment.commands.perform(.editSubject(id: id, subject: "Windows"))
        await environment.history.settle()
        // Old output: "Doors" — the pre-command snapshot was preferred over the command's own
        // after-state.
        #expect(environment.history.events.last?.markupSubject == "Windows")
        #expect(environment.history.events.last?.pageLabel == "A-101")
    }

    // MARK: BH-108

    @Test("A reopened trail shows each markup's subject and page")
    func reopenedTrailKnowsItsMarkups() async throws {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Self.area(documentID: documentID, pageID: pageID, subject: "Slab", ring: Self.outer)

        do {
            let (first, _, _, _) = try await makeEnvironment(documentID: documentID, pageID: pageID)
            first.history.attach(database: database, projectID: documentID.rawValue.uuidString)
            try await first.commands.perform(.addMarkup(record))
            await first.history.settle()
        }

        // Reopen: a fresh environment over a session holding the same markup, no recording.
        let (second, session, _, _) = try await makeEnvironment(documentID: documentID, pageID: pageID)
        try await session.apply(.addMarkup(record))
        await second.refresh()
        second.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        await second.history.settle()

        // Old output: markupSubject nil, pageLabel nil, and an empty page filter.
        let row = try #require(second.history.events.first { $0.markupID == record.id.rawValue })
        #expect(row.markupSubject == "Slab")
        #expect(row.pageLabel == "A-101")
        #expect(second.history.auditPageLabels == ["A-101"])
    }

    // MARK: BH-109

    @Test("Contract fields the presentation enum lacks still render in the person's units")
    func contractOnlyFieldsAreFormatted() {
        // Old output: fieldDisplayName nil and a raw canonical "12.345" beside formatted values.
        #expect(AppHistoryPresenter.fieldDisplayName("cutoutArea") == "Cutout Area")
        #expect(AppHistoryPresenter.fieldDisplayName("netWallArea") == "Net Wall Area")
        #expect(AppHistoryPresenter.fieldDimension("cutoutArea") == Shown.Dimension(domain: .area))
        #expect(AppHistoryPresenter.fieldDimension("truePerimeter") == Shown.Dimension(domain: .length))
        #expect(AppHistoryPresenter.fieldDimension("noSuchField") == nil)
    }

    @Test("A cutout-area change is shown in square feet on an imperial ledger")
    func cutoutAreaRendersInDisplayUnits() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await session.setUnits(.imperial)
        await environment.refresh()
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        try await calibrate(environment, page: page)
        let parentID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(
            Self.area(id: parentID, documentID: documentID, pageID: page.id, subject: "Slab", ring: Self.outer)
        ))
        try await environment.commands.perform(.addCutout(
            parent: parentID,
            cutout: Self.area(documentID: documentID, pageID: page.id, tool: .polygonCutout, subject: "Opening", ring: Self.hole)
        ))
        await environment.history.settle()
        let change = try #require(environment.history.events.flatMap(\.changes).first { $0.field == "cutoutArea" && $0.after != nil })
        // Hand-derived: 4 m² / 0.09290304 m²/ft² = 43.0556… ft² → "43.06 ft²".
        #expect(change.afterDisplay == "43.06 ft²")
        #expect(change.fieldDisplayName == "Cutout Area")
    }

    // MARK: BH-443

    @Test("A batch recorded detached does not report an earlier batch's group")
    func detachedBatchCarriesNoStaleGroup() async throws {
        let (environment, _, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        let first = Self.area(documentID: documentID, pageID: page.id, subject: "A", ring: Self.outer)
        let second = Self.area(documentID: documentID, pageID: page.id, subject: "B", ring: Self.hole)
        try await environment.commands.performBatch([.addMarkup(first)], actionName: "One")
        #expect(environment.history.lastBatchAuditGroup != nil)
        environment.history.detach()
        try await environment.commands.performBatch([.addMarkup(second)], actionName: "Two")
        // Old output: the first batch's group, claimed for a batch that wrote no trail.
        #expect(environment.history.lastBatchAuditGroup == nil)
    }

    // MARK: BH-445

    @Test("Create Project carries an action this build does not know verbatim")
    func migrationKeepsUnknownActions() async throws {
        let (environment, _, _, documentID) = try await makeEnvironment()
        let (old, oldDirectory) = try await makeDatabase()
        let (new, newDirectory) = try await makeDatabase()
        defer {
            try? FileManager.default.removeItem(at: oldDirectory)
            try? FileManager.default.removeItem(at: newDirectory)
        }
        let oldProject = "quick-\(documentID.rawValue.uuidString)"
        try await old.write { db in
            try MeasurementAuditRecord(
                id: UUID().uuidString,
                projectId: oldProject,
                markupId: UUID().uuidString,
                sequence: 1,
                occurredAt: PersistenceTimestamp.string(from: Date(timeIntervalSince1970: 1_700_000_000)),
                action: "markup_split_future",
                actor: "someone",
                commandName: "Split"
            ).insert(db)
        }
        environment.history.attach(database: old, projectID: oldProject)
        await environment.history.settle()
        environment.history.migrate(to: new, projectID: documentID.rawValue.uuidString)
        await environment.history.settle()
        // Old output: "markup_modified" — the append-only trail rewritten during the carry-over.
        #expect(environment.history.events.map(\.action) == ["markup_split_future"])
        #expect(environment.history.events.first?.actor == "someone")
    }

    // MARK: BH-446

    @Test("A page reorder writes no measurement event")
    func pageReorderIsNotAMeasurementEvent() async throws {
        let (environment, _, _, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        try await environment.commands.perform(.reorderPage(from: 0, to: 1))
        await environment.history.settle()
        // Old output: one anonymous `markup_modified` row with no markup.
        #expect(environment.history.events.isEmpty)
        // Undo still works with no token to compensate.
        await environment.commands.undo()
        await environment.history.settle()
        #expect(environment.history.events.isEmpty)
    }

    // MARK: BH-111

    @Test("Recording a fan-out over twenty thousand markups is linear, not quadratic")
    func largeFanOutIsLinear() async throws {
        let (environment, _, page, documentID) = try await makeEnvironment()
        let (database, directory) = try await makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        await environment.history.settle()

        let count = 20_000
        let ids = (0..<count).map { _ in UUID() }
        let summaries = ids.map { id in
            ZPDFUIPresentation.MarkupSummary(
                id: id,
                kind: .rectangle,
                subject: "S",
                label: "",
                pageLabel: "A-101",
                pageID: page.id.rawValue,
                pageIndex: 0,
                author: "t",
                colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0),
                created: Date(timeIntervalSince1970: 0),
                modified: Date(timeIntervalSince1970: 0),
                boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let base = environment.snapshot
        let snapshot = DocumentSnapshot(
            documentID: base.documentID,
            pages: base.pages,
            firstPageScale: nil,
            markups: summaries,
            ledger: base.ledger,
            units: base.units
        )
        let markupIDs = ids.map(MarkupID.init)
        let outcome = DocumentCommandOutcome(
            command: .batchStatusChange(ids: markupIDs, status: .open),
            inverse: DocumentCommandInverse(),
            forward: DocumentCommandInverse(),
            changedMarkupIDs: Set(markupIDs),
            changedPageIDs: []
        )
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = environment.history.recordApplied(outcome, snapshot: snapshot)
        }
        // Old cost: a linear scan of 20 000 summaries per affected markup — 2 × 10⁸ id
        // comparisons. Measured on this machine (debug): 155.7 s with the scan (and with a
        // per-copy index), under 1.2 s for the whole test with one shared index. The budget is
        // wide so a loaded machine cannot flake it, and still two orders below the old cost.
        #expect(elapsed < .seconds(10), "recordApplied took \(elapsed)")
        await environment.history.settle()
        #expect(environment.history.events.count == count)
        #expect(environment.history.events.allSatisfy { $0.markupSubject == "S" })
    }
}
