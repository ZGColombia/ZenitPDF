import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// CR-150 … CR-163: the app tier's lifecycle and routing findings of the 2026-09-01 review.
@MainActor
@Suite(.appTierSerialised)
struct AppTierLifecycleTests {

    private func makeHarness(
        _ name: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment, PDFCanvasViewController) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let canvas = try #require(controller.canvasController(for: document))
        return (document, controller, core, canvas)
    }

    // MARK: CR-150

    @Test("Closing a tab while its drawing is still loading leaves no zombie session")
    func closeDuringLoadTearsDown() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "CloseMidLoad.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(document.isLoading)
        // Before CR-150 `load()` ran to completion on the closed document: raster source,
        // session, FTS index and history DB all created (core != nil) and never torn down.
        document.close()
        #expect(await AppTestSupport.wait { !document.isLoading })
        try await Task.sleep(for: .milliseconds(200))
        #expect(document.isClosed)
        #expect(document.core == nil, "CR-150: the load must not finish on a closed document")
        #expect(document.drawing == nil && !document.hasOpenStorage, "nothing the load built may survive the close")
        #expect(document.loadFailure == nil, "a closed document is not a failed one")
    }

    // MARK: CR-151 / CR-154

    @Test("A drawing that fails to open does not stay as the active tab, and the last tab's close closes the window")
    func failedOpenIsClosedAndAnEmptyWindowGoes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Broken-\(UUID().uuidString).pdf")
        try Data("this is not a drawing".utf8).write(to: url)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        let window = try #require(controller.window)
        var windowClosed = false
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in MainActor.assumeIsolated { windowClosed = true } }
        defer { NotificationCenter.default.removeObserver(token) }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }

        #expect(await AppTestSupport.wait { !document.isLoading })
        #expect(document.loadFailure != nil, "the garbage file must fail to open")
        // The repair offer is answered without a user (Cancel) in a test process. Before
        // CR-151 that left the failed document as `activeDocument` with no content; before
        // CR-154 closing the window's only document left the window alive with no controller.
        #expect(await AppTestSupport.wait { controller.documents.isEmpty })
        #expect(controller.activeDocument == nil, "CR-151: a failed document must not remain active")
        #expect(document.isClosed)
        #expect(windowClosed, "CR-154: the window's only document closed → the window closes with it")
    }

    // MARK: CR-156

    @Test("A refused delete keeps the selection and says so")
    func refusedDeleteKeepsTheSelection() async throws {
        let (document, controller, core, _) = try await makeHarness("RefusedDelete.pdf")
        defer { document.close() }
        // A selection the core cannot remove: an id no markup has. Before CR-156 the
        // refusal was swallowed by `try?` and the selection was cleared anyway.
        #expect(!document.isDocumentEdited, "precondition: a freshly opened drawing is not edited")
        let ghost = UUID()
        core.canvas.select(markupIDs: [ghost], additive: false)
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZPDFCommandID.deleteSelection.rawValue
        controller.performZenitCommand(item)
        try await Task.sleep(for: .milliseconds(400))
        #expect(core.canvas.selectedMarkupIDs == [ghost], "CR-156: a refused delete must not clear the selection")
        #expect(!document.isDocumentEdited, "nothing was removed, so nothing is dirty")
    }

    // MARK: CR-157 / CR-159

    @Test("The window-close review asks over the tab it is about, and the window hosts nothing meanwhile")
    func windowCloseReviewActivatesItsTabAndRefusesGuests() async throws {
        let (first, controller, _, _) = try await makeHarness("ReviewFirst.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "ReviewSecond.pdf")
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.core != nil && second.shell != nil })
        defer { first.close(); second.close() }
        controller.activateTab(id: second.documentIdentity)
        #expect(controller.activeDocument === second)

        // The first tab is edited and its review is scripted to Cancel.
        first.updateChangeCount(.changeDone)
        first.unsavedTakeoffReview = { _, completion in completion(.cancel) }
        let previousProbe = ProjectWindowController.hostWindowVisibilityForTesting
        ProjectWindowController.hostWindowVisibilityForTesting = { _ in true }
        defer { ProjectWindowController.hostWindowVisibilityForTesting = previousProbe }
        #expect(controller.canHostAdditionalDocuments)

        let window = try #require(controller.window)
        #expect(!controller.windowShouldClose(window), "the review runs first; the close is answered later")
        #expect(!controller.canHostAdditionalDocuments,
                "CR-159: a window whose close review is pending must not take new documents")
        try await Task.sleep(for: .milliseconds(300))
        // Before CR-157 the question about the first tab was asked while the second
        // stayed in front.
        #expect(controller.activeDocument === first, "CR-157: the review shows the tab it asks about")
        #expect(controller.canHostAdditionalDocuments, "after Cancel the window hosts again")
        first.updateChangeCount(.changeCleared)
    }

    // MARK: CR-158

    @Test("Select All and Delete reach the canvas through the standard selectors")
    func standardSelectorsRouteToTheShell() async throws {
        let (document, _, core, canvas) = try await makeHarness("Selectors.pdf")
        defer { document.close() }
        var received: [ZPDFCommandID] = []
        canvas.onShellCommand = { received.append($0) }
        // Before CR-158 nothing on the responder chain implemented `selectAll:`/`delete:`,
        // so Edit ▸ Select All and Delete Selection were permanently disabled.
        canvas.selectAll(nil)
        canvas.delete(nil)
        #expect(received == [.selectAll, .deleteSelection])

        let deleteItem = NSMenuItem(title: "", action: #selector(PDFCanvasViewController.delete(_:)), keyEquivalent: "")
        #expect(!canvas.validateMenuItem(deleteItem), "nothing selected → Delete is disabled")
        core.canvas.select(markupIDs: [UUID()], additive: false)
        #expect(canvas.validateMenuItem(deleteItem), "a selection enables Delete")
    }

    // MARK: CR-160

    @Test("Returning to a tab at exactly 100 % keeps 100 %")
    func returningAtOneHundredPercentKeepsTheZoom() async throws {
        let (document, _, core, canvas) = try await makeHarness("KeepZoom.pdf")
        defer { document.close() }
        canvas.viewDidAppear()
        let fit = core.canvas.viewport.zoom
        try #require(fit != 1, "the fixture must not fit at exactly 100 % or the test proves nothing")
        core.canvas.setZoom(1)
        // Before CR-160 the second appearance read `zoom == 1` as "never fitted" and
        // snapped the tab back to fit.
        canvas.viewDidAppear()
        #expect(core.canvas.viewport.zoom == 1, "CR-160: 100 % is a choice, not an unfitted state")
    }

    // MARK: CR-161

    @Test("The untitled launch window has nothing to save, and says so instead of running a panel")
    func untitledWindowRefusesSaveInWords() async throws {
        let document = ZenitPDFProjectDocument()
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil })
        defer { document.close() }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        let item = NSMenuItem(title: "", action: #selector(NSDocument.save(_:)), keyEquivalent: "")
        #expect(!document.validateUserInterfaceItem(item), "CR-161: Save is disabled with no drawing loaded")
        document.save(nil)
        let note = document.core?.status.snapshot.activeToolNote ?? ""
        #expect(note.contains("open a drawing"), "CR-161: the refusal is spoken — got “\(note)”")
        #expect(!ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.appKitSavePanelModalIdentifier))
    }

    // MARK: CR-162

    @Test("Escape out of a table import names the table import, not the snippet")
    func cancelNoteNamesTheFeature() async throws {
        let (document, controller, core, canvas) = try await makeHarness("CancelNote.pdf")
        defer { document.close() }
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZenitAppCommand.importTableFromDrawing.rawValue
        controller.performZenitCommand(item)
        #expect(canvas.isCapturingSnippetRegion, "the command arms region capture")
        // Before CR-162 only the rectangle handler was replaced per feature; the cancel
        // note stayed whatever the last snippet left — or nothing at all.
        #expect(canvas.handle(key: .escape))
        let note = core.status.snapshot.activeToolNote ?? ""
        #expect(note == "Table import cancelled.", "CR-162: got “\(note)”")
    }

    // MARK: CR-163

    @Test("Security-scoped access begun for a dropped file is released when the document closes")
    func scopedAccessIsReleasedOnClose() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "ScopedRelease.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil })
        var released = 0
        document.scopedAccessRelease = { released += 1 }
        // Before CR-163 nothing stopped the access the document controller began.
        document.close()
        #expect(await AppTestSupport.wait(upTo: 5) { released == 1 })
        #expect(released == 1)
    }
}
