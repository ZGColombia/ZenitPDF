import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation

/// NL-COLLAB-08: a reviewer's PDF annotations become Zenit markups, replies and status changes.
@Suite("Collaboration — review annotation import")
struct CollaborationImportTests {

    /// A one-page PDF whose page carries the given annotation dictionaries, in order. Written by
    /// hand so every coordinate and reference is known exactly.
    static func pdf(annotations: [String], pageSize: (Double, Double) = (600, 800)) -> Data {
        var objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageSize.0) \(pageSize.1)] /Annots [\((0..<annotations.count).map { "\($0 + 4) 0 R" }.joined(separator: " "))] >>"
        ]
        objects.append(contentsOf: annotations)
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static let ownID = UUID(uuidString: "5B1D8E3C-2F4A-4C7E-9E0B-6A1B2C3D4E5F")!

    /// Seven annotations: three reviewer shapes, two replies, one state change, one of Zenit's own.
    static var reviewFixture: Data {
        pdf(annotations: [
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /NM (sq-1) /T (Bo) /Contents (Check slab edge) /Subj (Structure) /C [1 0 0] /BS << /W 2 >> /CreationDate (D:20260923101500Z) >>",
            "<< /Type /Annot /Subtype /Line /Rect [300 300 400 400] /L [310 320 390 380] /LE [/None /OpenArrow] /NM (ln-1) /T (Bo) >>",
            "<< /Type /Annot /Subtype /Polygon /Rect [50 500 250 700] /Vertices [50 500 250 500 250 700 50 700] /BE << /S /C /I 1 >> /NM (cl-1) /T (Cy) /Contents (Revise) >>",
            "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /IRT 4 0 R /NM (r-1) /T (Cy) /Contents (Agreed, see A-201) /CreationDate (D:20260923110000Z) /F 30 >>",
            "<< /Type /Annot /Subtype /Text /Rect [300 300 320 320] /IRT 5 0 R /NM (r-2) /T (Bo) /Contents (Move this 200 mm?) /CreationDate (D:20260923111500Z) /F 30 >>",
            "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /IRT 4 0 R /NM (s-1) /T (Cy) /StateModel (Review) /State (Accepted) /M (D:20260923120000Z) /F 30 >>",
            "<< /Type /Annot /Subtype /Square /Rect [10 10 20 20] /NM (\(ownID.uuidString)) /ZPDFMarkup true >>"
        ])
    }

    @Test("The reader reads page-space coordinates, replies and states the way the file holds them")
    func readerReadsRawDictionaries() throws {
        let reading = try ReviewAnnotationReader.read(data: Self.reviewFixture)
        #expect(reading.pageCount == 1)
        #expect(reading.annotations.count == 7)
        let line = reading.annotations[1]
        // PDFKit would say (10, 20)–(90, 80): relative to /Rect. The file says page space.
        #expect(line.points == [PDFPoint(x: 310, y: 320), PDFPoint(x: 390, y: 380)])
        #expect(line.lineEndings == ["None", "OpenArrow"])
        #expect(reading.annotations[2].cloudy)
        #expect(reading.annotations[3].inReplyToIndex == 0)
        #expect(reading.annotations[4].inReplyToIndex == 1)
        #expect(reading.annotations[5].stateModel == "Review")
        #expect(reading.annotations[5].state == "Accepted")
        #expect(reading.annotations[6].zenitOwned)
        #expect(reading.annotations[0].author == "Bo")
        #expect(reading.annotations[0].lineWidth == 2)
        #expect(reading.annotations[0].creationDate == ISO8601DateFormatter().date(from: "2026-09-23T10:15:00Z"))
    }

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, MarkupID, ProjectDatabaseActor, URL) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 600, height: 800))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        // Zenit's own markup, the one the seventh annotation was exported from.
        let own = ZPDFContracts.MarkupRecord(
            id: MarkupID(Self.ownID), documentID: documentID, pageID: page.id, kind: .rectangle, author: "Ada",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 10), PDFPoint(x: 20, y: 20), PDFPoint(x: 10, y: 20)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        try await environment.commands.perform(.addMarkup(own))
        await environment.refresh()
        return (environment, own.id, database, directory)
    }

    /// The acceptance criteria: previews as "3 new markups, 2 replies, 1 status change, 1 already in
    /// project"; accept is one undo step; re-importing the same file adds nothing.
    @Test("A reviewer's file previews, imports as one step, and a second import adds nothing")
    @MainActor
    func importAcceptance() async throws {
        let (environment, _, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reading = try ReviewAnnotationReader.read(data: Self.reviewFixture)
        let plan = await environment.planReviewImport(reading)
        #expect(plan.newMarkups.count == 3)
        #expect(plan.replies.count == 2)
        #expect(plan.statusChanges.count == 1)
        #expect(plan.alreadyInProject == 1)
        #expect(plan.summary == "3 new markups, 2 replies, 1 status change, 1 already in project")
        #expect(plan.newMarkups.map(\.kind) == [.rectangle, .arrow, .cloud])
        #expect(plan.newMarkups[0].author == "Bo")
        #expect(plan.newMarkups[0].comment == "Check slab edge")
        #expect(plan.newMarkups[0].subject == "Structure")
        #expect(plan.newMarkups.allSatisfy { $0.tool == nil && $0.measurement == nil }, "never a quantity")
        #expect(plan.countsByAuthor["Bo"] == 3 && plan.countsByAuthor["Cy"] == 3)

        let before = await environment.session.orderedMarkups.count
        _ = try await environment.acceptReviewImport(plan)
        await environment.review.settle()
        #expect(await environment.session.orderedMarkups.count == before + 3)
        let square = try #require(environment.snapshot.markups.first { $0.id == plan.newMarkups[0].id.rawValue })
        #expect(square.status == .accepted, "the reviewer's state reply")
        let thread = environment.review.thread(for: square)
        #expect(thread.items.contains { $0.kind == .reply && $0.author == "Cy" && $0.text == "Agreed, see A-201" })

        // A second import of the same file finds everything already there.
        let again = await environment.planReviewImport(reading)
        #expect(again.newMarkups.isEmpty)
        #expect(again.replies.isEmpty)
        #expect(again.alreadyInProject == 4)
        #expect(again.repliesAlreadyInProject == 2)

        // One undo takes every imported markup back.
        await environment.commands.undo()
        #expect(await environment.session.orderedMarkups.count == before)
        try? await database.close()
    }

    @Test("Ink, highlight, underline, free text, callout and note map to drawable kinds; stamps are said, not dropped")
    func mappingTable() throws {
        let data = Self.pdf(annotations: [
            "<< /Type /Annot /Subtype /Ink /Rect [0 0 100 100] /InkList [[10 10 20 20 30 10] [40 40 50 50]] /NM (ink) >>",
            "<< /Type /Annot /Subtype /Highlight /Rect [50 600 250 620] /QuadPoints [50 620 250 620 50 600 250 600] /NM (hl) /C [1 1 0] >>",
            "<< /Type /Annot /Subtype /StrikeOut /Rect [50 580 250 590] /QuadPoints [50 590 250 590 50 580 250 580] /NM (so) >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [300 100 400 140] /Contents (DEMOLISH) /NM (ft) >>",
            "<< /Type /Annot /Subtype /FreeText /IT /FreeTextCallout /CL [250 90 300 120] /Rect [300 100 400 140] /Contents (SEE DETAIL) /NM (co) >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Question for the architect) /NM (nt) >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [0 0 50 50] /NM (st) >>"
        ])
        let reading = try ReviewAnnotationReader.read(data: data)
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 600, height: 800))
        )
        let plan = AnnotationImportPlanner.plan(
            annotations: reading.annotations, pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest
        )
        #expect(plan.newMarkups.map(\.kind) == [.polyline, .polyline, .rectangle, .line, .text, .callout, .note])
        #expect(plan.newMarkups[0].geometry?.points == [PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 20), PDFPoint(x: 30, y: 10)])
        #expect(plan.newMarkups[2].style.fill != nil, "a highlight is a filled box")
        #expect(plan.newMarkups[3].geometry?.points == [PDFPoint(x: 50, y: 585), PDFPoint(x: 250, y: 585)], "strike-out through the middle")
        #expect(plan.newMarkups[4].caption == "DEMOLISH" && plan.newMarkups[4].comment == "", "free text is drawn text, not a note")
        #expect(plan.newMarkups[5].geometry?.points.first == PDFPoint(x: 250, y: 90), "the callout's target")
        #expect(plan.newMarkups[6].comment == "Question for the architect")
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.hasPrefix("Stamp") == true)
        // The ids are stable: the same file plans the same ids.
        let replan = AnnotationImportPlanner.plan(
            annotations: reading.annotations, pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest
        )
        #expect(replan.newMarkups.map(\.id) == plan.newMarkups.map(\.id))
    }

    @Test("Hostile input: the fixture corpus, a reply cycle, non-finite numbers and a flood are all survived")
    func hostileInput() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 600, height: 800))
        )
        for kind: FixtureKind in [.truncatedFile, .brokenXref, .cyclicPageTree, .missingObject, .deeplyNestedForms,
                                  .decompressionBomb, .encryptedUserPassword, .embeddedFileWithLaunchAction, .javaScriptAction] {
            let fixture = try ZPDFFixtures.make(kind, in: directory.url)
            if let reading = try? ReviewAnnotationReader.read(url: fixture.url) {
                _ = AnnotationImportPlanner.plan(
                    annotations: reading.annotations, pages: [page], documentID: page.documentID,
                    existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest
                )
            }
        }
        // A reply to itself, a polygon with a NaN-looking vertex list and a far-away rectangle.
        let cyclic = Self.pdf(annotations: [
            "<< /Type /Annot /Subtype /Text /Rect [0 0 10 10] /IRT 4 0 R /Contents (loop) >>",
            "<< /Type /Annot /Subtype /Polygon /Rect [0 0 1 1] /Vertices [0 0 1e400 1 2] >>",
            "<< /Type /Annot /Subtype /Square /Rect [1e30 1e30 2e30 2e30] >>"
        ])
        let reading = try ReviewAnnotationReader.read(data: cyclic)
        let plan = AnnotationImportPlanner.plan(
            annotations: reading.annotations, pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest
        )
        #expect(plan.replies.isEmpty, "a reply to itself answers nothing")
        // A flood: more than the cap is cut and said.
        let many = (0..<(AnnotationImportPlanner.maximumAnnotations + 5)).map { index in
            ImportedAnnotation(index: index, pageIndex: 0, subtype: "Square", rect: PDFRect(x: 0, y: 0, width: 1, height: 1))
        }
        let flooded = AnnotationImportPlanner.plan(
            annotations: many, pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "x"
        )
        #expect(flooded.newMarkups.count == AnnotationImportPlanner.maximumAnnotations)
        #expect(flooded.skipped.first?.contains("beyond") == true)
    }
}
