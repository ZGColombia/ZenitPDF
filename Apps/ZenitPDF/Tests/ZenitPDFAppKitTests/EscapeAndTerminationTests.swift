import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The no-dead-ends regression tests: Escape always exits, and quitting always works.
///
/// The first assembled build trapped the user inside Revision Compare and then refused to
/// quit. These tests drive the shipping objects — the mode registry, the window controller's
/// sheet presentation and the application delegate's termination path — and fail if any panel
/// or mode can exist without an exit, or if termination can stall behind a covered sheet.
@MainActor
@Suite(.appTierSerialised)
struct EscapeAndTerminationTests {

    // MARK: - Fixture

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Roof Plan.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Escape backs out of every registered panel and mode

    @Test("Every panel and mode kind escapes out, one level per press, generically")
    func everyPanelKindEscapesOut() {
        // Exhaustive over the shipping list: a new surface added to WorkflowPanelKind fails
        // here until it proves Escape closes it.
        for kind in WorkflowPanelKind.allCases {
            let registry = ZPDFModeExitRegistry()
            var closed = false
            registry.register(kind.makeRegistration(onClose: { closed = true }))
            #expect(registry.hasActiveMode, "\(kind) must register as an active mode")
            #expect(registry.escapeBacksOutOneLevel(), "\(kind): Escape must back out")
            #expect(closed, "\(kind): the exit route must actually run")
            #expect(!registry.hasActiveMode, "\(kind): nothing may remain after Escape")
        }
    }

