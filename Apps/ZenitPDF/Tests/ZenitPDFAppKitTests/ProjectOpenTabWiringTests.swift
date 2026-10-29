import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
@testable import ZenitPDFAppKit

/// LT-33 / LT-38b, 2026-08-29: opening a `.zpdfproj` — via ⌘O and via
/// Open Recent, both of which run `NSDocumentController.openDocument(withContentsOf:…)` —
/// never created a document tab. The project's content squatted in the current tab's view,
/// the tab strip kept the old drawing's title, and clicking any other chip discarded the
/// project without it ever having been represented in the UI. A password-protected PDF
/// opened the same tabless way.
///
/// These tests drive the exact shipping path: the real `ZenitDocumentController`, the real
/// `makeWindowControllers()`, the real `attach(document:)` — no hand-built documents where
/// the live session had controller-made ones. The window itself is never ordered onto the
/// screen; the tab-host eligibility that live visibility provides is injected
/// through `ProjectWindowController.hostWindowVisibilityForTesting`.
@MainActor
@Suite(.appTierSerialised)
struct ProjectOpenTabWiringTests {

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// Builds a real `.zpdfproj` on disk the way the product builds one: open a drawing,
    /// save it as a project, close it. Returns the package URL.
    private func makeProjectPackage(
        in directory: URL,
        named name: String
    ) async throws -> URL {
        let pdf = try AppTestSupport.writeFixturePDF(named: "Original.pdf")
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: pdf)
        #expect(await wait { document.core != nil && !document.isLoading })
        let destination = directory.appendingPathComponent(name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
        return destination
    }

    /// Opens a URL through the shipping document controller — the ⌘O / Open Recent path.
    ///
    /// `openDocument(withContentsOf:display:)` itself cannot run here: its LaunchServices
    /// preflight asks whether *this process* claims the type, and `swiftpm-testing-helper`
    /// claims nothing, so a `.zpdfproj` is refused before any Zenit code runs (the
    /// assembled bundle passes that check through its Info.plist). What follows the
    /// preflight is documented and driven verbatim: `typeForContents` → `makeDocument` →
    /// `addDocument` → `makeWindowControllers`. `showWindows()` is deliberately not
    /// called — it only fronts the window, and a test may never order one in.
    private func openThroughTheRealController(
        _ controller: NSDocumentController,
        url: URL
    ) async throws -> ZenitPDFProjectDocument {
        let type = try controller.typeForContents(of: url)
        let made: NSDocument
        do {
            made = try controller.makeDocument(withContentsOf: url, ofType: type)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 256 {
            // `makeDocument` consults `NSDocumentController.shared` for the process's own
            // type claims, and whichever earlier suite touched the shared controller first
            // decided its class for the whole process. When that preflight refuses the
            // package type, the documented remainder of `makeDocument` is driven directly:
            // allocate the class `documentClass(forType:)` names, `init(contentsOf:ofType:)`.
            made = try ZenitPDFProjectDocument(contentsOf: url, ofType: type)
        }
        let document = try #require(made as? ZenitPDFProjectDocument)
        controller.addDocument(document)
        document.makeWindowControllers()
        return document
    }

    @Test("A .zpdfproj opened through the document controller becomes a tab of the visible window")
    func projectOpensAsATabOfTheHostWindow() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let previousTabHost = ProjectWindowController.tabHost
        defer {
            ProjectWindowController.tabHost = previousTabHost
            ProjectWindowController.hostWindowVisibilityForTesting = nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-lt33-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let packageURL = try await makeProjectPackage(in: directory, named: "Tower Block.zpdfproj")

        // The window the user already has open, with one drawing in it.
        let firstURL = try AppTestSupport.writeFixturePDF(named: "First.pdf")
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let host = ProjectWindowController(document: first)
        first.addWindowController(host)
        #expect(await wait { first.core != nil && first.shell != nil })
        // Live, the window is on screen; a test may not put it there, so the visibility
        // half of `canHostAdditionalDocuments` is injected.
        ProjectWindowController.hostWindowVisibilityForTesting = { $0 === host }
        #expect(ProjectWindowController.tabHost === host)

        let documentController = ZenitDocumentController()
        let project = try await openThroughTheRealController(documentController, url: packageURL)
        defer {
            host.window?.close()
            project.close()
            first.close()
        }
        #expect(await wait { project.core != nil && !project.isLoading })
        #expect(project.loadFailure == nil)
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        // LT-33's exact complaint, inverted: the project is a tab of the same window.
        #expect(host.documents.count == 2, "the project never joined the window as a tab")
        #expect(host.activeDocument === project, "the opened project is the front tab")
        #expect(project.hostWindowController === host)
        #expect(host.document === project, "window-controller ownership follows the front tab")

        // Every attached shell's tab strip lists both documents with the project active —
        // that is what the chips render from, so this is "a tab exists and is titled with
        // the project name".
        #expect(await wait {
            host.documents.allSatisfy { $0.core?.document.tabs.count == 2 }
        }, "the tab strip never listed the project")
        for document in host.documents {
            let presenter = try #require(document.core?.document)
            #expect(presenter.tabs.map(\.title) == ["First", "Tower Block"])
            #expect(presenter.activeTabID == project.documentIdentity)
            #expect(presenter.tabs.last?.mode == .project)
        }
        let projectShell = try #require(project.shell)
        #expect(projectShell.tabBar.items.count == 2)
        #expect(projectShell.tabBar.items.first { $0.isActive }?.id == project.documentIdentity)

