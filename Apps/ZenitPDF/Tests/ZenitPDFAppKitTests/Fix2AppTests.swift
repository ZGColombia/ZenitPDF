import AppKit
import Foundation
import Testing
import ZPDFAppCore
@testable import ZenitPDFAppKit

/// Bug hunt 2, application: quit, Settings and the first-run name prompt.
@MainActor
@Suite(.appTierSerialised)
struct Fix2AppTests {

    private func source(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/\(relative)"),
            encoding: .utf8
        )
    }

    // MARK: - BH-873 first-run prompt

    @Test("BH-873: the first-run prompt pre-fills the name already in force, not the account name")
    func promptPrefillsTheStoredName() throws {
        try ScratchDefaults.with(prefix: "zenit-fix2-author") { scratch, _ in
            let previous = AuthorIdentity.defaults
            AuthorIdentity.defaults = scratch
            defer { AuthorIdentity.defaults = previous }
            AuthorIdentity.set("Site Office B")
            // Old: `AuthorIdentity.machineDefault` — Keep then overwrote the chosen name.
            #expect(AuthorNamePrompt.prefilledName == "Site Office B")
            #expect(AuthorNamePrompt.prefilledName != AuthorIdentity.machineDefault)
        }
    }

    // MARK: - BH-875 / BH-876 Settings name field

    @Test("BH-875: reopening Settings mid-edit keeps the typing; a closed window reloads the stored name")
    func reopenKeepsTheTyping() throws {
        // Old: `authorField.stringValue = AuthorIdentity.current()` unconditionally.
        #expect(ZenitSettingsWindowController.keepsTypedName(windowVisible: true, isEditing: true))
        #expect(!ZenitSettingsWindowController.keepsTypedName(windowVisible: false, isEditing: false))
        #expect(!ZenitSettingsWindowController.keepsTypedName(windowVisible: true, isEditing: false))
        let text = try source("App/ZenitSettingsWindowController.swift")
        #expect(text.contains("if !Self.keepsTypedName("), "showSettings must consult the decision")
    }

    @Test("BH-876: a name typed without Return is committed on quit")
    func quitCommitsTheTypedName() throws {
        try ScratchDefaults.with(prefix: "zenit-fix2-author-quit") { scratch, _ in
            let previous = AuthorIdentity.defaults
            AuthorIdentity.defaults = scratch
            defer { AuthorIdentity.defaults = previous }
            let settings = ZenitSettingsWindowController()
            settings.authorField.stringValue = "Estimator 2"
            // Old: only windowWillClose committed, and ⌘Q sends none — the name was lost.
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(AuthorIdentity.current() == "Estimator 2")
            // Nothing edited: the quit writes nothing.
            settings.commitAuthorNameIfEdited()
            #expect(AuthorIdentity.current() == "Estimator 2")
        }
    }

    // MARK: - BH-336 / BH-874 quit

    @Test("BH-336: a storage shutdown still queued after ⌘W holds the quit until it finishes")
    func pendingShutdownHoldsTheQuit() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        #expect(!NSDocumentController.shared.hasEditedDocuments)
        var finished = false
        let shutdown = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            finished = true
        }
        ZenitPDFProjectDocument.registerStorageShutdown(shutdown)
        let delegate = ZenitApplicationDelegate()
        delegate.terminationAffordanceDelay = .seconds(30)
        var replied: Bool?
        delegate.terminationReply = { replied = $0 }
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        // Old: no open storage, so `.terminateNow` — the process exited before the crash
        // marker came down, and the next open raised the false recovery prompt.
        #expect(reply == .terminateLater)
        #expect(await AppTestSupport.wait { replied != nil })
        #expect(replied == true)
        #expect(finished, "the reply came before the queued shutdown finished")
        #expect(!ZenitPDFProjectDocument.hasPendingStorageShutdowns)
    }

    @Test("BH-874: the quit Apple event is suspended until the quit is decided")
    func quitEventWaitsForTheDecision() throws {
        let text = try source("App/ZenitApplicationDelegate.swift")
        // Old: the handler called terminate and returned, answering the script at once —
        // "quit" succeeded while the review was up, or after Cancel.
        // W-018: every suspended event is kept (a second quit event joins the first).
        #expect(text.contains("if let suspension = NSAppleEventManager.shared().suspendCurrentAppleEvent()"))
        #expect(text.contains("pendingQuitEvents.append(suspension)"))
        #expect(text.contains(".resolvePendingQuitEvent(granted: shouldTerminate)"))
        #expect(text.contains("Int32(userCanceledErr)"))
        // With nothing suspended the resolution is a no-op.
        ZenitApplicationDelegate().resolvePendingQuitEvent(granted: false)
    }
}
