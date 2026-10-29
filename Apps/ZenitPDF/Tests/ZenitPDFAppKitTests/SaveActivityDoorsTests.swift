import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// CR-147: every `NSDocument` entry that waits synchronously for the document activity is
/// a door onto the RT-14 freeze while a save is running. Each one must refuse in words,
/// the menu rows must be disabled for the same span, and closing must wait rather than
/// park the main thread.
///
/// The seams (`beginSaveTaskActivity` / `beginSavePanelActivity`) stand in for a save whose
/// completion has not been delivered; a real one cannot be held open from a test without
/// holding the very activity these tests exist to keep off the main thread.
@MainActor
@Suite(.appTierSerialised)
struct SaveActivityDoorsTests {

    private func makeHarness(
        _ name: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        return (document, controller, try #require(document.core))
    }

    @Test("Save As, Save To, Print and Create Project refuse in words while a save runs")
    func synchronousDoorsRefuseWhileASaveRuns() async throws {
        let (document, _, core) = try await makeHarness("SaveDoors.pdf")
        defer { document.close() }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }

        // The precondition of the live freeze, now as the running-save half rather than the
        // panel half: the write is still in flight, no panel is up.
        document.beginSaveTaskActivity()
        defer { document.endSaveTaskActivity() }

        // Before CR-147 each of these reached AppKit: `saveAs`/`saveTo` ran the (diverted)
        // save panel — `didRequest(appKitSavePanelModalIdentifier)` was true — and live
        // parked the main thread on the activity semaphore.
        for door in ["saveAs", "saveTo", "print", "createProject", "save"] {
            core.status.setActiveToolNote(nil)
            switch door {
            case "saveAs": document.saveAs(nil)
            case "saveTo": document.saveTo(nil)
            case "print": document.printDocument(nil)
            case "createProject": document.createProject()
            default: document.save(nil)
            }
            let note = core.status.snapshot.activeToolNote ?? ""
            #expect(note.contains("save is already in progress"),
                    "CR-147: \(door) must refuse out loud while a save runs — got “\(note)”")
        }
        // Give the asynchronous print job the time it would have needed to reach the panel.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.appKitSavePanelModalIdentifier),
                "no save panel may be raised against a document whose activity is held")
        #expect(!ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.appKitPrintPanelModalIdentifier),
                "no print panel may be raised against a document whose activity is held")
    }

    @Test("A save panel that is already up refuses Save As too — no operation is exempt")
    func aSecondPanelIsRefusedRegardlessOfOperation() async throws {
        let (document, _, core) = try await makeHarness("SaveDoorsPanel.pdf")
        defer { document.close() }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        document.beginSavePanelActivity()
        defer { document.endSavePanelActivity() }

        // The old guard exempted `.saveAsOperation` — exactly what Save As uses — so with a
        // panel already up ⌘⇧S went straight to AppKit's second panel (old output in a test
        // process: `didRequest(appKitSavePanelModalIdentifier)` was true). Driven through
        // Save As rather than AppKit's own entry, which no application-tier test may call.
        core.status.setActiveToolNote(nil)
        document.saveAs(nil)
        #expect((core.status.snapshot.activeToolNote ?? "").contains("save is already in progress"),
                "the refusal is spoken")
        #expect(!ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.appKitSavePanelModalIdentifier),
                "CR-147: `.saveAsOperation` is no longer exempt from the re-entrancy guard")
    }

    @Test("The menu rows for the synchronous doors are disabled while a save runs")
    func menuRowsAreDisabledWhileASaveRuns() async throws {
        let (document, controller, _) = try await makeHarness("SaveDoorsMenu.pdf")
        defer { document.close() }

        func item(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }
        let doors = ZenitPDFProjectDocument.saveActivityActions
        #expect(doors.count == 8)

        document.beginSaveTaskActivity()
        for action in doors {
            #expect(!document.validateUserInterfaceItem(item(action)),
                    "CR-147: \(action) must be disabled while a save runs")
        }
        let createProject = item(#selector(ZenitCommandResponding.performZenitCommand(_:)))
        createProject.representedObject = ZenitAppCommand.createProject.rawValue
        #expect(!controller.validateMenuItem(createProject), "Create Project is disabled while a save runs")
        let saveCommand = item(#selector(ZenitCommandResponding.performZenitCommand(_:)))
        saveCommand.representedObject = ZPDFCommandID.save.rawValue
        #expect(!controller.validateMenuItem(saveCommand), "the File ▸ Save row is disabled while a save runs")
        document.endSaveTaskActivity()

        // With the activity released the same rows answer as before: Create Project is the
        // quick takeoff's save, and AppKit's own answer for Save As on a document is yes.
        #expect(controller.validateMenuItem(createProject))
        #expect(controller.validateMenuItem(saveCommand))
        #expect(document.validateUserInterfaceItem(item(#selector(NSDocument.saveAs(_:)))))
    }

    @Test("Closing waits for the running save instead of parking the main thread")
    func closeWaitsForTheRunningSave() async throws {
        let (document, _, _) = try await makeHarness("SaveDoorsClose.pdf")
        defer { document.close() }

        final class Probe: NSObject {
            var verdicts: [Bool] = []
            @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
                verdicts.append(shouldClose)
            }
        }
        let probe = Probe()
        document.beginSaveTaskActivity()
        document.canClose(
            withDelegate: probe,
            shouldClose: #selector(Probe.document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
        // Before CR-147 an unedited document answered synchronously here — `[true]` — which
        // live meant `canCloseDocumentWithDelegate:` had already parked on the activity.
        #expect(probe.verdicts.isEmpty, "the close question must wait for the save to finish")
        try await Task.sleep(for: .milliseconds(120))
        #expect(probe.verdicts.isEmpty, "…and keep waiting while the save is still running")

        document.endSaveTaskActivity()
        #expect(await AppTestSupport.wait(upTo: 5) { !probe.verdicts.isEmpty },
                "the deferred close question is asked once the save completes")
        #expect(probe.verdicts == [true], "an unedited document then closes as it always did")
    }
}
