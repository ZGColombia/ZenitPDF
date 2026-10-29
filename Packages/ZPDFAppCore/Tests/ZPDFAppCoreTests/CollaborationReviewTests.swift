import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// Review threads (NL-COLLAB-01/02), review fields in the History (bug
/// AppHistoryPresenter:768, ADR-0021), and the drawn text of a text box apart from its note
/// (NL-COLLAB-18). Every test drives the shipping presenters, bus and archive.
@Suite("Collaboration — review threads, review history, text-box text")
struct CollaborationReviewTests {

    // MARK: - Fixtures

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private static func area(documentID: DocumentID, pageID: PageID, author: String = "Ada") -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
            kind: .measurement, tool: .area, subject: "Slab", label: "Room 1", author: author,
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    private static func cloud(documentID: DocumentID, pageID: PageID) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID, kind: .cloud, author: "Ada",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 60, y: 40)]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, PageID, DocumentID, ProjectDatabaseActor, URL) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        return (environment, session, page.id, documentID, database, directory)
    }

    @MainActor
    private func summary(_ environment: AppCoreEnvironment, _ id: MarkupID) async throws -> MarkupSummary {
        await environment.refresh()
        return try #require(environment.snapshot.markups.first { $0.id == id.rawValue })
    }

    // MARK: - Bug AppHistoryPresenter:768 — review fields in the History

    /// Old output: the status change wrote `before_values_json` = `after_values_json` = NULL on a
    /// markup without a measurement, and only the measured values on one with — never the status.
    @Test("A status change Open → Accepted writes an audit row with those two values")
    @MainActor
    func statusChangeIsAudited() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Self.cloud(documentID: documentID, pageID: pageID)
        try await environment.commands.perform(.addMarkup(record))
        try await environment.commands.perform(.batchStatusChange(ids: [record.id], status: .open))
        try await environment.commands.perform(.batchStatusChange(ids: [record.id], status: .accepted))
        try await environment.commands.perform(.editLabel(id: record.id, label: "RFI 12"))
        await environment.history.settle()

        let events = environment.history.events.filter { $0.markupID == record.id.rawValue }
        let statusRows = events.compactMap { $0.changes.first { $0.field == ReviewAuditFields.status } }
        #expect(statusRows.count == 2)
        #expect(statusRows.last?.before == "open")
        #expect(statusRows.last?.after == "accepted")
        #expect(statusRows.last?.beforeDisplay == "Open")
        #expect(statusRows.last?.afterDisplay == "Accepted")
        #expect(statusRows.last?.fieldDisplayName == "Status")
        let label = try #require(events.last?.changes.first { $0.field == ReviewAuditFields.label })
        #expect(label.before == nil || label.before == "")
        #expect(label.after == "RFI 12")
        #expect(events.last?.changes.count == 1, "only the field that changed, not the whole record")
        try? await database.close()
    }

    @Test("A move repeats no review field; a status edit is not a re-measure for the trace")
    @MainActor
    func moveCarriesNoReviewFields() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = Self.area(documentID: documentID, pageID: pageID)
        record.comment = "Check the slab edge"
        try await environment.commands.perform(.addMarkup(record))
        try await environment.commands.perform(.moveMarkup(id: record.id, dx: 5, dy: 0))
        try await environment.commands.perform(.batchStatusChange(ids: [record.id], status: .accepted))
        await environment.history.settle()
        let events = environment.history.events.filter { $0.markupID == record.id.rawValue }
        #expect(events.count == 3)
        let created = events[0].changes.map(\.field)
        #expect(created.contains(ReviewAuditFields.comment), "a creation records the note it was made with")
        #expect(!created.contains(ReviewAuditFields.status), "a resting status is not a line")
        #expect(!events[1].changes.contains { MeasurementAuditStore.isReviewField($0.field) })

        var sources = MeasurementTraceResolver.Sources()
        sources.absorb(auditTrail: environment.history.auditRecords)
        let statusRecord = try #require(environment.history.auditRecords.last)
        #expect(!MeasurementTraceResolver.Sources.measuredValuesDiffer(statusRecord),
                "a status edit must not move 'measured at'")
        try? await database.close()
    }

    // MARK: - NL-COLLAB-01 acceptance

    /// Add 3 replies by 2 authors, change status twice, reopen: 5 entries in order with authors,
    /// times and from→to. ⌘Z removes the last reply only. Deleting the markup keeps the thread.
    @Test("Three replies by two authors and two status changes read back as five entries in order")
    @MainActor
    func threadAcceptance() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.history.actorNameProvider = { "Ada" }
        let record = Self.cloud(documentID: documentID, pageID: pageID)
        try await environment.commands.perform(.addMarkup(record))

        environment.review.actorNameProvider = { "Ada" }
        #expect(environment.review.addReply("Is this the slab edge?", to: record.id.rawValue) != nil)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await environment.commands.perform(.batchStatusChange(ids: [record.id], status: .open))
        try await Task.sleep(nanoseconds: 5_000_000)
        environment.review.actorNameProvider = { "Bo" }
        #expect(environment.review.addReply("Yes, per A-201.", to: record.id.rawValue) != nil)
        try await Task.sleep(nanoseconds: 5_000_000)
        environment.history.actorNameProvider = { "Bo" }
        try await environment.commands.perform(.batchStatusChange(ids: [record.id], status: .accepted))
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(environment.review.addReply("Closing.", to: record.id.rawValue) != nil)
        await environment.history.settle()
        await environment.review.settle()

        let thread = environment.review.thread(for: try await summary(environment, record.id))
        #expect(thread.items.count == 5)
        #expect(thread.items.map(\.author) == ["Ada", "Ada", "Bo", "Bo", "Bo"])
        guard thread.items.count == 5 else { return }
        #expect(thread.items[0].kind == .reply)
        #expect(thread.items[1].kind == .statusChange(from: ZPDFUIPresentation.MarkupStatus.none, to: .open, reverted: false))
        #expect(thread.items[3].kind == .statusChange(from: .open, to: .accepted, reverted: false))
        #expect(thread.items[4].text == "Closing.")

        // Reopen: a fresh presenter over the same database reads the same replies.
        let reopened = AppReviewPresenter(undoManager: UndoManager())
        reopened.history = environment.history
        reopened.attach(database: database, projectID: documentID.rawValue.uuidString)
        await reopened.settle()
        let again = reopened.thread(for: try await summary(environment, record.id))
        #expect(again.items.map(\.text) == thread.items.map(\.text))
        #expect(again.items.map(\.author) == thread.items.map(\.author))

        // ⌘Z removes the last reply only.
        environment.commands.undoManager.undo()
        await environment.review.settle()
        let afterUndo = environment.review.thread(for: try await summary(environment, record.id))
        #expect(afterUndo.items.count == 4)
        #expect(afterUndo.items.last?.kind == .statusChange(from: .open, to: .accepted, reverted: false))
        environment.commands.undoManager.redo()
        await environment.review.settle()
        #expect(environment.review.thread(for: try await summary(environment, record.id)).items.last?.text == "Closing.")

        // Deleting the markup keeps the thread as a record.
        let before = try await summary(environment, record.id)
        try await environment.commands.perform(.removeMarkup(record.id))
        await environment.review.settle()
        let rows = try await database.read { db in
            try ReviewEntryStore.entries(project: documentID.rawValue.uuidString, markup: record.id.rawValue.uuidString, in: db)
        }
        #expect(rows.count == 3)
        #expect(environment.review.thread(for: before).replyCount == 3)
        try? await database.close()
    }

    /// Old output: a reply typed while the opening reload was still queued was written to the file
    /// but dropped from `entries` when that reload published — gone from the thread and from the
    /// annotated export (ReviewImportFlowTests.repliesRoundTrip failed about 3 runs in 4).
    @Test("A reply added before the opening reload lands stays in the thread")
    @MainActor
    func replyDuringAttachSurvives() async throws {
        let (environment, _, _, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markup = UUID()
        let presenter = AppReviewPresenter(undoManager: UndoManager())
        presenter.history = environment.history
        presenter.actorNameProvider = { "Bo" }
        presenter.attach(database: database, projectID: documentID.rawValue.uuidString)
        let id = try #require(presenter.addReply("Agreed, per A-201", to: markup))
        await presenter.settle()
        #expect(presenter.entries.map(\.id) == [id.uuidString])
        let rows = try await database.read { db in
            try ReviewEntryStore.entries(project: documentID.rawValue.uuidString, in: db)
        }
        #expect(rows.map(\.id) == [id.uuidString])
        try? await database.close()
    }

    @Test("Withdrawing a reply keeps its row as a tombstone and undoes")
    @MainActor
    func withdrawIsATombstone() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Self.cloud(documentID: documentID, pageID: pageID)
        try await environment.commands.perform(.addMarkup(record))
        let id = try #require(environment.review.addReply("Wrong sheet", to: record.id.rawValue))
        // Two user actions are two run-loop events; settling lets the undo manager close the
        // first action's group before the second registers, as it does in the app.
        await environment.review.settle()
        environment.review.retractReply(id)
        await environment.review.settle()
        var rows = try await database.read { db in try ReviewEntryStore.entries(project: documentID.rawValue.uuidString, in: db) }
        #expect(rows.first?.retracted == true)
        #expect(rows.first?.body == "Wrong sheet", "withdrawn, never deleted")
        environment.commands.undoManager.undo()
        await environment.review.settle()
        rows = try await database.read { db in try ReviewEntryStore.entries(project: documentID.rawValue.uuidString, in: db) }
        #expect(rows.first?.retracted == false)
        #expect(environment.review.addReply("   ", to: record.id.rawValue) == nil)
        try? await database.close()
    }

    /// Bug InspectorCommentsTab:31, at the source. Old output: the note was attributed to
    /// `markup.author` ("Ada") and dated `markup.modified`, which a move changed.
    @Test("The note is attributed to whoever wrote it, and an undo restores the earlier writer")
    @MainActor
    func noteAttribution() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = Self.area(documentID: documentID, pageID: pageID, author: "Ada")
        try await environment.commands.perform(.addMarkup(record))
        environment.history.actorNameProvider = { "Ada" }
        try await environment.commands.perform(.editComment(id: record.id, comment: "First look"))
        environment.history.actorNameProvider = { "Bo" }
        try await environment.commands.perform(.editComment(id: record.id, comment: "Bo's note"))
        try await environment.commands.perform(.moveMarkup(id: record.id, dx: 3, dy: 0))
        await environment.history.settle()
        var note = try #require(environment.review.thread(for: try await summary(environment, record.id)).items.first { $0.kind == .note })
        #expect(note.author == "Bo")
        #expect(note.text == "Bo's note")

        await environment.commands.undo()  // the move
        await environment.commands.undo()  // Bo's note
        await environment.history.settle()
        note = try #require(environment.review.thread(for: try await summary(environment, record.id)).items.first { $0.kind == .note })
        #expect(note.text == "First look")
        #expect(note.author == "Ada", "the undo's own row is not the note's author")
        try? await database.close()
    }

    @Test("One note over several markups is one undo step")
    @MainActor
    func noteOverSelection() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = Self.cloud(documentID: documentID, pageID: pageID)
        let b = Self.cloud(documentID: documentID, pageID: pageID)
        try await environment.commands.perform(.addMarkup(a))
        try await environment.commands.perform(.addMarkup(b))
        #expect(environment.review.addReplies("see RFI 12", to: [a.id.rawValue, b.id.rawValue]) == 2)
        await environment.review.settle()
        #expect(environment.review.entries.count == 2)
        environment.commands.undoManager.undo()
        await environment.review.settle()
        #expect(environment.review.entries.isEmpty)
        try? await database.close()
    }

    // MARK: - NL-COLLAB-05 — a rename does not split a person

    @Test("Renaming the local author keeps the old name as this person's alias")
    @MainActor
    func renameKeepsAlias() throws {
        // An absolute-path suite keeps its plist in a scratch folder: nothing is ever written to
        // ~/Library/Preferences (a named suite left zenit.collab.author.<UUID>.plist behind there,
        // because cfprefsd flushed it after the test had deleted it).
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-author-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch = try #require(UserDefaults(suiteName: folder.appendingPathComponent("author").path))
        let previous = AuthorIdentity.defaults
        AuthorIdentity.defaults = scratch
        defer {
            AuthorIdentity.defaults = previous
            try? FileManager.default.removeItem(at: folder)
        }
        AuthorIdentity.set("Alex")
        AuthorIdentity.set("Alex B")
        #expect(AuthorIdentity.current() == "Alex B")
        #expect(AuthorIdentity.names().first == "Alex B")
        #expect(Set(AuthorIdentity.names()).isSuperset(of: ["Alex B", "Alex"]))
        let presenter = AppReviewPresenter(undoManager: UndoManager())
        presenter.actorNameProvider = { AuthorIdentity.current() }
        #expect(presenter.myNames.contains("Alex"), "old entries signed Alex are still mine")
    }

    // MARK: - NL-COLLAB-17 — assignee and due date

    @Test("Assign with a due date, reopen, clear; each is one undo step and a line in the thread")
    @MainActor
    func assignmentRoundTrip() async throws {
        let (environment, _, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = Self.cloud(documentID: documentID, pageID: pageID)
        let b = Self.cloud(documentID: documentID, pageID: pageID)
        try await environment.commands.perform(.addMarkup(a))
        try await environment.commands.perform(.addMarkup(b))
        environment.review.actorNameProvider = { "Ada" }
        let due = try #require(AppReviewPresenter.day(from: "2026-10-01"))
        environment.review.assign([a.id.rawValue, b.id.rawValue], to: "Bo", due: due)
        await environment.review.settle()
        #expect(environment.review.assignment(for: a.id.rawValue)?.assignee == "Bo")
        #expect(environment.review.assignment(for: b.id.rawValue)?.due == due)
        #expect(environment.review.assignment(for: a.id.rawValue)?.isOverdue(today: due.addingTimeInterval(86_400 * 2)) == true)
        #expect(environment.review.assignment(for: a.id.rawValue)?.isOverdue(today: due) == false, "due today is not overdue")

        let reopened = AppReviewPresenter(undoManager: UndoManager())
        reopened.attach(database: database, projectID: documentID.rawValue.uuidString)
        await reopened.settle()
        #expect(reopened.assignment(for: a.id.rawValue)?.assignee == "Bo", "survives reopen")
        let line = try #require(environment.review.thread(for: try await summary(environment, a.id)).items.first {
            if case .assignment = $0.kind { return true } else { return false }
        })
        #expect(line.kind == .assignment(assignee: "Bo", due: due))
        #expect(line.author == "Ada")

        environment.commands.undoManager.undo()
        await environment.review.settle()
        #expect(environment.review.assignment(for: a.id.rawValue) == nil, "one undo takes both assignments back")
        #expect(environment.review.assignment(for: b.id.rawValue) == nil)
        environment.commands.undoManager.redo()
        await environment.review.settle()
        environment.review.assign([a.id.rawValue], to: "", due: nil)
        #expect(environment.review.assignment(for: a.id.rawValue) == nil, "cleared")
        #expect(environment.review.assignment(for: b.id.rawValue)?.assignee == "Bo")
        try? await database.close()
    }

    // MARK: - NL-COLLAB-18 — text-box text apart from its note

    @Test("A committed text box draws its text from caption; its note starts empty")
    @MainActor
    func textToolWritesCaption() {
        let presenter = AppMarkupToolPresenter(documentID: DocumentID(UUID()), pageID: PageID(UUID()))
        var committed: ZPDFContracts.MarkupRecord?
        presenter.onCommit = { committed = $0 }
        presenter.activate(kind: .text, style: ToolStyleSelection(stroke: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1)))
        presenter.placePoint(PDFPointValue(x: 10, y: 10))
        presenter.placePoint(PDFPointValue(x: 110, y: 40))
        presenter.setDraftText("EXISTING WALL")
        presenter.commit()
        #expect(committed?.caption == "EXISTING WALL")
        #expect(committed?.comment == "", "old output: comment == \"EXISTING WALL\"")
    }

    @Test("A legacy text box migrates once: words to caption, note empty; later notes stay notes")
    func legacyTextMigrates() {
        let page = PageID(UUID())
        var legacy = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .callout,
            comment: "SEE DETAIL 4", createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        let migrated = MarkupVisibleText.migratingLegacy(legacy)
        #expect(migrated.caption == "SEE DETAIL 4")
        #expect(migrated.comment == "")
        var noted = migrated
        noted.comment = "Reviewer: detail 4 is superseded"
        #expect(MarkupVisibleText.migratingLegacy(noted) == noted, "a migrated record is never touched again")
        legacy.kind = .cloud
        #expect(MarkupVisibleText.migratingLegacy(legacy) == legacy, "only kinds that draw text")
    }

    @Test("A text box saved the old way reopens with its words drawn and no note")
    func legacyProjectReopens() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        // Exactly what the build before NL-COLLAB-18 committed: the words in `comment`, no caption.
        let old = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: fixture.firstPage.id, kind: .text,
            comment: "EXISTING WALL", author: "Ada",
            geometry: MeasurementGeometry(pageID: fixture.firstPage.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 30)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        _ = try await session.apply(.addMarkup(old))
        let url = directory.url.appendingPathComponent("Legacy.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: url, displayName: "Legacy", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: url) else {
            Issue.record("the saved package did not reopen")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        let record = try #require(stored.markups.first { $0.id == old.id })
        #expect(record.caption == "EXISTING WALL")
        #expect(record.comment == "")
        #expect(MarkupVisibleText.drawnText(of: record) == "EXISTING WALL")
        try await reopened.close()
    }

    @Test("Edit Text rewrites the drawn words only, undoes, and is audited as Text")
    @MainActor
    func editTextCommand() async throws {
        let (environment, session, pageID, documentID, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID, kind: .text,
            comment: "note", caption: "OLD",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 30)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        try await environment.commands.perform(.addMarkup(box))
        #expect(DocumentCommand.editText(id: box.id, text: "x").undoActionName == "Edit Text")
        try await environment.commands.perform(.editText(id: box.id, text: "NEW"))
        #expect(await session.markup(box.id)?.caption == "NEW")
        #expect(await session.markup(box.id)?.comment == "note")
        #expect(try await summary(environment, box.id).drawnText == "NEW")
        await environment.history.settle()
        let change = environment.history.events.last?.changes.first { $0.field == ReviewAuditFields.text }
        #expect(change?.before == "OLD" && change?.after == "NEW")
        await environment.commands.undo()
        #expect(await session.markup(box.id)?.caption == "OLD")
        try? await database.close()
    }
}
