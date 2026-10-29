import AppKit
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCollaboration
import ZPDFContracts
import ZPDFExport
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFSpreadsheet
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Loop iteration 2, area app-shell-glue: C-06, C-07, L-01 … L-03 and S-008 … S-023. Every test
/// states the old output it fails with. Headless throughout: no window is ordered front, every
/// modal is recorded or answered by injection, every store is a temporary one.
@MainActor
@Suite("Iteration 2 — app shell glue", .appTierSerialised)
struct Iter2ShellGlueTests {

    // MARK: - Helpers

    /// Polls an async condition, as `AppTestSupport.wait` polls a synchronous one.
    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it2-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func subjectFilter(_ subject: String) -> LedgerFilterGroup {
        LedgerFilterGroup(id: UUID(), rules: [LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text(subject))])
    }

    static func length(_ harness: Fix2Harness, from x: Double, to end: Double, y: Double, subject: String) async throws -> ZPDFContracts.MarkupRecord {
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: x, y: y), PDFPoint(x: end, y: y)])
        }, subject: subject)
    }

    /// A second window on the harness's document, opened through the command's own path.
    static func openSecondWindow(_ harness: Fix2Harness) async throws -> ProjectWindowController {
        let second = try #require(await harness.controller.openNewWindow(for: harness.document))
        #expect(await AppTestSupport.wait { second.canvasController(for: harness.document) != nil })
        if let canvas = second.canvasController(for: harness.document) {
            _ = canvas.view
            second.window?.layoutIfNeeded()
            canvas.view.layoutSubtreeIfNeeded()
            canvas.viewDidAppear()
        }
        return second
    }

    static func closeWindows(_ harness: Fix2Harness, _ windows: [ProjectWindowController]) {
        harness.document.unsavedTakeoffReview = { _, answer in answer(.discard) }
        for window in windows { window.window?.close() }
    }

    static func unzip(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static func zip(_ folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", "-r", archive.path, "."]
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static func saveAsProject(_ harness: Fix2Harness, name: String = "Project.zpdfproj") async throws -> URL {
        try await Iter1ShellGlueTests.saveAsProject(harness, name: name)
    }

    // MARK: - C-06

    @Test("C-06: every test document gets a fresh personal Tool Library of its own; a preset saved in one is not in the next")
    func eachTestDocumentHasItsOwnContainer() async throws {
        let first = try await Fix2Harness.make("C06a.pdf", calibrate: false)
        defer { first.tearDown() }
        let container = first.document.toolPresetContainer
        #expect(container === first.document.toolPresetContainer, "one container for the document's life")
        // Old: every document of the process shared ZenitPDFProjectDocument.processToolPresetContainer.
        #expect(container !== ZenitPDFProjectDocument.processToolPresetContainer)
        let mine = ToolPresetSummary(
            id: UUID(), name: "C06 personal", category: "Finishes", panel: .myTools, markupKind: .measurement,
            measurementKind: .area, colorRGBA: ColorRGBA.Zenit.Dark.cyan, defaultSubject: "C06"
        )
        first.document.applyToolPresets(first.core.toolLibrary.presets + [mine])
        #expect(await Self.eventually { ((try? await container.read()) ?? nil)?.contains { $0.id == mine.id } == true },
                "the personal preset reached the first document's container")

        let second = try await Fix2Harness.make("C06b.pdf", calibrate: false)
        defer { second.tearDown() }
        #expect(second.document.toolPresetContainer !== container)
        // Old: the second document opened with the first one's personal preset (I-6, I-13).
        #expect(!second.core.toolLibrary.presets.contains { $0.id == mine.id })
        #expect(second.core.toolLibrary.presets.count == DefaultToolSet.shipped.count, "a fresh library: the shipped set only")
    }

    // MARK: - S-008

    @Test("S-008: an edit that lands while a periodic autosave runs leaves the document with unautosaved changes")
    func editDuringLightAutosaveStaysUnautosaved() async throws {
        let harness = try await Fix2Harness.make("S008.pdf")
        defer { harness.tearDown() }
        _ = try await Self.saveAsProject(harness)
        _ = try await Self.length(harness, from: 0, to: 250, y: 10, subject: "Wall")
        #expect(await AppTestSupport.wait { harness.document.isDocumentEdited })
        var hookRan = false
        harness.document.packageSaveWillWriteHook = { [weak document = harness.document] in
            hookRan = true
            // The person's next edit, after the autosave read the counter and before it finished.
            document?.updateChangeCount(.changeDone)
        }
        defer { harness.document.packageSaveWillWriteHook = nil }
        try await harness.document.performLightAutosaveForTesting()
        #expect(hookRan)
        // Old: false — the light path recorded .changeAutosaved with no revision check.
        #expect(harness.document.hasUnautosavedChanges)
        harness.document.packageSaveWillWriteHook = nil
        try await harness.document.performLightAutosaveForTesting()
        #expect(!harness.document.hasUnautosavedChanges, "an autosave with nothing arriving meanwhile still counts")
        #expect(harness.document.isDocumentEdited, "an autosave never clears the edited state")
    }

    // MARK: - S-009

    @Test("S-009: with two windows on different sheets, a hidden layer stays hidden in both after a page turn in either")
    func layerFilterPerWindow() async throws {
        let directory = try Self.scratch("s009")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Two Sheets.pdf")
        try NLUXAppBugTests.twoPageLayeredPDF().write(to: url)
        let harness = try await Fix2Harness.make("Two Sheets.pdf", pageCount: 2, calibrate: false, fixture: url)
        let document = harness.document
        #expect(await AppTestSupport.wait { document.layerVisibility.hasLayers })
        #expect(await AppTestSupport.wait { !harness.shell.navigatorLayers.rows.isEmpty })
        let second = try await Self.openSecondWindow(harness)
        defer {
            Self.closeWindows(harness, [second])
            harness.tearDown()
        }
        let secondCore = try #require(second.windowCore(for: document))
        let firstCanvas = harness.canvas
        let secondCanvas = try #require(second.canvasController(for: document))
        harness.core.document.goToPage(index: 0)
        secondCore.document.goToPage(index: 1)
        let walls = try #require(harness.shell.navigatorLayers.rows.first)
        harness.shell.navigatorLayers.setVisible(false, layerID: walls.id)
        // Old: one filter, built for the focused window's sheet (the second window's, page 2),
        // went to both canvases, so the first window's sheet 1 rendered the hidden layer.
        #expect(await AppTestSupport.wait {
            firstCanvas.underlayHiddenLayerIDs(forPageIndex: 0).contains("L0")
                && secondCanvas.underlayHiddenLayerIDs(forPageIndex: 1).contains("L0")
        })
        // A page turn in the second window refilters that window only.
        secondCore.document.goToPage(index: 0)
        #expect(await AppTestSupport.wait { secondCanvas.underlayHiddenLayerIDs(forPageIndex: 0).contains("L0") })
        secondCore.document.goToPage(index: 1)
        #expect(await AppTestSupport.wait { secondCanvas.underlayHiddenLayerIDs(forPageIndex: 1).contains("L0") })
        #expect(firstCanvas.underlayHiddenLayerIDs(forPageIndex: 0).contains("L0"),
                "old: the second window's page turn handed the first window a filter for page 2")
    }

    // MARK: - S-010

    @Test("S-010: the Review List and the Inbox belong to the drawing they were opened for, and close with its tab and window")
    func panelsPerDocument() async throws {
        let harness = try await Fix2Harness.make("S010a.pdf", calibrate: false)
        let otherURL = try AppTestSupport.writeFixturePDF(named: "S010b.pdf")
        let other = try AppTestSupport.makeDocument(opening: otherURL)
        harness.controller.attach(document: other)
        #expect(await AppTestSupport.wait { other.shell != nil })
        defer {
            other.close()
            harness.tearDown()
            try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent())
        }
        let controller = harness.controller
        controller.activateTab(id: harness.document.documentIdentity)
        let listA = try #require(ReviewListWindow.present(for: controller, document: harness.document))
        controller.activateTab(id: other.documentIdentity)
        let listB = try #require(ReviewListWindow.present(for: controller, document: other))
        // Old: one panel per window — tab B's Review List was tab A's, under A's name.
        #expect(listA !== listB)
        #expect(listB.title.contains("S010b"))
        let inboxA = AssistantInboxWindow.present(for: controller, document: harness.document)
        let inboxB = AssistantInboxWindow.present(for: controller, document: other)
        // Old: the same panel, bound to the first drawing's inbox; its Accept changed that drawing.
        #expect(inboxA !== inboxB)
        #expect(AssistantInboxWindow.present(for: controller, document: other) === inboxB, "reused for the same drawing")

        // The drawing leaving the window takes its panels (old: nothing ever removed them).
        controller.detach(other)
        #expect(ReviewListWindow.openPanel(for: controller, document: other) == nil)
        #expect(AssistantInboxWindow.openPanel(for: controller, document: other) == nil)
        #expect(ReviewListWindow.openPanel(for: controller, document: harness.document) === listA)
        // And the window closing takes the rest.
        controller.window?.close()
        #expect(ReviewListWindow.openPanel(for: controller, document: harness.document) == nil)
        #expect(AssistantInboxWindow.openPanel(for: controller, document: harness.document) == nil)
    }

    // MARK: - S-011

    @Test("S-011: Import Spreadsheet Changes compares with the whole ledger, whatever filter or columns the screen shows")
    func spreadsheetImportIgnoresTheScreen() async throws {
        let harness = try await Fix2Harness.make("S011.pdf")
        defer { harness.tearDown() }
        let wall = try await Self.length(harness, from: 10, to: 260, y: 10, subject: "Wall")
        let slab = try await Self.length(harness, from: 10, to: 160, y: 60, subject: "Slab")
        let seeded = try await harness.core.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: wall.id.rawValue, columnKey: "costCode", text: "CC-0"),
            SpreadsheetCellEdit(markupID: slab.id.rawValue, columnKey: "costCode", text: "CC-1"),
        ])
        #expect(seeded.applied == 2)
        await harness.settle()
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "S011", scaleDescription: nil, request: harness.core.ledger.request)
        #expect(projection.table.columns.contains { $0.key == "costCode" })
        let identity = await SpreadsheetRoundTrip.identity(of: harness.document)
        let options = SpreadsheetRoundTrip.withRowIdentity(XLSXExportOptions(), projection: projection, identity: identity)
        let workbookURL = harness.directory.appendingPathComponent("Ledger.xlsx")
        try XLSXExporter().export(projection, to: workbookURL, options: options)

        // A workbook column the comparison does not carry is not compared: old, every filled cell
        // of it read as a change from empty.
        let untouched = try LedgerRoundTripWorkbook(data: Data(contentsOf: workbookURL))
        let values = SpreadsheetRoundTrip.currentValues(of: projection)
        var current = values.values
        for key in current.keys { current[key]?["costCode"] = nil }
        let trimmed = LedgerRoundTrip.review(untouched, current: current, numericKeys: values.numeric, projectID: identity)
        #expect(trimmed.changes.isEmpty, "old: 2 phantom Cost Code changes: \(trimmed.changes.map(\.after))")
        // And the comparison asks for every column the workbook carries.
        #expect(SpreadsheetRoundTrip.comparisonRequest(for: untouched).visibleColumns.map(\.rawValue) == untouched.columns.map(\.key))
        #expect(SpreadsheetRoundTrip.comparisonRequest(for: untouched).filter.isEmpty)

        // The Slab row's cost code edited in the workbook, as a spreadsheet saves it.
        let unpacked = harness.directory.appendingPathComponent("unpacked", isDirectory: true)
        try Self.unzip(workbookURL, into: unpacked)
        let strings = unpacked.appendingPathComponent("xl/sharedStrings.xml")
        var stringsXML = try String(contentsOf: strings, encoding: .utf8)
        #expect(stringsXML.contains(">CC-1<"))
        stringsXML = stringsXML.replacingOccurrences(of: ">CC-1<", with: ">CC-9<")
        try stringsXML.write(to: strings, atomically: true, encoding: .utf8)
        let edited = harness.directory.appendingPathComponent("Ledger edited.xlsx")
        try Self.zip(unpacked, to: edited)

        // The ledger on screen now shows only Wall.
        harness.core.ledger.setFilter(Self.subjectFilter("Wall"))
        #expect(await AppTestSupport.wait { harness.core.ledger.rowCount == 1 })
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in request.identifier == SpreadsheetRoundTrip.reviewIdentifier ? .button(0) : .dismissed }
        defer { ZenitModalPresenter.reset() }
        // Old: nil — the Slab row was "no longer in the ledger and ignored", so nothing applied.
        let receipt = try #require(await SpreadsheetRoundTrip.importChanges(from: edited, into: harness.document))
        #expect(receipt.applied == 1)
        let review = try #require(ZenitModalPresenter.recorded.first { $0.identifier == SpreadsheetRoundTrip.reviewIdentifier })
        #expect(review.detail.contains("“CC-1” → “CC-9”"))
        #expect(!review.detail.contains("no longer in the ledger"))
        await harness.settle()
        let costCode = LedgerIdentifiers.columnID(for: .costCode)
        #expect(await harness.core.session.markup(slab.id)?.customValues[costCode] == .text("CC-9"))
    }

    // MARK: - S-012

    /// S-012 as reported — "plan.pdf" beside "Plan.pdf" passes the path checks and replaces the
    /// drawing — does not happen on local volumes of this macOS (26.6): `resolvingSymlinksInPath()`
    /// returns an existing file's name in its on-disk case (measured on APFS, and on FAT and exFAT
    /// images read with a cold cache), so the old resolved-path comparisons already called the
    /// case variant the drawing and refused it. The change is hardening: both writers now decide
    /// "the same file" by the one rule every derived-copy writer uses,
    /// `StagedFileReplacement.sameItem` (resolved path, then file identity). A hard link to the
    /// drawing is where the old comparisons and the one rule part: the old ones called it another
    /// file and wrote the copy under its name (the drawing's bytes survived — both writers replace
    /// the name atomically — but the link was split); the one rule refuses it like the drawing, as
    /// Redaction, Scan Clean-up, Fill Form Fields and Optimize Copy already did.
    @Test("S-012: an annotated export or a signed copy aimed at the drawing under another name (a hard link, another case) is refused by the one 'same file' rule")
    func derivedCopyUnderAnotherNameOfTheDrawingIsRefused() async throws {
        let drawing = try AppTestSupport.writeFixturePDF(named: "Plan.pdf")
        let folder = drawing.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: drawing)
        let hardLink = folder.appendingPathComponent("Plan (hard link).pdf")
        try FileManager.default.linkItem(at: drawing, to: hardLink)
        var destinations = [hardLink]
        // The case only matters on a case-insensitive volume, which the temporary directory is on
        // a default macOS install; on a case-sensitive one the two names are two files. This half
        // passes on the old comparisons too (see above) and stays as a pin.
        let variant = folder.appendingPathComponent("plan.pdf")
        if FileManager.default.fileExists(atPath: variant.path) { destinations.append(variant) }

        for destination in destinations {
            let name = destination.lastPathComponent
            #expect(SaveAsCarryOver.sameItem(destination, drawing), "one rule for 'the same file': \(name)")

            let job = StandardAnnotationExport.Job(pages: [], sourceURL: drawing, sourceDigest: nil)
            // Old (hard link): the resolved paths differ, so no refusal — the export went on to
            // the writer. Old (case variant): refused, but with the export's own error, not the
            // derived-copy refusal every other copy writer gives.
            await #expect(throws: DerivedCopyGuard.Refusal.self, "annotated export to \(name)") {
                _ = try await StandardAnnotationExport.write(job, to: destination)
            }

            // Old (hard link): no refusal — the "copy" branch replaced the hard link's name with
            // the signed copy.
            let refusal = #expect(throws: (any Error).self, "signed copy to \(name)") {
                try SignDrawingCopy.write(source: drawing, opened: nil, to: destination, inPlace: false, options: .init(), signer: { $0 })
            }
            #expect(refusal.map { "\($0)".contains("cannot replace the drawing it is made from") } == true, "\(String(describing: refusal))")
            #expect(try Data(contentsOf: drawing) == original)
            #expect(try Data(contentsOf: hardLink) == original, "nothing is written under the hard link's name (\(name))")
        }
    }

    // MARK: - S-013

    /// One machine of a shared review, as `SharedReviewSyncTests` builds it.
    static func reviewMachine(_ directory: URL) async throws -> AppCoreEnvironment {
        let documentID = DocumentID(UUID(uuidString: "0A000000-0000-0000-0000-0000000000A1")!)
        let pageID = PageID(UUID(uuidString: "0B000000-0000-0000-0000-0000000000A1")!)
        let page = ZPDFContracts.PageDescriptor(
            id: pageID, documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        await environment.review.settle()
        return environment
    }

    static func cloud(_ documentID: DocumentID, _ pageID: PageID) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID, kind: .cloud, author: "Ada",
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 300, y: 300), PDFPoint(x: 400, y: 300), PDFPoint(x: 400, y: 400)
            ], isClosed: true))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// A MainActor box, so the folder-reader closure can remember it already ran.
    @MainActor final class Once { var done = false }

    @Test("S-013: a reply written while a shared-review sync runs is published by the next sync, not absorbed into the base")
    func editDuringSyncIsPublishedNextTime() async throws {
        let root = try Self.scratch("s013")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Shared", isDirectory: true)
        let a = try await Self.reviewMachine(root.appendingPathComponent("A", isDirectory: true))
        let b = try await Self.reviewMachine(root.appendingPathComponent("B", isDirectory: true))
        let syncA = SharedReviewSync(folderURL: folder, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folder, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P1", projectName: "Tower")
        try syncB.prepare(projectID: "P1", projectName: "Tower")
        let documentID = DocumentID(UUID(uuidString: "0A000000-0000-0000-0000-0000000000A1")!)
        let pageID = PageID(UUID(uuidString: "0B000000-0000-0000-0000-0000000000A1")!)
        let cloud = Self.cloud(documentID, pageID)
        try await a.commands.perform(.addMarkup(cloud))
        try await syncA.sync(core: a, authorName: "Ada")
        try await syncB.sync(core: b, authorName: "Bo")

        // The person replies while the next sync is between its publish and its new base: the
        // folder reader is called after the sync read what to publish.
        let once = Once()
        syncA.readFile = { url in
            // The folder is read off the main actor (T-083): the edit hops to the main thread,
            // which is free while the sync awaits the read.
            let edit = {
                MainActor.assumeIsolated {
                    if !once.done {
                        once.done = true
                        _ = a.review.addReply("Written during the sync", to: cloud.id.rawValue)
                    }
                }
            }
            if Thread.isMainThread { edit() } else { DispatchQueue.main.sync(execute: edit) }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        let during = try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(1))
        #expect(once.done)
        #expect(during.unpublishedLocalChanges == 1, "the sync says it left one local change unpublished")
        syncA.readFile = { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        await a.review.settle()
        let next = try await syncA.sync(core: a, authorName: "Ada", now: Date().addingTimeInterval(2))
        // Old: 0 — the reply had gone into the base with the rest of the document and no diff
        // against that base could find it.
        #expect(next.published >= 1)
        #expect(next.unpublishedLocalChanges == 0)
        let received = try await syncB.sync(core: b, authorName: "Bo", now: Date().addingTimeInterval(3))
        await b.review.settle()
        #expect(received.replies == 1)
        #expect(b.review.entries.map(\.body).contains("Written during the sync"))
    }

    @Test("S-013: the base after a sync is what was published, with only what the sync applied read back from the document")
    func syncBaseKeepsThePublishedState() {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let published = Self.cloud(documentID, pageID)
        var edited = published
        edited.subject = "Edited during the sync"
        let arrived = Self.cloud(documentID, pageID)
        let next = SharedReviewSync.base(
            published: ([published], [], []),
            after: ([edited, arrived], [:], [:]),
            appliedMarkups: [arrived.id], appliedReplies: [], installedScalePages: []
        )
        // Old: the base took `edited` wholesale, and the next publish found nothing to send.
        #expect(next.markups[published.id] == MarkupRegisters(record: published))
        #expect(next.markups[arrived.id] == MarkupRegisters(record: arrived), "what the sync applied is read back")
        #expect(next.unpublished == 1)
    }

    // MARK: - S-014 / S-015

    @Test("S-014: after a new folder is granted, search ignores the old folder's catalogue and says the new one is not indexed")
    func searchNeedsTheGrantedFoldersCatalogue() async throws {
        let fixture = try Iter1FolderIndexTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try #require(await fixture.index.rebuild())
        #expect(!(await fixture.index.search("FOUNDATION")).isEmpty)
        // Another folder with a file at the same relative path.
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try Iter1FolderIndexTests.textPDF(at: other.appendingPathComponent("A-101 Plan.pdf"), words: ["ROOF PLAN"])
        fixture.index.grant(other)
        #expect(!fixture.index.isCatalogueCurrent)
        // Old: one hit, the old folder's text joined onto the new folder's file.
        #expect(await fixture.index.search("FOUNDATION").isEmpty)
        let model = FolderSearchModel(index: fixture.index, folderName: "Other")
        model.query = "FOUNDATION"
        await model.search()
        #expect(model.summary == "“Other” has not been indexed yet. Choose Update Index.")
        _ = try #require(await fixture.index.rebuild())
        #expect(fixture.index.isCatalogueCurrent)
        #expect(await fixture.index.search("ROOF").first?.fileURL.lastPathComponent == "A-101 Plan.pdf")
        #expect(await fixture.index.search("FOUNDATION").isEmpty)
    }

    @Test("S-015: Forget during an indexing run stops the run, and nothing it read is left on disk")
    func forgetDuringIndexing() async throws {
        let fixture = try Iter1FolderIndexTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var forgotten = false
        let report = await fixture.index.rebuild { _, _ in
            guard !forgotten else { return }
            forgotten = true
            fixture.index.revoke()
        }
        #expect(forgotten)
        #expect(report == nil)
        // Old: the run went on — the next drawing's index and, at its end, catalogue.json were
        // written back into the root Forget had just deleted.
        #expect(!FileManager.default.fileExists(atPath: fixture.index.root.path))
        #expect(fixture.index.loadCatalogue() == nil)
    }

    // MARK: - S-016

    @Test("S-016: Import Review File on a Quick PDF refuses before any open panel")
    func importReviewFileRefusesFirst() async throws {
        let harness = try await Fix2Harness.make("S016.pdf", calibrate: false)
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .button(0) }
        defer { ZenitModalPresenter.reset() }
        ReviewFileFlow.importFile(document: harness.document, window: nil)
        // Old: the open panel first, and the refusal only after a file was chosen.
        #expect(!ZenitModalPresenter.didRequest(ReviewFileFlow.importPanelIdentifier))
        #expect(ZenitModalPresenter.didRequest(ReviewFileFlow.refusalIdentifier))
        // Export, Import and Connect stay enabled on a Quick PDF on purpose, to say why.
        let state = ZenitAppCommandWindowState(controller: harness.controller)
        for command in [ZenitAppCommand.exportReviewFile, .importReviewFile, .connectSharedReview] {
            #expect(ZenitAppCommandTable.validate(command, item: nil, state: state), "\(command)")
        }
    }

    // MARK: - S-017

    @Test("S-017: while a print is prepared, the disabled save rows say a print is running, not a save")
    func printTooltipNamesThePrint() async throws {
        func row(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
        let printing = row(#selector(NSDocument.saveAs(_:)))
        #expect(ZenitDocumentActionTable.validate(printing, hasSession: true, isSaveActivityBusy: true, isPrintInPreparation: true, hasDrawing: true) == false)
        // Old: "Saving… available when the save finishes".
        #expect(printing.toolTip == "A print is being prepared — available when it finishes.")
        let saving = row(#selector(NSDocument.saveAs(_:)))
        _ = ZenitDocumentActionTable.validate(saving, hasSession: true, isSaveActivityBusy: true, hasDrawing: true)
        #expect(saving.toolTip == "Saving… available when the save finishes")

        let harness = try await Fix2Harness.make("S017.pdf")
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        harness.document.printDocument(nil)
        #expect(harness.document.printActivityInFlight)
        let item = row(#selector(NSDocument.printDocument(_:)))
        #expect(!harness.document.validateUserInterfaceItem(item))
        #expect(item.toolTip == "A print is being prepared — available when it finishes.")
        #expect(await AppTestSupport.wait { !harness.document.printActivityInFlight })
    }

    // MARK: - S-018

    @Test("S-018: a ledger export's confirmation counts the rows written, not the rows on screen")
    func exportConfirmationCountsTheFile() async throws {
        let harness = try await Fix2Harness.make("S018.pdf")
        defer { harness.tearDown() }
        _ = try await Self.length(harness, from: 0, to: 250, y: 10, subject: "Wall")
        _ = try await Self.length(harness, from: 0, to: 150, y: 60, subject: "Wall")
        _ = try await Self.length(harness, from: 0, to: 100, y: 110, subject: "Slab")
        #expect(harness.core.ledger.rowCount == 3)
        var request = harness.core.ledger.request
        request.filter = Self.subjectFilter("Slab")
        let url = harness.directory.appendingPathComponent("Slab.zpdfjson")
        await harness.controller.writeProjectedExport(
            format: .zenitJSON, for: harness.document, core: harness.core, includeTrail: false,
            requestOverride: request, to: url
        ).value
        let confirmation = try #require(harness.core.document.warnings.first { $0.id == ExportCompletion.warningID })
        // Old: "3 rows" — the screen's count for a one-row file.
        #expect(confirmation.message == ExportCompletion.message(rowCount: 1, formatName: ExportAccessoryView.Format.zenitJSON.menuTitle))
    }

    // MARK: - S-019

    @Test("S-019: Process PDF Files takes its progress note down when it ends, and names an original that changed")
    func batchNoteAndResult() async throws {
        let harness = try await Fix2Harness.make("S019.pdf", calibrate: false)
        defer { harness.tearDown() }
        let root = try Self.scratch("s019")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("in/Plan.pdf")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: harness.directory.appendingPathComponent("S019.pdf"), to: input)
        var steps = BatchFileProcessor.Steps()
        steps.reduceSize = true
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .button(0) }
        defer { ZenitModalPresenter.reset() }
        #expect(BatchFileCommand.start(
            inputs: [input], steps: steps, folder: root.appendingPathComponent("out"), beside: false,
            document: harness.document, window: nil, transform: Iter1ShellGlueTests.copyTransform()
        ))
        let run = try #require(BatchFileCommand.running)
        await run.value
        #expect(harness.core.document.warnings.contains { $0.id == BatchFileCommand.resultNoteID })
        // Old: "Processing PDF files: 1 of 1." stayed in the status strip.
        #expect(harness.core.status.snapshot.activeToolNote == nil)

        let changed = BatchFileProcessor.Report(items: [
            .init(input: URL(fileURLWithPath: "/tmp/A.pdf"), output: nil, status: .failed("the original changed while it was processed"), inputUnchanged: false),
            .init(input: URL(fileURLWithPath: "/tmp/B.pdf"), output: URL(fileURLWithPath: "/tmp/out/B.pdf"), status: .done, inputUnchanged: true),
        ], cancelled: false)
        let note = BatchFileCommand.resultNote(changed, folder: root)
        // Old: "…; the originals are unchanged." beside a report that marked A.pdf "no".
        #expect(!note.message.contains("the originals are unchanged"))
        #expect(note.message.contains("these originals changed while they were processed: A.pdf"))
        #expect(note.severity == .warning)
        let clean = BatchFileCommand.resultNote(.init(items: [changed.items[1]], cancelled: false), folder: root)
        #expect(clean.message.contains("the originals are unchanged"))
    }

    // MARK: - S-020

    @Test("S-020: a tool set opened from Finder reaches a background tab's window, and the front tab is the key window's")
    func dataFileReachesABackgroundTab() async throws {
        let harness = try await Fix2Harness.make("S020a.pdf", calibrate: false)
        let backgroundURL = try AppTestSupport.writeFixturePDF(named: "S020b.pdf")
        let background = try AppTestSupport.makeDocument(opening: backgroundURL)
        harness.controller.attach(document: background)
        #expect(await AppTestSupport.wait { background.shell != nil && background.core != nil })
        defer {
            background.close()
            harness.tearDown()
            try? FileManager.default.removeItem(at: backgroundURL.deletingLastPathComponent())
        }
        harness.controller.activateTab(id: harness.document.documentIdentity)
        #expect(background.windowControllers.isEmpty, "a background tab owns no window controller")
        #expect(ZenitDataFileRoutes.frontDocument(current: nil, documents: [background, harness.document], windows: [harness.controller.window])
                === harness.document, "old: documents.first — the background tab")
        let url = harness.directory.appendingPathComponent("Office.zpdftools")
        try R2PlatformAppTests.toolSetData(name: "Office", presets: [R2PlatformAppTests.preset("Floor finish")]).write(to: url)
        // Old: nil — windowControllers.first of a background tab is nil, and the import returned silently.
        let model = try #require(await ZenitDataFileRoutes.reviewToolSet(url, document: background))
        #expect(model.importReview?.presets.map(\.name) == ["Floor finish"])
        #expect(harness.controller.activeDocument === background, "the drawing the file is for comes to the front")
    }

    // MARK: - S-021

    @Test("S-021: the export profile library and the job template store default to temporary directories in a test process")
    func libraryDefaultsAreScratch() async {
        let profiles = ExportProfileLibrary.standard().directory.path
        let templates = await ProjectWindowController.jobTemplateStore().directory.path
        for path in [profiles, templates] {
            // Old: ~/Library/Application Support/Zenit PDF/… for both.
            #expect(!path.contains("Application Support"), "\(path)")
            #expect(path.hasPrefix(FileManager.default.temporaryDirectory.path)
                    || path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path), "\(path)")
        }
    }

    // MARK: - S-022

    @Test("S-022: detached Split Canvas panes close with their window, and when Split Canvas ends")
    func paneWindowsCloseWithTheirOwner() async throws {
        let harness = try await Fix2Harness.make("S022.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let previous = ProjectWindowController.paneWindowPresenter
        ProjectWindowController.paneWindowPresenter = { _ in }
        defer { ProjectWindowController.paneWindowPresenter = previous }
        let split = harness.shell.splitCanvas
        split.setLayout(.twoColumns)
        split.setContent(documentID: harness.document.documentIdentity, documentTitle: "Pane",
                         page: harness.core.document.pages[0], in: .first)
        split.setContent(documentID: harness.document.documentIdentity, documentTitle: "Pane",
                         page: harness.core.document.pages[1], in: .second)
        _ = try #require(harness.controller.detachSplitPane(.first, shell: harness.shell))
        #expect(harness.controller.openPaneWindowCount == 1)
        // Split Canvas ends: the mode is no longer active when the mode observer fills.
        harness.controller.fillCanvasMode(shell: harness.shell, document: harness.document)
        // Old: the pane window stayed, "This pane is empty.", keeping the split controller alive.
        #expect(harness.controller.openPaneWindowCount == 0)
        #expect(split.detachedPaneIDs.isEmpty)

        _ = try #require(harness.controller.detachSplitPane(.second, shell: harness.shell))
        #expect(harness.controller.paneWindow(.second) != nil)
        harness.controller.window?.close()
        // Old: still registered under the closed controller's address.
        #expect(harness.controller.openPaneWindowCount == 0)
        #expect(split.detachedPaneIDs.isEmpty)
    }

    // MARK: - S-023

    @Test("S-023: the Quick Look summary's totals are the whole project's, whatever filter the ledger shows at save")
    func quickLookTotalsAreUnfiltered() async throws {
        let harness = try await Fix2Harness.make("S023.pdf")
        defer { harness.tearDown() }
        // 250 pt + 150 pt at 100 pt = 1 m: 2.5 m + 1.5 m = 4 m of length in all.
        _ = try await Self.length(harness, from: 0, to: 250, y: 10, subject: "Wall")
        _ = try await Self.length(harness, from: 0, to: 150, y: 60, subject: "Slab")
        let whole = try #require(await harness.document.quickLookSummary())
        #expect(whole.totals.contains { $0.text.hasPrefix("4") }, "\(whole.totals)")
        harness.core.ledger.setFilter(Self.subjectFilter("Wall"))
        #expect(await AppTestSupport.wait { harness.core.ledger.rowCount == 1 })
        let filtered = try #require(await harness.document.quickLookSummary())
        // Old: the filtered 2.5 m beside a markup count of 2.
        #expect(filtered.totals == whole.totals)
        #expect(filtered.markupCount == 2)
        let request = ZenitPDFProjectDocument.wholeProjectRequest(from: harness.core.ledger.request)
        #expect(request.filter.isEmpty && !request.onlyOlderScaleValues && request.markupScope == nil)
    }

    // MARK: - L-01

    @Test("L-01: the device import row keeps its own title when AppKit offers an unlocalized key")
    func deviceImportTitleStays() {
        let item = DeviceImport.menuItem()
        #expect(item.identifier == NSMenuItem.importFromDeviceIdentifier)
        item.title = "<<Import From Device - unlocalized>>"
        // Old: a plain NSMenuItem, which showed the raw key in the File menu.
        #expect(item.title == "Import from iPhone or iPad")
        item.attributedTitle = NSAttributedString(string: "<<Import From Device - unlocalized>>")
        #expect(item.title == "Import from iPhone or iPad")
        #expect(item.attributedTitle == nil)
        item.title = "Import from Device"
        #expect(item.title == "Import from Device", "a real title from AppKit is kept")
        #expect(DeviceImport.isUnlocalizedPlaceholder(" <<Take Photo - unlocalized>> "))
        #expect(!DeviceImport.isUnlocalizedPlaceholder("Take Photo"))
    }

    // MARK: - L-02 / L-03

    static func menu(_ group: ZPDFCommandGroup, in bar: NSMenu) throws -> NSMenu {
        try #require(bar.items.compactMap(\.submenu).first { $0.title == group.displayName })
    }

    static func visibleRows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
    }

    static func commands(in menu: NSMenu) -> [ZenitAppCommand] {
        visibleRows(menu).compactMap { ($0.representedObject as? String).flatMap(ZenitAppCommand.init(rawValue:)) }
    }

    @Test("L-02: File, Tools and Measure group their families into submenus, and every command and shortcut is still there")
    func menusAreGrouped() throws {
        let bar = ZenitMenuBar.make()
        let file = try Self.menu(.file, in: bar)
        let tools = try Self.menu(.tools, in: bar)
        let measure = try Self.menu(.measure, in: bar)
        // Old: 41, 31 and 33 rows.
        #expect(Self.visibleRows(file).count <= 30, "\(Self.visibleRows(file).map(\.title))")
        #expect(Self.visibleRows(tools).count <= 29, "\(Self.visibleRows(tools).map(\.title))")
        #expect(Self.visibleRows(measure).count <= 24, "\(Self.visibleRows(measure).map(\.title))")
        let review = try #require(file.items.first { $0.title == "Review" }?.submenu)
        #expect(Self.commands(in: review) == [.importReviewAnnotations, .connectSharedReview, .syncSharedReview, .disconnectSharedReview,
                                              .exportReviewFile, .importReviewFile, .shareReviewFile, .exportXFDF, .importXFDF])
        let indexed = try #require(file.items.first { $0.title == "Indexed Drawings" }?.submenu)
        #expect(Self.commands(in: indexed) == [.indexDrawingFolder, .searchDrawingFolder, .forgetDrawingFolder])
        let redaction = try #require(tools.items.first { $0.title == "Redaction" }?.submenu)
        #expect(Self.commands(in: redaction) == [.markRedaction, .applyRedactions, .clearRedactionMarks])
        let automation = try #require(measure.items.first { $0.title == "Automation" }?.submenu)
        #expect(Self.commands(in: automation) == [.checkDrawnDimensions, .createSymbolSchedule, .autoTraceOptions, .findLibrarySymbols,
                                                  .findGeometry, .detectRooms, .findWalls, .findRepeatedSheets, .prepareSet, .assistantInbox])
        // Every sentence that points at a moved row names its real place (R-034's rule).
        #expect(ZenitAppCommandTable.menuPath(for: .connectSharedReview) == "File ▸ Review ▸ Connect Shared Review Folder…")
        #expect(FolderIndexCommand.noFolderMessage == "No folder is indexed yet. Choose File ▸ Indexed Drawings ▸ Index a Folder of Drawings… first.")
        #expect(ZenitAppCommandTable.menuPath(for: .applyRedactions) == "Tools ▸ Redaction ▸ Apply Redactions to a Copy…")
        #expect(ZenitAppCommandTable.menuPath(for: .assistantInbox) == "Measure ▸ Automation ▸ Takeoff Assistant Inbox")
        #expect(ProjectWindowController.noJobTemplatesNote == "No job templates saved yet — Tools ▸ Job Templates ▸ Save as Job Template…")
        // Set Scale… keeps its row at the top of Measure, with its chord (R-042).
        #expect(Self.commands(in: measure).contains(.calibrateScale))
        // Nothing lost: every application command has one visible row somewhere in the bar, and
        // every chord the table gives it is on that row or its hidden twin.
        func allRows(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allRows) ?? []) } }
        let rows = allRows(bar)
        for spec in ZenitAppCommandTable.specs {
            let visible = rows.filter { ($0.representedObject as? String) == spec.command.rawValue && !$0.isHidden }
            #expect(visible.count == 1, "\(spec.command)")
            if let chord = spec.keyEquivalent {
                #expect(visible.first?.keyEquivalent == chord.key && visible.first?.keyEquivalentModifierMask == chord.modifiers, "\(spec.command)")
            }
        }
    }

    @Test("L-03: File ▸ Drawing Set holds the Navigator's five set actions, in its order, and runs the same flows")
    func drawingSetCommandsAreInTheMenu() async throws {
        let bar = ZenitMenuBar.make()
        let file = try Self.menu(.file, in: bar)
        let set = try #require(file.items.first { $0.title == "Drawing Set" }?.submenu)
        // Old: in no menu of the bar at all — only on the Navigator card's ⋯ menu (R-071).
        // L-57/L-93: Add Revision… sits before the report that needs a revision.
        #expect(Self.commands(in: set) == [.exportArrangedSet, .linkSheetReferences, .addRevision, .setCompareReport, .splitIntoSheets, .combineOpenDrawings])
        #expect(Self.visibleRows(set).map(\.title) == [
            "Export Arranged Set…", "Link Sheet References…", "Add Revision…", "Set Compare Report…", "Split into Sheets…",
            "Combine Open Drawings into This Project…",
        ])

        let harness = try await Fix2Harness.make("L03.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let state = ZenitAppCommandWindowState(controller: harness.controller)
        for command in [ZenitAppCommand.exportArrangedSet, .linkSheetReferences, .setCompareReport, .splitIntoSheets] {
            #expect(ZenitAppCommandTable.validate(command, item: nil, state: state), "\(command)")
        }
        #expect(!ZenitAppCommandTable.validate(.combineOpenDrawings, item: nil, state: state), "one tab: nothing to combine")
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        ZenitAppCommandTable.perform(.exportArrangedSet, controller: harness.controller, document: harness.document)
        #expect(await AppTestSupport.wait { ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.exportArrangedSetPanelIdentifier) })
        ZenitAppCommandTable.perform(.splitIntoSheets, controller: harness.controller, document: harness.document)
        #expect(await AppTestSupport.wait { ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.splitIntoSheetsPanelIdentifier) })
        ZenitAppCommandTable.perform(.setCompareReport, controller: harness.controller, document: harness.document)
        // V-029: the whole set's own refusal, no longer the sheet card's "This sheet has…".
        // L-57: the refusal names the menu command, not only the ⌥ drop.
        #expect(harness.core.status.snapshot.activeToolNote == "The set has no revision to compare with. Choose File ▸ Drawing Set ▸ Add Revision…, or hold ⌥ and drop the revised PDF on the canvas, to add one first.")
        ZenitAppCommandTable.perform(.linkSheetReferences, controller: harness.controller, document: harness.document)
        #expect(await AppTestSupport.wait { harness.core.status.snapshot.activeToolNote == "Name the sheets first: links are made to sheet numbers." })
    }

    // MARK: - C-07

    @Test("C-07: each window has its own undo toast, workspace follower and jump history; snap toggles show in every window")
    func secondWindowKeepsItsOwnViewState() async throws {
        let harness = try await Fix2Harness.make("C07.pdf", pageCount: 2)
        let document = harness.document
        let second = try await Self.openSecondWindow(harness)
        defer {
            Self.closeWindows(harness, [second])
            harness.tearDown()
        }
        let firstShell = harness.shell
        let secondShell = try #require(second.windowShell(for: document))
        let secondCore = try #require(second.windowCore(for: document))

        // Undo toast: old, one feed per document, on the first window's toast only.
        #expect(UndoToastFeed.hasFeed(for: firstShell) && UndoToastFeed.hasFeed(for: secondShell))
        _ = try await Self.length(harness, from: 0, to: 250, y: 10, subject: "Wall")
        second.focusThisWindow()
        #expect(document.shell === secondShell)
        document.undoManager?.undo()
        #expect(await AppTestSupport.wait { secondShell.undoToast.message != nil })
        #expect(firstShell.undoToast.message == nil, "the toast speaks in the window the ⌘Z came from")

        // Workspace follower: old, the second window's canvas modes were followed by nobody.
        let firstFollower = try #require(ZenitWorkspaceMenu.follower(for: firstShell))
        let secondFollower = try #require(ZenitWorkspaceMenu.follower(for: secondShell))
        #expect(firstFollower !== secondFollower)

        // Snap toggles are the session's: old, the other window's strip kept the old state.
        harness.core.status.setMarkupSnapEnabled(false)
        #expect(!secondCore.status.toggles.markup)
        secondCore.status.setMarkupSnapEnabled(true)
        #expect(harness.core.status.toggles.markup)

        // Jumps: a jump in the second window is that window's to go back from.
        let target = try #require(secondCore.document.pages.last?.id)
        second.follow(.sheet(target), shell: secondShell, document: document)
        #expect(!second.navigationHistory(of: document).back.isEmpty)
        // Old: one history per document — the first window's ⌘[ went back to where the second
        // window's jump started.
        #expect(harness.controller.navigationHistory(of: document).back.isEmpty)
        harness.controller.focusThisWindow()
        #expect(document.navigationHistory.back.isEmpty, "the document's history is the focused window's")

        // Closing the second window takes its feed and follower.
        second.window?.close()
        #expect(!UndoToastFeed.hasFeed(for: secondShell))
        #expect(ZenitWorkspaceMenu.follower(for: secondShell) == nil)
        #expect(UndoToastFeed.hasFeed(for: firstShell))
    }

    @Test("C-07: the window session records each drawing's second windows, and a relaunch reopens them at their sheet")
    func secondWindowsAreRestored() async throws {
        let harness = try await Fix2Harness.make("C07s.pdf", pageCount: 2, calibrate: false)
        let document = harness.document
        let previousOpener = ProjectWindowController.dropOpener
        defer {
            ProjectWindowController.dropOpener = previousOpener
            ProjectWindowController.pendingSecondWindows = [:]
            ProjectWindowController.pendingSessionViewports = [:]
            ProjectWindowController.pendingActivePath = nil
            document.unsavedTakeoffReview = { _, answer in answer(.discard) }
            for view in document.windowViews { view.controller?.window?.close() }
            harness.tearDown()
        }
        // The session names file-backed drawings: a project.
        _ = try await Self.saveAsProject(harness)
        let path = try #require(document.fileURL?.path)
        let second = try await Self.openSecondWindow(harness)
        let secondCore = try #require(second.windowCore(for: document))
        secondCore.document.goToPage(index: 1)
        let session = try #require(harness.controller.currentSession())
        // Old: no record of the second window at all.
        #expect(session.secondWindows == [WindowSession.SecondWindow(
            path: path, viewport: WindowSession.Viewport(position: 1, zoom: secondCore.canvas.viewport.zoom)
        )])
        second.window?.close()
        #expect(harness.controller.currentSession()?.secondWindows == nil)

        // A session written before second windows were recorded still reads.
        let legacy = try JSONDecoder().decode(WindowSession.self, from: Data(#"{"paths":["/tmp/A.pdf"],"activeIndex":0,"viewports":{}}"#.utf8))
        #expect(legacy.paths == ["/tmp/A.pdf"] && legacy.secondWindows == nil)

        // Relaunch: the drawing opens (injected) and its second window comes back at sheet 2.
        let defaults = ZenitScratchDefaults()
        WindowSessionStore.save(session, defaults: defaults)
        var opened: [URL] = []
        ProjectWindowController.dropOpener = { opened.append(contentsOf: $0) }
        ProjectWindowController.restoreLastSession(defaults: defaults)
        // The opener may be handed the bookmark's resolved spelling (/private/var for /var); the
        // document it opens carries that URL, and the pending windows are filed under it.
        let reopened = try #require(opened.first)
        #expect(opened.count == 1)
        #expect(reopened.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        #expect(ProjectWindowController.pendingSecondWindows[reopened.path]?.map(\.position) == [1])
        // This document stands in for the one the opener would make from `reopened`.
        if reopened.path != path {
            ProjectWindowController.pendingSecondWindows[path] = ProjectWindowController.pendingSecondWindows.removeValue(forKey: reopened.path)
            ProjectWindowController.pendingSessionViewports[path] = ProjectWindowController.pendingSessionViewports.removeValue(forKey: reopened.path)
        }
        harness.controller.applyPendingSessionViewport(for: document)
        #expect(await AppTestSupport.wait { document.windowViews.count == 1 })
        let restored = try #require(document.windowViews.first)
        #expect(await AppTestSupport.wait { restored.core.document.currentPageID == restored.core.document.pages.last?.id })
        #expect(ProjectWindowController.pendingSecondWindows.isEmpty)
    }
}
