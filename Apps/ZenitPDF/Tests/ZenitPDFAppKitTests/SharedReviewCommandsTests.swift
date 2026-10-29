import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// NL-COLLAB-12 through two real project documents — two copies of one project, as two people
/// would have — syncing through one folder. No dialogue reaches the screen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct SharedReviewCommandsTests {

    private func openProject(_ url: URL) async throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.projectPackage != nil })
        return document
    }

    @Test("Connect, draw, sync: the other copy of the project receives the markup; Quick PDFs are refused")
    func twoCopiesSync() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "SharedReview.pdf")
        let root = pdf.deletingLastPathComponent()
        let defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.defaults = defaults
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        ZenitModalPresenter.reset()
        defer {
            SharedReviewCommands.defaults = .store
            SharedReviewCommands.baseDirectoryOverride = SharedReviewCommands.defaultBaseDirectoryOverride
            ZenitModalPresenter.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let urlA = root.appendingPathComponent("Tower.zpdfproj", isDirectory: true)
        try await ProjectPackage.create(at: urlA, displayName: "Tower", originalPDF: pdf, pageCount: 1).close()
        let urlB = root.appendingPathComponent("Tower copy.zpdfproj", isDirectory: true)
        try FileManager.default.copyItem(at: urlA, to: urlB)
        let folder = root.appendingPathComponent("Shared", isDirectory: true)

        let a = try await openProject(urlA)
        let b = try await openProject(urlB)
        defer {
            a.close()
            b.close()
        }
        let coreA = try #require(a.core)
        let coreB = try #require(b.core)
        let page = try #require(coreA.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(coreA.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
        try await coreA.commands.perform(.addMarkup(cloud))

        let connected = await SharedReviewCommands.connect(document: a, folder: folder)
        #expect(connected?.published == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("review.json").path))
        // The same participant id on one machine: B is another person here, so it gets its own.
        defaults.removeObject(forKey: "zenit.sharedReview.participantID")
        let received = await SharedReviewCommands.connect(document: b, folder: folder)
        #expect(received?.added == 1)
        #expect(await coreB.session.markup(cloud.id)?.kind == .cloud)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)

        // NL-COLLAB-10: a review file from A merges into B; a second import adds nothing.
        let reply = coreA.review.addReply("Checked on site", to: cloud.id.rawValue)
        #expect(reply != nil)
        await coreA.review.settle()
        let reviewFile = root.appendingPathComponent("Tower.zpdfreview")
        #expect(await ReviewFileFlow.write(document: a, to: reviewFile))
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewFileFlow.previewIdentifier ? .button(0) : .dismissed
        }
        let imported = await ReviewFileFlow.importFile(reviewFile, into: b)
        #expect(imported == .imported(added: 0, changed: 0, replies: 1), "the cloud is already there; the reply is new — got \(imported)")
        let again = await ReviewFileFlow.importFile(reviewFile, into: b)
        #expect(again == .nothingToImport, "\(again)")
        ZenitModalPresenter.handler = nil

        // Share Review File… hands a written .zpdfreview to the picker (injected: nothing shown).
        var shared: URL?
        ReviewFileFlow.sharingPresenter = { url, _ in shared = url }
        defer { ReviewFileFlow.sharingPresenter = nil }
        ReviewFileFlow.share(document: a, window: nil)
        #expect(await AppTestSupport.wait { shared != nil })
        if let shared {
            #expect(shared.pathExtension == "zpdfreview")
            #expect((try? ReviewExchangeFile.decode(Data(contentsOf: shared)))?.projectName == "Tower")
        }

        // A Quick PDF has no project to share, and says so.
        let quick = try AppTestSupport.makeDocument(opening: pdf)
        defer { quick.close() }
        #expect(await AppTestSupport.wait { quick.core != nil })
        SharedReviewCommands.connect(document: quick, window: nil)
        #expect(ZenitModalPresenter.recorded.contains { $0.identifier == SharedReviewCommands.refusalIdentifier })
    }

    @Test("The sync note says what came in, what went out and who else is reviewing")
    func noteWords() {
        var report = SharedReviewSync.Report()
        report.added = 2
        report.replies = 1
        report.published = 3
        report.others = ["Bo"]
        let note = SharedReviewCommands.note(for: report, folder: URL(fileURLWithPath: "/tmp/Tower Review"))
        #expect(note.title == "Synced with “Tower Review”")
        #expect(note.message.contains("2 added, 0 changed, 0 removed."))
        #expect(note.message.contains("1 new reply."))
        #expect(note.message.contains("3 of your changes shared."))
        #expect(note.message.contains("Reviewing with Bo."))
    }
}
