import AppKit
import ZPDFUIPresentation
import ZPDFUIShell

/// The application object's delegate.
///
/// It owns three things and nothing else: the menu bar, the document controller, and the URL
/// scheme. Everything a window does belongs to `ProjectWindowController`; everything a document
/// does belongs to `ZenitPDFProjectDocument`.
@MainActor
public final class ZenitApplicationDelegate: NSObject, NSApplicationDelegate {

    /// Instantiated before anything touches `NSDocumentController.shared`, which is what makes the
    /// subclass — and therefore the `.zpdfproj` / `.pdf` routing — the shared controller.
    private let documentController = ZenitDocumentController()

    public override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // NL-UX-11: the person's own shortcuts, before the menu bar is built from the table.
        ZenitShortcutSettings.installStoredOverrides()
        ZenitMenuBar.install(ZenitMenuBar.make())
        // Settings ▸ Appearance, before the first window exists: dark unless the person chose
        // Light or Match System.
        ZenitAppearancePreference.applyStored(to: NSApplication.shared)
        _ = documentController
    }

    /// Markers `Scripts/verify-app-launches.sh` reads out of the unified log.
    ///
    /// Three, and each one means something different:
    ///
    /// - `begin` — the delegate was entered, so dyld got us to `main()`. On 2026-08-24 an
    ///   assembled bundle passed every static gate and never reached this line: it died in dyld
    ///   because Library Validation refused the embedded framework, and a human found out from a
    ///   crash dialog.
    /// - `ready` — the delegate *returned*. `begin` without `ready` means launch blocked, which
    ///   is what a modal presented during launch looks like from outside.
    /// - `run-loop-serviced` — a block scheduled during launch actually ran. Only a main run loop
    ///   that is servicing events can emit it, which is the difference between a process that
    ///   exists and an application that works.
    public enum LaunchMarker {
        public static let prefix = "ZENIT-LAUNCH"
        public static let begin = "begin"
        public static let ready = "ready"
        public static let runLoopServiced = "run-loop-serviced"
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("%@ %@ pid=%d", LaunchMarker.prefix, LaunchMarker.begin,
              ProcessInfo.processInfo.processIdentifier)
        // Scheduled here, emitted only if the main run loop drains. It survives a nested modal
        // loop, and it does not survive a main-thread deadlock — which is the point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSLog("%@ %@", LaunchMarker.prefix, LaunchMarker.runLoopServiced)
        }
        NSApplication.shared.activate(ignoringOtherApps: false)
        // L-33: AppKit's Open Recent rows to single spaces. AppKit inserts that submenu during
        // launch; the tidier finds it now, or when the menu bar is first opened.
        if let bar = NSApplication.shared.mainMenu { OpenRecentTitleTidier.shared.watch(bar) }
        // NL-UX-18: Finder ▸ Services ▸ Open as Quick Takeoff in Zenit PDF.
        NSApplication.shared.servicesProvider = ZenitServicesProvider.shared
        // Container autosaves nobody came back for in a month go now (CR-153); the ones a
        // drawing is reopened against are offered for restore at that open.
        // Once the first window has had its turn, and off the main thread (IM-237).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ZenitPDFProjectDocument.sweepStaleQuickAutosavesInBackground()
            // Added drawings' index files under the retired per-open key (W-019).
            ZenitPDFProjectDocument.sweepRetiredSetSearchIndexesInBackground()
        }
        // The first-run author question is no longer asked here: it
        // blocked launch before any drawing opened. The first project window asks it as a
        // sheet once its content is installed (IM-160).
        // Own the quit Apple event. AppKit's built-in handler refuses the event with
        // error -128 ("user cancelled") while any sheet session is open, without ever
        // consulting `terminate(_:)` — which is exactly how a scripted quit used to
        // fail. Routing the event into `terminate(_:)` lets
        // `ZenitApplication` tear the sheets down and quit properly.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
        NSLog("%@ %@", LaunchMarker.prefix, LaunchMarker.ready)
        // NL-DOCS-14: the drawings the last window held, in order, unless a file was opened
        // with the launch (Finder, a drop on the Dock icon) — then that is what was asked for —
        // and only when macOS is set to keep windows on quit ("Close windows when quitting an
        // application" off), as every other application honours it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSDocumentController.shared.documents.isEmpty else { return }
            ProjectWindowController.restoreLastSessionIfAllowed()
        }
    }

    @objc private func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReply reply: NSAppleEventDescriptor
    ) {
        // Suspended until the quit is decided: answering at once told a script the app had
        // quit while the review was still up, or after the person pressed Cancel (BH-874).
        // A cancelled quit resumes it with userCanceledErr (-128), as AppKit's own handler does.
        // A second quit event while the first is being decided joins it and hears the same
        // verdict; it used to overwrite the first suspension, which then never resumed (W-018).
        if let suspension = NSAppleEventManager.shared().suspendCurrentAppleEvent() {
            pendingQuitEvents.append(suspension)
        }
        NSApplication.shared.terminate(nil)
    }

    /// The suspended quit Apple events, while their quit is being decided (BH-874, W-018).
    var pendingQuitEvents: [NSAppleEventManager.SuspensionID] = []

    /// Resumes one suspended quit event with the verdict: nothing on success (the process is
    /// exiting), userCanceledErr (-128) when the quit was cancelled. Replaceable so a test sees
    /// the verdict without a real Apple event.
    var resumeQuitEvent: @MainActor (NSAppleEventManager.SuspensionID, Bool) -> Void = { suspension, granted in
        let manager = NSAppleEventManager.shared()
        if !granted, let reply = manager.replyAppleEvent(forSuspensionID: suspension) as NSAppleEventDescriptor? {
            reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
        }
        manager.resume(withSuspensionID: suspension)
    }

    /// Answers every suspended quit event with the quit's verdict.
    func resolvePendingQuitEvent(granted: Bool) {
        let suspensions = pendingQuitEvents
        pendingQuitEvents = []
        for suspension in suspensions { resumeQuitEvent(suspension, granted) }
    }

    /// The quit review was cancelled before AppKit was asked (W-018): the quit is over, so every
    /// window ``prepareWindowsForTermination(_:)`` froze records its session again, and a
    /// scripted quit hears -128 instead of timing out. ``TerminationFlow`` calls this; the
    /// review AppKit's own `applicationShouldTerminate` runs answers through
    /// ``terminationReply`` instead.
    func quitCancelledByReview(_ application: NSApplication) {
        windowsAfterCancelledTermination(application)
        resolvePendingQuitEvent(granted: false)
    }

    /// Zenit is a document application: closing the last window leaves the app running so the Open
    /// panel and Open Recent are still reachable, which is what every macOS document app does.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening with no document shows an empty project window rather than an Open panel.
    ///
    /// A first-run user who is shown a file chooser before ever seeing the application has to
    /// decide what to open before they know what the tool does.
    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Termination

    /// Quitting always works.
    ///
    /// The first assembled build could not be quit with the Compare panel open: the
    /// unsaved-changes review was presented under a surface that covered the window, the app
    /// waited forever on a question nobody could see, and scripted termination came back as
    /// AppleEvent error -128. The fix is ordering, made explicit here:
    ///
    /// 1. Every window first leaves every panel and mode through its registered exit route
    ///    and ends any attached sheet — nothing may sit above a document sheet.
    /// 2. A window owning unsaved changes is deminiaturised and brought forward, so the
    ///    review sheet lands on a **visible, key** window.
    /// 3. Only then does the unsaved-changes review run. Its answer is the only thing that
    ///    may cancel termination, because it is the only Cancel the user can actually see.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareWindowsForTermination(sender)
        // `isDocumentEdited`, not `hasEditedDocuments`: the controller's flag follows
        // *unautosaved* changes, and the terminate sequence has already run every dirty
        // document's autosave by the time this is consulted — for a Quick PDF that
        // autosave is a deliberate no-op reporting success, which flips the controller's
        // flag to false and would quit past the review, discarding the takeoff in
        // silence (found live).
        let documents = NSDocumentController.shared.documents
        NSLog("ZENIT-QUIT applicationShouldTerminate: documents=%d edited=%d unautosaved=%d",
              documents.count,
              documents.filter(\.isDocumentEdited).count,
              documents.filter(\.hasUnautosavedChanges).count)
        let hasEdited = documents.contains(where: \.isDocumentEdited)
        guard hasEdited else {
            // Nothing to review — but open packages still have to *close* before the
            // process exits: `ProjectPackage.close()` is what disarms the crash marker,
            // and quitting past it left every cleanly-quit project claiming "was not
            // closed properly" on its next open (the false recovery
            // prompt).
            let zenit = documents.compactMap { $0 as? ZenitPDFProjectDocument }
            // A ⌘W a moment before ⌘Q leaves its storage shutdown still queued with no
            // document left to report it; exiting then skipped the crash-marker removal and
            // the next open showed the false recovery prompt (BH-336).
            guard zenit.contains(where: \.hasOpenStorage)
                    || ZenitPDFProjectDocument.hasPendingStorageShutdowns else { return .terminateNow }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.awaitTerminationStorageShutdown()
                self.terminationReply(true)
            }
            return .terminateLater
        }
        unsavedReviewRunner()
        return .terminateLater
    }

    /// Closes every Zenit document's storage and drains the in-flight shutdowns, so the
    /// reply to a granted termination never races the crash-marker removal.
    public func shutDownAllDocumentStorage() async {
        for document in NSDocumentController.shared.documents {
            if let zenit = document as? ZenitPDFProjectDocument, zenit.hasOpenStorage {
                await zenit.shutDownStorage()
            }
        }
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }

    // MARK: - The quit wait

    /// How long a quit may wait silently before the progress affordance appears.
    /// One second, per the quit rules; the tests shorten it.
    public var terminationAffordanceDelay: Duration = .seconds(1)

    /// The bound on the quit wait. Storage shutdown is local-disk work measured in
    /// milliseconds even with a save pipeline ahead of it; a wait that reaches this
    /// bound is a defect, and the answer to a defect is to stop holding the user's
    /// quit hostage — never to hang.
    public var terminationShutdownBound: Duration = .seconds(30)

    /// Awaits every document's storage shutdown before termination is granted.
    ///
    /// Because ``ProjectPackage/close()`` queues behind any in-flight save pipeline,
    /// this is also the wait for the recovery journal's `session-closed` transition —
    /// a ⌘S answered by an immediate ⌘Q exits with the journal settled and the crash
    /// marker down, never with the false "was not closed properly" prompt armed.
    /// The wait is bounded, and past one second it is visible:
    /// a small panel with an indeterminate spinner names what the app is finishing.
    ///
    /// Returns whether the shutdown completed within the bound.
    @discardableResult
    public func awaitTerminationStorageShutdown() async -> Bool {
        let work = Task { @MainActor in await self.shutDownAllDocumentStorage() }
        let affordance = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.terminationAffordanceDelay)
            guard !Task.isCancelled else { return }
            self.showTerminationProgressPanel()
        }
        let bound = terminationShutdownBound
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work.value; return true }
            group.addTask {
                try? await Task.sleep(for: bound)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        affordance.cancel()
        hideTerminationProgressPanel()
        if !finished {
            NSLog("ZENIT-QUIT storage shutdown exceeded %.0f s; terminating anyway",
                  Double(bound.components.seconds))
        }
        return finished
    }

    /// The quit progress affordance, on screen only when a quit has waited past
    /// ``terminationAffordanceDelay``.
    private var terminationProgressPanel: NSPanel?

    /// Whether the affordance is showing — observable by the termination tests.
    public private(set) var terminationProgressVisible = false

    /// The stable name of the application delegate's on-screen affordance. (An unknown
    /// `zenitpdf:` link used to have a modal too; it is a status note now, ``ZenitURLNotes``.)
    public static let quitProgressModalIdentifier = "app.quitProgress"

    private func showTerminationProgressPanel() {
        guard terminationProgressPanel == nil else { return }
        terminationProgressVisible = true
        // No modal in a process with no user. The affordance stays observable — `terminationProgressVisible` is
        // what the termination tests read — and only the drawing is withheld from a process
        // with no user; `ZenitModalPresenter.presentPanel` is where that decision lives.
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: NSLocalizedString(
            "Finishing saving your projects…",
            comment: "Progress shown when quitting waits for project storage to close"
        ))
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = NSLocalizedString("Quitting Zenit PDF", comment: "Quit progress panel title")
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.center()
        ZenitModalPresenter.presentPanel(panel, identifier: Self.quitProgressModalIdentifier)
        terminationProgressPanel = panel
    }

    private func hideTerminationProgressPanel() {
        terminationProgressVisible = false
        terminationProgressPanel?.orderOut(nil)
        terminationProgressPanel?.close()
        terminationProgressPanel = nil
    }

    /// Runs the unsaved-changes review and replies to the pending termination.
    ///
    /// Replaceable so the quit regression test in `EscapeAndTerminationTests` can stand in for
    /// the review — asserting that
    /// by the time it runs, the edited window is visible and nothing covers it — without
    /// blocking the test process on a real modal.
    ///
    /// This drives each edited document's `canClose` directly — where the Quick PDF's
    /// Save / Don't Save / Cancel review lives — instead of `reviewUnsavedDocuments` or
    /// `closeAllDocuments`. With `autosavesInPlace` on, both of those save edited
    /// documents *silently*: the review call degraded a quick PDF's save into the refused
    /// non-panel write (an error alert blocked ⌘Q), and the close-all call believed the
    /// no-op autosave and discarded the takeoff without a word. Both were found live.
    /// Only `canClose` asks.
    public lazy var unsavedReviewRunner: @MainActor () -> Void = { [weak self] in
        guard let self else { return }
        self.reviewEditedDocuments { verdict in
            guard verdict else {
                // The windows stay: each one's session, frozen for the quit, follows it again.
                self.windowsAfterCancelledTermination(NSApplication.shared)
                self.terminationReply(false)
                return
            }
            // Granted: close what the review left open (clean documents are not
            // reviewed) and wait for every package to disarm its crash marker before
            // the process is allowed to exit.
            Task { @MainActor in
                await self.awaitTerminationStorageShutdown()
                self.terminationReply(true)
            }
        }
    }

    /// Whether termination must pause for a review: any document with unsaved changes.
    /// `isDocumentEdited`, never the controller's unautosaved-changes flag — a Quick
    /// PDF's NSDocument autosave is a deliberate no-op that reports success, which
    /// clears that flag without saving anything.
    public var hasEditedDocumentsRequiringReview: Bool {
        NSDocumentController.shared.documents.contains(where: \.isDocumentEdited)
    }

    /// The in-flight review's completion. One review runs at a time; termination is the
    /// only caller.
    private var reviewCompletion: (@MainActor (Bool) -> Void)?

    /// Whether a quit review is waiting on the person's answer right now.
    ///
    /// `ZenitApplication.terminate` consults this before it does anything else: a second
    /// quit — ⌘Q pressed again, a Dock quit, a scripted quit's Apple event — while the
    /// review sheet is up used to run the pre-termination sweep again, and that sweep ends
    /// every attached sheet, the review's included. From the user's chair the review
    /// "dismissed itself before any button was pressed" (LT-17). A quit that is already
    /// being reviewed needs no second entrance; the pending review's answer governs.
    public var isReviewingEditedDocuments: Bool { reviewCompletion != nil }

    /// Reviews every edited document through its `canClose` — where the Quick PDF's
    /// Save / Don't Save / Cancel review lives — closing each as it passes. Calls
    /// `completion(true)` when everything edited was saved or discarded, `completion(false)`
    /// the moment one review is cancelled (everything still open stays open).
    ///
    /// Re-entrant calls **join** the pending review rather than restarting it: a restart
    /// would drive a second `canClose` at a document already showing its review sheet —
    /// a second identical sheet queued behind the first, and a completion slot silently
    /// overwritten so the first caller never heard the verdict (LT-17's other half). The
    /// joined caller gets the same verdict the pending review produces.
    public func reviewEditedDocuments(completion: @escaping @MainActor (Bool) -> Void) {
        if let pending = reviewCompletion {
            reviewCompletion = { verdict in
                pending(verdict)
                completion(verdict)
            }
            return
        }
        reviewCompletion = completion
        // Several edited takeoffs: one question first, not one sheet per drawing (IM-238).
        let editedQuick = NSDocumentController.shared.documents
            .compactMap { $0 as? ZenitPDFProjectDocument }
            .filter { $0.mode == .quickPDF && $0.isDocumentEdited }
        guard editedQuick.count > 1 else {
            reviewNextEditedDocument()
            return
        }
        let choice = (quitSummaryPrompt ?? Self.presentQuitSummary)(editedQuick.count)
        switch choice {
        case .reviewEach:
            reviewNextEditedDocument()
        case .cancel:
            let pending = reviewCompletion
            reviewCompletion = nil
            pending?(false)
        case .discardAll:
            Task { @MainActor in
                for document in editedQuick {
                    await document.discardQuickTakeoffForQuit()
                    self.closeReviewedDocumentPreservingSharedWindow(document)
                }
                // Project-mode documents, if any are edited, still get their own review.
                self.reviewNextEditedDocument()
            }
        }
    }

    /// The answer to the several-takeoffs question.
    public enum QuitSummaryChoice: Sendable, Equatable {
        case reviewEach
        case discardAll
        case cancel
    }

    /// Asks the several-takeoffs question. Injectable for tests; the default goes through
    /// ``ZenitModalPresenter`` and, with no user, reviews each (the non-destructive answer).
    public var quitSummaryPrompt: (@MainActor (Int) -> QuitSummaryChoice)?

    public static let quitSummaryModalIdentifier = "app.quitSummary"

    static func presentQuitSummary(count: Int) -> QuitSummaryChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "You have %ld takeoffs that are not saved as projects.",
                comment: "Quit summary title; the number of edited Quick PDF takeoffs"
            ),
            count
        )
        alert.informativeText = NSLocalizedString(
            "Review each one to save it as a project, or discard them all. The drawings themselves are never changed.",
            comment: "Quit summary detail"
        )
        alert.addButton(withTitle: NSLocalizedString("Review Changes…", comment: "Quit summary button"))
        let discard = alert.addButton(withTitle: NSLocalizedString("Discard All", comment: "Quit summary button"))
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Quit summary button"))
        switch ZenitModalPresenter.runAlert(alert, identifier: quitSummaryModalIdentifier, answerWithoutAUser: .button(0)) {
        case .button(0): return .reviewEach
        case .button(1): return .discardAll
        default: return .cancel
        }
    }

    private func reviewNextEditedDocument() {
        guard let edited = NSDocumentController.shared.documents.first(where: \.isDocumentEdited) else {
            let completion = reviewCompletion
            reviewCompletion = nil
            completion?(true)
            return
        }
        // The question is asked over the tab it is about, not over whichever tab happens
        // to be in front (CR-157).
        if let document = edited as? ZenitPDFProjectDocument, let host = document.hostWindowController {
            host.activateTab(id: document.documentIdentity)
        }
        edited.canClose(
            withDelegate: self,
            shouldClose: #selector(reviewedDocument(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    /// One reviewed document's verdict: close it and continue, or keep the app alive.
    @objc private func reviewedDocument(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard shouldClose else {
            let completion = reviewCompletion
            reviewCompletion = nil
            completion?(false)
            return
        }
        closeReviewedDocumentPreservingSharedWindow(document)
        reviewNextEditedDocument()
    }

    /// Closes one reviewed document without taking the shared window down with it.
    ///
    /// A plain `close()` of the tab that owns the window controller closes the **window**
    /// — every other tab's view vanishes and the next document's review sheet has no
    /// visible window to hang from, so the person watches their drawings disappear while
    /// a question is still pending (LT-17: "the documents closed without an explicit
    /// choice", the click after landing on the desktop). While other tabs remain attached,
    /// the close goes through the window controller's tab-aware teardown, which migrates
    /// ownership to a survivor first; the last document out closes the window normally.
    private func closeReviewedDocumentPreservingSharedWindow(_ document: NSDocument) {
        if let zenit = document as? ZenitPDFProjectDocument,
           let host = zenit.hostWindowController,
           host.documents.contains(where: { $0 !== zenit }) {
            host.closeReviewedDocumentKeepingWindow(zenit)
            return
        }
        document.close()
    }

    /// Delivers the termination verdict. Replaceable for the same test.
    public var terminationReply: @MainActor (Bool) -> Void = { shouldTerminate in
        (NSApplication.shared.delegate as? ZenitApplicationDelegate)?
            .resolvePendingQuitEvent(granted: shouldTerminate)
        NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    /// Exits every panel and mode in every window, so no surface can cover the review sheet.
    /// Public so the termination regression test can drive the exact quit path.
    public func prepareWindowsForTermination(_ application: NSApplication) {
        for window in application.windows {
            if let controller = window.windowController as? ProjectWindowController {
                controller.prepareForTermination()
            }
        }
    }

    /// The quit review was cancelled: every window that ``prepareWindowsForTermination(_:)``
    /// froze records its session again (R-022).
    public func windowsAfterCancelledTermination(_ application: NSApplication) {
        for window in application.windows {
            if let controller = window.windowController as? ProjectWindowController {
                controller.terminationCancelled()
            }
        }
    }

    // MARK: - URL scheme

    /// Handles `zenitpdf:` URLs and file URLs handed over by Launch Services.
    ///
    /// A file URL arrives here only when the person opened the file — Finder, the Dock, Open
    /// With — so it is opened. A `zenitpdf:` link is a request any web page can make, and it never
    /// opens a file (S17-05, ``ZenitURLRoute``).
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                documentController.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { ZenitErrorPresenter.present(error) }
                }
                continue
            }
            guard url.scheme?.lowercased() == ZenitAppInfo.urlScheme else { continue }
            handleZenitURL(url)
        }
    }

    /// Where a `zenitpdf:` link's status note goes: the front project's status tray. A test
    /// replaces it to read the note without a project window.
    var postLinkNote: @MainActor (_ note: AppWarning, _ front: ZenitPDFProjectDocument?) -> Void = { note, front in
        ZenitURLNotes.post(note, to: front)
    }

    /// Routes a `zenitpdf:` link. A link is a request any web page can make, so nothing here
    /// raises a modal and nothing here opens a file: an unknown link, or one naming a file, leaves
    /// one quiet note in the front project's status tray (``ZenitURLNotes``), and the note never
    /// echoes the link's text.
    func handleZenitURL(_ url: URL) {
        let front = documentController.currentDocument as? ZenitPDFProjectDocument
            ?? documentController.documents.lazy.compactMap { $0 as? ZenitPDFProjectDocument }.first
        switch ZenitURLRoute(url) {
        case .open:
            documentController.openDocument(nil)
        case .refusedFileRequest:
            // S17-05: a page must not be able to make the app open a file of its choosing —
            // not the container's autosaves, not a system path, not a planted download.
            postLinkNote(ZenitURLNotes.fileLinkRefusedNote(), front)
        case .new:
            documentController.newDocument(nil)
        case let .reveal(project, markup):
            let documents = documentController.documents.compactMap { $0 as? ZenitPDFProjectDocument }
            Task { @MainActor in _ = await ZenitURLNotes.reveal(project: project, markup: markup, in: documents) }
        case .unknown:
            postLinkNote(ZenitURLNotes.unknownLinkNote(), front)
        }
    }
}

