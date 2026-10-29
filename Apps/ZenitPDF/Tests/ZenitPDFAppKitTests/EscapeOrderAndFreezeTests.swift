import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The retest findings of 2026-08-31 around Escape and the Create-Project freeze.
@MainActor
@Suite(.appTierSerialised)
struct EscapeOrderAndFreezeTests {

    private func makeHarness(
        _ name: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment, ProjectShellEnvironment) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        return (document, controller, core, shell)
    }

    @Test("Escape cancels the measurement in progress even while a workflow mode is registered")
    func inProgressWorkWinsEscape() async throws {
        let (document, _, core, shell) = try await makeHarness("EscapeOrder.pdf")
        defer { document.close() }
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        await core.refresh()

        // A leftover registration — the live session had the Scale Regions panel's mode
        // still registered, and the first Escape-fix popped IT instead of the half-drawn
        // line: two Escapes did nothing visible to the measurement (RT-1).
        var ghostExited = 0
        shell.modeRegistry.register(
            id: "test.ghost", displayName: "Ghost",
            exitRoute: ZPDFModeExitRoute(menuTitle: "Close Ghost", performExit: { ghostExited += 1 })
        )
        shell.perform(.measureLength)
        core.measurement.placePoint(PDFPointValue(x: 100, y: 100))
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 1)

        shell.perform(.cancelTool)
        #expect(core.measurement.placedPoints.isEmpty,
                "RT-1: Escape must cancel the half-drawn measurement first")
        #expect(ghostExited == 0, "the registered mode must NOT be popped while work is in progress")

        // With nothing in progress the same key now backs out the mode.
        shell.perform(.cancelTool)
        #expect(ghostExited == 1, "with no work in progress Escape backs out the registered mode")
        shell.modeRegistry.unregister(id: "test.ghost")
    }

    @Test("Escape leaves Revision Overlay even when a ghost registration sits above it")
    func escapeLeavesTheVisibleCanvasMode() async throws {
        let (document, controller, _, shell) = try await makeHarness("EscapeOverlay.pdf")
        defer { document.close() }
        #expect(shell.enterCanvasMode(.revisionOverlay))
        // The live failure shape: a stale registration ABOVE the canvas mode, so the old
        // Escape popped the ghost and the visible overlay stayed (RT-13).
        shell.modeRegistry.register(
            id: "test.stale", displayName: "Stale",
            exitRoute: ZPDFModeExitRoute(menuTitle: "Close Stale", performExit: {})
        )
        controller.cancelOperation(nil)
        #expect(!shell.canvasModes.isInMode,
                "RT-13: Escape must close the canvas mode the person can SEE")
        shell.modeRegistry.unregister(id: "test.stale")
    }

    @Test("Create Project while a save is in flight refuses in words instead of freezing")
    func createProjectRefusesDuringASave() async throws {
        let (document, _, core, _) = try await makeHarness("FreezeGuard.pdf")
        defer { document.close() }
        // The exact precondition of the live freeze: the save activity is still open when
        // Create Project is invoked. Live this deadlocked the main thread on the document
        // serialization semaphore — no menu, no key, kill-only (RT-14, sampled).
        document.beginSavePanelActivity()
        defer { document.endSavePanelActivity() }
        document.createProject()
        let note = core.status.snapshot.activeToolNote ?? ""
        #expect(note.contains("save is already in progress"),
                "RT-14: the refusal must be spoken — got “\(note)”")
    }

    @Test("The text editor frame is floored to a readable size at any zoom")
    func editorFrameIsReadable() {
        let tiny = PDFCanvasViewController.readableEditorFrame(NSRect(x: 400, y: 300, width: 22, height: 3))
        #expect(tiny.width >= 180 && tiny.height >= 26,
                "RT-6: a page-space box a few pixels tall must not be the editing surface")
        #expect(abs(tiny.midX - 411) < 1 && abs(tiny.midY - 301.5) < 1, "the floor grows around the centre")
        let big = NSRect(x: 10, y: 10, width: 400, height: 120)
        #expect(PDFCanvasViewController.readableEditorFrame(big) == big,
                "a box already readable is left exactly alone")
    }
}