        // LT-33b: no dead-event window. The first chip click after the project opened is
        // driven through the tab bar's own wiring and must switch immediately — and the
        // click back must find the project still attached, not silently closed.
        projectShell.tabBar.select(first.documentIdentity)
        #expect(host.activeDocument === first, "the first tab click after opening was dead")
        let firstShell = try #require(first.shell)
        firstShell.tabBar.select(project.documentIdentity)
        #expect(host.activeDocument === project,
                "clicking back to the project closed or lost it (LT-33's silent discard)")
        #expect(host.documents.count == 2)
    }

    @Test("A stale tab-host registration cannot push a project into a ghost window of its own")
    func projectJoinsTheSurvivingVisibleWindowAfterAnotherWindowClosed() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let previousTabHost = ProjectWindowController.tabHost
        defer {
            ProjectWindowController.tabHost = previousTabHost
            ProjectWindowController.hostWindowVisibilityForTesting = nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-lt33b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packageURL = try await makeProjectPackage(in: directory, named: "Tower Block.zpdfproj")

        // The surviving window the user is looking at…
        let firstURL = try AppTestSupport.writeFixturePDF(named: "Survivor.pdf")
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let host = ProjectWindowController(document: first)
        first.addWindowController(host)
        #expect(await wait { first.core != nil && first.shell != nil })

        // …and a second window that opened later (so the last-created host registration
        // points at it) and has since closed. Live this is any drawing opened into its own
        // window and closed again; the registration must not die with it while a perfectly
        // visible window survives.
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Ephemeral.pdf")
        defer { try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        let ephemeral = ProjectWindowController(document: second)
        second.addWindowController(ephemeral)
        #expect(ProjectWindowController.tabHost === ephemeral)
        ProjectWindowController.hostWindowVisibilityForTesting = { $0 === host }
        second.close()
        ephemeral.window?.close()

        // The exact live open: ⌘O / Open Recent on the .zpdfproj.
        let documentController = ZenitDocumentController()
        let project = try await openThroughTheRealController(documentController, url: packageURL)
        defer {
            host.window?.close()
            project.close()
            first.close()
        }
        #expect(await wait { project.core != nil && !project.isLoading })
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        // LT-33: the project must join the surviving visible window as a tab — never open
        // a window of its own stacked over it, titled like the drawing it was created from.
        #expect(project.hostWindowController === host,
                "the project opened outside the visible window (LT-33's ghost window)")
        #expect(host.documents.count == 2, "the project never became a tab of the visible window")
        #expect(host.activeDocument === project)
        #expect(host.documents.compactMap { $0.core?.document.tabs.count }.allSatisfy { $0 == 2 })
    }

    @Test("A locked drawing, once unlocked, joins the visible window as a tab (LT-38b)")
    func unlockedDrawingOpensAsATab() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let previousTabHost = ProjectWindowController.tabHost
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        defer {
            ProjectWindowController.tabHost = previousTabHost
            ProjectWindowController.hostWindowVisibilityForTesting = nil
            ZenitPDFProjectDocument.passwordPrompt = previousPrompt
        }

        let firstURL = try AppTestSupport.writeFixturePDF(named: "First.pdf")
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let host = ProjectWindowController(document: first)
        first.addWindowController(host)
        #expect(await wait { first.core != nil && first.shell != nil })
        ProjectWindowController.hostWindowVisibilityForTesting = { $0 === host }
        ZenitPDFProjectDocument.passwordPrompt = { _ in "byggare1" }

        let lockedURL = try AppTestSupport.writeLockedFixturePDF(
            named: "Locked Tab.pdf",
            password: "byggare1"
        )
        defer { try? FileManager.default.removeItem(at: lockedURL.deletingLastPathComponent()) }

        let documentController = ZenitDocumentController()
        let locked = try await openThroughTheRealController(documentController, url: lockedURL)
        defer {
            host.window?.close()
            locked.close()
            first.close()
        }
        #expect(await wait { locked.core != nil && !locked.isLoading })
        #expect(locked.loadFailure == nil)

        // LT-38b's exact complaint, inverted: the unlocked drawing is a tab of the same
        // window, chip titled with the drawing's name, and closeable like any tab.
        #expect(locked.hostWindowController === host,
                "the locked drawing opened outside the visible window (LT-38b)")
        #expect(host.documents.count == 2)
        #expect(host.activeDocument === locked)
        #expect(await wait {
            host.documents.allSatisfy { $0.core?.document.tabs.count == 2 }
        })
        #expect(locked.core?.document.tabs.map(\.title) == ["First", "Locked Tab"])
        let stillLocked = await locked.drawing?.rasterSource.isLocked
        #expect(stillLocked == false, "the tabbed drawing must be the unlocked one")
    }
}
