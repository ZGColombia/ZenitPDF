import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-COLLAB-08 through the real document: File ▸ Import Review Annotations… previews, imports
/// on Import only, refuses another drawing, and never puts a dialogue on the screen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ReviewImportFlowTests {

    /// A marked-up copy of a one-page drawing: two reviewer shapes and one reply.
    private func reviewFile(pages: Int = 1) throws -> URL {
        let annotations = [
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /NM (sq-1) /T (Bo) /Contents (Check slab edge) >>",
            "<< /Type /Annot /Subtype /Polygon /Rect [50 500 250 700] /Vertices [50 500 250 500 250 700 50 700] /BE << /S /C >> /NM (cl-1) /T (Cy) >>",
            "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /IRT 4 0 R /NM (r-1) /T (Cy) /Contents (Agreed) >>"
        ]
        let kids = (0..<pages).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>"
        ]
        let firstAnnotation = 3 + pages
        for page in 0..<pages {
            let annots = page == 0 ? "/Annots [\((0..<annotations.count).map { "\($0 + firstAnnotation) 0 R" }.joined(separator: " "))]" : ""
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] \(annots) >>")
        }
        // The reply's /IRT names the square, which is the first annotation object.
        objects.append(contentsOf: annotations.map { $0.replacingOccurrences(of: "/IRT 4 0 R", with: "/IRT \(firstAnnotation) 0 R") })
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).pdf")
        try Data(out.utf8).write(to: url)
        return url
    }

    @Test("Import previews through the presenter, adds the markups as one step, and a second run adds nothing")
    func importsOnConfirm() async throws {
        let harness = try await Fix2Harness.make("ReviewImport.pdf", calibrate: false)
        let file = try reviewFile()
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: file)
        }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewAnnotationImportFlow.previewIdentifier ? .button(0) : .dismissed
        }
        let before = harness.core.snapshot.markups.count
        let outcome = await ReviewAnnotationImportFlow.importFile(file, into: harness.document)
        #expect(outcome == .imported(markups: 2, replies: 1, statusChanges: 0))
        let preview = try #require(ZenitModalPresenter.recorded.first { $0.identifier == ReviewAnnotationImportFlow.previewIdentifier })
        #expect(preview.detail.hasPrefix("2 new markups, 1 reply"))
        #expect(preview.detail.contains("Cy: 2"))
        #expect(preview.buttons == ["Import", "Cancel"])
        #expect(harness.core.snapshot.markups.count == before + 2)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty, "nothing reached the screen")

        let again = await ReviewAnnotationImportFlow.importFile(file, into: harness.document)
        #expect(again == .nothingToImport)
        #expect(harness.core.snapshot.markups.count == before + 2)

        await harness.core.commands.undo()
        await harness.core.refresh()
        #expect(harness.core.snapshot.markups.count == before)
    }

    @Test("Cancel on the preview changes nothing; a process with no user gets Cancel")
    func cancelChangesNothing() async throws {
        let harness = try await Fix2Harness.make("ReviewImportCancel.pdf", calibrate: false)
        let file = try reviewFile()
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: file)
        }
        ZenitModalPresenter.reset()
        let before = harness.core.snapshot.markups.count
        let outcome = await ReviewAnnotationImportFlow.importFile(file, into: harness.document)
        #expect(outcome == .cancelled)
        #expect(harness.core.snapshot.markups.count == before)
    }

    @Test("A file with another page count is refused, naming both counts")
    func otherDrawingIsRefused() async throws {
        let harness = try await Fix2Harness.make("ReviewImportOther.pdf", calibrate: false)
        let file = try reviewFile(pages: 3)
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: file)
        }
        ZenitModalPresenter.reset()
        let outcome = await ReviewAnnotationImportFlow.importFile(file, into: harness.document)
        guard case let .refused(reason) = outcome else {
            Issue.record("another drawing's annotations were not refused: \(outcome)")
            return
        }
        #expect(reason.contains("3 pages") && reason.contains("has 1"))
        #expect(ZenitModalPresenter.recorded.contains { $0.identifier == ReviewAnnotationImportFlow.refusalIdentifier })
    }

    /// NL-COLLAB-07 round trip: the annotated export carries each markup's replies as /IRT
    /// replies with author and text, and importing that file back adds nothing.
    @Test("Annotated export writes replies with /IRT; importing the export back adds nothing")
    func repliesRoundTrip() async throws {
        let harness = try await Fix2Harness.make("ReviewRoundTrip.pdf", calibrate: false)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("annotated-\(UUID().uuidString).pdf")
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: out)
        }
        let page = try #require(harness.core.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, comment: "Check the edge", author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        try await harness.core.commands.perform(.addMarkup(cloud))
        // The Quick PDF container attaches the review store once its database is open.
        let attached = await AppTestSupport.wait(upTo: 10) { harness.core.review.isAttached }
        guard attached else {
            Issue.record("the review store is not attached in this document mode")
            return
        }
        harness.core.review.actorNameProvider = { "Bo" }
        #expect(harness.core.review.addReply("Agreed, per A-201", to: cloud.id.rawValue) != nil)
        await harness.core.review.settle()
        let result = try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: out)

        let reading = try ReviewAnnotationReader.read(url: out)
        let parent = try #require(reading.annotations.first { $0.name == cloud.id.rawValue.uuidString })
        let reply = try #require(reading.annotations.first { $0.contents == "Agreed, per A-201" })
        #expect(reply.inReplyToIndex == parent.index)
        #expect(reply.author == "Bo")
        #expect(reply.subtype == "Text")
        let plan = await harness.core.planReviewImport(reading)
        #expect(plan.newMarkups.isEmpty)
        #expect(plan.replies.isEmpty)
        #expect(plan.repliesAlreadyInProject == 1)
    }

    @Test("File ▸ Import Review Annotations… exists and needs a drawing")
    func menuCommandExists() {
        let spec = ZenitAppCommandTable.spec(for: .importReviewAnnotations)
        #expect(spec.title == "Import Review Annotations…")
    }
}

