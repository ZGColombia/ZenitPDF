import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Loop iteration 5, area app-shell-glue, the re-fix (it5r): V-018, L-17, V-023 and L-18 as the
/// independent checker left them. Every test states the old output it fails with. Headless
/// throughout: no window is ordered front, every modal is recorded or answered by injection, and
/// every store and fixture is a temporary one.
@MainActor
@Suite("Iteration 5 re-fix — app shell glue", .appTierSerialised, .serialized)
struct Iter5RShellGlueTests {

    // MARK: - Helpers

    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        await Iter2ShellGlueTests.eventually(upTo: seconds, condition)
    }

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it5r-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Three 200 × 200 pt sheets, each a square on layer "Walls" and a diagonal on layer
    /// "Furniture", both switched on in the file.
    static func layeredSheets() throws -> URL {
        let content = """
        1 w 0 0 0 RG
        /OC /W BDC 20 20 m 180 20 l 180 180 l 20 180 l h S EMC
        /OC /F BDC 20 20 m 180 180 l S EMC
        """
        func page(_ contents: Int) -> String {
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents \(contents) 0 R /Resources << /Properties << /W 9 0 R /F 10 0 R >> >> >>"
        }
        return try AutomationFixtures.writePDF(
            named: "Layered Sheets.pdf",
            objects: [
                "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [9 0 R 10 0 R] /D << /Order [9 0 R 10 0 R] /ON [9 0 R 10 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>",
                page(4), "",
                page(6), "",
                page(8), "",
                "<< /Type /OCG /Name (Walls) >>",
                "<< /Type /OCG /Name (Furniture) >>"
            ],
            streams: [4: content, 6: content, 8: content]
        )
    }

    /// Dark pixels on page `number` (1-based) of the PDF at `url`, drawn at twice its size.
    static func darkPixels(onPage number: Int, of url: URL) throws -> Int {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: number))
        let box = page.getBoxRect(.cropBox)
        let side = Int(max(box.width, box.height) * 2)
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        let image = try #require(context.makeImage())
        return Iter4ShellGlueTests.darkPixelCount(image)
    }

    static func exportReport(_ harness: Fix2Harness) -> AppWarning? {
        harness.core.document.warnings.first { $0.id == FlattenedDrawingExport.reportWarningID }
    }

    static func clearExportReport(_ harness: Fix2Harness) {
        harness.core.document.dismissWarning(id: FlattenedDrawingExport.reportWarningID)
    }

    // MARK: - V-018

    @Test("V-018 (it5r): a layer hidden in the Navigator is honoured — or named — by Print, Marked and Clean of an arranged one-drawing set")
    func arrangedSetHonoursNavigatorLayers() async throws {
        let fixture = try Self.layeredSheets()
        let harness = try await Fix2Harness.make("Layered Sheets.pdf", calibrate: false, fixture: fixture)
        defer { harness.tearDown(); ZenitModalPresenter.reset() }
        let layers = harness.document.layerVisibility
        #expect(await Self.eventually { layers.items.count == 2 })
        layers.setVisible(false, layerID: try #require(layers.items.first { $0.name == "Furniture" }).id)
        #expect(!layers.matchesDocumentDefault)
        let drawing = try #require(harness.document.drawing)
        let sheets = drawing.pages.sorted { $0.index < $1.index }
        try await harness.core.commands.perform(.addMarkup(Iter5ShellGlueTests.cloud(on: sheets[0].id, document: drawing.documentID)))
        await harness.settle()
        try await Iter5ShellGlueTests.exclude(harness, [sheets[1]])
        let set = try #require(try await DrawingSetOutput.make(for: harness.document), "the arranged set is composed")
        set.cleanUp()
        let directory = try Self.scratch("v018-nav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hiddenNote = "Layers hidden in the Navigator are still included on page(s) 1, 2."

        // Clean. Old: no report at all — the composed file was drawn by a drawer that knew no
        // hidden layer, refused nothing, and the Furniture diagonal was on both sheets unsaid.
        Self.clearExportReport(harness)
        let clean = directory.appendingPathComponent("Clean.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: clean)
        #expect(CGPDFDocument(clean as CFURL)?.numberOfPages == 2)
        #expect(Self.exportReport(harness)?.message.contains(hiddenNote) == true, "\(Self.exportReport(harness)?.message ?? "no report")")

        // Marked. Old: the ink was appended onto the composed file (it kept the Furniture layer
        // on) and the omission notes were cleared, leaving "…layers are kept."
        Self.clearExportReport(harness)
        let marked = directory.appendingPathComponent("Marked.pdf")
        try await harness.controller.writeDrawing(.flattened, for: harness.document, to: marked)
        let markedReport = try #require(Self.exportReport(harness))
        #expect(markedReport.message.contains(hiddenNote), "\(markedReport.message)")
        #expect(markedReport.message.contains("The pages were rebuilt (layers hidden in the Navigator are applied only when the pages are rebuilt)"), "\(markedReport.message)")

        // Print, through ⌘P with the panel answered by injection. Old: no layer note.
        Self.clearExportReport(harness)
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        harness.document.printDocument(nil)
        #expect(await Self.eventually { !harness.document.printActivityInFlight })
        #expect(ZenitModalPresenter.recorded.contains { $0.identifier == ZenitPDFProjectDocument.appKitPrintPanelModalIdentifier })
        let printReport = try #require(Self.exportReport(harness))
        #expect(printReport.title == "Not everything on the canvas is in the printout.")
        #expect(printReport.message.contains(hiddenNote), "\(printReport.message)")
        ZenitModalPresenter.reset()

        // A sheet numbered — the common case — composes too (PDFKit, the qpdf route refuses a
        // number that is not the file's label), and Clean still names the hidden layer.
        _ = try await harness.core.commands.perform(.setPagesExcluded([sheets[1].id], excluded: false))
        await harness.core.commands.settle()
        await harness.document.nameSheet(sheets[0].id, number: "A-101", title: nil)
        await harness.core.refresh()
        #expect(!DrawingSetOutput.isDrawingAsFiled(await harness.document.setExportPages(), primary: drawing))
        Self.clearExportReport(harness)
        let numbered = directory.appendingPathComponent("Numbered.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: numbered)
        #expect(CGPDFDocument(numbered as CFURL)?.numberOfPages == 3)
        #expect(Self.exportReport(harness)?.message.contains("Layers hidden in the Navigator are still included on page(s) 1, 2, 3.") == true,
                "\(Self.exportReport(harness)?.message ?? "no report")")

        // A turned sheet too: PDFKit composes, the Furniture layer is plain content in the
        // composed file, and the sheet is still drawn from the drawing and named.
        await harness.document.rotatePages([sheets[2].id], by: 90)
        await harness.core.refresh()
        Self.clearExportReport(harness)
        let turned = directory.appendingPathComponent("Turned.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: turned)
        #expect(Self.exportReport(harness)?.message.contains("Layers hidden in the Navigator are still included on page(s) 1, 2, 3.") == true,
                "\(Self.exportReport(harness)?.message ?? "no report")")
    }

    @Test("V-018 (it5r): a turned sheet keeps the drawing's switched-off layer off in Clean and Marked, Marked is rebuilt, and Annotated and Layered say the layers were lost")
    func turnedSheetKeepsDefaultOffLayersOff() async throws {
        let folder = try Self.scratch("v018-turn")
        let fixture = folder.appendingPathComponent("Default Off.pdf")
        // Three sheets whose every line is on layer "Walls", which the file keeps switched off.
        try Iter1RExportPDFAppTests.drawing(at: fixture, pageCount: 3, layered: true, named: false)
        let harness = try await Fix2Harness.make("Default Off.pdf", calibrate: false, fixture: fixture)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing)
        let sheets = drawing.pages.sorted { $0.index < $1.index }
        #expect(try Self.darkPixels(onPage: 1, of: fixture) == 0, "the control: the drawing itself shows nothing")
        try await harness.core.commands.perform(.addMarkup(Iter5ShellGlueTests.cloud(on: sheets[0].id, document: drawing.documentID)))
        await harness.settle()
        await harness.document.rotatePages([sheets[2].id], by: 90)
        await harness.core.refresh()
        let set = try #require(try await DrawingSetOutput.make(for: harness.document))
        // PDFKit composed the turned set, and it says what it could not carry: the file has no
        // layer definitions, its sheets written as the drawing shows them by default (measured:
        // the switched-off layer's content is left out, so nothing is left to switch).
        #expect(set.lostLayerDefinitions)
        #expect(!ZenitPDFProjectDocument.drawingHasLayerDefinitions(set.url, password: nil))
        #expect(try Self.darkPixels(onPage: 1, of: set.url) == 0)
        set.cleanUp()
        let directory = try Self.scratch("v018-turn-out")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Clean: drawn from the drawing itself, the switched-off layer stays off on every sheet,
        // the turned one included.
        let clean = directory.appendingPathComponent("Clean.pdf")
        let report = try await harness.controller.writeDrawing(.clean, for: harness.document, to: clean)
        #expect(report.pagesWithoutUnderlay.isEmpty, "every sheet's drawing was drawn")
        for page in 1...3 {
            #expect(try Self.darkPixels(onPage: page, of: clean) == 0, "page \(page) shows the switched-off layer")
        }

        // Marked. Old: the ink appended onto the composed file, which has no layers, under the
        // note "The drawing's bookmarks, links, page labels and layers are kept."
        Self.clearExportReport(harness)
        let marked = directory.appendingPathComponent("Marked.pdf")
        try await harness.controller.writeDrawing(.flattened, for: harness.document, to: marked)
        let markedReport = try #require(Self.exportReport(harness))
        #expect(markedReport.message.contains("The pages were rebuilt (the drawing's layer definitions could not be carried into the arranged set)"), "\(markedReport.message)")
        #expect(!markedReport.message.contains("layers are kept"))
        #expect(try Self.darkPixels(onPage: 2, of: marked) == 0, "a sheet with no markup shows no Walls line")

        // Annotated and Layered are written on the composed file itself: said, not silent. Old:
        // no word — Annotated posted nothing, Layered only its status note.
        let lostNote = "The drawing's layer definitions could not be carried into the arranged set, so the layers in this file cannot be switched: each sheet shows them as the drawing does by default."
        Self.clearExportReport(harness)
        try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: directory.appendingPathComponent("Annotated.pdf"))
        #expect(Self.exportReport(harness)?.message.contains(lostNote) == true, "\(Self.exportReport(harness)?.message ?? "no report")")
        Self.clearExportReport(harness)
        try await harness.controller.writeLayeredDrawing(for: harness.document, to: directory.appendingPathComponent("Layered.pdf"))
        let layered = try #require(Self.exportReport(harness))
        #expect(layered.message == lostNote)
        #expect(layered.title.contains("without the drawing's own layers"))
        #expect(layered.severity == .warning)
    }

    // MARK: - L-17

    @Test("L-17 (it5r): the canvas appearing again never takes the keyboard from the canvas bar's search field")
    func canvasReappearingLeavesTheFieldItsKeyboard() async throws {
        let text = "BT /F1 24 Tf 100 300 Td (Wall) Tj ET 0.5 w 0 0 0 RG 72 72 m 300 72 l S"
        let fixture = try AutomationFixtures.writePages(named: "L17R Search.pdf", mediaBox: "0 0 842 595", contents: [text, text])
        let harness = try await Fix2Harness.make("L17R Search.pdf", fixture: fixture)
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window)
        let pageView = harness.canvas.pageViewForTesting
        // The harness ran the first appearance: the canvas holds the keyboard, as at launch.
        #expect(window.firstResponder === pageView)
        harness.shell.toolbar.activateMeasurement(.count)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .count })
        window.setContentSize(NSSize(width: 1700, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let content = try #require(window.contentView)
        let field = try #require(Iter5ShellGlueTests.editableTextFields(in: content).max { $0.frame.width < $1.frame.width })
        #expect(field.frame.width >= 150, "the search field: \(field.frame)")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Wall", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await Self.eventually { harness.shell.search.query == "Wall" })

        // The canvas appears again with no click — the window brought back to the front, a tab
        // shown again. Old: `viewDidAppear` made the canvas first responder unconditionally, so
        // the Return below went to the canvas and finished the armed Count tool.
        harness.canvas.viewDidAppear()
        #expect(window.firstResponder === editor, "the field keeps the keyboard, not \(String(describing: window.firstResponder))")

        let layout = try #require(harness.controller.layoutController(for: harness.document))
        func pressReturn() throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            window.sendEvent(event)
        }
        try pressReturn()
        // The field's submit ran: the Navigator opened on its Search page.
        #expect(await Self.eventually { layout.panelState.navigatorSection == .search })
        #expect(await Self.eventually(upTo: 20) { harness.shell.search.hits.count == 2 })
        #expect(window.firstResponder === editor, "focus stays in the field after the submit")
        let first = harness.shell.search.activeHitID
        // A second Return is the field's too: it steps to the next hit.
        try pressReturn()
        #expect(await Self.eventually { harness.shell.search.activeHitID != nil && harness.shell.search.activeHitID != first })
        #expect(window.firstResponder === editor)
        // The Count tool heard neither Return.
        #expect(harness.core.measurement.activeKind == .count)
        #expect(harness.core.measurement.placedPoints.isEmpty)
        #expect(!(harness.core.status.snapshot.activeToolNote ?? "").contains("more point"))

        // With no text being edited, appearing again still puts the keyboard on the canvas —
        // tool keys work after a tab switch as before.
        window.makeFirstResponder(nil)
        harness.canvas.viewDidAppear()
        #expect(window.firstResponder === pageView)
    }

    // MARK: - V-023

    @Test("V-023 (it5r): a project opened with its folder unreachable starts watching by itself when the folder comes back")
    func sharedReviewResumesWhenTheFolderReturns() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "V023R.pdf")
        let root = pdf.deletingLastPathComponent()
        let defaults = ReviewPreferences(defaults: nil)
        SharedReviewCommands.defaults = defaults
        SharedReviewCommands.baseDirectoryOverride = root.appendingPathComponent("bases", isDirectory: true)
        let interval = SharedReviewAutoSync.pollInterval
        let retry = SharedReviewAutoSync.resumeRetryInterval
        let automatic = SharedReviewAutoSync.automaticStart
        SharedReviewAutoSync.pollInterval = 600
        SharedReviewAutoSync.resumeRetryInterval = 600
        SharedReviewAutoSync.automaticStart = false
        ZenitModalPresenter.reset()
        defer {
            SharedReviewAutoSync.pollInterval = interval
            SharedReviewAutoSync.resumeRetryInterval = retry
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
        func goOffline() {
            SharedReviewAutoSync.stop(document: document)
            defaults.set(Data("not a bookmark".utf8), forKey: SharedReviewCommands.bookmarkKey(projectID))
            defaults.removeObject(forKey: SharedReviewCommands.pathKey(projectID))
            core.document.dismissWarning(id: SharedReviewCommands.noteID)
        }
        func comeBack() {
            defaults.removeObject(forKey: SharedReviewCommands.bookmarkKey(projectID))
            defaults.set(folder.path, forKey: SharedReviewCommands.pathKey(projectID))
        }
        SharedReviewAutoSync.automaticStart = true

        // Offline at open: the note, and a wait for the folder.
        goOffline()
        await SharedReviewAutoSync.resume(document: document)
        #expect(SharedReviewAutoSync.watcher(for: document) == nil)
        #expect(core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" })
        // Old: nothing waited — the watch started only after a manual File ▸ Sync Shared Review.
        #expect(SharedReviewAutoSync.pendingResume(for: document) != nil)

        // The drive is mounted again: the watch starts by itself, and the note comes down.
        comeBack()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        #expect(await Self.eventually { SharedReviewAutoSync.watcher(for: document) != nil })
        let watcher = try #require(SharedReviewAutoSync.watcher(for: document))
        #expect(watcher.folder.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(SharedReviewAutoSync.pendingResume(for: document) == nil)
        #expect(await Self.eventually { watcher.syncCount >= 1 }, "what changed meanwhile is synced at once")
        #expect(!core.document.warnings.contains { $0.id == SharedReviewCommands.noteID && $0.title == "Shared review paused" })

        // A share that comes back without a mount event is found by the light timer.
        goOffline()
        SharedReviewAutoSync.resumeRetryInterval = 0.2
        await SharedReviewAutoSync.resume(document: document)
        #expect(SharedReviewAutoSync.pendingResume(for: document) != nil)
        comeBack()
        #expect(await Self.eventually { SharedReviewAutoSync.watcher(for: document) != nil })

        // Closing or disconnecting ends the wait (both run `stop`).
        goOffline()
        await SharedReviewAutoSync.resume(document: document)
        #expect(SharedReviewAutoSync.pendingResume(for: document) != nil)
        SharedReviewAutoSync.stop(document: document)
        #expect(SharedReviewAutoSync.pendingResume(for: document) == nil)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    // MARK: - L-18

    /// What AppKit's `terminate` does when the delegate answers `.terminateLater`, and what the
    /// delegate's reply is: the run loop in the modal-panel mode until a main-actor task replies.
    /// Returns whether the reply arrived while it waited.
    static func appKitTerminateHearsItsReply() -> Bool {
        Iter5ShellGlueTests.TerminateLaterProbe().appKitTerminate()
    }

    @MainActor
    final class QuitState {
        var needsReview = true
        var pendingReview: (@MainActor (Bool) -> Void)?
        var deliveringAnswer = false
        var terminateCalledDuringAnswer: Bool?
        var heardReply: Bool?
        var prepared = 0
    }

    @Test("L-18 (it5r): the quit flow re-enters AppKit's terminate from the run loop after the review's answer, never inside it")
    func quitFlowReentersAfterTheReview() async throws {
        _ = NSApplication.shared
        let state = QuitState()
        // The flow ZenitApplication.terminate runs, with AppKit's own terminate replaced by the
        // terminate-later wait it performs. Its re-entry is the production one.
        let flow = TerminationFlow(
            isReviewing: { state.pendingReview != nil },
            hasSheet: { false },
            prepareWindows: { state.prepared += 1 },
            needsReview: { state.needsReview },
            review: { completion in state.pendingReview = completion },
            cancelled: { Issue.record("the review was not cancelled") },
            terminateNow: {
                state.terminateCalledDuringAnswer = state.deliveringAnswer
                state.heardReply = Self.appKitTerminateHearsItsReply()
            }
        )
        flow.terminate()
        #expect(state.pendingReview != nil && state.heardReply == nil, "the review is up; nothing terminated yet")
        // A second ⌘Q while the review is up joins it (LT-17): no second sweep.
        flow.terminate()
        #expect(state.prepared == 1)

        // Don't Save: `canClose` answers from a main-actor task, as the Quick PDF review does.
        Task { @MainActor in
            guard let answer = state.pendingReview else { return }
            state.pendingReview = nil
            state.needsReview = false
            state.deliveringAnswer = true
            answer(true)
            state.deliveringAnswer = false
        }
        #expect(await Self.eventually(upTo: 10) { state.heardReply != nil })
        // Old (terminate re-entered inline from the answer): called during the answer, inside
        // its main-queue job, where the modal wait never drains the main queue — false, and the
        // application stayed up with its window open after Don't Save.
        #expect(state.terminateCalledDuringAnswer == false)
        #expect(state.heardReply == true)
    }

    @Test("L-18 (it5r): after a sheet is ended the quit flow re-enters from the run loop, where the terminate-later reply is heard")
    func quitFlowReentersAfterASheet() async throws {
        _ = NSApplication.shared
        let state = QuitState()
        let flow = TerminationFlow(
            isReviewing: { false },
            hasSheet: { true },
            prepareWindows: { state.prepared += 1 },
            needsReview: { false },
            review: { _ in Issue.record("nothing to review") },
            cancelled: { Issue.record("nothing was reviewed, so nothing was cancelled") },
            terminateNow: { state.heardReply = Self.appKitTerminateHearsItsReply() }
        )
        // Called from a main-actor job (this test body), as a menu or Apple-event quit can be.
        flow.terminate()
        #expect(state.prepared == 1)
        #expect(state.heardReply == nil, "AppKit is asked again only after the sheet sessions retire")
        #expect(await Self.eventually(upTo: 10) { state.heardReply != nil })
        // Old (`DispatchQueue.main.async`): AppKit's terminate ran as a main-queue job — false.
        #expect(state.heardReply == true)
    }
}
