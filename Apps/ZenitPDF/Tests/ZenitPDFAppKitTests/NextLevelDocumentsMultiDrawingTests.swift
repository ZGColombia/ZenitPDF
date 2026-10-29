import AppKit
import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-DOCS-04 (round 2): a project holds several drawings and the app works with them — every
/// drawing opens with the project, a dropped PDF joins it at the drop position, each sheet renders
/// from its own drawing, and a takeoff over three drawings saves, reopens and totals.
/// Headless: the window is built, never shown. Hand-derived values: 100 pt = 1 m.
@MainActor
@Suite("Documents — several drawings in one project", .appTierSerialised)
struct NextLevelDocumentsMultiDrawingTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func length(on page: ZPDFContracts.PageDescriptor, points: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: page.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .polylength,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 100 + points, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test("Three drawings: dropped order, each sheet from its own PDF, 9 m over the set, saved, reopened, sources untouched")
    func threeDrawingsInTheApp() async throws {
        let harness = try await Fix2Harness.make("Set A.pdf", pageCount: 2, calibrate: false)
        let package = harness.directory.appendingPathComponent("Set.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)
        let b = try AppTestSupport.writeFixturePDF(named: "Set B.pdf", pageCount: 2)
        let c = try AppTestSupport.writeFixturePDF(named: "Set C.pdf", pageCount: 1)
        defer {
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: c.deletingLastPathComponent())
        }
        let shaBefore = try [b, c].map(sha256)
        let document = harness.document
        let core = harness.core
        let a = try #require(document.drawing)

        // B at position 0, C after A's first sheet: B1 B2 A1 C1 A2.
        #expect(await document.addDrawingToSet(fileAt: b, at: 0))
        #expect(await document.addDrawingToSet(fileAt: c, at: 3))
        let set = try #require(document.drawingSet)
        #expect(set.members.count == 3)
        let bID = set.members[1].drawing.documentID
        let cID = set.members[2].drawing.documentID
        let pages = await core.session.pageDescriptors
        #expect(pages.map(\.documentID) == [bID, bID, a.documentID, cID, a.documentID])
        #expect(pages.map(\.index) == [0, 1, 0, 0, 1], "each sheet keeps its index in its own PDF")
        await core.refresh()
        #expect(core.document.pages.count == 5)

        // The canvas renders each sheet from its own drawing, and page 1 of B is never page 1 of A.
        let canvas = harness.canvas
        let bFirst = try #require(core.document.pages.first)
        let aFirst = try #require(core.document.pages.first { $0.id == pages[2].id.rawValue })
        #expect(canvas.rasterSource(for: bFirst) === set.members[1].drawing.rasterSource)
        #expect(canvas.rasterSource(for: aFirst) === a.rasterSource)
        #expect(canvas.rasterKey(of: aFirst) == 0, "a single drawing's keys are unchanged")
        #expect(canvas.rasterKey(of: bFirst) != canvas.rasterKey(of: aFirst))

        // One measurement on a sheet of each drawing: 2 m on A, 3 m on B, 4 m on C.
        let measured: [(ZPDFContracts.PageDescriptor, Double)] = [(pages[2], 200), (pages[1], 300), (pages[3], 400)]
        for (page, points) in measured {
            _ = try await core.commands.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre
            )
            _ = try await core.commands.perform(.addMarkup(length(on: page, points: points)))
        }
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(9), "2 + 3 + 4 m over the set")
        #expect(await core.session.orderedMarkups.map(\.documentID) == [a.documentID, bID, cID])

        try await save(document, to: package, .saveOperation)
        harness.controller.window?.close()
        document.close()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait(upTo: 30) { reopened.core != nil })
        let reopenedCore = try #require(reopened.core)
        let reopenedPages = await reopenedCore.session.pageDescriptors
        #expect(reopenedPages.map(\.id) == pages.map(\.id), "every sheet back, in the dropped order, with its identity")
        #expect(reopened.drawingSet?.members.count == 3, "every drawing of the project opened")
        await reopenedCore.refresh()
        #expect(reopenedCore.ledger.grandTotals.total("planLength")?.value == Decimal(9))
        for (page, _) in measured {
            #expect(await reopenedCore.session.orderedMarkups.filter { $0.pageID == page.id }.count == 1)
        }
        #expect(await reopenedCore.session.refusedMarkupIDs.isEmpty)
        #expect(try [b, c].map(sha256) == shaBefore, "the dropped drawings were never written")
        let copies = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("documents").path)
        #expect(copies.filter { $0.hasPrefix("added-") }.count == 2)
        #expect(!reopened.isDocumentEdited)
    }

    /// Old behaviour (NL-DOCS-03 interim): the PDF opened as a separate drawing. Now it joins the
    /// project at the drop line, and one ⌘Z takes its sheets back out of the set.
    @Test("A PDF dropped on a project's Navigator joins it at the drop line; undo takes its sheets out")
    func dropJoinsProject() async throws {
        let harness = try await Fix2Harness.make("Drop Host.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let package = harness.directory.appendingPathComponent("Drop.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)
        let dropped = try AppTestSupport.writeFixturePDF(named: "Dropped A-201.pdf")
        defer { try? FileManager.default.removeItem(at: dropped.deletingLastPathComponent()) }
        var opened: [URL] = []
        let previous = ProjectWindowController.dropOpener
        ProjectWindowController.dropOpener = { opened.append(contentsOf: $0) }
        defer { ProjectWindowController.dropOpener = previous }

        #expect(harness.controller.handleNavigatorDrop(urls: [dropped], insertionIndex: 1, document: harness.document))
        #expect(await AppTestSupport.wait(upTo: 20) { harness.document.drawingSet?.isMultiDrawing == true })
        #expect(await AppTestSupport.wait { harness.core.document.pages.count == 3 })
        #expect(opened.isEmpty, "the PDF is not opened beside the project")
        let added = try #require(harness.document.drawingSet?.members.last?.drawing.documentID)
        #expect(await harness.core.session.pageDescriptors.map(\.documentID)[1] == added, "at the drop line")
        let documents = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("documents").path)
        #expect(documents.contains { $0.hasPrefix("added-") }, "copied into the package")

        await harness.core.commands.undo()
        await harness.core.refresh()
        #expect(harness.core.document.pages.count == 2, "one ⌘Z takes the added sheets out of the set")
    }

    @Test("Search spans the set: text on an added drawing is found and turns to its sheet here")
    func searchSpansTheSet() async throws {
        let harness = try await Fix2Harness.make("Search Host.pdf", calibrate: false)
        defer { harness.tearDown() }
        let package = harness.directory.appendingPathComponent("Search.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("nl-docs-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let titled = try ZPDFFixtures.make(.titleBlockSheet, in: fixtures)   // prints "SCALE 1:50"
        #expect(await harness.document.addDrawingToSet(fileAt: titled.url, at: 1))
        #expect(await AppTestSupport.wait(upTo: 20) { harness.document.drawingSet?.searchSources.count == 1 })
        let source = try #require(harness.document.drawingSet?.searchSources.first)
        let added = try #require(harness.document.drawingSet?.members.last?.drawing)
        var hits: [ZPDFUIPresentation.SearchHit] = []
        for _ in 0..<50 where hits.isEmpty {
            hits = await source.search("SCALE", ZPDFUIPresentation.ProjectSearchOptions())
            if hits.isEmpty { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        let hit = try #require(hits.first, "the added drawing's text is indexed and found")
        #expect(hit.pageID == added.pages[0].id.rawValue, "the hit names the added sheet")
        #expect(hit.sourceDocumentID == nil || hit.sourceDocumentID == harness.document.documentIdentity,
                "revealed in this project, not handed to another tab")
        #expect((harness.document.searchPresenter as? AppSearchPresenter)?.searchesAllDrawings == true)
        // W-081: the member source answers under the asker's Match Case, not case-folded.
        #expect(await source.search("scale", ZPDFUIPresentation.ProjectSearchOptions()).isEmpty == false)
        #expect(await source.search("scale", ZPDFUIPresentation.ProjectSearchOptions(isCaseSensitive: true)).isEmpty,
                "Match Case `scale` finds no lower-case scale on the added drawing")
    }

    @Test("Combine Open Drawings: the other drawing joins with its scale, markups and sheet names; 3 m re-measured")
    func combineOpenDrawings() async throws {
        let harness = try await Fix2Harness.make("Combine Host.pdf", calibrate: false)
        defer { harness.tearDown() }
        let package = harness.directory.appendingPathComponent("Combine.zpdfproj")
        try await save(harness.document, to: package, .saveAsOperation)

        let otherURL = try AppTestSupport.writeFixturePDF(named: "Combine Other.pdf", pageCount: 2)
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        let shaBefore = try sha256(otherURL)
        let other = try AppTestSupport.makeDocument(opening: otherURL)
        defer { other.close() }
        #expect(await AppTestSupport.wait { other.core != nil })
        let otherCore = try #require(other.core)
        let otherPages = await otherCore.session.pageDescriptors
        // Sheet 2 of the other drawing: 1 m per 100 pt, a 300 pt wall, named S-201.
        _ = try await otherCore.commands.calibrate(
            page: otherPages[1].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        _ = try await otherCore.commands.perform(.addMarkup(length(on: otherPages[1], points: 300)))
        _ = try await otherCore.commands.perform(.setSheetIdentities(
            [otherPages[1].id: SheetIdentity(number: "S-201", title: "FRAMING", source: .manual)], overwriteManual: true
        ))

        #expect(await harness.document.combine(openDrawings: [other]) == 1)
        let core = harness.core
        // L-26: the note counts in the singular. Old: "1 drawings added to this project…".
        let note = core.status.snapshot.activeToolNote ?? ""
        #expect(note.hasPrefix("1 drawing added to this project with its takeoff."), "\(note)")
        let set = try #require(harness.document.drawingSet)
        let joined = try #require(set.members.last?.drawing)
        let pages = await core.session.pageDescriptors
        #expect(pages.count == 3)
        let target = try #require(pages.first { $0.documentID == joined.documentID && $0.index == 1 })
        #expect(await core.session.isCalibrated(page: target.id), "the page scale came with its sheet")
        let carried = await core.session.orderedMarkups
        #expect(carried.count == 1)
        #expect(carried.first?.pageID == target.id && carried.first?.documentID == joined.documentID)
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(3), "300 pt at 1 m / 100 pt, re-measured")
        #expect(await core.session.sheetIdentity(of: target.id)?.number == "S-201")
        #expect(try sha256(otherURL) == shaBefore, "the other drawing's file was never written")

        await core.commands.undo()   // the takeoff
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value ?? 0 == 0)
        await core.commands.undo()   // the sheets
        await core.refresh()
        #expect(core.document.pages.count == 1)
    }
}
