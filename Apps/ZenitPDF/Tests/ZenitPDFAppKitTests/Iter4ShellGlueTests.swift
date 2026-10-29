import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Loop iteration 4, area app-shell-glue: U-007 … U-026. Every test states the old output it
/// fails with. Headless throughout: no window is ordered front, every modal is recorded or
/// answered by injection, every store and fixture is a temporary one.
@MainActor
@Suite("Iteration 4 — app shell glue", .appTierSerialised, .serialized)
struct Iter4ShellGlueTests {

    // MARK: - Helpers

    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        await Iter2ShellGlueTests.eventually(upTo: seconds, condition)
    }

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it4-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func metres(_ value: Decimal?) -> Double {
        value.map { NSDecimalNumber(decimal: $0).doubleValue } ?? .nan
    }

    /// Saves the harness's drawing as a project and adds `added` to its set, at the end or at
    /// `position`. Answers the added drawing's member.
    static func addDrawing(_ harness: Fix2Harness, _ added: URL, at position: Int? = nil) async throws -> DrawingSet.Member {
        _ = try await Iter1ShellGlueTests.saveAsProject(harness)
        let end = await harness.core.session.pageOrderIDs.count
        #expect(await harness.document.addDrawingToSet(fileAt: added, at: position ?? end))
        await harness.core.commands.settle()
        await harness.core.refresh()
        return try #require(harness.document.drawingSet?.members.last)
    }

    static func calibrate(_ harness: Fix2Harness, _ page: ZPDFContracts.PageDescriptor) async throws {
        _ = try await harness.core.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        await harness.core.refresh()
    }

    static func exclude(_ harness: Fix2Harness, _ pages: [ZPDFContracts.PageDescriptor]) async throws {
        _ = try await harness.core.commands.perform(.setPagesExcluded(pages.map(\.id), excluded: true))
        await harness.core.commands.settle()
        await harness.core.refresh()
    }

    /// Pages that are each one raster picture of `texts[i]` in large letters, with no text layer.
    static func scannedPages(named name: String, texts: [String]) throws -> URL {
        let directory = try scratch("scan")
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let scale: CGFloat = 3
        for text in texts {
            let width = Int(mediaBox.width * scale), height = Int(mediaBox.height * scale)
            let bitmap = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 100 * scale, y: 300 * scale), withAttributes: [
                .font: NSFont(name: "Helvetica", size: 40 * scale) ?? NSFont.systemFont(ofSize: 40 * scale),
                .foregroundColor: NSColor.black
            ])
            NSGraphicsContext.restoreGraphicsState()
            let image = try #require(bitmap.makeImage())
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: mediaBox)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return url
    }

    /// Pixels darker than mid-grey in `image`.
    static func darkPixelCount(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (0..<(width * height)).reduce(0) { $0 + (bytes[$1] < 128 ? 1 : 0) }
    }

    /// Counts calls, from any isolation.
    actor Recorder {
        private(set) var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    // MARK: - U-007

    @Test("U-007: ⌥-click in a room on an added drawing's sheet traces that sheet's linework, not the primary drawing's same-index sheet")
    func autoTraceReadsTheSheetsOwnDrawing() async throws {
        // The primary: a 300 × 200 pt room on layer Walls, split at x = 222 by layer Furniture.
        let primary = try AutomationFixtures.writeLayeredRoom()
        // The annex: one room 100…500 × 100…400 pt = 400 × 300 pt, no layers.
        let annex = try AutomationFixtures.writeSinglePage(
            named: "Annex Room.pdf", content: "1 w 0 0 0 RG 100 100 m 500 100 l 500 400 l 100 400 l h S"
        )
        let harness = try await Fix2Harness.make("Layered Room.pdf", calibrate: false, fixture: primary)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: annex.deletingLastPathComponent()) }
        let layers = harness.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 }, "the primary's two layers were never read")
        let furniture = try #require(layers.items.first { $0.name == "Furniture" })
        layers.setVisible(false, layerID: furniture.id)
        let added = try await Self.addDrawing(harness, annex)
        let sheet = try #require(added.drawing.pages.first)
        let primarySheet = try #require(harness.document.drawing?.pages.first)
        #expect(sheet.index == primarySheet.index, "both sheets are page 0 of their own PDF")

        // The trace's hidden layers: the primary's on its own sheet, none on the annex's.
        let context = try #require(harness.canvas.automationContext)
        #expect(context.traceHiddenLayerIDs(primarySheet.id.rawValue, primarySheet.index) == ["F"], "the control")
        // Old: ["F"] — the primary's hidden name applied to the annex sheet by index.
        #expect(context.traceHiddenLayerIDs(sheet.id.rawValue, sheet.index).isEmpty)
        // The extraction the trace walks is the annex's own: its room reaches x = 500.
        let extraction = try #require(await context.extraction(sheet.id.rawValue, sheet.index))
        // Old: the primary's extraction, whose linework ends at x = 372.
        #expect(extraction.primitives.contains { $0.bounds.maxX >= 499 }, "\(extraction.primitives.map(\.bounds))")

        try await Self.calibrate(harness, sheet)
        harness.core.document.goToPage(id: sheet.id.rawValue)
        await harness.settle()
        #expect(harness.core.document.currentPageID == sheet.id.rawValue)
        harness.shell.perform(.measureArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 250), additive: false, optionHeld: true)
        await harness.canvas.settleAutoTrace()
        #expect(await Self.eventually { await harness.records().contains { $0.pageID == sheet.id && $0.tool == .area } })
        let traced = await harness.records().first { $0.pageID == sheet.id && $0.tool == .area }
        // Old: 6 m² — the primary's room (300 × 200 pt, Furniture hidden) committed on the annex
        // sheet. The annex's room is 400 × 300 pt at 100 pt/m = 4 m × 3 m = 12 m².
        let area = Self.metres(traced?.measurement?.values[.planArea]?.value)
        #expect(abs(area - 12) < 1e-6, "traced \(area) m²")
        #expect(traced?.measurement?.provenance?.capture.kind == .autoTraced)
    }

    @Test("U-007: ⌥-click on a scanned sheet of an added drawing traces that scan's pixels, not the primary drawing's linework")
    func scanTraceReadsTheSheetsOwnDrawing() async throws {
        let primary = try AutomationFixtures.writeLayeredRoom()
        // The scan: a picture of a 300 × 200 pt room with 1 pt walls at 72, 72 — no vector linework.
        let scan = try R2AutomationAppTests.scannedRoomPDF()
        let harness = try await Fix2Harness.make("Layered Room.pdf", calibrate: false, fixture: primary)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: scan.deletingLastPathComponent()) }
        #expect(await AppTestSupport.wait { harness.document.layerVisibility.items.count == 2 })
        let added = try await Self.addDrawing(harness, scan)
        let sheet = try #require(added.drawing.pages.first)
        try await Self.calibrate(harness, sheet)
        harness.core.document.goToPage(id: sheet.id.rawValue)
        await harness.settle()
        harness.shell.perform(.measureArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 150), additive: false, optionHeld: true)
        await harness.canvas.settleAutoTrace()
        #expect(await Self.eventually(upTo: 30) { await harness.records().contains { $0.pageID == sheet.id && $0.tool == .area } })
        let traced = await harness.records().first { $0.pageID == sheet.id && $0.tool == .area }
        // Old: the primary's same-index sheet — vector linework, so the vector path traced its
        // left half, 150 × 200 pt = 3 m², recorded as auto-traced. The scan's own room is its
        // wall centrelines, 300 × 200 pt = 6.00 m² at 100 pt/m, within 1 % (half a scan pixel).
        #expect(traced?.measurement?.provenance?.capture.kind == .fromScan)
        let area = Self.metres(traced?.measurement?.values[.planArea]?.value)
        #expect(abs(area - 6) / 6 < 0.01, "traced \(area) m²")
    }

    // MARK: - U-008

    @Test("U-008: Page Scales proposes an added drawing's sheet scale from that sheet's own text only")
    func pageScalesReadEachSheetsOwnDrawing() async throws {
        let plain = "0.5 w 0 0 0 RG 72 72 m 300 72 l S"
        let titled = "BT /F1 8 Tf 700 20 Td (SCALE 1:50) Tj ET " + plain
        let a = try AutomationFixtures.writePages(named: "Scales A.pdf", mediaBox: "0 0 842 595", contents: [plain, titled])
        let b = try AutomationFixtures.writePages(named: "Scales B.pdf", mediaBox: "0 0 842 595", contents: [plain, plain])
        let harness = try await Fix2Harness.make("Scales A.pdf", calibrate: false, fixture: a)
        ZenitModalPresenter.reset()
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let added = try await Self.addDrawing(harness, b)
        let primarySheets = try #require(harness.document.drawing).pages
        let addedSheets = added.drawing.pages
        let sheet = try #require(harness.controller.presentPageScalesSheet(for: harness.document))
        defer { sheet.finish() }
        #expect(await Self.eventually(upTo: 30) { sheet.model.rows.allSatisfy { $0.status != .reading } })
        let status = Dictionary(uniqueKeysWithValues: sheet.model.rows.map { ($0.id, $0.status) })
        guard case .proposed(let ratio, _)? = status[primarySheets[1].id.rawValue] else {
            Issue.record("the control: A-2 prints SCALE 1:50 — got \(String(describing: status[primarySheets[1].id.rawValue]))")
            return
        }
        #expect(ratio == "1:50")
        // Old: B-2 .proposed("1:50") — read from A-2's title block at B-2's PDF index — and
        // applicable in bulk with the others.
        #expect(status[addedSheets[1].id.rawValue] == PageScaleStatus.none)
        #expect(sheet.model.proposals[addedSheets[1].id.rawValue] == nil)
        #expect(status[addedSheets[0].id.rawValue] == PageScaleStatus.none)
    }

    // MARK: - U-009

    @Test("U-009: after a failed automatic sync the unpublished edit is published by a later poll, with no new edit")
    func failedSyncIsRetried() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "Retry.pdf")
        let root = pdf.deletingLastPathComponent()
        let defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.defaults = defaults
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        // The watcher's own timer never fires during the test: every tick below is the test's.
        let interval = SharedReviewAutoSync.pollInterval
        SharedReviewAutoSync.pollInterval = 600
        ZenitModalPresenter.reset()
        defer {
            SharedReviewAutoSync.pollInterval = interval
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
        let watcher = SharedReviewAutoSync.start(document: document, folder: folder, participant: "ada-mac", registersPresenter: false)
        let participants = folder.appendingPathComponent("participants", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: participants.path)
        var restored = false
        defer { if !restored { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: participants.path) } }
        let page = try #require(core.snapshot.pages.first)
        let cloud = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: PageID(page.id),
            kind: .cloud, author: "A. Berg",
            geometry: MeasurementGeometry(pageID: PageID(page.id), polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 10, y: 10), PDFPoint(x: 50, y: 10), PDFPoint(x: 50, y: 50)
            ], isClosed: true))]),
            createdAt: Date(), modifiedAt: Date())
        try await core.commands.perform(.addMarkup(cloud))
        await core.refresh()
        let start = Date()
        #expect(await watcher.tick(now: start) == nil, "the folder is read-only: the sync fails")
        #expect(core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" })
        #expect(watcher.consecutiveFailures == 1)
        let syncsAfterFailure = watcher.syncCount
        // Before the retry is due, a poll does not hammer the folder.
        #expect(await watcher.tick(now: start.addingTimeInterval(1)) == nil)
        #expect(watcher.syncCount == syncsAfterFailure)

        // The share is writable again. Nobody edits.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: participants.path)
        restored = true
        let retried = await watcher.tick(now: start.addingTimeInterval(SharedReviewAutoSync.pollInterval + 1))
        // Old: nil — the failed tick had recorded this revision and fingerprint as synced, so no
        // later poll ran until the person edited again, and the cloud stayed unpublished.
        #expect(retried?.published == 1, "\(String(describing: retried))")
        #expect(watcher.consecutiveFailures == 0)
        #expect(!core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" },
                "a resumed sync takes the paused note down")
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    @Test("U-009: a project with no folder connected is not a failed sync and is not backed off; a remembered folder that cannot be reached is")
    func notConnectedIsNotAFailure() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "Unconnected.pdf")
        let root = pdf.deletingLastPathComponent()
        SharedReviewCommands.defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        let interval = SharedReviewAutoSync.pollInterval
        SharedReviewAutoSync.pollInterval = 600
        ZenitModalPresenter.reset()
        defer {
            SharedReviewAutoSync.pollInterval = interval
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
        let projectID = try #require(await document.projectPackage?.manifest.projectId)
        func paused() -> Bool {
            core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" }
        }

        // Not connected: nothing to sync with, which the watcher no longer takes for a failure.
        if case .notConnected = await SharedReviewCommands.runSync(document: document, quiet: true) {} else {
            Issue.record("a project with no folder connected is .notConnected")
        }
        // The watcher's presence heartbeat writes into its folder; the connect below gets a fresh one.
        let watched = root.appendingPathComponent("Watched", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let watcher = SharedReviewAutoSync.start(document: document, folder: watched, participant: "ada-mac", registersPresenter: false)
        let start = Date()
        #expect(await watcher.tick(now: start) == nil)
        #expect(watcher.syncCount == 1)
        // Old: 1 failure and a retry not before start + the poll interval, for a sync that never failed.
        #expect(watcher.consecutiveFailures == 0)
        #expect(watcher.retryNotBefore == .distantPast)
        #expect(!paused())
        document.updateChangeCount(.changeDone)
        _ = await watcher.tick(now: start.addingTimeInterval(1))
        // Old: 1 — the edit's tick was skipped by the backoff the not-connected sync had set.
        #expect(watcher.syncCount == 2, "an edit is looked at on the next tick")
        document.updateChangeCount(.changeCleared)
        SharedReviewAutoSync.stop(document: document)

        // Connected, and then the remembered folder stops resolving (a share that is not mounted):
        // a failure, said as a paused note and retried with backoff.
        #expect(await SharedReviewCommands.connect(document: document, folder: folder) != nil)
        SharedReviewCommands.defaults.set(Data([0, 1, 2, 3]), forKey: SharedReviewCommands.bookmarkKey(projectID))
        SharedReviewCommands.defaults.removeObject(forKey: SharedReviewCommands.pathKey(projectID))
        #expect(SharedReviewCommands.folderURL(projectID) == nil)
        #expect(SharedReviewCommands.isConnected(projectID))
        core.document.dismissWarning(id: SharedReviewCommands.noteID)
        let unreachable = SharedReviewAutoSync.start(document: document, folder: folder, participant: "ada-mac", registersPresenter: false)
        #expect(await unreachable.tick(now: start) == nil)
        #expect(unreachable.consecutiveFailures == 1)
        #expect(unreachable.retryNotBefore == start.addingTimeInterval(SharedReviewAutoSync.pollInterval))
        #expect(paused(), "the unreachable folder is said, not swallowed")
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    @Test("U-009: the retry waits the poll interval, doubling to a cap")
    func retryBackoff() {
        let interval = SharedReviewAutoSync.pollInterval, cap = SharedReviewAutoSync.maximumRetryInterval
        defer { SharedReviewAutoSync.pollInterval = interval; SharedReviewAutoSync.maximumRetryInterval = cap }
        SharedReviewAutoSync.pollInterval = 4
        SharedReviewAutoSync.maximumRetryInterval = 60
        // 4, 8, 16, 32, then 60 (not 64), and 60 from then on.
        #expect((1...7).map(SharedReviewAutoSync.retryDelay(afterFailures:)) == [4, 8, 16, 32, 60, 60, 60])
    }

    // MARK: - U-010

    @Test("U-010: writing beside the originals never replaces an original whose name is another input's output name")
    func batchNeverReplacesAnOriginal() async throws {
        let folder = try Self.scratch("batch-beside")
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = folder.appendingPathComponent("Plan.pdf")
        let original = folder.appendingPathComponent("Plan — Processed.pdf")
        let one = try AppTestSupport.writeFixturePDF(named: "one.pdf", pageCount: 1)
        let two = try AppTestSupport.writeFixturePDF(named: "two.pdf", pageCount: 2)
        defer {
            try? FileManager.default.removeItem(at: one.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: two.deletingLastPathComponent())
        }
        try FileManager.default.copyItem(at: one, to: plan)
        try FileManager.default.copyItem(at: two, to: original)
        let before = try Data(contentsOf: original)

        // No state in the folder: nothing records either file as an earlier output.
        let names = BatchFileProcessor.outputNames(for: [original, plan], folder: folder)
        #expect(names[plan] == "Plan (\(folder.lastPathComponent)) — Processed.pdf")
        #expect(names[original] == "Plan — Processed — Processed.pdf")

        let report = try await BatchFileProcessor.run(
            inputs: [folder], steps: BatchFileProcessor.Steps(), outputFolder: folder, allowBesideInputs: true,
            transform: { input, output, _ in try FileManager.default.copyItem(at: input, to: output) }
        )
        // Old: Plan.pdf's output took the name "Plan — Processed.pdf", deleted that original and
        // copied over it — while the report said every original was unchanged.
        #expect(try Data(contentsOf: original) == before)
        #expect(report.items.count == 2 && report.done == 2)
        #expect(report.items.first { $0.input.lastPathComponent == "Plan.pdf" }?.output?.lastPathComponent
                == "Plan (\(folder.lastPathComponent)) — Processed.pdf")

        // The last line of defence: an output named like an original is refused, not written.
        var state = BatchFileProcessor.State()
        let refused = await BatchFileProcessor.process(
            plan, steps: BatchFileProcessor.Steps(), folder: folder, outputName: "Plan — Processed.pdf",
            state: &state, originals: [plan, original],
            transform: { input, output, _ in try FileManager.default.copyItem(at: input, to: output) }
        )
        guard case .failed = refused.status else {
            Issue.record("an output named like an original was written: \(refused.status)")
            return
        }
        #expect(try Data(contentsOf: original) == before)
    }

    // MARK: - U-011

    @Test("U-011: Symbol Schedule on an added drawing's sheet cross-counts its own tags, draws its own thumbnails and reveals its own rows")
    func symbolScheduleUsesTheSheetsOwnDrawing() async throws {
        let a = try AutomationFixtures.writeSinglePage(named: "Doors A.pdf", mediaBox: "0 0 612 792", content: "1 w 0 0 0 RG 50 700 m 150 700 l S")
        // Three L symbols (one turned 90°), each with the tag D01 printed 30 pt to its right.
        let symbols = """
        1 w 0 0 0 RG
        100 100 m 120 100 l S 100 100 m 100 112 l S
        300 200 m 320 200 l S 300 200 m 300 212 l S
        450 400 m 450 420 l S 450 400 m 438 400 l S
        BT /F1 6 Tf 130 100 Td (D01) Tj ET
        BT /F1 6 Tf 330 200 Td (D01) Tj ET
        BT /F1 6 Tf 470 405 Td (D01) Tj ET
        """
        let b = try AutomationFixtures.writePages(named: "Doors B.pdf", mediaBox: "0 0 612 792", contents: [symbols])
        let harness = try await Fix2Harness.make("Doors A.pdf", calibrate: false, fixture: a)
        let previousPrompt = ProjectWindowController.symbolSearchPrompt
        let previousPresenter = ProjectWindowController.symbolReviewPresenter
        defer {
            ProjectWindowController.symbolSearchPrompt = previousPrompt
            ProjectWindowController.symbolReviewPresenter = previousPresenter
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let added = try await Self.addDrawing(harness, b)
        let sheet = try #require(added.drawing.pages.first)
        let primarySheet = try #require(harness.document.drawing?.pages.first)
        harness.core.document.goToPage(id: sheet.id.rawValue)
        await harness.settle()
        #expect(harness.core.document.currentPageID == sheet.id.rawValue)

        ProjectWindowController.symbolSearchPrompt = { _, _ in SymbolSearchRequest(designation: "D01", scope: .thisPage) }
        var review: SymbolCountReviewModel?
        ProjectWindowController.symbolReviewPresenter = { model, _ in
            review = model
            return {}
        }
        harness.controller.beginSymbolSchedule(for: harness.document)
        harness.canvas.onSnippetRegion?(PDFRectValue(x: 95, y: 95, width: 32, height: 24))
        #expect(await Self.eventually(upTo: 30) { review.map { !$0.isSearching } ?? false }, "the review never finished its search")
        let model = try #require(review)
        let counts = try #require(model.tagCounts[sheet.index])
        // Old: 3 symbols against 0 tags — the tags were read from the primary drawing's page 0,
        // which prints none, so a false mismatch was reported and no tag was matched.
        #expect(counts.symbols == 3 && counts.tags == 3 && counts.orphanTags == 0, "\(counts)")

        // The thumbnail is of this sheet: the symbol's strokes are in it. Old: the primary's
        // page 0 at the same place — blank paper.
        let row = try #require(model.rows.first { $0.status == .confirmed })
        let thumbnail = try #require(await model.thumbnailProvider?(row))
        #expect(Self.darkPixelCount(thumbnail) > 0)

        // Reveal from another sheet lands on the row's sheet. Old: the set's first page of that
        // index — the primary drawing's sheet.
        harness.core.document.goToPage(id: primarySheet.id.rawValue)
        #expect(harness.core.document.currentPageID == primarySheet.id.rawValue)
        model.reveal(row)
        #expect(harness.core.document.currentPageID == sheet.id.rawValue)
    }

    // MARK: - U-012

    @Test("U-012: the primary drawing's hidden layer names hide nothing on an added drawing's sheet")
    func hiddenLayersAreThePrimarysOnly() async throws {
        let primary = try AutomationFixtures.writeLayeredRoom()
        // The annex marks its own walls with a property that happens to be named F, as one CAD
        // exporter names them in every file.
        let annex = try AutomationFixtures.writePDF(
            named: "Annex Layered.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] /ON [5 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Properties << /F 5 0 R >> >> >>",
                "",
                "<< /Type /OCG /Name (Annex Walls) >>"
            ],
            streams: [4: "1 w 0 0 0 RG /OC /F BDC 100 100 m 500 100 l 500 400 l 100 400 l h S EMC"]
        )
        let harness = try await Fix2Harness.make("Layered Room.pdf", calibrate: false, fixture: primary)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: annex.deletingLastPathComponent()) }
        let layers = harness.document.layerVisibility
        #expect(await AppTestSupport.wait { layers.items.count == 2 })
        layers.setVisible(false, layerID: try #require(layers.items.first { $0.name == "Furniture" }).id)
        let added = try await Self.addDrawing(harness, annex)
        let sheet = try #require(added.drawing.pages.first)
        let primarySheet = try #require(harness.document.drawing?.pages.first)

        #expect(harness.document.hiddenLayerNames(for: primarySheet, snap: false) == ["F"], "the control")
        #expect(harness.document.hiddenLayerNames(for: sheet, snap: false).isEmpty)
        #expect(harness.document.hiddenLayerNames(for: sheet, snap: true).isEmpty)
        // A detector on the annex sheet sees what the sheet shows.
        let input = try await harness.controller.symbolSearchInput(for: harness.document, page: sheet)
        #expect(input.extraction.primitives.contains { $0.layerID == "F" }, "the annex's walls carry the name F")
        // Old: every primitive on the annex's F was dropped — the primary's hidden name, applied by
        // page index — so symbol matching, walls, geometry queries and rooms saw an empty sheet.
        #expect(input.primitives.count == input.extraction.primitives.count)
        #expect(!input.primitives.isEmpty)
    }

    // MARK: - U-013

    @Test("U-013: the report's page appendix holds the set's sheets, and the saved thumbnail is the set's first sheet")
    func reportAppendixAndThumbnailFollowTheSet() async throws {
        let a = try AppTestSupport.writeFixturePDF(named: "Report A.pdf", pageCount: 2)
        let b = try AppTestSupport.writeFixturePDF(named: "Report B.pdf", pageCount: 2)
        let harness = try await Fix2Harness.make("Report A.pdf", calibrate: false, fixture: a)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        let primarySheets = try #require(harness.document.drawing).pages
        try await Self.exclude(harness, [primarySheets[1]])
        #expect(await harness.core.session.pageDescriptors.map(\.id) == [primarySheets[0].id] + added.drawing.pages.map(\.id))

        let images = await ProjectWindowController.reportSheetImages(for: harness.document)
        // Old: 2 pages — A-1 and the removed A-2 — with both of the annex's sheets missing and
        // no note saying so.
        #expect(images.pages.count == 3, "\(images.pages.count) appendix pages, skipped \(images.skipped)")
        #expect(images.unavailable == nil)

        // With A-1 set aside too, the set starts with the annex's first sheet.
        try await Self.exclude(harness, [primarySheets[0]])
        let job = try #require(await harness.document.packagePicture()?.job)
        // Old: [A-1] — the primary drawing's lowest page index, a sheet no longer in the set.
        #expect(job.pages.map(\.page.id) == [added.drawing.pages[0].id])
        let pictures = try #require(await harness.document.renderSavedPictures(), "the annex sheet is drawn from its own file")
        #expect(pictures.preview.width > 0)
    }

    @Test("U-013: a set whose every sheet is an added drawing's — the primary's all removed — is what the appendix and the Marked export hold")
    func setOfOneAddedDrawingIsNotThePrimary() async throws {
        // A: two portrait sheets. B: two landscape sheets, so every output page says whose it is.
        let a = try AppTestSupport.writeFixturePDF(named: "Only A.pdf", pageCount: 2)
        let b = try Self.scannedPages(named: "Only B.pdf", texts: ["B-1", "B-2"])
        let harness = try await Fix2Harness.make("Only A.pdf", calibrate: false, fixture: a)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        let primarySheets = try #require(harness.document.drawing).pages
        try await Self.exclude(harness, primarySheets)
        #expect(await harness.core.session.pageDescriptors.map(\.id) == added.drawing.pages.map(\.id))

        // The appendix: B-1 and B-2. Old: no page at all and no note — the set was taken for the
        // primary drawing alone, whose sheets were all filtered out, and the failure swallowed.
        let images = await ProjectWindowController.reportSheetImages(for: harness.document)
        #expect(images.pages.count == 2, "\(images.pages.count) appendix pages, skipped \(images.skipped), note \(String(describing: images.unavailable))")
        #expect(images.unavailable == nil)
        #expect(images.pages.allSatisfy { $0.image.width > $0.image.height }, "every appendix page is one of B's landscape sheets")

        // File ▸ Export Marked PDF: B-1 and B-2, no A sheet. Old: A-1 and A-2 — the two removed
        // sheets of the primary drawing — reported as exported.
        let marked = harness.directory.appendingPathComponent("marked.pdf")
        try await harness.controller.writeDrawing(.flattened, for: harness.document, to: marked)
        let written = try #require(PDFDocument(url: marked))
        #expect(written.pageCount == 2)
        for index in 0..<written.pageCount {
            let box = try #require(written.page(at: index)).bounds(for: .cropBox)
            #expect(box.width > box.height, "page \(index + 1) is \(box.size), a portrait sheet of the primary drawing")
        }
    }

    // MARK: - U-014

    @Test("U-014: Revision Overlay says once that a revision has no sheet, however often it re-pairs")
    func pairingWarningIsSaidOnce() async throws {
        let labelled = try AutomationFixtures.writePDF(
            named: "Labelled.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /P (A-101) >>] >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
                ""
            ],
            streams: [4: "0.5 w 0 0 0 RG 72 72 m 300 72 l S"]
        )
        let harness = try await Fix2Harness.make("Labelled.pdf", calibrate: false, fixture: labelled)
        let revision: RevisionSummary.ID = UUID()
        defer {
            harness.document.revisionPages[revision] = nil
            harness.document.revisionPageLabels[revision] = nil
            harness.tearDown()
        }
        #expect(harness.document.drawing?.pages.first?.label == "A-101", "the fixture's page label")
        harness.document.revisionPages[revision] = RevisionPageReference(document: DocumentHandle(rawValue: 7), pageIndex: 0, label: "Rev B")
        harness.document.revisionPageLabels[revision] = ["B-201"]
        // A count before the coalescing wait, then three composite requests: zoom, page turn,
        // opacity drag.
        _ = harness.document.labelPairedOverlayPages(for: harness.core, postsWarnings: false)
        for _ in 0..<3 { _ = harness.document.labelPairedOverlayPages(for: harness.core) }
        let said = harness.core.document.warnings.filter { $0.title == "Rev B has no sheet A-101" }
        // Old: 4 — a fresh identity per post, the count path included.
        #expect(said.count == 1, "\(said.count) copies")
        #expect(said.first?.id == ZenitPDFProjectDocument.revisionPairingWarningID("\(revision.uuidString)|A-101"))
    }

    // MARK: - U-015

    @Test("U-015: one sheet's recognised words are that page's rows alone, the same words the whole-drawing read gives it")
    func recognisedWordsOfOnePage() async throws {
        let scanned = try Self.scannedPages(named: "Two Scans.pdf", texts: ["SCALE 1:50", "LEVEL 2 PLAN"])
        let harness = try await Fix2Harness.make("Two Scans.pdf", calibrate: false, fixture: scanned)
        defer { harness.tearDown() }
        #expect(await Self.eventually(upTo: 60) { harness.document.searchIndex != nil })
        let index = try #require(harness.document.searchIndex)
        _ = try await index.recognize(pageIndices: [0, 1], languageIDs: [], skipsPagesWithText: false) { _ in }
        let whole = try await index.recognisedWords()
        let first = try await index.recognisedWords(onPage: 0)
        let second = try await index.recognisedWords(onPage: 1)
        #expect(first.map(\.text).joined(separator: " ").contains("SCALE"), "\(first.map(\.text))")
        #expect(second.map(\.text).joined(separator: " ").contains("LEVEL"), "\(second.map(\.text))")
        #expect(first.map(\.text) == (whole[0] ?? []).map(\.text))
        #expect(first.map(\.bounds) == (whole[0] ?? []).map(\.bounds))
        #expect(second.map(\.text) == (whole[1] ?? []).map(\.text))
        #expect(try await index.recognisedWords(onPage: 7).isEmpty)
        let pages = try #require(harness.document.drawing).pages
        #expect(await harness.document.recognisedWords(onPage: pages[1]).map(\.text) == second.map(\.text))
    }

    // MARK: - U-016

    @Test("U-016: opening a synced project fetches what the open reads; the version history comes after")
    func syncedOpenFetchesOnlyWhatItReads() async throws {
        let package = try Self.scratch("synced").appendingPathComponent("Synced.zpdfproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let members = [
            "manifest.json", "project.sqlite", "documents/working.pdf",
            "versions/latest/project.sqlite", "versions/previous/project.sqlite",
            "thumbnails/package.png", "QuickLook/Thumbnail.png"
        ]
        for member in members {
            let url = package.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let root = package.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let evicted: @Sendable (URL) -> Bool = { !$0.path.hasSuffix("manifest.json") }
        let previous = SyncedFolderSafety.download
        defer { SyncedFolderSafety.download = previous }
        let downloads = Recorder()
        SyncedFolderSafety.download = { url in
            await downloads.add(url.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: ""))
            return true
        }
        try await SyncedFolderSafety.materializeForOpen(package, isEvicted: evicted)
        // Old: all six, the two version slots and both pictures among them, before the open.
        #expect(await downloads.names.sorted() == ["documents/working.pdf", "project.sqlite"])
        let failed = await SyncedFolderSafety.prefetchMembersTheOpenSkips(package, isEvicted: evicted)
        #expect(failed.isEmpty)
        #expect(await downloads.names.sorted() == [
            "QuickLook/Thumbnail.png", "documents/working.pdf", "project.sqlite", "thumbnails/package.png",
            "versions/latest/project.sqlite", "versions/previous/project.sqlite"
        ])
    }

    // MARK: - U-017

    @Test("U-017: the ledger report, Export Snippet as PDF and the review report never replace the drawing")
    func reportsNeverReplaceTheDrawing() async throws {
        let harness = try await Fix2Harness.make("U017 Plan.pdf", calibrate: false)
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset(); harness.tearDown() }
        let drawing = try #require(harness.document.drawing?.url)
        let before = try Data(contentsOf: drawing)

        // Old: the snippet PDF was written over Plan.pdf, atomically, with no question asked.
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            try await harness.controller.writeSnippet(
                for: harness.document, of: .region(PDFRectValue(x: 60, y: 60, width: 200, height: 100)), to: drawing
            )
        }
        // Old: the review report replaced it.
        #expect(throws: DerivedCopyGuard.Refusal.self) {
            try ReviewReportExport.export([], document: harness.document, to: drawing)
        }
        // Old: the ledger PDF report replaced it (replaceItemAt).
        await harness.controller.writeProjectedExport(
            format: .pdfReport, for: harness.document, core: harness.core, includeTrail: false, to: drawing
        ).value
        #expect(try Data(contentsOf: drawing) == before)

        // The same guard names every revision's file.
        let revisionFile = harness.directory.appendingPathComponent("Rev B.pdf")
        try before.write(to: revisionFile)
        let revision: RevisionSummary.ID = UUID()
        harness.document.revisionPages[revision] = RevisionPageReference(document: DocumentHandle(rawValue: 9), pageIndex: 0, fileURL: revisionFile, label: "Rev B")
        defer { harness.document.revisionPages[revision] = nil }
        #expect(throws: DerivedCopyGuard.Refusal.self) {
            try DerivedCopyGuard.refuseIfDocumentFile(revisionFile, document: harness.document)
        }
        // An unrelated destination is fine.
        try DerivedCopyGuard.refuseIfDocumentFile(harness.directory.appendingPathComponent("Report.pdf"), document: harness.document)
    }

    @Test("U-017: the Set Compare Report refuses the drawing, leaves its bytes alone and writes no companion CSV")
    func setCompareReportNeverReplacesTheDrawing() async throws {
        let harness = try await Fix2Harness.make("U017 Set.pdf", calibrate: false)
        ZenitModalPresenter.reset()
        let presenter = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { _, _, _ in {} }
        defer {
            ZenitPDFProjectDocument.sheetMatchReviewPresenter = presenter
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let drawing = try #require(harness.document.drawing?.url)
        let before = try Data(contentsOf: drawing)
        // An earlier revision to compare with: the report needs one before it asks for a name.
        let revision = harness.directory.appendingPathComponent("Rev B.pdf")
        try before.write(to: revision)
        var added = false
        harness.document.addRevision(fromDroppedFile: revision) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added })
        #expect(harness.document.newestRevision != nil)

        func run(answering destination: URL) {
            ZenitModalPresenter.handler = { request in
                request.identifier == ZenitPDFProjectDocument.setCompareReportPanelIdentifier ? .urls([destination]) : .dismissed
            }
            harness.document.exportSetCompareReport(window: harness.controller.window)
        }
        func note() -> String? { harness.core.status.snapshot.activeToolNote }

        // The drawing itself, answered in the report's save panel.
        run(answering: drawing)
        let refusal = DerivedCopyGuard.Refusal(drawingName: drawing.lastPathComponent).errorDescription
        #expect(await AppTestSupport.wait(upTo: 60) { note() == refusal }, "\(String(describing: note()))")
        #expect(ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.setCompareReportPanelIdentifier))
        // Old: the report PDF was written over the drawing and its CSV beside it.
        #expect(try Data(contentsOf: drawing) == before, "the set compare report replaced the drawing")
        let companion = drawing.deletingPathExtension().appendingPathExtension("csv")
        #expect(!FileManager.default.fileExists(atPath: companion.path), "a companion CSV was written for a refused report")

        // The control: an ordinary name gets the report — that one file, the one the panel
        // granted (W-020: no sibling CSV the sandbox never granted).
        let report = harness.directory.appendingPathComponent("Report.pdf")
        run(answering: report)
        #expect(await AppTestSupport.wait(upTo: 120) { note()?.hasPrefix("Set compare report written") == true },
                "\(String(describing: note()))")
        #expect(FileManager.default.fileExists(atPath: report.path))
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("Report.csv").path))
        #expect(try Data(contentsOf: drawing) == before)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    // MARK: - U-018

    @Test("U-018: AppleScript `export ledger` refuses the drawing and anything inside the project, and writes elsewhere")
    func scriptedExportNeverReplacesTheDrawing() async throws {
        let harness = try await Fix2Harness.make("U018 Plan.pdf")
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing?.url)
        let before = try Data(contentsOf: drawing)
        do {
            _ = try await ZenitScripting.export(document: harness.document, to: drawing, format: .csv)
            Issue.record("the ledger was written over the drawing")
        } catch let error as ZenitScripting.ScriptError {
            #expect(error.description.contains("is the drawing it is made from"), "\(error.description)")
        }
        // Old: `export ledger document 1 to (file of document 1)` replaced Plan.pdf with a CSV.
        #expect(try Data(contentsOf: drawing) == before)

        let package = try await Iter1ShellGlueTests.saveAsProject(harness, name: "U018.zpdfproj")
        let inside = package.appendingPathComponent("ledger.csv")
        await #expect(throws: ZenitScripting.ScriptError.self) {
            _ = try await ZenitScripting.export(document: harness.document, to: inside, format: .csv)
        }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        // The control: an ordinary destination is written.
        let out = harness.directory.appendingPathComponent("Ledger.csv")
        _ = try await ZenitScripting.export(document: harness.document, to: out, format: .csv)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - U-019

    @Test("U-019: Marked, Annotated and Layered exports of a set that could not be composed refuse, instead of writing the primary drawing alone")
    func uncomposableSetIsRefusedEverywhere() async throws {
        let b = try AppTestSupport.writeFixturePDF(named: "Compose B.pdf")
        let harness = try await Fix2Harness.make("Compose A.pdf", calibrate: false)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        // The added drawing's file is gone: the set cannot be put together.
        try FileManager.default.removeItem(at: added.drawing.url)
        let marked = harness.directory.appendingPathComponent("marked.pdf")
        await #expect(throws: DrawingSetOutput.ComposeFailure.self) {
            try await harness.controller.writeDrawing(.flattened, for: harness.document, to: marked)
        }
        // Old: a one-page file of the primary drawing, reported "was exported".
        #expect(!FileManager.default.fileExists(atPath: marked.path))
        let annotated = harness.directory.appendingPathComponent("annotated.pdf")
        await #expect(throws: DrawingSetOutput.ComposeFailure.self) {
            _ = try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: annotated)
        }
        #expect(!FileManager.default.fileExists(atPath: annotated.path))
        let layered = harness.directory.appendingPathComponent("layered.pdf")
        await #expect(throws: DrawingSetOutput.ComposeFailure.self) {
            _ = try await harness.controller.writeLayeredDrawing(for: harness.document, to: layered)
        }
        #expect(!FileManager.default.fileExists(atPath: layered.path))
        // The report appendix says why it has no page images.
        #expect(await ProjectWindowController.reportSheetImages(for: harness.document).unavailable != nil)
    }

    // MARK: - U-020

    @Test("U-020: a save writes the Finder icon from the one saved render; an autosave writes no picture")
    func oneThumbnailWriter() async throws {
        let harness = try await Fix2Harness.make("U020.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 72, y: 400), PDFPoint(x: 500, y: 400)])
        })
        let package = try await Iter1ShellGlueTests.saveAsProject(harness)
        let previous = ZenitPDFProjectDocument.writesPackageThumbnail
        ZenitPDFProjectDocument.writesPackageThumbnail = true
        defer { ZenitPDFProjectDocument.writesPackageThumbnail = previous }
        let finder = package.appendingPathComponent(ZenitPDFProjectDocument.finderThumbnailPath)
        let quickLook = package.appendingPathComponent(ZenitPDFProjectDocument.packageThumbnailMember)
        harness.document.updateChangeCount(.changeDone)
        try await Iter1ShellGlueTests.save(harness.document, to: package, .saveOperation)
        // Old: a second writer rendered the bare drawing for the Finder icon — and, in a test
        // process, never wrote it at all.
        #expect(await AppTestSupport.wait { FileManager.default.fileExists(atPath: finder.path) && FileManager.default.fileExists(atPath: quickLook.path) })
        #expect(try Data(contentsOf: finder) == Data(contentsOf: quickLook), "one render, one picture, markups included")

        try FileManager.default.removeItem(at: finder)
        try FileManager.default.removeItem(at: quickLook)
        harness.document.updateChangeCount(.changeDone)
        try await Iter1ShellGlueTests.save(harness.document, to: package, .autosaveInPlaceOperation)
        // Old: every autosave rendered the Finder icon again.
        #expect(!(await AppTestSupport.wait(upTo: 2) { FileManager.default.fileExists(atPath: finder.path) }))
        #expect(!FileManager.default.fileExists(atPath: quickLook.path))
    }

    // MARK: - U-021

    @Test("U-021: New from Template on a drawing that is already open leaves its takeoff alone and says where Apply is")
    func newFromTemplateRefusesAnOpenTakeoff() async throws {
        let harness = try await Fix2Harness.make("U021.pdf")
        let previousOpener = NewFromTemplate.drawingOpener
        defer { NewFromTemplate.drawingOpener = previousOpener; harness.tearDown() }
        let template = try #require(StarterJobTemplates.all.first)
        let presetsBefore = harness.core.toolLibrary.presets.map(\.id)
        NewFromTemplate.drawingOpener = { _ in (harness.document, true) }
        let outcome = await NewFromTemplate.start(template, onDrawingAt: try #require(harness.document.drawing?.url))
        // Old: the template's presets and units replaced the open takeoff's, and the note said
        // "The scale is not set: calibrate the drawing before you measure" on a calibrated sheet.
        #expect(outcome == .refusedAlreadyOpen)
        #expect(harness.core.toolLibrary.presets.map(\.id) == presetsBefore)
        let note = try #require(harness.core.document.warnings.first { $0.id == NewFromTemplate.noteID })
        #expect(note.title.contains("is already open"), "\(note.title)")
        #expect(note.message.contains(ZenitAppCommandTable.menuPath(for: .applyJobTemplate)), "\(note.message)")
        #expect(!note.message.contains("scale is not set"))

        // The control: a drawing that was not open starts from the template.
        let url = try AppTestSupport.writeFixturePDF(named: "U021 New.pdf")
        let fresh = try AppTestSupport.makeDocument(opening: url)
        defer { fresh.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        NewFromTemplate.drawingOpener = { _ in (fresh, false) }
        guard case .started(let presets) = await NewFromTemplate.start(template, onDrawingAt: url) else {
            Issue.record("a drawing that was not open did not start from the template")
            return
        }
        #expect(presets > 0)
    }

    // MARK: - U-023

    @Test("U-023: a job template opened with nothing open is imported, and the Job Templates rows work with no window")
    func jobTemplatesNeedNoDocument() async throws {
        let folder = try Self.scratch("templates")
        let previousStore = ProjectWindowController.jobTemplateStore
        ZenitModalPresenter.reset()
        defer {
            ProjectWindowController.jobTemplateStore = previousStore
            ZenitModalPresenter.reset()
            try? FileManager.default.removeItem(at: folder)
        }
        let storeFolder = folder.appendingPathComponent("store", isDirectory: true)
        ProjectWindowController.jobTemplateStore = { JobTemplateStore(directory: storeFolder) }
        var kerbs = try #require(StarterJobTemplates.all.first)
        kerbs.name = "U023 Kerbs"
        let kerbsFile = folder.appendingPathComponent("Kerbs.zpdftemplate")
        try JobTemplateFile.export(kerbs).write(to: kerbsFile)
        var screed = try #require(StarterJobTemplates.all.last)
        screed.name = "U023 Screed"
        let screedFile = folder.appendingPathComponent("Screed.zpdftemplate")
        try JobTemplateFile.export(screed).write(to: screedFile)
        var chosen = kerbsFile
        ZenitModalPresenter.handler = { request in request.kind == .openPanel ? .urls([chosen]) : .button(0) }

        // Opened from Finder with nothing open. Old: refused ("belongs to a drawing or project"),
        // and the route returned at `guard let document` besides.
        #expect(!ZenitDataFileKind.jobTemplate.needsADrawing)
        await ZenitDataFileRoutes.run(.jobTemplate, url: kerbsFile, document: nil)
        #expect(try await JobTemplateStore(directory: storeFolder).read()?.contains { $0.name == "U023 Kerbs" } == true)
        #expect(ZenitModalPresenter.recorded.contains {
            $0.identifier == ProjectWindowController.jobTemplateNoteIdentifier && $0.title == "Job template “U023 Kerbs” imported"
        }, "with no takeoff open, the import says so in an alert of its own")

        // The rows, after the last window closed. Old: disabled (.withDocument, .activeDocument).
        #expect(ZenitAppCommandTable.validateWithoutWindow(.importJobTemplate, item: nil))
        #expect(ZenitAppCommandTable.validateWithoutWindow(.exportJobTemplate, item: nil))
        chosen = screedFile
        ZenitAppCommandTable.perform(.importJobTemplate, controller: nil, document: nil)
        #expect(await Self.eventually {
            (try? await JobTemplateStore(directory: storeFolder).read())?.contains { $0.name == "U023 Screed" } == true
        })
        #expect(ZenitModalPresenter.recorded.contains { $0.identifier == ProjectWindowController.templateFileModalIdentifier && !$0.sheeted })
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    // MARK: - U-024

    @Test("U-024: with no window a disabled toggle shows no checkmark and a state title shows its resting words")
    func noWindowRowsSayTheirState() {
        func row(_ command: ZenitAppCommand, title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
            item.representedObject = command.rawValue
            return item
        }
        let tint = row(.tintByAuthor, title: "Tint Markups by Author")
        tint.state = .on
        #expect(!ZenitAppCommandTable.validateWithoutWindow(.tintByAuthor, item: tint))
        // Old: .on — the early return skipped the only code that clears it.
        #expect(tint.state == .off)
        let lock = row(.toggleLockSelection, title: "Unlock Selection")
        #expect(!ZenitAppCommandTable.validateWithoutWindow(.toggleLockSelection, item: lock))
        #expect(lock.title == "Lock Selection")
        // As AppKit asks it, through the application delegate.
        tint.state = .on
        #expect(!ZenitApplicationDelegate().validateMenuItem(tint))
        #expect(tint.state == .off)
    }

    // MARK: - U-025

    @Test("U-025: Apply Job Template offers the one list New from Template offers")
    func applyOffersTheSharedList() async throws {
        let harness = try await Fix2Harness.make("U025.pdf")
        let folder = try Self.scratch("apply-templates")
        let previousStore = ProjectWindowController.jobTemplateStore
        let previousPicker = ProjectWindowController.templatePicker
        defer {
            ProjectWindowController.jobTemplateStore = previousStore
            ProjectWindowController.templatePicker = previousPicker
            harness.tearDown()
            try? FileManager.default.removeItem(at: folder)
        }
        ProjectWindowController.jobTemplateStore = { JobTemplateStore(directory: folder) }
        var offered: [String]?
        ProjectWindowController.templatePicker = { names, _, _ in offered = names; return nil }
        harness.controller.applyJobTemplate(for: harness.document)
        #expect(await Self.eventually { offered != nil })
        // Nothing saved: the starters alone, never the dead "none saved" refusal.
        #expect(offered == (await NewFromTemplate.templates()).map(\.name))
        #expect(offered == StarterJobTemplates.all.map(\.name))
        #expect(harness.core.status.snapshot.activeToolNote != ProjectWindowController.noJobTemplatesNote)
    }

    // MARK: - U-026

    @Test("U-026: AppleScript `page count` is the set's sheets, as the tab strip counts them")
    func scriptPageCountIsTheSets() async throws {
        let b = try AppTestSupport.writeFixturePDF(named: "Count B.pdf", pageCount: 2)
        let harness = try await Fix2Harness.make("Count A.pdf", calibrate: false)
        defer { harness.tearDown(); try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let added = try await Self.addDrawing(harness, b)
        // Old: 1 — the primary PDF's pages alone.
        #expect(harness.document.scriptPageCount == 3)
        try await Self.exclude(harness, [added.drawing.pages[1]])
        #expect(harness.document.scriptPageCount == 2)
        #expect(harness.document.scriptPageCount == harness.document.makeTabSummary().pageCount)
    }
}
