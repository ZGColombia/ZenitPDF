import AppKit
import Foundation
import Testing
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Tabbed multi-document: a second opened PDF becomes a chip in the same
/// window's tab strip, chips switch documents, the close control closes one document
/// without taking the window, and NSDocument semantics — one document per tab, ownership
/// of the shared window controller migrating on close — stay intact.
@MainActor
@Suite(.appTierSerialised)
struct TabbedWindowTests {

    @Test("A second document attaches to the same window as a tab and becomes active")
    func secondDocumentBecomesATab() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "First.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Second.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        // NSDocument semantics: the first document owns the shared controller.
        first.addWindowController(controller)
        #expect(controller.document === first)

        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })

        // One window, two documents; the newly opened one is the front tab. Ownership of
        // the shared controller follows the active tab (the ⌘S defect found live, 2026-08-24):
        // AppKit's current-document machinery reads `windowController.document`, so the
        // front tab must be the owner, and the previous owner is detached — one window,
        // never two.
        #expect(controller.documents.count == 2)
        #expect(controller.activeDocument === second)
        #expect(second.hostWindowController === controller)
        #expect(controller.document === second)
        #expect(second.windowControllers.count == 1, "the front tab owns the one shared controller")
        #expect(first.windowControllers.isEmpty, "the previous owner is detached, not doubled")
        #expect(controller.window?.title == "Second")

        // Every attached document's presenter shows the whole strip, in tab order, with
        // the front tab active — that is what the chips render from.
        controller.syncTabs()
        for document in controller.documents {
            let core = try #require(document.core)
            #expect(core.document.tabs.count == 2)
            #expect(core.document.tabs.map(\.title) == ["First", "Second"])
            #expect(core.document.activeTabID == second.documentIdentity)
        }

        // Clicking the first chip switches the window's content to that document's shell,
        // and controller ownership switches with it.
        controller.activateTab(id: first.documentIdentity)
        #expect(controller.activeDocument === first)
        #expect(controller.document === first)
        #expect(second.windowControllers.isEmpty)
        #expect(controller.window?.title == "First")
        #expect(first.core?.document.activeTabID == first.documentIdentity)

        // The tab bar model of the front shell resolves the same active chip.
        let shell = try #require(first.shell)
        #expect(shell.tabBar.items.count == 2)
        #expect(shell.tabBar.items.first { $0.isActive }?.id == first.documentIdentity)

        controller.window?.close()
        first.close()
        second.close()
    }

    @Test("The window hands ⌘Z the active tab's undo manager, not the owner's")
    func windowReturnsTheActiveTabsUndoManager() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "First.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Second.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)

        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })
        #expect(controller.activeDocument === second)

        // `undo:` resolves through NSWindow → delegate. The active tab is the second
        // document, whose undo manager is NOT the window controller's document's — without
        // the delegate override, ⌘Z on any attached tab was dead (found live, 2026-08-24).
        let window = try #require(controller.window)
        #expect(controller.windowWillReturnUndoManager(window) === second.undoManager)
        #expect(second.undoManager !== first.undoManager)

        controller.activateTab(id: first.documentIdentity)
        #expect(controller.windowWillReturnUndoManager(window) === first.undoManager)

        controller.window?.close()
        first.close()
        second.close()
    }

    @Test("Document actions target the active tab's document, not the owner's")
    func documentActionsTargetTheActiveTab() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "First.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Second.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)

        let second = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: second)
        #expect(await AppTestSupport.wait { second.shell != nil })
        #expect(controller.activeDocument === second)

        // `save:` (and every other document action) resolves through the responder
        // chain's supplemental target. Without the override that is
        // `windowController.document` — the first tab — so ⌘S on the front tab ran the
        // owner's save panel (found live, 2026-08-24).
        let saveAction = #selector(NSDocument.save(_:))
        #expect(
            controller.supplementalTarget(forAction: saveAction, sender: nil) as AnyObject? === second
        )

        controller.activateTab(id: first.documentIdentity)
        #expect(
            controller.supplementalTarget(forAction: saveAction, sender: nil) as AnyObject? === first
        )

        // A selector no document answers still defers to AppKit's own supplement.
        let bogus = #selector(NSColorPanel.orderFront(_:))
        #expect(
            controller.supplementalTarget(forAction: bogus, sender: nil) as AnyObject? !== second
        )

        controller.window?.close()
        first.close()
        second.close()
    }

    @Test("Closing a tab closes its document, keeps the window, and migrates ownership")
    func closingATabKeepsTheWindow() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "Owner.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Survivor.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let owner = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: owner)
        owner.addWindowController(controller)
        let survivor = try AppTestSupport.makeDocument(opening: secondURL)
        controller.attach(document: survivor)
        #expect(await AppTestSupport.wait { owner.shell != nil && survivor.shell != nil })

        // Closing the owner's tab must not tear the shared window down: the controller's
        // ownership migrates to the surviving document first.
        controller.requestCloseTab(id: owner.documentIdentity)
        #expect(await AppTestSupport.wait { controller.documents.count == 1 })
        #expect(controller.documents.first === survivor)
        #expect(controller.document === survivor, "window-controller ownership migrated")
        #expect(controller.activeDocument === survivor)
        #expect(controller.window != nil)
        #expect(survivor.core?.document.tabs.count == 1)

        controller.window?.close()
        survivor.close()
    }

    @Test("Headless windows never volunteer as tab hosts, so one-window-per-document holds in tests")
    func headlessWindowsDoNotHost() async throws {
        let url = try AppTestSupport.writeFixturePDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        // The window was never ordered in: it must refuse additional documents, which is
        // exactly why `makeWindowControllers` in a headless test still gets its own window.
        #expect(!controller.canHostAdditionalDocuments)
        controller.window?.close()
        document.close()
    }
}
