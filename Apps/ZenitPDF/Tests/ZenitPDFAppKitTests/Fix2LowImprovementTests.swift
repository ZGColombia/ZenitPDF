import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Improvements 2, the low-priority app items: launch sweep, quit summary, pill placement,
/// zoom jumps, text preview, legend debounce, save wait, Create Project, menus, shortcut
/// reference and the export file split.
@MainActor
@Suite(.appTierSerialised)
struct Fix2LowImprovementTests {

    private func source(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/\(relative)"),
            encoding: .utf8
        )
    }

    // MARK: - IM-237

    @Test("IM-237: the launch sweep runs off the main thread and still removes only stale autosaves")
    func launchSweepIsBackground() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        defer {
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 24 * 3600)], ofItemAtPath: stale.path
        )
        let removed = await ZenitPDFProjectDocument.sweepStaleQuickAutosavesInBackground().value
        #expect(removed.map(\.lastPathComponent) == ["stale"])
        // Old: `sweepStaleQuickAutosaves()` inline in applicationDidFinishLaunching.
        let delegate = try source("App/ZenitApplicationDelegate.swift")
        #expect(delegate.contains("sweepStaleQuickAutosavesInBackground()"))
        #expect(!delegate.contains("ZenitPDFProjectDocument.sweepStaleQuickAutosaves()\n"))
    }

    // MARK: - IM-238

    @Test("IM-238: several edited takeoffs get one question; Discard All closes them without a sheet each")
    func quitWithSeveralTakeoffsAsksOnce() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        var documents: [ZenitPDFProjectDocument] = []
        var directories: [URL] = []
        for index in 0..<2 {
            let url = try AppTestSupport.writeFixturePDF(named: "Quit\(index).pdf")
            directories.append(url.deletingLastPathComponent())
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil && !document.isLoading })
            NSDocumentController.shared.addDocument(document)
            document.updateChangeCount(.changeDone)
            documents.append(document)
        }
        var perDocumentReviews = 0
        for document in documents {
            document.unsavedTakeoffReview = { _, answer in
                perDocumentReviews += 1
                answer(.cancel)
            }
        }
        defer {
            for document in documents {
                document.updateChangeCount(.changeCleared)
                NSDocumentController.shared.removeDocument(document)
                document.close()
            }
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
        let delegate = ZenitApplicationDelegate()
        // Cancel from the summary keeps everything open.
        delegate.quitSummaryPrompt = { _ in .cancel }
        var cancelled: Bool?
        delegate.reviewEditedDocuments { cancelled = $0 }
        #expect(cancelled == false)
        #expect(documents.allSatisfy { $0.isDocumentEdited })

        var asked: Int?
        delegate.quitSummaryPrompt = { count in
            asked = count
            return .discardAll
        }
        var verdict: Bool?
        delegate.reviewEditedDocuments { verdict = $0 }
        // Old: one Save / Don't Save / Cancel sheet per takeoff.
        #expect(asked == 2)
        #expect(await AppTestSupport.wait { verdict != nil })
        #expect(verdict == true)
        #expect(perDocumentReviews == 0)
        #expect(documents.allSatisfy { !$0.isDocumentEdited })
    }

    // MARK: - IM-240

    @Test("IM-240: the live caption pill flips left and below instead of leaving the visible area")
    func livePillStaysVisible() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 60, height: 14)
        let middle = CanvasPageView.anchoredPillBox(size: size, anchor: CGPoint(x: 200, y: 150), visible: visible)
        #expect(middle.minX == 208 && middle.maxY == 150)
        // Old: always right of and above the cursor — off-screen near the right or top edge.
        let corner = CanvasPageView.anchoredPillBox(size: size, anchor: CGPoint(x: 390, y: 5), visible: visible)
        #expect(visible.contains(corner), "\(corner)")
        #expect(corner.maxX <= 390 && corner.minY >= 5)
    }

    // MARK: - IM-242

    @Test("IM-242: a zoom jump interpolates, ends exactly on the target, and never animates under Reduce Motion")
    func zoomJumpsAnimate() {
        let from = PDFRectValue(x: 0, y: 0, width: 600, height: 400)
        let to = PDFRectValue(x: 300, y: 200, width: 60, height: 40)
        let frames = PDFCanvasViewController.zoomAnimationFrames(
            fromZoom: 1, toZoom: 10, fromRect: from, toRect: to, steps: 9
        )
        #expect(frames.count == 9)
        #expect(frames.last?.zoom == 10 && frames.last?.rect == to)
        let zooms = frames.map(\.zoom)
        #expect(zip(zooms, zooms.dropFirst()).allSatisfy { $0 < $1 }, "monotonic: \(zooms)")
        // Old: `restore` jumped straight there.
        #expect(!PDFCanvasViewController.animatesZoomJumps(reduceMotion: true, windowVisible: true))
        #expect(!PDFCanvasViewController.animatesZoomJumps(reduceMotion: false, windowVisible: false),
                "a headless test never animates")
        #expect(PDFCanvasViewController.animatesZoomJumps(reduceMotion: false, windowVisible: true))
    }

    // MARK: - IM-243

    @Test("IM-243: the text editor previews the committed size, and follows a zoom")
    func textEditorPreviewsTheCommittedSize() {
        // Old: the editor used box height × 0.6 × zoom; the sheet drew fontSize × zoom.
        #expect(CanvasPageView.markupTextPointSize(requested: 24, boxHeight: 100) == 24)
        #expect(CanvasPageView.markupTextPointSize(requested: 400, boxHeight: 30) == 30, "clamped to the box")
        #expect(abs(CanvasPageView.markupTextPointSize(requested: nil, boxHeight: 20) - 14.4) < 1e-6)
    }

    // MARK: - IM-247

    @Test("IM-247: a stream of edits reads the markups for the symbol legend once")
    func legendRefreshIsDebounced() async throws {
        let harness = try await Fix2Harness.make("IM247.pdf")
        defer { harness.tearDown() }
        try? await Task.sleep(for: .milliseconds(400))
        let before = harness.document.symbolLegendReadCountForTesting
        for _ in 0..<6 { harness.document.updateChangeCount(.changeDone) }
        try? await Task.sleep(for: .milliseconds(500))
        // Old: six edits, six full copies of every record across the actor.
        #expect(harness.document.symbolLegendReadCountForTesting - before == 1)
        harness.document.updateChangeCount(.changeCleared)
    }

    // MARK: - IM-248

    @Test("IM-248: a close during a save waits for the save's own completion, not a 25 ms poll")
    func closeWaitsOnTheSave() async throws {
        let harness = try await Fix2Harness.make("IM248.pdf")
        defer { harness.tearDown() }
        harness.document.beginSaveTaskActivity()
        var woke = false
        let waiter = Task { @MainActor in
            await harness.document.waitUntilSaveTaskIdle()
            woke = true
        }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!woke)
        harness.document.endSaveTaskActivity()
        await waiter.value
        #expect(woke)
        #expect(harness.document.saveIdleWaitCountForTesting == 1)
        // Old: `while self.isSaveTaskRunning { Task.sleep(25 ms) }`.
        #expect(!(try source("Document/ZenitPDFProjectDocument.swift")).contains("try? await Task.sleep(for: .milliseconds(25))"))
    }

    // MARK: - IM-249

    @Test("IM-249: Create Project starts beside the drawing and has its own shortcut")
    func createProjectStartsBesideTheDrawing() throws {
        let drawing = URL(fileURLWithPath: "/Users/someone/Jobs/Tower/A-101.pdf")
        #expect(ZenitPDFProjectDocument.createProjectStartDirectory(mode: .quickPDF, drawingURL: drawing)?.path
                == "/Users/someone/Jobs/Tower")
        #expect(ZenitPDFProjectDocument.createProjectStartDirectory(mode: .project, drawingURL: drawing) == nil)
        let bar = ZenitMenuBar.make()
        var createItem: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.representedObject as? String == ZenitAppCommand.createProject.rawValue { createItem = item }
                if let nested = item.submenu { walk(nested) }
            }
        }
        walk(bar)
        let item = try #require(createItem)
        // Old: no key equivalent and no word about ⌘S.
        #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command, .option])
        #expect(item.toolTip?.contains("⌘S") == true)
    }

    // MARK: - IM-250

    @Test("IM-250: the drawing exports and job templates are grouped into submenus")
    func menusAreGrouped() throws {
        let bar = ZenitMenuBar.make()
        let menus = bar.items.compactMap(\.submenu)
        let exportDrawing = menus.flatMap(\.items).first { $0.title == "Export Drawing" }
        let templates = menus.flatMap(\.items).first { $0.title == "Job Templates" }
        // Old: nine flat rows between the File and Tools menus.
        // nl-pdf added Optimize or Protect a Copy…, Save Searchable Copy… and Sign a Copy….
        #expect(exportDrawing?.submenu?.items.count == 7)
        #expect(templates?.submenu?.items.count == 4)
    }

    // MARK: - IM-251

    @Test("IM-251: Help ▸ Keyboard Shortcuts is generated from the command table and the menu bar")
    func shortcutReferenceIsGenerated() throws {
        let sections = KeyboardShortcutsReference.sections()
        let all = sections.flatMap(\.entries)
        // Every bound shell command is listed, with the chord the table declares.
        for command in ZPDFCommandTable.standard.boundCommands {
            #expect(all.contains { $0.title == command.title && $0.shortcut == command.binding?.displayString },
                    "\(command.title) missing")
        }
        #expect(all.contains { $0.title == "Show Next Tab" })
        #expect(all.contains { $0.title.hasPrefix("Create Zenit PDF Project") })
        let text = KeyboardShortcutsReference.text(for: sections)
        #expect(text.contains("⌘"))
        let help = try #require(ZenitMenuBar.specialMenu(.help, in: ZenitMenuBar.make()))
        #expect(help.items.contains { $0.title == "Keyboard Shortcuts" })
        // Shown through the modal door: a test never puts the panel on screen.
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.handler = nil }
        KeyboardShortcutsReference.show()
        #expect(ZenitModalPresenter.didRequest(KeyboardShortcutsReference.modalIdentifier))
    }

    // MARK: - IM-253

    @Test("IM-253: export, import and snippet code live in their own file")
    func exportCodeMoved() throws {
        let main = try source("Window/ProjectWindowController.swift")
        let export = try source("Window/ProjectWindowController+Export.swift")
        #expect(!main.contains("func writeProjectedExport("))
        #expect(export.contains("func writeProjectedExport("))
        #expect(export.contains("func exportDrawing("))
        #expect(export.contains("func importLedgerJSON("))
    }
}
