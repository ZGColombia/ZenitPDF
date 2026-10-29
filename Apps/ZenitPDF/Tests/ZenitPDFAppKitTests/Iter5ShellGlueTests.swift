import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFTestingSupport
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Loop iteration 5, area app-shell-glue: L-17, L-18 and V-016 … V-029. Every test states the old
/// output it fails with. Headless throughout: no window is ordered front, every modal is recorded
/// or answered by injection, every store and fixture is a temporary one.
@MainActor
@Suite("Iteration 5 — app shell glue", .appTierSerialised, .serialized)
struct Iter5ShellGlueTests {

    // MARK: - Helpers

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it5-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        await Iter2ShellGlueTests.eventually(upTo: seconds, condition)
    }

    static func exclude(_ harness: Fix2Harness, _ pages: [ZPDFContracts.PageDescriptor]) async throws {
        try await Iter4ShellGlueTests.exclude(harness, pages)
    }

    static func cloud(on page: PageID, document: DocumentID, subject: String = "Walls") -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: document, pageID: page,
            kind: .cloud, subject: subject, author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date()
        )
    }

    // MARK: - L-18

    /// What AppKit does after `applicationShouldTerminate` answers `.terminateLater`, and what the
    /// delegate does to answer it: the run loop runs in the modal-panel mode until the reply, and
    /// the reply comes from a main-actor task (the storage shutdown's).
    @MainActor
    final class TerminateLaterProbe {
        var inline: Bool?
        var reentered: Bool?

        /// Returns whether the reply arrived while `terminate` was still waiting for it.
        func appKitTerminate() -> Bool {
            final class Flag { var replied = false }
            let flag = Flag()
            Task { @MainActor in flag.replied = true }
            let deadline = Date().addingTimeInterval(3)
            while !flag.replied, Date() < deadline {
                _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
            }
            return flag.replied
        }
    }

    @Test("L-18: after the quit review, termination is re-entered from the run loop, where the terminate-later wait hears its reply")
    func terminationReentryHearsItsReply() async throws {
        _ = NSApplication.shared
        let probe = TerminateLaterProbe()
        // Old: the review's answer arrives on a main-queue job — Don't Save retires the takeoff in
        // a task, then answers — and `terminate` was re-entered straight from it. Inside that job
        // the modal wait never drains the main queue, so the reply's task never ran: false, and
        // the application stayed up with its window open after Don't Save.
        Task { @MainActor in probe.inline = probe.appKitTerminate() }
        #expect(await Self.eventually(upTo: 10) { probe.inline != nil })
        #expect(probe.inline == false, "the mechanism behind L-18: a main-queue job cannot hear a main-actor reply")
        // Now: the same answer re-enters through `ZenitApplication.reenterTermination`, a run-loop
        // block, and the wait hears the reply.
        Task { @MainActor in
            ZenitApplication.reenterTermination { probe.reentered = probe.appKitTerminate() }
        }
        #expect(await Self.eventually(upTo: 10) { probe.reentered != nil })
        #expect(probe.reentered == true)
    }

    // MARK: - V-016

    @Test("V-016: Page Scales… from the menu keeps its coordinator: the rows fill in and Close ends the sheet")
    func pageScalesFromTheMenu() async throws {
        let harness = try await Fix2Harness.make("V016 Scales.pdf", pageCount: 2)
        ZenitModalPresenter.reset()
        defer {
            if let window = harness.controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let window = try #require(harness.controller.window)
        // The menu's own route, which drops the coordinator `present` returns.
        ZenitAppCommandTable.perform(.pageScales, controller: harness.controller, document: harness.document)
        #expect(ZenitModalPresenter.didRequest(PageScalesCoordinator.modalIdentifier))
        let sheet = try #require(window.attachedSheet)
        let host = try #require(sheet.contentViewController as? NSHostingController<PageScalesHost>)
        let model = host.rootView.model
        // Old: every row stayed `.reading` — the coordinator was gone before its read task ran.
        #expect(await Self.eventually(upTo: 30) { model.rows.allSatisfy { $0.status != .reading } },
                "\(model.rows.map(\.status))")
        // Old: Close called a closure whose coordinator was nil; the sheet stayed attached.
        model.onClose()
        #expect(await Self.eventually { window.attachedSheet == nil })
        #expect(PageScalesCoordinator.active(for: harness.document) == nil, "the coordinator is let go with its sheet")
    }

    @Test("V-016: Apply Scale to Pages… from the menu shows its preview and Cancel ends the sheet")
    func applyScaleFromTheMenu() async throws {
        let harness = try await Fix2Harness.make("V016 Bulk.pdf", pageCount: 3)
        ZenitModalPresenter.reset()
        defer {
            if let window = harness.controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let window = try #require(harness.controller.window)
        ZenitAppCommandTable.perform(.applyScaleToPages, controller: harness.controller, document: harness.document)
        let sheet = try #require(window.attachedSheet)
        let host = try #require(sheet.contentViewController as? NSHostingController<BulkScaleHost>)
        let model = host.rootView.model
        // Old: the preview task found its coordinator gone and never counted: 0 pages.
        #expect(await Self.eventually { model.impact.pageCount == 2 }, "\(model.impact)")
        model.onCancel()
        // Old: Cancel reached nothing and the sheet stayed attached.
        #expect(await Self.eventually { window.attachedSheet == nil })
        #expect(BulkScaleCoordinator.active(for: harness.document) == nil)
    }

    // MARK: - V-017

    private func writeRevisionB(from fixture: URL, to url: URL, pages: Int) async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: fixture)
        let labels = try await provider.pageLabels(of: opened.handle).allLabels()
        let composed = (0..<pages).map { ComposedPage(document: opened.handle, pageIndex: $0, label: labels[$0]) }
        _ = try await provider.composeDocument(composed, to: DocumentDestination(url: url))
        await provider.close(opened.handle)
    }

    private func storedRevisions(_ package: ProjectPackage) async throws -> [(RevisionEntryRecord, [RevisionSheetRecord])] {
        try await package.read { db in
            guard let document = try String.fetchOne(db, sql: "SELECT id FROM document ORDER BY created_at, id LIMIT 1") else { return [] }
            return try DocumentSetStore.revisions(document: document, in: db).map { ($0, try DocumentSetStore.sheets(revision: $0.id, in: db)) }
        }
    }

    @Test("V-017: Save As carries the revisions and a confirmed pairing into the new project, and reopening finds them")
    func saveAsCarriesRevisions() async throws {
        let directory = try Self.scratch("v017")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZPDFFixtures.make(.set30SheetsTitleBlocks, in: directory)
        let harness = try await Fix2Harness.make("RevSet.pdf", calibrate: false, fixture: fixture.url)
        defer {
            harness.controller.window?.close()
            harness.document.close()
        }
        try await Iter1ShellGlueTests.save(harness.document, to: directory.appendingPathComponent("Rev.zpdfproj"), .saveAsOperation)
        let revB = directory.appendingPathComponent("Rev B.pdf")
        try await writeRevisionB(from: fixture.url, to: revB, pages: 30)

        var captured: (model: SheetMatchReviewModel, rowID: String)?
        let previous = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { model, rowID, _ in captured = (model, rowID); return {} }
        defer { ZenitPDFProjectDocument.sheetMatchReviewPresenter = previous }
        var added = false
        harness.document.addRevision(fromDroppedFile: revB) { added = $0 }
        #expect(await Self.eventually(upTo: 30) { added && captured != nil })
        let review = try #require(captured)
        review.model.setPartner(5, forSetIndex: 5)
        review.model.accept(revisionID: review.rowID)
        let summaryID = try #require(harness.document.newestRevision?.id)
        let setPage5 = harness.core.document.pages[5].id
        let original = try #require(harness.document.projectPackage)
        #expect(await Self.eventually {
            (try? await self.storedRevisions(original))?.first?.1.first { $0.revisionPageIndex == 5 }?.evidence == "manual"
        }, "the confirmed pair is stored in the open project first")

        let copyURL = directory.appendingPathComponent("Copy.zpdfproj")
        try await Iter1ShellGlueTests.save(harness.document, to: copyURL, .saveAsOperation)
        let copy = try #require(harness.document.projectPackage)
        #expect(copy !== original)
        let carried = try await storedRevisions(copy)
        // Old: [] — the copy started empty and only the takeoff, artwork, photos and layers moved.
        #expect(carried.count == 1)
        #expect(carried.first?.0.label == "Rev B")
        #expect(carried.first?.1.count == 30)
        #expect(carried.first?.1.first { $0.revisionPageIndex == 5 }?.evidence == "manual")
        #expect(carried.first?.1.first { $0.revisionPageIndex == 5 }?.pageId == setPage5.uuidString)
        #expect(FileManager.default.fileExists(atPath: copy.revisionFileURL(try #require(carried.first?.0)).path))
        // The session's revision now names the copy's row, not the old package's.
        #expect(harness.document.persistedRevisionIDs[summaryID] == carried.first?.0.id)

        // Reopened, the copy has its revision and the pair the person confirmed.
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: copyURL, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await Self.eventually(upTo: 30) { reopened.core != nil && reopened.shell != nil })
        let controller = ProjectWindowController(document: reopened)
        reopened.addWindowController(controller)
        defer {
            controller.window?.close()
            reopened.close()
        }
        #expect(await Self.eventually(upTo: 30) { reopened.newestRevision != nil })
        let reopenedRevision = try #require(reopened.newestRevision?.id)
        let reopenedPage5 = try #require(reopened.core?.document.pages[5].id)
        #expect(await Self.eventually { reopened.revisionSheetPairEvidence[reopenedRevision]?[reopenedPage5] == .manual })
    }

    @Test("V-017: Create Project from a Quick PDF keeps the revision the session holds")
    func createProjectKeepsSessionRevisions() async throws {
        let harness = try await Fix2Harness.make("V017 Quick.pdf", pageCount: 2)
        defer { harness.tearDown() }
        let revision = harness.directory.appendingPathComponent("V017 Quick rev B.pdf")
        try FileManager.default.copyItem(at: try #require(harness.document.drawing?.url), to: revision)
        var added = false
        harness.document.addRevision(fromDroppedFile: revision) { added = $0 }
        #expect(await Self.eventually(upTo: 30) { added })
        #expect(harness.document.projectPackage == nil, "a Quick PDF keeps its revision for the session only")
        let summaryID = try #require(harness.document.newestRevision?.id)

        _ = try await Iter1ShellGlueTests.saveAsProject(harness, name: "V017.zpdfproj")
        let package = try #require(harness.document.projectPackage)
        let stored = try await storedRevisions(package)
        // Old: [] — Create Project never stored a session revision.
        #expect(stored.count == 1)
        #expect(stored.first?.0.label == "V017 Quick rev B")
        #expect(stored.first?.0.pageCount == 2)
        #expect(stored.first?.1.count == 2, "one pairing row per revision page")
        #expect(harness.document.persistedRevisionIDs[summaryID] == stored.first?.0.id)
        #expect(FileManager.default.fileExists(atPath: package.revisionFileURL(try #require(stored.first?.0)).path),
                "the file is copied into the project, not referenced where it was dropped from")
    }

    // MARK: - V-018

    @Test("V-018: a one-drawing set that is not the file as filed is composed for Print and the exports")
    func oneDrawingSetIsComposedWhenArranged() async throws {
        let harness = try await Fix2Harness.make("V018.pdf", pageCount: 3)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let sheets = drawing.pages.sorted { $0.index < $1.index }

        // The control: the file exactly as filed is written on directly, as always.
        #expect(DrawingSetOutput.isDrawingAsFiled(await harness.document.setExportPages(), primary: drawing))
        #expect(try await DrawingSetOutput.make(for: harness.document) == nil)

        try await Self.exclude(harness, [sheets[1]])
        // Old: nil — only a sheet from another drawing composed, so Print, Marked, Clean,
        // Annotated and Layered wrote all three pages, the removed one included.
        let set = try #require(try await DrawingSetOutput.make(for: harness.document))
        defer { set.cleanUp() }
        #expect(set.pages.map(\.id) == [sheets[0].id, sheets[2].id])
        #expect(set.pages.map(\.index) == [0, 1])
        #expect(CGPDFDocument(set.url as CFURL)?.numberOfPages == 2)
        let job = try await FlattenedDrawingExport.job(for: harness.document, set: set)
        #expect(job.pages.map(\.page.id) == [sheets[0].id, sheets[2].id], "old: three pages, in file order")
        #expect(job.sourceURL == set.url)

        // A turn or a sheet number of its own is not the file as filed either.
        _ = try await harness.core.commands.perform(.setPagesExcluded([sheets[1].id], excluded: false))
        await harness.core.commands.settle()
        await harness.core.refresh()
        #expect(DrawingSetOutput.isDrawingAsFiled(await harness.document.setExportPages(), primary: drawing))
        await harness.document.rotatePages([sheets[2].id], by: 90)
        await harness.core.refresh()
        #expect(!DrawingSetOutput.isDrawingAsFiled(await harness.document.setExportPages(), primary: drawing))
        let turned = try #require(try await DrawingSetOutput.make(for: harness.document))
        defer { turned.cleanUp() }
        #expect(turned.pages.last?.rotation.rawValue == 90)
        await harness.document.rotatePages([sheets[2].id], by: -90)
        await harness.document.nameSheet(sheets[0].id, number: "A-101", title: nil)
        await harness.core.refresh()
        #expect(!DrawingSetOutput.isDrawingAsFiled(await harness.document.setExportPages(), primary: drawing))
    }

    // MARK: - V-019

    @Test("V-019: a markup on a sheet after a removed one gets its own snapshot in the review report")
    func reviewSnapshotFollowsTheMarkupsSheet() async throws {
        let harness = try await Fix2Harness.make("V019.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let sheets = try #require(harness.document.drawing).pages.sorted { $0.index < $1.index }
        let cloud = Self.cloud(on: sheets[1].id, document: try #require(harness.document.drawing).documentID)
        try await harness.core.commands.perform(.addMarkup(cloud))
        await harness.core.refresh()
        try await Self.exclude(harness, [sheets[0]])
        let review = try #require(harness.document.shell?.review)
        let entries = ReviewReportExport.entries(for: [cloud.id.rawValue], review: review)
        #expect(entries.count == 1)
        #expect(entries.first?.row.pageIndex == 0, "the row's index is the sheet's set position, not its PDF index")
        let pictures = await ReviewReportSnapshots.snapshots(for: entries, document: harness.document)
        // Old: nothing — set position 0 picked the primary drawing's page 0 (the removed sheet),
        // the markup was not on it, and the snapshot was dropped by `try?`.
        let png = try #require(pictures[cloud.id.rawValue])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width >= 222 && image.width < 400, "a crop of the markup on its own sheet: \(image.width)")
    }

    // MARK: - V-020

    @Test("V-020: the Carry Forward report states values in the ledger's units and precision, with headers and the total change")
    func carryForwardReportIsFormatted() {
        let length = CarryForwardReport.Row(
            sourceID: MarkupID(UUID()), carriedID: MarkupID(UUID()), subject: "Wall", classification: .moved,
            field: .planLength, oldValue: Decimal(string: "12.3456789"), newValue: Decimal(string: "12.5")
        )
        let area = CarryForwardReport.Row(
            sourceID: MarkupID(UUID()), carriedID: MarkupID(UUID()), subject: "", classification: .needsReview,
            field: .netArea, oldValue: 10, newValue: Decimal(string: "12.25")
        )
        let report = CarryForwardReport(
            rows: [length, area],
            totalDelta: [.planLength: Decimal(string: "0.1543211")!, .netArea: Decimal(string: "2.25")!]
        )
        #expect(CarryForwardReportDisplay.header == ["Measurement", "Before", "After", "Change", "Result"])

        // Metric, two places: 12.3456789 m → 12.35 m; 12.5 → 12.50; 12.5 − 12.3456789 = 0.1543211
        // → +0.15 m. 10 m² → 10.00 m²; 12.25 → 12.25; +2.25 m².
        let metric = CarryForwardReportDisplay(report: report, formatter: QuantityFormatter())
        // Old: "12.3456789", "12.5", "0.1543211" — SI digits with no unit, field or header.
        #expect(metric.rows[0] == .init(measurement: "Wall · Plan Length", before: "12.35 m", after: "12.50 m", change: "+0.15 m", result: "Moved with the drawing"))
        #expect(metric.rows[1] == .init(measurement: "Measurement · Plan Area", before: "10.00 m²", after: "12.25 m²", change: "+2.25 m²", result: "Linework changed — review"))
        // Old: the total change was never shown.
        #expect(metric.totals == [.init(field: "Plan Length", change: "+0.15 m"), .init(field: "Plan Area", change: "+2.25 m²")])

        // Decimal feet, two places: 12.3456789 / 0.3048 = 40.5042… → 40.50 ft; 12.5 / 0.3048 =
        // 41.0104… → 41.01 ft; 0.1543211 / 0.3048 = 0.50630… → +0.51 ft.
        let feet = CarryForwardReportDisplay(
            report: report,
            formatter: QuantityFormatter(units: DisplayUnitSelection().withImperialLengthStyle(.decimalFeet))
        )
        #expect(feet.rows[0].before == "40.50 ft")
        #expect(feet.rows[0].after == "41.01 ft")
        #expect(feet.rows[0].change == "+0.51 ft")
        // A shrink carries its minus sign and no plus.
        let shrink = CarryForwardReport(rows: [.init(
            sourceID: MarkupID(UUID()), carriedID: MarkupID(UUID()), subject: "Wall", classification: .moved,
            field: .planLength, oldValue: 3, newValue: Decimal(string: "2.75")
        )], totalDelta: [.planLength: Decimal(string: "-0.25")!])
        #expect(CarryForwardReportDisplay(report: shrink, formatter: QuantityFormatter()).rows[0].change == "-0.25 m")
    }

    // MARK: - V-021

    @Test("V-021: the drawing exports and the searchable copy refuse to replace a revision dropped on the drawing")
    func drawingOutputsRefuseRevisionFiles() async throws {
        let harness = try await Fix2Harness.make("V021 Plan.pdf", pageCount: 1)
        defer { harness.tearDown() }
        let revision = harness.directory.appendingPathComponent("V021 Plan rev B.pdf")
        try FileManager.default.copyItem(at: try #require(harness.document.drawing?.url), to: revision)
        let before = try Data(contentsOf: revision)
        var added = false
        harness.document.addRevision(fromDroppedFile: revision) { added = $0 }
        #expect(await Self.eventually(upTo: 30) { added })
        // Old: no refusal — Marked, Clean, Annotated and Layered checked the drawing and the
        // set's sources only, so Replace in the panel overwrote the open revision.
        #expect(throws: DerivedCopyGuard.Refusal.self) {
            try DerivedCopyGuard.refuseIfSource(revision, document: harness.document, set: nil)
        }
        // Old: compared with the drawing alone, then wrote the searchable copy over the revision.
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            _ = try await SearchableCopyExport.write(for: harness.document, to: revision)
        }
        #expect(try Data(contentsOf: revision) == before)
        // A file of nobody's is still written to.
        let elsewhere = harness.directory.appendingPathComponent("Out.pdf")
        try DerivedCopyGuard.refuseIfSource(elsewhere, document: harness.document, set: nil)
    }

    // MARK: - V-022

    @Test("V-022: the Set Compare CSV and the batch report CSV write formula-like text as text")
    func csvOutputsNeutraliseFormulas() {
        typealias Row = ZenitPDFProjectDocument.SetCompareRow
        let rows = [Row(setSheet: "A-101", revisionSheet: "=HYPERLINK(\"http://x\",\"A-1\")", status: .changed, differences: 1, affectedMeasurements: 0, evidence: "@SUM(1)")]
        let csv = ZenitPDFProjectDocument.setCompareCSV(rows)
        // Old: "\"=HYPERLINK(…)\"" — quoted, which a spreadsheet still evaluates — and @SUM(1) bare.
        #expect(csv.contains("\nA-101,\"'=HYPERLINK(\"\"http://x\"\",\"\"A-1\"\")\",changed,1,0,'@SUM(1)\n"), "\(csv)")

        let report = BatchFileProcessor.Report(items: [
            .init(input: URL(fileURLWithPath: "/tmp/=cmd|calc.pdf"), output: nil, status: .failed("+ could not read"), inputUnchanged: true),
            .init(input: URL(fileURLWithPath: "/tmp/Plan.pdf"), output: URL(fileURLWithPath: "/tmp/out/Plan.pdf"), status: .done, inputUnchanged: true),
        ], cancelled: false)
        let batch = BatchFileProcessor.csv(report)
        // Old: "\"=cmd|calc.pdf\",failed,\"+ could not read\"" — every field quoted, none neutralised.
        #expect(batch.contains("\n'=cmd|calc.pdf,failed,'+ could not read,,yes\n"), "\(batch)")
        #expect(batch.contains("\nPlan.pdf,done,,Plan.pdf,yes\n"), "\(batch)")
    }

    // MARK: - V-023

    @Test("V-023: a connected project opened while its folder is unreachable says so, and a later manual sync starts the watch")
    func sharedReviewResumesAfterAnOfflineOpen() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "V023.pdf")
        let root = pdf.deletingLastPathComponent()
        let defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.defaults = defaults
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        let interval = SharedReviewAutoSync.pollInterval
        let automatic = SharedReviewAutoSync.automaticStart
        SharedReviewAutoSync.pollInterval = 600
        SharedReviewAutoSync.automaticStart = false
        ZenitModalPresenter.reset()
        defer {
            SharedReviewAutoSync.pollInterval = interval
            SharedReviewAutoSync.automaticStart = automatic
            SharedReviewCommands.defaults = .store
            SharedReviewCommands.baseDirectoryOverride = SharedReviewCommands.defaultBaseDirectoryOverride
            ZenitModalPresenter.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("Site.zpdfproj", isDirectory: true)
        try await ProjectPackage.create(at: url, displayName: "Site", originalPDF: pdf, pageCount: 1).close()
        let folder = root.appendingPathComponent("Shared", isDirectory: true)
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.projectPackage != nil })
        defer {
            SharedReviewAutoSync.stop(document: document)
            document.close()
        }
        let core = try #require(document.core)
        #expect(await SharedReviewCommands.connect(document: document, folder: folder) != nil)
        let package = try #require(document.projectPackage)
        let projectID = await package.manifest.projectId

        // The drive is offline at the next open: the remembered bookmark does not resolve.
        defaults.set(Data("not a bookmark".utf8), forKey: SharedReviewCommands.bookmarkKey(projectID))
        defaults.removeObject(forKey: SharedReviewCommands.pathKey(projectID))
        #expect(SharedReviewCommands.isConnected(projectID) && SharedReviewCommands.folderURL(projectID) == nil)
        core.document.dismissWarning(id: SharedReviewCommands.noteID)
        SharedReviewAutoSync.automaticStart = true
        await SharedReviewAutoSync.resume(document: document)
        // Old: nothing — no watcher and no word; the project stayed silently unsynced.
        #expect(SharedReviewAutoSync.watcher(for: document) == nil)
        #expect(core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" })

        // The drive is back, and the person runs File ▸ Sync Shared Review.
        defaults.removeObject(forKey: SharedReviewCommands.bookmarkKey(projectID))
        defaults.set(folder.path, forKey: SharedReviewCommands.pathKey(projectID))
        #expect(await SharedReviewCommands.syncNow(document: document) != nil)
        // Old: nil — only Connect started a watcher; the manual sync synced once and stopped.
        let watcher = try #require(SharedReviewAutoSync.watcher(for: document))
        #expect(watcher.folder.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    // MARK: - V-024

    @Test("V-024: New from Template leaves a takeoff restored from a crash autosave alone")
    func newFromTemplateRefusesARestoredTakeoff() async throws {
        let root = try Self.scratch("v024-autosaves")
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        let previousOpener = NewFromTemplate.drawingOpener
        defer {
            NewFromTemplate.drawingOpener = previousOpener
            QuickTakeoffRestorePrompt.decisionOverride = nil
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let url = try AppTestSupport.writeFixturePDF(named: "V024 Restore.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A crashed session's takeoff: calibrated, autosaved, left in the container.
        let crashed = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { crashed.core != nil })
        let crashedCore = try #require(crashed.core)
        _ = try await crashedCore.commands.calibrate(
            page: try #require(await crashedCore.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre
        )
        await crashedCore.refresh()
        crashed.updateChangeCount(.changeDone)
        _ = try await crashed.autosaveQuickPDFTakeoff()
        crashed.close()
        #expect(await AppTestSupport.wait { !crashed.hasOpenStorage })

        QuickTakeoffRestorePrompt.decisionOverride = .restore
        var opened: ZenitPDFProjectDocument?
        NewFromTemplate.drawingOpener = { url in
            guard let document = try? AppTestSupport.makeDocument(opening: url) else { return nil }
            opened = document
            return (document, false)
        }
        let template = try #require(StarterJobTemplates.all.first)
        let outcome = await NewFromTemplate.start(template, onDrawingAt: url)
        let document = try #require(opened)
        defer { document.close() }
        #expect(document.restoredFromAutosave)
        // Old: .started — the template's presets and units landed on the restored takeoff, with
        // "The scale is not set" said over its calibrated sheet.
        #expect(outcome == .refusedRestoredTakeoff)
        let core = try #require(document.core)
        #expect(core.document.currentPageScale != nil, "the restored calibration is untouched")
        let note = try #require(core.document.warnings.first { $0.id == NewFromTemplate.noteID })
        #expect(note.title.contains("reopened with its recovered takeoff"), "\(note.title)")
        #expect(note.message.contains(ZenitAppCommandTable.menuPath(for: .applyJobTemplate)))
        #expect(!note.message.contains("scale is not set"))
    }

    // MARK: - V-025

    private struct LockState: ZenitAppCommandState {
        var hasActiveDocument = true
        var isQuickPDF = true
        var hasDrawing = true
        var hasSearchIndex = false
        var hasLoadedCore = true
        var hasPagesAndStampPreset = false
        var hasMarkupSelection = false
        var selectionIsLocked = false
        var hasHiddenMarkups = false
        var tabCount = 1
        var isSaveActivityBusy = false
        var isBatchProcessing = false
    }

    @Test("V-025: with a window, a disabled Lock row names what it would do now")
    func disabledLockRowIsRetitled() {
        let item = NSMenuItem(title: "Lock Selection", action: nil, keyEquivalent: "")
        var state = LockState(hasMarkupSelection: true, selectionIsLocked: true)
        #expect(ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state))
        #expect(item.title == "Unlock Selection")
        state = LockState(hasMarkupSelection: false, selectionIsLocked: false)
        #expect(!ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state))
        // Old: "Unlock Selection" — the title was rewritten only on an enabled row.
        #expect(item.title == "Lock Selection")
        // The save door closes the row and still retitles it.
        state = LockState(hasMarkupSelection: true, selectionIsLocked: true, isSaveActivityBusy: true)
        _ = ZenitAppCommandTable.validate(.toggleLockSelection, item: item, state: state)
        #expect(item.title == "Unlock Selection")
    }

    // MARK: - V-026

    @Test("V-026: Symbol Schedule's All Pages and Matching Size search only the set's sheets, in set order")
    func symbolScopesFollowTheSet() async throws {
        let harness = try await Fix2Harness.make("V026.pdf", pageCount: 4, calibrate: false)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let sheets = drawing.pages.sorted { $0.index < $1.index }
        try await Self.exclude(harness, [sheets[1]])
        await harness.document.movePages([sheets[3].id], to: 0)
        await harness.core.refresh()
        #expect(harness.core.snapshot.pages.map(\.id) == [sheets[3], sheets[0], sheets[2]].map(\.id.rawValue))
        for scope in [SymbolSearchScope.allPages, .matchingSize] {
            let pages = ProjectWindowController.pages(for: scope, current: sheets[0], in: drawing.pages, core: harness.core)
            // Old: [1, 2, 3, 4] by PDF index — the removed sheet 2 searched and counted on.
            #expect(pages.map(\.id) == [sheets[0], sheets[3], sheets[2]].map(\.id), "\(scope)")
        }
    }

    // MARK: - V-027

    @Test("V-027: in a one-drawing project, Extract Page(s)… writes a turned sheet turned")
    func extractComposesTurnedSheets() async throws {
        let harness = try await Fix2Harness.make("V027.pdf", pageCount: 2, calibrate: false)
        let output = harness.directory.appendingPathComponent("V027 extract.pdf")
        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        defer {
            ZenitModalPresenter.handler = previous
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        ZenitModalPresenter.handler = { request in
            request.identifier == ZenitPDFProjectDocument.extractPagesPanelIdentifier ? .urls([output]) : .dismissed
        }
        let sheets = try #require(harness.document.drawing).pages.sorted { $0.index < $1.index }
        #expect(!harness.document.extractNeedsComposing([sheets[1].id]), "the control: an untouched sheet is copied raw")
        await harness.document.rotatePages([sheets[1].id], by: 90)
        await harness.core.refresh()
        #expect(harness.document.extractNeedsComposing([sheets[1].id]))
        harness.document.extractPages([sheets[1].id], window: nil)
        #expect(await Self.eventually(upTo: 30) {
            FileManager.default.fileExists(atPath: output.path) && CGPDFDocument(output as CFURL)?.numberOfPages == 1
        })
        // Old: 0 — PDFKit's raw extract of PDF index 1, unturned.
        #expect(CGPDFDocument(output as CFURL)?.page(at: 1)?.rotationAngle == 90)

        await harness.document.rotatePages([sheets[1].id], by: -90)
        await harness.document.nameSheet(sheets[0].id, number: "A-101", title: nil)
        await harness.core.refresh()
        #expect(harness.document.extractNeedsComposing([sheets[0].id]), "a sheet number of its own is written as its label")
        #expect(!harness.document.extractNeedsComposing([sheets[1].id]))
    }

    // MARK: - V-029

    @Test("V-029: the Set Compare Report refuses with the set's own sentence")
    func setCompareReportRefusal() async throws {
        let harness = try await Fix2Harness.make("V029.pdf")
        defer { harness.tearDown() }
        harness.document.exportSetCompareReport(window: nil)
        // Old: "This sheet has no earlier revision to compare with." — the card command's words.
        #expect(harness.core.status.snapshot.activeToolNote
                == "The set has no revision to compare with. Choose File ▸ Drawing Set ▸ Add Revision…, or hold ⌥ and drop the revised PDF on the canvas, to add one first.")
    }

    // MARK: - L-17

    static func editableTextFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for sub in view.subviews { found += editableTextFields(in: sub) }
        return found
    }

    /// The headless half of L-17: Return pressed in the canvas bar's "Search in document" field,
    /// with the Count tool armed and nothing placed, is the field's. The live symptom — the Count
    /// tool saying "Count needs 1 more point…" — needs the canvas to hold the keyboard at the
    /// Return, which no path reachable without a key window gives it (see the status line).
    @Test("L-17: Return in the canvas bar's search field runs the search and never reaches the armed Count tool")
    func returnInTheSearchFieldStaysInTheField() async throws {
        let text = "BT /F1 24 Tf 100 300 Td (Wall) Tj ET 0.5 w 0 0 0 RG 72 72 m 300 72 l S"
        let fixture = try AutomationFixtures.writePages(named: "L17 Search.pdf", mediaBox: "0 0 842 595", contents: [text, text])
        let harness = try await Fix2Harness.make("L17 Search.pdf", fixture: fixture)
        defer { harness.tearDown() }
        harness.shell.toolbar.activateMeasurement(.count)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .count })
        let window = try #require(harness.controller.window)
        // Wide enough that the bar keeps its search field (it drops it below its minimum width).
        window.setContentSize(NSSize(width: 1700, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let content = try #require(window.contentView)
        let field = try #require(Self.editableTextFields(in: content).max { $0.frame.width < $1.frame.width })
        #expect(field.frame.width >= 150, "the search field, not the page or zoom field: \(field.frame)")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Wall", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await Self.eventually { harness.shell.search.query == "Wall" })
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        // The window's key rule sees text being edited, so no canvas key claims the Return.
        #expect(layout.currentToolSlotFocus() == ToolSlotKeyRouter.Focus(isCanvasFirstResponder: false, isEditingText: true))
        #expect(!layout.toolSlotRouter.handleKey(characters: "\r", modifiers: [], focus: layout.currentToolSlotFocus()))
        let noteBefore = harness.core.status.snapshot.activeToolNote

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        #expect(!window.performKeyEquivalent(with: returnKey), "no key equivalent in the window takes a bare Return")
        window.sendEvent(returnKey)
        // The field's submit ran: the Navigator shows the Search page and the hits arrive.
        #expect(await Self.eventually { layout.panelState.navigatorSection == .search })
        #expect(await Self.eventually(upTo: 20) { harness.shell.search.hits.count == 2 })
        // The Count tool heard nothing: armed, nothing placed, no "needs 1 more point" note.
        #expect(harness.core.measurement.activeKind == .count)
        #expect(harness.core.measurement.placedPoints.isEmpty)
        #expect(harness.core.status.snapshot.activeToolNote == noteBefore)
        #expect(!(harness.core.status.snapshot.activeToolNote ?? "").contains("more point"))
        #expect(window.firstResponder is NSTextView, "the field keeps the keyboard")
        // No menu row takes a bare Return from a text field either (non-⌘ bindings are withheld).
        func returnRows(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item -> [String] in
                (item.keyEquivalent == "\r" && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).isEmpty ? [item.title] : [])
                    + (item.submenu.map(returnRows) ?? [])
            }
        }
        #expect(returnRows(ZenitMenuBar.make()).isEmpty)
    }
}