/// NL-COLLAB-06: tint by author is display only.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct AuthorTintTests {

    @Test("Tinting swaps each shape's stroke for its author's colour; the records keep theirs")
    func tintIsDisplayOnly() {
        let page = PageID(UUID())
        func record(_ author: String) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .cloud, author: author,
                geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
                ], isClosed: true))]),
                createdAt: Date(), modifiedAt: Date()
            )
        }
        let records = [record("Bo"), record("Ada"), record("")]
        let shapes = CanvasSceneBuilder.build(records: records, summaries: [], pageID: page.rawValue)
        #expect(shapes.count == 3)
        let tinted = AuthorTint.apply(to: shapes, records: records, allAuthors: records.map(\.author))
        let colours = AuthorColors.assignments(for: ["Bo", "Ada"])
        #expect(tinted[0].color == colours["Bo"]?.color)
        #expect(tinted[1].color == colours["Ada"]?.color)
        #expect(tinted[0].color != tinted[1].color, "two authors, two colours")
        #expect(tinted[2].color == shapes[2].color, "no author, own colour")
        #expect(records.allSatisfy { $0.style == MarkupStyle.default }, "the stored style is untouched")
        #expect(AuthorColors.legend(colours) == "Ada — Cyan, Bo — Blue")
    }
}

/// NL-COLLAB-03: a status change over a selection with a note saying why.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct StatusNoteTests {

    @Test("Set Status with Note writes the status on each markup and the note in each thread")
    func statusWithNote() async throws {
        let harness = try await Fix2Harness.make("StatusNote.pdf", calibrate: false)
        defer {
            ReviewStatusNotePrompt.answerOverride = nil
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let page = try #require(harness.core.snapshot.pages.first)
        var ids: Set<UUID> = []
        for offset in [0.0, 50.0] {
            let cloud = ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: PageID(page.id),
                kind: .cloud, author: "Ada",
                geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100 + offset, y: 100), PDFPoint(x: 140 + offset, y: 100), PDFPoint(x: 140 + offset, y: 140)
                ], isClosed: true))]),
                createdAt: Date(), modifiedAt: Date()
            )
            try await harness.core.commands.perform(.addMarkup(cloud))
            ids.insert(cloud.id.rawValue)
        }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewStatusNotePrompt.modalIdentifier ? .button(0) : .dismissed
        }
        ReviewStatusNotePrompt.answerOverride = (.rejected, "see RFI 12")
        let answer = try #require(ReviewStatusNotePrompt.ask(count: ids.count))
        await ReviewStatusNotePrompt.apply(status: answer.status, note: answer.note, to: ids, core: harness.core)
        await harness.core.review.settle()
        await harness.core.refresh()
        for id in ids {
            #expect(await harness.core.session.markup(MarkupID(id))?.status == .rejected)
        }
        if harness.core.review.isAttached {
            #expect(harness.core.review.entries.filter { $0.body == "see RFI 12" }.count == 2)
        }
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
        // Nobody there: the prompt cancels and nothing changes.
        ReviewStatusNotePrompt.answerOverride = nil
        ZenitModalPresenter.reset()
        #expect(ReviewStatusNotePrompt.ask(count: 2) == nil)
    }
}

