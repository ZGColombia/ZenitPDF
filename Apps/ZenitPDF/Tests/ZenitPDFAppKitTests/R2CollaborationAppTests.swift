import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// NL-COLLAB-12, round 2, through two real project documents — two copies of one project, as two
/// people would have — watching one folder: B sees A's cloud within the polling bound with nobody
/// pressing Sync, a recalibration travels as a scale and is measured locally, and each window
/// says who else is looking at which sheet. No dialogue reaches the screen.
@MainActor
@Suite("r2-platform shared review, watched", .appTierSerialised, .serialized)
struct R2CollaborationAppTests {

    private func openProject(_ url: URL) async throws -> ZenitPDFProjectDocument {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.projectPackage != nil })
        return document
    }

    /// Waits for an asynchronous condition, polling as the watcher does.
    private func eventually(upTo seconds: Double = 10, _ condition: @MainActor () async -> Bool) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test("A draws, B receives it within the polling bound; A recalibrates, B measures under the new scale; presence names the sheet")
    func watchedFolder() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "Watched.pdf")
        let root = pdf.deletingLastPathComponent()
        let defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.defaults = defaults
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        let interval = SharedReviewAutoSync.pollInterval
        SharedReviewAutoSync.pollInterval = 0.2
        ZenitModalPresenter.reset()
        defer {
            SharedReviewAutoSync.pollInterval = interval
            SharedReviewCommands.defaults = .store
            SharedReviewCommands.baseDirectoryOverride = SharedReviewCommands.defaultBaseDirectoryOverride
            ZenitModalPresenter.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let draft = root.appendingPathComponent("Draft.zpdfproj", isDirectory: true)
        try await ProjectPackage.create(at: draft, displayName: "Tower", originalPDF: pdf, pageCount: 1).close()
        // Saved once before it is shared, as Send Project sends a saved project: the sheets'
        // identities are then in the file, and both copies read the same ones.
        let urlA = root.appendingPathComponent("Tower.zpdfproj", isDirectory: true)
        let original = try await openProject(draft)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            original.save(to: urlA, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        original.close()
        #expect(await AppTestSupport.wait { original.projectPackage == nil })
        let urlB = root.appendingPathComponent("Tower copy.zpdfproj", isDirectory: true)
        try FileManager.default.copyItem(at: urlA, to: urlB)
        let folder = root.appendingPathComponent("Shared", isDirectory: true)

        let a = try await openProject(urlA)
        let b = try await openProject(urlB)
        defer {
            SharedReviewAutoSync.stop(document: a)
            SharedReviewAutoSync.stop(document: b)
            a.close()
            b.close()
        }
        let coreA = try #require(a.core)
        let coreB = try #require(b.core)
        // Two copies of one project name their sheet alike once each has read its stored pages.
        #expect(await eventually {
            let pageA = await coreA.session.firstPageID
            let pageB = await coreB.session.firstPageID
            return pageA != nil && pageA == pageB
        }, "the copies never agreed on the sheet's identity")
        let idsA = await coreA.session.pageDescriptors.map(\.id), idsB = await coreB.session.pageDescriptors.map(\.id)
        let snapA = coreA.snapshot.pages.map(\.id), snapB = coreB.snapshot.pages.map(\.id)
        #expect(idsA == idsB, "session A \(idsA) B \(idsB); snapshot A \(snapA) B \(snapB)")
        let firstPage = try #require(await coreA.session.firstPageID)
        let page = try #require(coreA.snapshot.pages.first { $0.id == firstPage.rawValue })
        // Both copies measure at 100 pt = 1 m before connecting.
        for core in [coreA, coreB] {
            _ = try await core.commands.calibrate(page: PageID(page.id), first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                  knownLength: 1, knownLengthUnit: .metre)
            await core.refresh()
        }
        #expect(await SharedReviewCommands.connect(document: a, folder: folder) != nil)
        defaults.removeObject(forKey: "zenit.sharedReview.participantID")
        #expect(await SharedReviewCommands.connect(document: b, folder: folder) != nil)
        // Two people on one Mac: each watcher writes its own log, as two machines would.
        SharedReviewAutoSync.start(document: a, folder: folder, participant: "ada-mac", registersPresenter: false)
        SharedReviewAutoSync.start(document: b, folder: folder, participant: "bo-mac", registersPresenter: false)

        // A draws a 200 × 100 pt area: 2 m × 1 m = 2 m² at 100 pt/m. Nobody presses Sync.
        let slab = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(coreA.snapshot.documentID), pageID: PageID(page.id),
            kind: .measurement, tool: .area, subject: "Slab", author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date())
        try await coreA.commands.perform(.addMarkup(slab))
        await coreA.refresh()
        #expect(await eventually { await coreB.session.markup(slab.id) != nil }, "B never received A's markup")
        #expect(await coreB.session.markup(slab.id)?.measurement?.values[.planArea]?.value == 2)

        // A recalibrates: 100 pt is 2 m, so the slab is 4 m × 2 m = 8 m². The value is not sent;
        // the scale is, and B recomputes.
        _ = try await coreA.commands.calibrate(page: PageID(page.id), first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                               knownLength: 2, knownLengthUnit: .metre)
        await coreA.refresh()
        #expect(await eventually {
            await coreB.session.markup(slab.id)?.measurement?.values[.planArea]?.value == 8
        }, "B never measured under A's new scale")
        #expect(await coreA.session.markup(slab.id)?.measurement?.values[.planArea]?.value == 8)

        // Presence: B's window names A and the sheet A is on.
        #expect(await AppTestSupport.wait(upTo: 10) { SharedReviewAutoSync.presenceText(for: b) != nil })
        let presence = try #require(SharedReviewAutoSync.presenceText(for: b))
        #expect(presence.contains(" on \(page.label)"), "\(presence)")
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)

        // Disconnecting stops the watch and the window stops naming anyone.
        await SharedReviewCommands.disconnect(document: b)
        #expect(SharedReviewAutoSync.watcher(for: b) == nil)
        #expect(SharedReviewAutoSync.presenceText(for: b) == nil)
    }

    @Test("A watcher whose folder became unwritable says so in a note, never in a dialogue")
    func quietFailure() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "Quiet.pdf")
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
        let url = root.appendingPathComponent("Site.zpdfproj", isDirectory: true)
        try await ProjectPackage.create(at: url, displayName: "Site", originalPDF: pdf, pageCount: 1).close()
        let folder = root.appendingPathComponent("Shared", isDirectory: true)
        let document = try await openProject(url)
        defer {
            SharedReviewAutoSync.stop(document: document)
            document.close()
        }
        let core = try #require(document.core)
        #expect(await SharedReviewCommands.connect(document: document, folder: folder) != nil)
        let watcher = SharedReviewAutoSync.start(document: document, folder: folder, participant: "ada-mac", registersPresenter: false)
        // The share went read-only under us.
        let participants = folder.appendingPathComponent("participants", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: participants.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: participants.path) }
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: PageID(try #require(core.snapshot.pages.first).id),
            kind: .cloud, author: "Ada",
            geometry: MeasurementGeometry(pageID: PageID(try #require(core.snapshot.pages.first).id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 10, y: 10), PDFPoint(x: 50, y: 10), PDFPoint(x: 50, y: 50)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date())
        try await core.commands.perform(.addMarkup(cloud))
        await core.refresh()
        #expect(await watcher.tick() == nil)
        #expect(core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" })
        #expect(ZenitModalPresenter.recorded.allSatisfy { $0.identifier != SharedReviewCommands.refusalIdentifier }, "no dialogue from a watcher")
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }
}
