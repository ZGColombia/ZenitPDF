import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZPDFCollaboration
import ZPDFUIPresentation

/// Iteration 2, appcore: Shared Review convergence (S-025) and review import page identity (S-030).
@Suite("Iter2 appcore: review")
struct Iter2AppCoreReviewTests {

    // MARK: S-025

    private static func hole(_ id: UUID, x: Double) -> ZPDFContracts.MarkupRecord {
        var record = SharedReviewSyncTests.area(id)
        record.tool = .polygonCutout
        record.geometry = MeasurementGeometry(pageID: SharedReviewSyncTests.pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: 10), PDFPoint(x: x + 20, y: 10), PDFPoint(x: x + 20, y: 30), PDFPoint(x: x, y: 30)
        ], isClosed: true))])
        return record
    }

    @Test("Deleting an area with cutouts converges on the other machine, whichever UUID sorts first",
          arguments: [true, false])
    @MainActor
    func parentWithCutoutsRemoved(parentSortsFirst: Bool) async throws {
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-folder-\(UUID().uuidString)", isDirectory: true)
        let (a, dbA, dirA) = try await SharedReviewSyncTests.machine()
        let (b, dbB, dirB) = try await SharedReviewSyncTests.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        try syncB.prepare(projectID: "P1", projectName: "Tower")

        let low = "00000000-0000-0000-0000-00000000000"
        let high = "FFFFFFFF-0000-0000-0000-00000000000"
        let parentID = UUID(uuidString: (parentSortsFirst ? low : high) + "1")!
        let holeIDs = [UUID(uuidString: (parentSortsFirst ? high : low) + "2")!,
                       UUID(uuidString: (parentSortsFirst ? high : low) + "3")!]
        // 200 pt × 50 pt at 1 pt = 1 cm is 2 m × 0.5 m = 1 m²; two 20 cm × 20 cm holes, 0.04 m² each.
        let parent = SharedReviewSyncTests.area(parentID, width: 200)
        try await a.commands.perform(.addMarkup(parent))
        try await a.commands.perform(.addCutout(parent: parent.id, cutout: Self.hole(holeIDs[0], x: 20)))
        try await a.commands.perform(.addCutout(parent: parent.id, cutout: Self.hole(holeIDs[1], x: 60)))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(1))
        let received = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(2))
        #expect(received.added == 3)
        #expect(await b.session.markup(parent.id)?.cutoutMarkupIDs.count == 2)
        #expect(await b.session.markup(parent.id)?.measurement?.values[.netArea]?.value == Decimal(string: "0.92"))

        try await a.commands.perform(.removeMarkup(parent.id))
        try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(3))
        // Old behaviour with the parent sorting first: `.removeMarkup(hole)` after the parent's
        // threw unknownMarkup, the batch rolled back and this threw SyncError.refused — and so did
        // every later sync, because the base never moved.
        let removal = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(4))
        #expect(removal.removed == 3)
        #expect(await b.session.orderedMarkups.isEmpty)
        let quiet = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(5))
        #expect(quiet.isQuiet)
        // One undoable step brings the parent back with both holes.
        await b.commands.undo()
        #expect(await b.session.markup(parent.id)?.cutoutMarkupIDs.count == 2)
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("The planned commands skip a cutout whose parent is removed in the same sync")
    @MainActor
    func plannedCommandsSkipOrphanedCutouts() {
        var parent = SharedReviewSyncTests.area(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var hole = Self.hole(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!, x: 20)
        let loose = Self.hole(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000003")!, x: 60)
        hole.parentMarkupID = parent.id
        hole.locked = true
        parent.cutoutMarkupIDs = [hole.id]
        var changes = SharedReviewSyncPlanner.LocalChanges()
        changes.removed = [parent.id, hole.id, loose.id]
        let plan = SharedReviewSync.commands(
            for: changes,
            context: ReviewApplyContext(
                local: [parent.id: parent, hole.id: hole, loose.id: loose],
                livePages: [SharedReviewSyncTests.pageID]
            )
        )
        // Old output: [.setLocked([hole], false), .removeMarkup(parent), .removeMarkup(hole), .removeMarkup(loose)].
        let expected: [DocumentCommand] = [.removeMarkup(parent.id), .removeMarkup(loose.id)]
        #expect(plan.commands.map { String(describing: $0) } == expected.map { String(describing: $0) })
    }

    // MARK: S-030

    static func square(page: Int, index: Int) -> ImportedAnnotation {
        ImportedAnnotation(index: index, pageIndex: page, subtype: "Square", contents: "on PDF page \(page)",
                           rect: PDFRect(x: 100, y: 100, width: 50, height: 50))
    }

    static func reading(_ annotations: [ImportedAnnotation], pages: Int) -> ReviewAnnotationReader.Reading {
        ReviewAnnotationReader.Reading(annotations: annotations, pageCount: pages, pageSizes: [], digest: "it2-s030-\(UUID())")
    }

    @Test("With PDF page 0 removed from the set, each mark lands on the sheet it was drawn on")
    @MainActor
    func removedSheetKeepsMarksOnTheirSheets() async throws {
        let documentID = DocumentID(UUID())
        let pages = (0..<3).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        await session.restoreArrangement(excluded: [pages[0].id], views: [:])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        #expect(await environment.reviewDrawingPageCount() == 3, "the PDF's pages, the removed one included")

        let plan = await environment.planReviewImport(Self.reading([
            Self.square(page: 0, index: 0), Self.square(page: 1, index: 1), Self.square(page: 2, index: 2)
        ], pages: 3))
        // Old output: page 0's mark on sheet A-102, page 1's on A-103, page 2's skipped.
        #expect(plan.newMarkups.count == 2)
        #expect(plan.newMarkups.first { $0.comment.contains("page 1") }?.pageID == pages[1].id)
        #expect(plan.newMarkups.first { $0.comment.contains("page 2") }?.pageID == pages[2].id)
        #expect(!plan.newMarkups.contains { $0.comment.contains("page 0") })
        #expect(plan.skipped.count == 1)
    }

    @Test("In a two-drawing set, marks land on the document's own drawing, never on the other's")
    @MainActor
    func twoDrawingSetImportAndExport() async throws {
        let own = DocumentID(UUID())
        let other = DocumentID(UUID())
        func page(_ drawing: DocumentID, _ index: Int, _ label: String) -> ZPDFContracts.PageDescriptor {
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: drawing, index: index, label: label,
                                         boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792)))
        }
        let pages = [page(own, 0, "A-101"), page(own, 1, "A-102"), page(other, 0, "S-101"), page(other, 1, "S-102")]
        let session = try TakeoffSession(documentID: own, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: own)
        #expect(await environment.reviewDrawingPageCount() == 2)

        let plan = await environment.planReviewImport(Self.reading([Self.square(page: 0, index: 0), Self.square(page: 1, index: 1)], pages: 2))
        // Old output: positions sorted by index were [A-101, S-101, A-102, S-102], so page 1's mark
        // landed on S-101 — another drawing — carrying this drawing's identity.
        #expect(plan.newMarkups.first { $0.comment.contains("page 0") }?.pageID == pages[0].id)
        #expect(plan.newMarkups.first { $0.comment.contains("page 1") }?.pageID == pages[1].id)
        #expect(plan.newMarkups.allSatisfy { $0.documentID == own })

        // XFDF names one PDF: only the own drawing's markups are written.
        try await environment.acceptReviewImport(plan)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: other, pageID: pages[2].id, kind: .rectangle, author: "Bo",
            geometry: MeasurementGeometry(pageID: pages[2].id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 10, y: 10), PDFPoint(x: 60, y: 10), PDFPoint(x: 60, y: 60), PDFPoint(x: 10, y: 60)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )))
        #expect(await environment.session.orderedMarkups.count == 3)
        let data = await environment.exportXFDF(drawingName: "Own.pdf", drawingDigest: nil)
        let written = try XFDF.read(data).annotations.filter { $0.inReplyToIndex == nil }
        // Old output: 3 — S-101's rectangle was written as a page-0 mark of Own.pdf.
        #expect(written.count == 2)
        #expect(Set(written.map(\.pageIndex)) == [0, 1])
    }
}