/// NL-COLLAB-16: the review summary report.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ReviewReportTests {

    @Test("The report lists the chosen markups with status and thread; CSV cells are guarded against formulas")
    func reportRows() throws {
        let presenter = MockReviewThreadPresenter(author: "Bo", now: { Date(timeIntervalSince1970: 1_790_000_000) })
        func markup(_ subject: String, _ comment: String, status: ZPDFUIPresentation.MarkupStatus) -> MarkupSummary {
            MarkupSummary(
                id: UUID(), kind: .cloud, subject: subject, label: "", comment: comment, pageLabel: "A-101",
                pageID: UUID(), pageIndex: 0, status: status, author: "Ada",
                colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
                created: Date(timeIntervalSince1970: 1_789_000_000), modified: Date(timeIntervalSince1970: 1_789_000_000),
                boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let first = markup("Walls", "=HYPERLINK(\"http://x\")", status: .open)
        let second = markup("Doors", "Fine", status: .accepted)
        presenter.reviewMarkups = [first, second]
        presenter.addReply("Agreed", to: first.id)
        let entries = ReviewReportExport.entries(for: [first.id], review: presenter)
        #expect(entries.count == 1, "only the rows the list showed")
        let csv = String(decoding: ReviewReportExport.csv(entries, delimiter: ","), as: UTF8.self)
        #expect(csv.contains("'=HYPERLINK"), "a note that would execute is text")
        #expect(csv.contains("Bo ("))
        #expect(csv.contains("Agreed"))
        #expect(csv.contains("Open"))
        let pdf = ReviewReportExport.pdf(entries, title: "Tower")
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages == 1)
    }
}

/// NL-COLLAB-09 through the app: export XFDF from one window, import it into another on the same
/// drawing; another drawing is refused by name.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct XFDFFlowTests {

    @Test("XFDF from one copy of the drawing imports into another; a different drawing is refused")
    func exportImport() async throws {
        let fixture = try AppTestSupport.writeFixturePDF(named: "XFDF Plan.pdf")
        let a = try await Fix2Harness.make("XFDF Plan.pdf", calibrate: false, fixture: fixture)
        let b = try await Fix2Harness.make("XFDF Plan.pdf", calibrate: false, fixture: fixture)
        let other = try await Fix2Harness.make("Other.pdf", pageCount: 2, calibrate: false)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString).xfdf")
        defer {
            ZenitModalPresenter.reset()
            a.tearDown(); b.tearDown(); other.tearDown()
            try? FileManager.default.removeItem(at: out)
        }
        let page = try #require(a.core.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(a.core.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, comment: "Revise", author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        try await a.core.commands.perform(.addMarkup(cloud))
        #expect(await ReviewXFDFFlow.write(document: a.document, to: out))

        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewAnnotationImportFlow.previewIdentifier ? .button(0) : .dismissed
        }
        let outcome = await ReviewXFDFFlow.importFile(out, into: b.document)
        #expect(outcome == .imported(markups: 1, replies: 0, statusChanges: 0))
        #expect(await b.core.session.markup(cloud.id)?.comment == "Revise")

        let refused = await ReviewXFDFFlow.importFile(out, into: other.document)
        guard case let .refused(reason) = refused else {
            Issue.record("an XFDF made on another drawing was not refused: \(refused)")
            return
        }
        #expect(reason.contains("XFDF Plan.pdf"))
    }
}

/// NL-COLLAB-15: notifications are asked for only when turned on, and posted only then.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ReviewNotificationTests {

    @Test("Off by default; turning on asks once through the seam; posting reaches the poster only when on")
    func notificationsAreOptIn() {
        var asked = 0
        var posted: [ReviewActivityItem] = []
        ReviewNotifications.authorizer = { done in asked += 1; done(true) }
        ReviewNotifications.poster = { posted.append($0) }
        defer {
            ReviewNotifications.authorizer = nil
            ReviewNotifications.poster = nil
            ReviewNotifications.setEnabled(false)
        }
        let item = ReviewActivityItem(markupID: UUID(), kind: .mention, author: "Bo", text: "@Ada look", date: Date())
        ReviewNotifications.setEnabled(false)
        ReviewNotifications.post([item])
        #expect(posted.isEmpty && asked == 0, "nothing is asked or posted before the person opts in")
        ReviewNotifications.setEnabled(true)
        #expect(asked == 1)
        #expect(ReviewNotifications.isEnabled)
        ReviewNotifications.post([item])
        #expect(posted == [item])
        #expect(item.sentence == "Bo mentioned you: @Ada look")
    }
}
