import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// The Inspector's Notes field writes the markup's comment.
///
/// `MarkupRecord.comment` was stored, persisted, searched and displayed, and nothing could
/// change it. The Inspector sent `values[.comment]` through `applyBulkEdit`, which matched no
/// case, built an empty batch and answered `LedgerBulkEditReceipt(undoActionName:)` — a
/// success with **no changed markup and no failure** — while the comment stayed as it was.
/// These drive the shipping presenter, command bus and archive; no double stands in for any.
@Suite("Comment edits reach the document")
struct CommentEditTests {

    private static func markup(documentID: DocumentID, pageID: PageID, comment: String = "") -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            label: "Room 1",
            comment: comment,
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

    @MainActor
    private func makeEnvironment(comment: String = "") async throws
        -> (AppCoreEnvironment, TakeoffSession, MarkupID, [ZPDFContracts.PageDescriptor], DocumentID) {
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
        let record = Self.markup(documentID: documentID, pageID: page.id, comment: comment)
        try await environment.commands.perform(.addMarkup(record))
        await environment.ledger.refresh()
        return (environment, session, record.id, [page], documentID)
    }

    @Test("A Notes edit changes the comment and says so — the old path answered success and changed nothing")
    @MainActor
    func notesEditLands() async throws {
        let (environment, session, id, _, _) = try await makeEnvironment()
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [id.rawValue],
            values: [.comment: .text("Verify finish with architect")]
        ))
        // Old output: changedMarkupIDs == [], failureDescription == nil, comment == "".
        #expect(receipt.failureDescription == nil)
        #expect(receipt.changedMarkupIDs == [id.rawValue], "the edit reports the markup it changed")
        #expect(await session.markup(id)?.comment == "Verify finish with architect")
        #expect(environment.canvas.visibleMarkups.first { $0.id == id.rawValue }?.comment == "Verify finish with architect",
                "the summary the Inspector reads follows the edit")
    }

    @Test("The command itself is one undoable step named Edit Notes")
    @MainActor
    func commandUndoes() async throws {
        let (environment, session, id, _, _) = try await makeEnvironment(comment: "before")
        #expect(DocumentCommand.editComment(id: id, comment: "x").undoActionName == "Edit Notes")
        #expect(DocumentCommand.editComment(id: id, comment: "x").kind == .editCustomValue)
        try await environment.commands.perform(.editComment(id: id, comment: "after"))
        #expect(await session.markup(id)?.comment == "after")
        await environment.commands.undo()
        #expect(await session.markup(id)?.comment == "before")
    }

    @Test("A bulk Notes edit undoes in one step")
    @MainActor
    func bulkEditUndoes() async throws {
        let (environment, session, id, _, _) = try await makeEnvironment(comment: "before")
        _ = await environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [id.rawValue], values: [.comment: .text("after")]))
        #expect(await session.markup(id)?.comment == "after")
        await environment.commands.undo()
        #expect(await session.markup(id)?.comment == "before")
    }

    @Test("Clearing a note or a label writes the empty string instead of being ignored")
    @MainActor
    func clearingWritesEmpty() async throws {
        let (environment, session, id, _, _) = try await makeEnvironment(comment: "remove me")
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [id.rawValue], values: [.comment: .empty, .label: .empty]
        ))
        #expect(receipt.changedMarkupIDs == [id.rawValue])
        #expect(await session.markup(id)?.comment == "")
        #expect(await session.markup(id)?.label == "")
    }

    @Test("An unchanged note is not a command")
    @MainActor
    func unchangedIsNoCommand() async throws {
        let (environment, _, id, _, _) = try await makeEnvironment(comment: "same")
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [id.rawValue], values: [.comment: .text("same")]))
        #expect(receipt.changedMarkupIDs.isEmpty && receipt.failureDescription == nil)
    }

    @Test("An edited note survives save and reopen")
    func notesRoundTrip() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        let record = Self.markup(documentID: fixture.documentID, pageID: pageID)
        _ = try await session.apply(.addMarkup(record))
        _ = try await session.apply(.editComment(id: record.id, comment: "Confirm plumbing layout"))

        let packageURL = directory.url.appendingPathComponent("Notes.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Notes", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()

        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("the saved package did not reopen")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        #expect(stored.markups.first { $0.id == record.id }?.comment == "Confirm plumbing layout")
        try await reopened.close()
    }
    // MARK: - Fill

    @Test("A fill edit sets MarkupStyle.fill, reaches the summary, undoes, and removesFill clears it")
    @MainActor
    func fillEdit() async throws {
        let (environment, session, id, _, _) = try await makeEnvironment()
        #expect(await session.markup(id)?.style.fill == nil)
        #expect(environment.canvas.visibleMarkups.first { $0.id == id.rawValue }?.fillRGBA == nil)

        let fill = ColorRGBA(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.2)
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [id.rawValue], style: MarkupStyleEdit(fill: fill)
        ))
        #expect(receipt.changedMarkupIDs == [id.rawValue])
        let stored = try #require(await session.markup(id)?.style.fill)
        #expect(abs(stored.alpha - 0.2) < 0.001 && abs(stored.blue - 0.9) < 0.001)
        let shown = try #require(environment.canvas.visibleMarkups.first { $0.id == id.rawValue }?.fillRGBA)
        #expect(abs(shown.alpha - 0.2) < 0.001)

        await environment.commands.undo()
        #expect(await session.markup(id)?.style.fill == nil)

        _ = await environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [id.rawValue], style: MarkupStyleEdit(fill: fill)))
        _ = await environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [id.rawValue], style: MarkupStyleEdit(removesFill: true)))
        #expect(await session.markup(id)?.style.fill == nil)
    }

    @Test("A fill survives save and reopen")
    func fillRoundTrip() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        var record = Self.markup(documentID: fixture.documentID, pageID: pageID)
        _ = try await session.apply(.addMarkup(record))
        record.style.fill = RGBAColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.2)
        _ = try await session.apply(.changeStyle(id: record.id, style: record.style))

        let packageURL = directory.url.appendingPathComponent("Fill.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(at: packageURL, displayName: "Fill", originalPDF: fixture.url)
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        _ = try await package.save()
        try await package.close()
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("the saved package did not reopen")
            return
        }
        let stored = try #require(try await TakeoffArchive.read(from: reopened))
        #expect(stored.markups.first { $0.id == record.id }?.style.fill == record.style.fill)
        try await reopened.close()
    }
}