    @Test("Escape backs out one level at a time through stacked modes, newest first")
    func escapeBacksOutOneLevelAtATime() {
        let registry = ZPDFModeExitRegistry()
        var order: [String] = []
        for kind in [WorkflowPanelKind.toolLibrary, .search, .revisionCompare] {
            registry.register(kind.makeRegistration(onClose: { order.append(kind.id) }))
        }
        #expect(registry.escapeBacksOutOneLevel())
        #expect(order == [WorkflowPanelKind.revisionCompare.id])
        #expect(registry.escapeBacksOutOneLevel())
        #expect(registry.escapeBacksOutOneLevel())
        #expect(order == [
            WorkflowPanelKind.revisionCompare.id,
            WorkflowPanelKind.search.id,
            WorkflowPanelKind.toolLibrary.id
        ])
        #expect(!registry.escapeBacksOutOneLevel(), "an empty stack must report nothing to leave")
    }

    @Test("The window's Escape pops the newest presented sheet and the canvas is usable again")
    func windowEscapeClosesPresentedSheet() async throws {
        let (document, controller, url) = try openDocumentWithWindowResources()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        _ = await wait { controller.contentViewController is ProjectWindowLayoutController }

        // Present Revision Compare the way the command does, then press Escape at the window.
        controller.performZenitCommand(menuItem(for: .revisionCompare))
        #expect(await wait { controller.modeRegistry.hasActiveMode })

        controller.cancelOperation(nil)
        #expect(await wait { !controller.modeRegistry.hasActiveMode },
                "Escape must leave Revision Compare (the original trap)")
        #expect(await wait { controller.window?.attachedSheet == nil },
                "nothing may remain covering the canvas")
    }

    private func openDocumentWithWindowResources() throws -> (ZenitPDFProjectDocument, ProjectWindowController, URL) {
        let url = try fixtureURL()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        guard let controller = document.windowControllers.first as? ProjectWindowController else {
            throw ZenitDocumentError.documentNotReady
        }
        return (document, controller, url)
    }

    private func menuItem(for id: ZPDFCommandID) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = id.rawValue
        return item
    }

    // MARK: - Quitting always works

    @Test("Termination with every panel and mode open: everything exits, reply is terminate")
    func terminationExitsEveryPanelAndMode() async throws {
        // `NSDocumentController.shared` is one object for the whole
        // process and the review path walks every document registered in it. Hold it
        // for the duration of this test so no other suite's review closes this
        // document out from under the assertion below.
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let (document, controller, url) = try openDocumentWithWindowResources()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        _ = await wait { controller.contentViewController is ProjectWindowLayoutController }

        // Open every registered surface the window can present.
        controller.performZenitCommand(menuItem(for: .toolLibrary))
        controller.performZenitCommand(menuItem(for: .revisionCompare))
        _ = await wait { controller.modeRegistry.hasActiveMode }

        let delegate = ZenitApplicationDelegate()
        var replied: Bool?
        delegate.terminationReply = { replied = $0 }
        // No unsaved changes: termination must go through, from any state. It is
        // immediate unless storage still has to close first — this document's Quick PDF
        // container (IM-181), or a shutdown another suite's ⌘W left queued in this process
        // (BH-336) — and then the deferred reply must be "terminate", never a cancel. The old
        // assertion demanded `.terminateNow` and failed whenever that process-wide state was
        // present, which is the correct product answer.
        document.updateChangeCount(.changeCleared)
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(reply != .terminateCancel, "a clean quit must never be cancelled")
        if reply == .terminateLater {
            #expect(await wait { replied != nil }, "a deferred clean quit must answer")
            #expect(replied == true, "…and the answer must be terminate")
        }
        #expect(!controller.modeRegistry.hasActiveMode,
                "every panel and mode must have exited before termination proceeds")
        #expect(await wait { controller.window?.attachedSheet == nil },
                "no panel may sit above a document sheet")
    }

    @Test("Termination with an unsaved document: the review runs on a visible, uncovered window")
    func terminationWithUnsavedDocumentPresentsReview() async throws {
        // `NSDocumentController.shared` is one object for the whole
        // process and the review path walks every document registered in it. Hold it
        // for the duration of this test so no other suite's review closes this
        // document out from under the assertion below.
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let (document, controller, url) = try openDocumentWithWindowResources()
        defer {
            document.updateChangeCount(.changeCleared)
            NSDocumentController.shared.removeDocument(document)
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        _ = await wait { controller.contentViewController is ProjectWindowLayoutController }

        // The original failure: the Compare surface covered the window while the review sheet
        // waited underneath. Recreate the state, then quit.
        controller.performZenitCommand(menuItem(for: .revisionCompare))
        _ = await wait { controller.modeRegistry.hasActiveMode }
        NSDocumentController.shared.addDocument(document)
        document.updateChangeCount(.changeDone)
        #expect(NSDocumentController.shared.hasEditedDocuments)

        let delegate = ZenitApplicationDelegate()
        var reviewRan = false
        var replied: Bool?
        delegate.terminationReply = { shouldTerminate in replied = shouldTerminate }
        delegate.unsavedReviewRunner = { [weak controller, weak document] in
            reviewRan = true
            // The test finds the state the sheet would land in before answering it: the
            // window must be on screen with nothing covering it — a sheet presented under a
            // panel is the -128 hang.
            #expect(controller?.window?.attachedSheet == nil,
                    "the review must never be presented under another surface")
            #expect(controller?.modeRegistry.hasActiveMode == false,
                    "every mode must have exited before the review is presented")
            #expect(controller?.window?.isMiniaturized == false)
            // Answer the review: save nothing, terminate.
            document?.updateChangeCount(.changeCleared)
            delegate.terminationReply(true)
        }

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        #expect(reply == .terminateLater,
                "an unsaved document defers termination to the review, never cancels it silently")
        #expect(reviewRan, "the unsaved-changes review must actually run")
        #expect(replied == true, "answering the review must terminate the application")
    }

    @Test("Quitting with an edited Quick PDF consults its three-button review, never a silent save")
    func terminationConsultsQuickPDFReview() async throws {
        // `NSDocumentController.shared` is one object for the whole
        // process and the review path walks every document registered in it. Hold it
        // for the duration of this test so no other suite's review closes this
        // document out from under the assertion below.
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let (document, controller, url) = try openDocumentWithWindowResources()
        defer {
            document.updateChangeCount(.changeCleared)
            NSDocumentController.shared.removeDocument(document)
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        _ = await wait { controller.contentViewController is ProjectWindowLayoutController }
        NSDocumentController.shared.addDocument(document)
        document.updateChangeCount(.changeDone)

        // The live 12.1 regression: the quit path went through the autosave-everything
        // review, whose silent save a quick PDF refuses — so ⌘Q hit an error alert and
        // the document's Save / Don't Save / Cancel review never ran. The real runner
        // must consult that review.
        // The AppKit pre-terminate save (`-[NSApplication _shouldTerminate]`) autosaves
        // every dirty document before the delegate is consulted. For a quick PDF that
        // must complete as a harmless no-op — not degrade into the refused silent save —
        // while the document honestly stays edited so the review below still runs.
        var autosaveError: (any Error)?
        var autosaveCompleted = false
        document.autosave(withImplicitCancellability: true) { error in
            autosaveCompleted = true
            autosaveError = error
        }
        _ = await wait { autosaveCompleted }
        #expect(autosaveError == nil, "a quick PDF's NSDocument autosave is a no-op")
        #expect(document.isDocumentEdited, "the edit itself must still drive the review")

        var reviewConsulted = false
        document.unsavedTakeoffReview = { _, answer in
            reviewConsulted = true
            answer(.cancel)
        }
        let delegate = ZenitApplicationDelegate()
        var replied: Bool?
        delegate.terminationReply = { replied = $0 }
        delegate.unsavedReviewRunner()
        _ = await wait { replied != nil }
        #expect(reviewConsulted,
                "quit must run the Quick PDF's Save / Don't Save / Cancel review")
        #expect(replied == false, "Cancel in the review keeps the application running")
    }

    // MARK: - Drop bookkeeping

    @Test("A dropped file's security-scoped bookmark is taken at drop time and found later")
    func droppedFileBookmarkRoundTrip() throws {
        // This suite used to name its own `zenit-test-<uuid>` domain and never remove it:
        // 348 of the 2 547 empty plists measured in a development machine's Preferences folder on
        // 2026-08-25 are this test's. `ScratchDefaults` removes the domain and the file.
        try ScratchDefaults.with(prefix: "zenit-test") { defaults, _ in
            let url = try fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(!DroppedFileBookmarks.hasBookmark(forPath: url.path, defaults: defaults))
            DroppedFileBookmarks.remember(url, defaults: defaults)
            #expect(DroppedFileBookmarks.hasBookmark(forPath: url.path, defaults: defaults),
                    "the bookmark must be stored at drop time, not at open time")
            let resolved = DroppedFileBookmarks.beginAccess(forPath: url.path, defaults: defaults)
            // Bookmarks resolve through /private; compare the canonical paths.
            #expect(resolved?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
            resolved?.stopAccessingSecurityScopedResource()
            DroppedFileBookmarks.removeAll(defaults: defaults)
        }
    }

    @Test("The drop badge states what will happen, including the option-for-revision variant")
    func dropBadgeStatesTheBehavior() {
        #expect(CanvasDropBehavior.open.badgeText(fileCount: 1) == "Open")
        #expect(CanvasDropBehavior.open.badgeText(fileCount: 3) == "Open 3 drawings")
        #expect(CanvasDropBehavior.addAsRevision.badgeText(fileCount: 1) == "Add as revision")
    }
}