// MARK: - Document-free commands with no window (T-009)

/// The commands built to run with nothing open — Import Zenit JSON…, New from Template…, the
/// folder index, packs, Process PDF Files… and Stop Processing PDF Files, New PDF from
/// Documents…, Set Up “Print to Zenit PDF”… — answered here once no project window is in the
/// responder chain.
///
/// Every application command row targets `nil` with ``ZenitCommandResponding/performZenitCommand(_:)``,
/// and only `ProjectWindowController` implemented it. Closing the last window leaves the
/// application running (``applicationShouldTerminateAfterLastWindowClosed(_:)``), and then no
/// responder answered, so AppKit disabled all of these rows — among them Stop Processing PDF
/// Files, the only way to stop a batch that belongs to no window. The delegate is the last
/// responder AppKit asks, after the key and main windows, so while a project window is there it
/// still answers first. Here the command runs with no window and no document: its panels and
/// alerts are app-modal.
extension ZenitApplicationDelegate: ZenitCommandResponding, NSMenuItemValidation {

    public func performZenitCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = ZenitAppCommand(rawValue: raw),
              ZenitAppCommandTable.validateWithoutWindow(command, item: nil) else { return }
        ZenitAppCommandTable.perform(command, controller: nil, document: nil)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(ZenitCommandResponding.performZenitCommand(_:)) else { return true }
        // A shell command acts on a document; with no window it stays disabled, as before.
        guard let raw = menuItem.representedObject as? String,
              let command = ZenitAppCommand(rawValue: raw) else { return false }
        return ZenitAppCommandTable.validateWithoutWindow(command, item: menuItem)
    }
}
