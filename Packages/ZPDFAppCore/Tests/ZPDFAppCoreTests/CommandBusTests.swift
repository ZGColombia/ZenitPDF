import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport

/// Undo, over the real session.
///
/// The claim being tested is spec 14.5's: *every* mutation is a command and every command
/// is undoable. So the suite enumerates `MarkupCommandKind` and requires a case for each,
/// which means adding a twelfth mutation without an undo path is a compile error here.
@Suite("Document command bus")
struct CommandBusTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
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

    private static func markup(
        id: MarkupID = MarkupID(UUID()),
        documentID: DocumentID,
        pageID: PageID,
        tool: MeasurementTool? = .area,
        subject: String = "Slab"
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: tool,
            subject: subject,
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

    @Test("Every mutation in spec 14.5 has a command, and every command reports its kind")
    func everyMutationIsACommand() throws {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let markupID = MarkupID(UUID())
        let record = Self.markup(id: markupID, documentID: documentID, pageID: pageID)

        let commands: [DocumentCommand] = [
            .addMarkup(record),
            .removeMarkup(markupID),
            .moveMarkup(id: markupID, dx: 1, dy: 2),
            .changeStyle(id: markupID, style: .default),
            .editVertices(id: markupID, geometry: MeasurementGeometry(pageID: pageID)),
            .changeScale(try ScaleTransform.uniform(
                id: ScaleID(UUID()),
                metresPerPoint: Decimal(string: "0.1")!,
                units: .metric,
                source: .preset
            )),
            .recalculateMeasurements(pageID: nil),
            .addCutout(parent: markupID, cutout: record),
            .editCustomValue(id: markupID, column: ColumnID(UUID()), value: .text("x")),
            .batchStatusChange(ids: [markupID], status: .accepted),
            .reorderPage(from: 0, to: 1),
            .editSubject(id: markupID, subject: "Takfot")
        ]

        // The mapping is onto: every frozen command name is reachable from a case here.
        let kinds = Set(commands.map(\.kind))
        #expect(kinds == Set(MarkupCommandKind.allCases))
        // And every one has undo copy, because "Undo" with no verb is a bug report.
        #expect(commands.allSatisfy { !$0.undoActionName.isEmpty })
    }

    @Test("Adding a markup is undoable and redoable, and the ledger follows both ways")
    @MainActor
    func addIsUndoable() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )

        let id = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id))
        )
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 1)
        #expect(environment.commands.lastCommandKind == .addMarkup)

        await environment.commands.undo()
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 0)
        #expect(await session.markup(id) == nil)

        await environment.commands.redo()
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 1)
        #expect(await session.markup(id) != nil)
    }

    @Test("A subject edit lands in the record and the ledger, and one undo restores the old name")
    @MainActor
    func subjectEditIsUndoableAndTheLedgerFollows() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await environment.commands.calibrate(
            page: try #require(await environment.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let id = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id, subject: "Length"))
        )

        let revisionBefore = environment.ledger.contentRevision
        try await environment.commands.perform(.editSubject(id: id, subject: "Takfot"))
        await environment.refresh()
        #expect(await session.markup(id)?.subject == "Takfot")
        #expect(environment.snapshot.markups.first { $0.id == id.rawValue }?.subject == "Takfot",
                "the summary the ledger and the inspector render from must carry the new subject")
        #expect(environment.ledger.contentRevision > revisionBefore,
                "a projection swap must move the ledger pane's reload cue even though the row count did not change")

        await environment.commands.undo()
        await environment.refresh()
        #expect(await session.markup(id)?.subject == "Length", "one undo restores the old subject")

        await environment.commands.redo()
        await environment.refresh()
        #expect(await session.markup(id)?.subject == "Takfot")
    }

    @Test("Deleting a parent takes its cutouts and puts all of them back on undo")
    @MainActor
    func deletingAParentRestoresItsCutouts() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await environment.commands.calibrate(
            page: try #require(await environment.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )

        let parentID = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.markup(id: parentID, documentID: documentID, pageID: page.id))
        )
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addCutout(
            parent: parentID,
            cutout: Self.markup(
                id: cutoutID,
                documentID: documentID,
                pageID: page.id,
                tool: .polygonCutout,
                subject: "Opening"
            )
        ))
        #expect(await session.markup(parentID)?.cutoutMarkupIDs == [cutoutID])

        try await environment.commands.perform(.removeMarkup(parentID))
        #expect(await session.markup(parentID) == nil)
        #expect(await session.markup(cutoutID) == nil, "a cutout without its parent is orphaned")

        await environment.commands.undo()
        #expect(await session.markup(parentID) != nil)
        #expect(await session.markup(cutoutID) != nil, "both come back together")
        #expect(await session.markup(parentID)?.cutoutMarkupIDs == [cutoutID])
    }

    @Test("A batch status change is one undo step, not one per markup")
    @MainActor
    func batchStatusIsOneStep() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        var ids: [MarkupID] = []
        for index in 0..<5 {
            let id = MarkupID(UUID())
            ids.append(id)
            try await environment.commands.perform(.addMarkup(
                Self.markup(id: id, documentID: documentID, pageID: page.id, subject: "Slab \(index)")
            ))
        }

        try await environment.commands.perform(.batchStatusChange(ids: ids, status: .accepted))
        for id in ids {
            #expect(await session.markup(id)?.status == .accepted)
        }

        await environment.commands.undo()
        for id in ids {
            #expect(await session.markup(id)?.status == MarkupStatus.none, "one undo restores all five")
        }
        // The five adds are still on the stack, which is how we know only one step was popped.
        #expect(environment.commands.undoManager.canUndo)
    }

    @Test("Moving a markup translates its geometry and undo puts it back exactly")
    @MainActor
    func moveIsExactlyReversible() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id))
        )
        let before = try #require(await session.markup(id)?.geometry)

        try await environment.commands.perform(.moveMarkup(id: id, dx: 12.5, dy: -3.25))
        let moved = try #require(await session.markup(id)?.geometry)
        #expect(moved.polygons[0].outer.points[0].x == before.polygons[0].outer.points[0].x + 12.5)
        #expect(moved.polygons[0].outer.points[0].y == before.polygons[0].outer.points[0].y - 3.25)

        await environment.commands.undo()
        let restored = try #require(await session.markup(id)?.geometry)
        #expect(restored == before, "exactly, not approximately: undo restores the stored value")
    }

    @Test("Reordering pages keeps each page's PDF index and undo restores the original order")
    @MainActor
    func pageReorderIsUndoable() async throws {
        let (environment, session, _, _) = try await makeEnvironment()
        let before = await session.pageDescriptors.map(\.label)
        #expect(before == ["A-101", "A-102"])

        try await environment.commands.perform(.reorderPage(from: 0, to: 1))
        let after = await session.pageDescriptors
        #expect(after.map(\.label) == ["A-102", "A-101"])
        // ADR-0022: `index` is the page's index in its own PDF and never moves. This used to
        // expect [0, 1] ("indices are rewritten"), which put the wrong PDF page under A-102.
        #expect(after.map(\.index) == [1, 0], "each sheet keeps its own PDF page")

        await environment.commands.undo()
        #expect(await session.pageDescriptors.map(\.label) == ["A-101", "A-102"])
        #expect(await session.pageDescriptors.map(\.index) == [0, 1])
    }

    @Test("A refused command changes nothing and leaves the undo stack alone")
    @MainActor
    func refusedCommandIsInert() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await environment.commands.perform(
            .addMarkup(Self.markup(documentID: documentID, pageID: page.id))
        )
        let stackDepthBefore = environment.commands.undoManager.canUndo

        await #expect(throws: DocumentCommandError.self) {
            try await environment.commands.perform(.removeMarkup(MarkupID(UUID())))
        }
        #expect(environment.commands.lastError != nil)
        #expect(await session.orderedMarkups.count == 1)
        #expect(environment.commands.undoManager.canUndo == stackDepthBefore)

        // And undoing now undoes the *add*, not a phantom entry for the refusal.
        await environment.commands.undo()
        #expect(await session.orderedMarkups.isEmpty)
    }

    @Test("The document's first calibration is undoable, and redo reinstalls it")
    @MainActor
    func firstCalibrationIsUndoable() async throws {
        // Regression, found by the CORE_LOOP acceptance test: the first calibration's
        // before-state has no scale to reinstate, so its inverse used to come out empty,
        // no undo was registered, and the one mutation CORE_LOOP promises is always
        // reversible ("one ⌘Z returns to the previous scale") silently was not.
        let (environment, session, _, _) = try await makeEnvironment()
        #expect(await session.firstPageScale == nil)

        try await environment.commands.calibrate(
            page: try #require(await environment.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 360, y: 72),
            knownLength: 28.8,
            knownLengthUnit: .metre
        )
        let installed = try #require(await session.firstPageScale)
        #expect(environment.commands.undoManager.canUndo, "the first calibration registers undo")

        await environment.commands.undo()
        #expect(await session.firstPageScale == nil, "one ⌘Z removes the first scale entirely")
        let orphanPage = try #require(await environment.session.firstPageID)
        #expect(await session.scale(onPage: orphanPage, scaleID: installed.id) == nil,
                "no orphaned scale is left behind")

        #expect(environment.commands.undoManager.canRedo)
        await environment.commands.redo()
        let redone = try #require(await session.firstPageScale)
        #expect(redone.id == installed.id)
        #expect(redone.matrix == installed.matrix, "redo reinstalls the identical scale")
    }

    @Test("A locked markup is not edited silently")
    @MainActor
    func lockedMarkupRefuses() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        var record = Self.markup(id: id, documentID: documentID, pageID: page.id)
        record.locked = true
        try await environment.commands.perform(.addMarkup(record))

        await #expect(throws: DocumentCommandError.self) {
            try await environment.commands.perform(.moveMarkup(id: id, dx: 5, dy: 5))
        }
        #expect(await session.markup(id)?.geometry == record.geometry)
    }
}
