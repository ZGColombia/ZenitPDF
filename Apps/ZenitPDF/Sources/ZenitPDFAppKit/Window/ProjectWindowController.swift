import AppKit
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFSnapEngine
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

/// One project window hosting one or more open documents as tabs, plus the
/// command routing that only the application can do.
///
/// `ZPDFUIShell` owns the layout, the toolbar and the panels of each document, and services
/// every command that is about the *window* — zoom, pane visibility, arming a tool.
/// Everything left over is about the *document*: files, export, print, undo — and those are
/// routed to the **active tab's** document. NSDocument semantics stay intact: every tab is
/// its own `ZenitPDFProjectDocument` with its own undo stack, autosave and dirty state; the
/// window controller is owned by one of them at a time and migrates when that one closes.
@MainActor
public final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ZenitCommandResponding {

    /// The window new documents open into as tabs. Weak: a closed window must never
    /// capture the next open. Only a window actually on screen may host, which also keeps
    /// unit tests — whose windows are never ordered in — on one controller per document.
    public internal(set) static weak var tabHost: ProjectWindowController?

    /// Everything one attached document contributes to the window.
    struct DocumentContent {
        let layout: ProjectWindowLayoutController
        let canvas: PDFCanvasViewController
        /// Keeps the canvas bar's Undo and Redo in step with this document's undo stack.
        var undoFeed: CanvasUndoStateFeed?
    }

    /// Attached documents, in tab order.
    public internal(set) var documents: [ZenitPDFProjectDocument] = []

    /// Where a copied snippet goes. An instance property, injected by the app-tier tests,
    /// **never** a process-global override: `NSPasteboard.general` is one object for the whole
    /// machine, and a test that wrote it would be doing to the user's clipboard what
    /// `PresetApplySkipReportTests` once did to the user's `UserDefaults`.
    public var snippetPasteboard: any SnippetPasteboardWriting = SystemSnippetPasteboard()
    /// Where copied markups go (nl-markup, NL-MARKUP-05). Injected by tests, like the above.
    public var markupPasteboard: any MarkupPasteboardAccess = MarkupPasteboards.makeDefault()
    /// The document of the front tab.
    public internal(set) weak var activeDocument: ZenitPDFProjectDocument?
    var contents: [UUID: DocumentContent] = [:]
    /// NL-UX-20: the views this window shows documents through, when it is a second window on
    /// them (`ProjectWindowController+SecondWindow.swift`). Empty for a document's first window,
    /// which shows each document through its own core.
    var windowViews: [UUID: DocumentWindowView] = [:]
    private var placeholderController: NSViewController?
    /// Guards the close-every-tab review chain a window close runs.
    private(set) var windowCloseReviewInProgress = false

    /// The stack of open panels and modes, newest last. `Escape` pops it one level at a
    /// time, and nothing can be registered in it without an exit route — that is the whole
    /// no-dead-ends guard.
    public let modeRegistry = ZPDFModeExitRegistry()

    /// Tracks canvas view modes and holds the viewport to restore when one exits, so
    /// Compare, Overlay and Split give back exactly the view the person had.
    private let viewModeCoordinator = CanvasViewModeCoordinator()

    public init(document: ZenitPDFProjectDocument) {
        let window = Self.makeProjectWindow()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        installLoadingContent(for: document)
        Self.tabHost = self
        attach(document: document)
    }

    /// NL-UX-20: a second window on a document another window already shows — Window ▸ New
    /// Window for Project. It shows the document through `view`, its own core view and shell
    /// over the document's one core, never hosts other tabs, and is never the tab host.
    init(secondWindowFor document: ZenitPDFProjectDocument, view: DocumentWindowView) {
        let window = Self.makeProjectWindow()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        installLoadingContent(for: document)
        adoptSecondWindow(document: document, view: view)
    }

    /// The project window both initialisers build.
    private static func makeProjectWindow() -> ZPDFProjectWindow {
        // `ZPDFProjectWindow`: View ▸ Hide Toolbar collapses the window's own top band rather than
        // revealing the hidden NSToolbar underneath it.
        let window = ZPDFProjectWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        // Settings ▸ Appearance: dark by default whatever the system says,
        // Light or Match System when the person chose so. Set on the window as well as
        // on the application so a window built before launch finished — and every headless
        // test window — gets the same answer.
        ZenitAppearancePreference.load(from: ZenitAppearancePreference.processDefaults).apply(to: window)
        // One dark surface from the first frame: the loading placeholder
        // already stands on the chrome ground under a transparent titlebar, so installing the
        // project layout later changes the panels, not the window's colour.
        ProjectWindowLayoutController.applyChrome(to: window)
        return window
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// Test-only stand-in for `window?.isVisible` (LT-33). The live tab-host path is
    /// only reachable through a window that is actually on screen, and a test may never
    /// put one there — so a regression test for "an opened project joins the visible
    /// window as a tab" injects the visibility verdict here instead. Nothing under
    /// `Apps/ZenitPDF/Sources` may assign it; `ModalInjectionTests` scans the sibling
    /// modal seam the same way, and this one is `internal` so only `@testable` code can
    /// reach it at all.
    static var hostWindowVisibilityForTesting: ((ProjectWindowController) -> Bool)?

    /// Whether a newly opened document may join this window as a tab. Only a window the
    /// user can see qualifies; anything else gets its own window, which is also what keeps
    /// headless tests deterministic.
    public var canHostAdditionalDocuments: Bool {
        // A window whose close review is pending is on its way out: a document joining it
        // now would be swept into the close (CR-159).
        if windowCloseReviewInProgress { return false }
        // A second window on a document shows that document only (NL-UX-20).
        if isSecondWindow { return false }
        if let probe = Self.hostWindowVisibilityForTesting { return probe(self) }
        return window?.isVisible == true
    }

    /// The window a newly opened document joins as a tab, or `nil` when no visible window
    /// can host one.
    ///
    /// LT-33: ``tabHost`` is one weak last-created reference, so
    /// it dies with whichever window happened to be created last — `windowWillClose` nils
    /// it, and being `weak` it clears on deallocation too — even while an older, perfectly
    /// visible window survives. From that moment every open fell into the own-window
    /// branch: a reopened `.zpdfproj` appeared as a second window stacked over the real
    /// one, titled exactly like the drawing it was created from, with no chip in the
    /// surviving window's tab strip, nothing recognisable in the Window menu, a dead first
    /// click (the click that merely activated the window underneath), and "switching
    /// tabs" silently burying the project. The registration is therefore a hint, not the
    /// truth: when it cannot host, the surviving windows are searched — front-to-back,
    /// key and main first — and the first one that can host is re-registered and used.
    static func resolveTabHost() -> ProjectWindowController? {
        if let tabHost, tabHost.canHostAdditionalDocuments { return tabHost }
        let application = NSApplication.shared
        var candidates: [NSWindow] = []
        if let key = application.keyWindow { candidates.append(key) }
        if let main = application.mainWindow { candidates.append(main) }
        // `orderedWindows` is the visible set front-to-back; `windows` catches a host
        // whose eligibility a test injected without ordering anything onto a screen.
        candidates.append(contentsOf: application.orderedWindows)
        candidates.append(contentsOf: application.windows)
        for window in candidates {
            guard let controller = window.windowController as? ProjectWindowController,
                  controller.canHostAdditionalDocuments else { continue }
            tabHost = controller
            return controller
        }
        return nil
    }

    // MARK: - Attaching documents (tabs)

    /// Adds a document to this window as a tab and makes it the front one.
    public func attach(document: ZenitPDFProjectDocument) {
        guard !documents.contains(where: { $0 === document }) else {
            activateTab(id: document.documentIdentity)
            return
        }
        documents.append(document)
        document.hostWindowController = self
        document.onStateChange = { [weak self, weak document] in
            guard let self, let document else { return }
            self.documentStateChanged(for: document)
        }
        document.onSearchPresenterReady = { [weak self] in
            self?.refreshProjectSearchSources()
        }
        document.onRevealForeignHit = { [weak self] hit in
            self?.revealForeignHit(hit)
        }
        // Ownership through NSDocument's own machinery is the caller's: the first
        // document adds the controller in `makeWindowControllers`; later tabs stay
        // unowned until ownership migrates on close.
        documentStateChanged(for: document)
        activateTab(id: document.documentIdentity)
        refreshProjectSearchSources()
    }

    /// Rewires every drawing's "All Drawings" search fan-out to the current open set.
    ///
    /// Each drawing's sources are all the *other* drawings. Runs on attach, on detach and
    /// whenever a drawing's real search presenter replaces its placeholder — the presenter's
    /// own `didSet` re-runs a live query when the id set changes, so closing a drawing drops
    /// its hits rather than leaving results pointing at a tab that no longer exists.
    private func refreshProjectSearchSources() {
        let sources = documents.compactMap { $0.projectSearchSource() }
        for document in documents {
            document.installProjectSearchSources(
                sources.filter { $0.documentID != document.documentIdentity }
            )
        }
        // NL-QTY-15: the whole-project ledger summary follows the same open set.
        refreshProjectLedgerSources()
    }

    /// Fronts the drawing a foreign search hit belongs to, then reveals the hit there — and
    /// takes the search along, so that drawing's Search page lists the same results with the
    /// opened hit active (L-91, `ZPDFSearchHandoff`).
    private func revealForeignHit(_ hit: ZPDFUIPresentation.SearchHit) {
        guard let sourceID = hit.sourceDocumentID,
              let target = documents.first(where: { $0.documentIdentity == sourceID })
        else { return }
        let origin = activeDocument?.searchPresenter
        activateTab(id: sourceID)
        target.revealFromProjectSearch(hit)
        if let origin { ZPDFSearchHandoff.continueSearch(from: origin, into: target.searchPresenter, at: hit) }
    }

    /// Fronts a tab: swaps the window content to that document's shell composition.
    public func activateTab(id: UUID) {
        guard let document = documents.first(where: { $0.documentIdentity == id }) else { return }
        activeDocument = document
        // The tab the person just brought forward in the window they are using (NL-UX-20).
        if window?.isKeyWindow == true { focusThisWindow(on: document) }
        migrateOwnership(to: document)
        if let content = contents[id] {
            present(content: content)
        } else {
            // A tab still loading shows its own opening state, never the previous tab's
            // canvas under the new tab's title — edits there went to a document that was no
            // longer in front, or one already closed (BH-367, BH-368).
            installLoadingContent(for: document)
        }
        updateWindowChrome()
        syncTabs()
    }

    /// Window-controller ownership follows the active tab.
    ///
    /// AppKit resolves every nil-target document action — ⌘S, Save As, Print, the
    /// autosave cycle — through `NSDocumentController.currentDocument`, which is the main
    /// window's `windowController.document`. While ownership stayed with the
    /// first-opened tab, ⌘S with any other tab in front ran the *owner's* save flow
    /// (an "Untitled" panel from the startup document, found live on 2026-08-24):
    /// the dead-⌘Z disease on the whole
    /// document-action family. Undo got a targeted delegate fix; the systemic cure is
    /// that the controller's document is always the active tab, so every AppKit
    /// association — current document, Auto Save, window state — follows the tab the
    /// person is looking at. The close path's own migration (``finalizeClose(of:)``)
    /// stays untouched: it runs when the owner leaves, this runs when the front changes.
    private func migrateOwnership(to document: ZenitPDFProjectDocument) {
        guard !document.windowControllers.contains(where: { $0 === self }) else { return }
        if let owner = documents.first(where: { $0.windowControllers.contains(self) }) {
            owner.removeWindowController(self)
        }
        document.addWindowController(self)
    }

    /// Closes one tab, asking about unsaved work first. Closing the last tab closes the
    /// window through the same review everyone else gets.
    public func requestCloseTab(id: UUID) {
        guard let document = documents.first(where: { $0.documentIdentity == id }) else { return }
        // A drawing another window still shows leaves this window without closing (NL-UX-20).
        if documents.count > 1, handOverToAnotherWindow(document) { return }
        if documents.count == 1 {
            window?.performClose(nil)
            return
        }
        // The × on a background tab asked its question over the tab in front — the third door
        // CR-157 missed (BH-905). An edited tab comes to the front before it is reviewed.
        if document.isDocumentEdited, activeDocument !== document {
            activateTab(id: id)
        }
        document.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard shouldClose, let document = document as? ZenitPDFProjectDocument else { return }
        finalizeClose(of: document)
    }

    /// Closes one already-reviewed document while keeping the shared window alive for the
    /// tabs that remain.
    ///
    /// The application-termination review closes documents one at a time as each passes
    /// its `canClose`; when the reviewed document owned this window controller, a plain
    /// `NSDocument.close()` closed the whole window — every other tab's drawing vanished
    /// while a later tab's review was still pending, and that review's sheet had no
    /// visible window left to hang from (LT-17). This is the tab-aware teardown the tab
    /// strip already uses, exposed for the delegate's review chain.
    public func closeReviewedDocumentKeepingWindow(_ document: ZenitPDFProjectDocument) {
        finalizeClose(of: document)
    }

    /// Detaches and closes a reviewed document, migrating window-controller ownership to a
    /// surviving tab first so `NSDocument.close()` cannot tear the shared window down.
    private func finalizeClose(of document: ZenitPDFProjectDocument) {
        let wasActive = activeDocument === document
        let survivor = documents.first(where: { $0 !== document })
        if document.windowControllers.contains(where: { $0 === self }), let survivor {
            document.removeWindowController(self)
            survivor.addWindowController(self)
        }
        // With no survivor the controller stays attached, so `close()` takes the window
        // down with the document. Detaching first left a window with no controller and no
        // delegate, its tab strip wired to nothing (CR-154).
        detach(document)
        document.close()
        if wasActive, let next = documents.last {
            activateTab(id: next.documentIdentity)
        } else {
            updateWindowChrome()
            syncTabs()
        }
    }

    /// Closes the window's empty untitled start documents once a drawing is open beside them.
    ///
    /// A launch with nothing to reopen shows an untitled start document. Opening a drawing then
    /// made it a tab of the same window, so the empty "Untitled" stayed beside the drawing:
    /// Save refused it, nothing could be added to it, and Combine Open Drawings on it posted
    /// "Save this takeoff as a project first", which the person could not do
    /// (L-40). A start document is untouched by definition — no file, no drawing, no edit — so
    /// it closes with nothing to review, the way a document application replaces its blank
    /// window with the first file opened.
    func retireUntouchedStartDocuments() {
        guard documents.contains(where: { $0.drawing != nil }) else { return }
        let starts = documents.filter(\.isUntouchedStartDocument)
        for start in starts { finalizeClose(of: start) }
    }

    func detach(_ document: ZenitPDFProjectDocument) {
        // The drawing's panels in this window go with it (S-022, S-010).
        if let split = windowShell(for: document)?.splitCanvas { closePaneWindows(of: split) }
        ReviewListWindow.forget(self, document: document)
        AssistantInboxWindow.forget(self, document: document)
        contents[document.documentIdentity]?.layout.persistLayoutState()
        contents.removeValue(forKey: document.documentIdentity)
        overlayCompositors[document.documentIdentity]?.detach()
        overlayCompositors[document.documentIdentity] = nil
        documents.removeAll { $0 === document }
        // A second window never took these over (NL-UX-20); only the host hands them back.
        if document.hostWindowController === self {
            document.onStateChange = nil
            document.onSearchPresenterReady = nil
            document.onRevealForeignHit = nil
            document.hostWindowController = nil
        }
        if activeDocument === document { activeDocument = nil }
        refreshProjectSearchSources()
    }

    /// Rebuilds the tab strip of every attached document's shell, so each shows the whole
    /// window's tabs with the right one active, and keeps the window chrome honest.
    /// Moves a tab within the strip (NL-DOCS-14): the window's document order is the tab order.
    func moveTab(id: UUID, to target: Int) {
        let order = Self.reordered(documents.map(\.documentIdentity), moving: id, to: target)
        documents = order.compactMap { identity in documents.first { $0.documentIdentity == identity } }
        syncTabs()
    }

    public func syncTabs() {
        for document in documents {
            // The Files section's thumbnails, resolved **by identity** against the live document
            // list — never by position, which hands the wrong sheet to the wrong drawing the
            // moment a tab closes. Installed on every shell so the section works from any tab.
            // Installed with the window's document set as its identity (CR-101): the loader
            // flushes its cache only when a drawing opens or closes, not on every tab sync.
            windowShell(for: document)?.drawingThumbnails.setIdentifiedProvider({ [weak self] id, pixels in
                guard let source = self?.documents
                    .first(where: { $0.documentIdentity == id })?
                    .drawing?.rasterSource
                else { return nil }
                return try? await source.thumbnail(pageIndex: 0, maximumPixelSize: pixels)
            }, identity: Set(documents.map(\.documentIdentity)))
        }
        refreshTabState()
    }

    /// The cheap half of ``syncTabs()``: every shell's tab summaries, the edited dot and the
    /// recorded session. What a document's edit, undo, redo, save or autosave changes — the
    /// structural half (the Files section's thumbnail provider) changes only when a drawing
    /// opens, closes or moves, and those paths call ``syncTabs()`` (R-021).
    func refreshTabState() {
        let activeID = activeDocument?.documentIdentity
        let summaries = documents.map { document in
            var summary = document.makeTabSummary()
            summary.isActive = document.documentIdentity == activeID
            return summary
        }
        for document in documents {
            // This window's view of each drawing, not whichever window has focus (NL-UX-20).
            windowCore(for: document)?.document.setTabs(summaries, active: activeID)
            // A project takes dropped PDFs as drawings of its own (NL-DOCS-04).
            windowShell(for: document)?.navigatorDropAddsToProject = document.mode == .project && document.drawingSet != nil
        }
        window?.isDocumentEdited = activeDocument?.isDocumentEdited ?? false
        // The window's drawings, in order, for the next launch (NL-DOCS-14). A no-op when
        // the session is the one already stored.
        recordSession()
    }

    func updateWindowChrome() {
        window?.title = secondWindowTitle ?? activeDocument?.displayName ?? ZenitAppInfo.displayName
        window?.subtitle = subtitle
        window?.representedURL = activeDocument?.fileURL
        window?.isDocumentEdited = activeDocument?.isDocumentEdited ?? false
    }

    public override func synchronizeWindowTitleWithDocumentName() {
        // The owner document is not necessarily the front tab; the chrome follows the tab.
        updateWindowChrome()
    }

    // MARK: - Content

    /// The window before any drawing has arrived: the shell's own empty state, no chrome
    /// missing — and already a drop target, because dragging a PDF into an empty window is
    /// how people actually start work.
    func installLoadingContent(for document: ZenitPDFProjectDocument? = nil) {
        let host = NSViewController()
        let view = ZenitEmptyWindowDropView(frame: .zero)
        view.layer?.backgroundColor = ZPDFColor.nsColor(.background).cgColor
        view.onDropFiles = { urls in
            for url in urls { DroppedFileBookmarks.remember(url, defaults: ZenitProcessDefaults.bookmarks) }
            Self.openDropped(urls: urls)
            return true
        }
        if let document {
            // A large drawing takes seconds to open, and a bare window said nothing about what
            // it was doing or which file it was (IM-050): name it, say it is opening, and offer
            // the way out.
            let identity = document.documentIdentity
            let placeholder = LoadingPlaceholderView(fileName: document.displayName ?? "") { [weak self] in
                self?.requestCloseTab(id: identity)
            }
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            loadingPlaceholder = placeholder
        }
        host.view = view
        // Assigning `contentViewController` sizes the window to the new content's fitting size,
        // and the placeholder's is zero — so the window fell to its 1040 × 640 minimum whenever
        // a second drawing joined as a tab and showed its opening state (L-19). The window's
        // first content no longer sizes it either: a window with no autosaved frame to restore
        // — a second window on a project, whose frame autosave name the first window holds —
        // kept the placeholder's size and opened at 864 × 526, under the minimum, with the page
        // fitted at 15 % (L-96). Every window keeps the frame it has, as ``present(content:)``
        // does.
        let frameBeforeInstall = window?.frame
        contentViewController = host
        if let frameBeforeInstall, let window { window.setFrame(frameBeforeInstall, display: false) }
        placeholderController = host
        window?.title = ZenitAppInfo.displayName
    }

    /// The "Opening…" state shown while the first document loads. IM-050's test seam.
    private(set) var loadingPlaceholder: LoadingPlaceholderView?

    private func documentStateChanged(for document: ZenitPDFProjectDocument) {
        if let error = document.loadFailure {
            presentLoadFailure(error, for: document)
            return
        }
        if contents[document.documentIdentity] == nil,
           let shell = windowShell(for: document), let core = windowCore(for: document) {
            install(shell: shell, core: core, for: document)
            // The Whole Project panel and the office recipe library need the shell, which does
            // not exist yet when the search presenter's arrival first wires them: without this a
            // window with one drawing never offered the office library (NL-UX-20).
            refreshProjectLedgerSources()
            // A drawing reopened from the last session lands where it was (NL-DOCS-14).
            applyPendingSessionViewport(for: document)
            // The first drawing to open into the start window takes the empty untitled
            // document's place (L-40). Here, once per document and only when its drawing has
            // arrived, so a drawing that fails to open leaves the start window as it was.
            if document.drawing != nil { retireUntouchedStartDocuments() }
        }
        if document === activeDocument || activeDocument == nil {
            if activeDocument == nil { activeDocument = document }
            if let content = contents[document.documentIdentity] {
                present(content: content)
            }
            updateWindowChrome()
        }
        syncTabs()
    }

    /// Builds one document's canvas and layout and wires everything that crosses the
    /// shell/app seam. Called exactly once per attached document, when its core is ready.
    func install(
        shell: ProjectShellEnvironment,
        core: AppCoreEnvironment,
        for document: ZenitPDFProjectDocument
    ) {
        let rasterSource = document.drawing?.rasterSource
        let canvas = PDFCanvasViewController(core: core, rasterSource: rasterSource, toolbar: shell.toolbar)
        // A project of several drawings: each page renders from its own drawing (NL-DOCS-04).
        canvas.drawingSet = document.drawingSet
        // Automation reads the document's layer state and other pages' geometry (nl-automation).
        wireAutomation(canvas: canvas, for: document)
        // The drawing's own links follow on click (nl-documents, NL-DOCS-09).
        wireDrawingLinks(canvas: canvas, shell: shell, for: document)
        canvas.onShellCommand = { [weak self, weak document] command in
            guard let self, let document else { return }
            self.performShell(command, for: document)
        }
        // Each closure names the document it belongs to: resolving `activeDocument` dropped or
        // misapplied the points whenever the front tab was not the canvas that collected
        // them (BH-909).
        canvas.onCalibrationPointsCollected = { [weak self, weak document] points in
            guard let document else { return }
            self?.finishCalibration(points: points, for: document)
        }
        // Curve an Edge judges its edge click at the zoom it was clicked at (S-007).
        canvas.onCalibrationClick = { [weak document] index in
            guard index == 0, let document else { return }
            CurveEdgePick.noteEdgeClick(document)
        }
        wireScaleSheet(core: core, shell: shell, for: document)
        // A count mark can name imported artwork by digest (ADR-0011 §2.1). The picture lives
        // in the project's content-addressed store and the canvas has no package, so the
        // lookup crosses here. Asked once per digest; a digest the store has no row for draws
        // the mark's fallback glyph rather than nothing.
        canvas.onResolveArtwork = { [weak document] digest in
            guard let package = document?.projectPackage else { return nil }
            return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
        }
        // ADR-0043 (L-81): an inserted image draws from its own pixels, decoded off the main
        // thread from the bytes the store keeps beside its mosaic.
        canvas.onResolveInsertedImage = { [weak document] digest in
            guard let package = document?.projectPackage,
                  let data = try? await ProjectArtworkStore.rasterSourceBytes(forDigest: digest, in: package)
            else { return nil }
            return await Task.detached(priority: .userInitiated) { InsertedImagePixels.decode(data) }.value
        }
        // The Scale Regions panel starts the same two-click flow with a different
        // destination, and reveals an overlap by scrolling the drawing to the shared area.
        document.onBeginCalibration = { [weak self, weak document] in
            guard let document else { return }
            // The region's (or draft's) points, never a pick left armed without Escape: the
            // borrowed picks are served before the region destination in `finishCalibration`,
            // so a stale Pick Fall Line took these two clicks and rewrote the slope (R-001).
            PendingPointPicks.disarmAll(document)
            self?.beginCalibration(for: document)
        }
        document.onRevealPageRect = { [weak canvas] rect in
            canvas?.zoom(toPageRect: rect)
        }
        document.onZoomToSelection = { [weak canvas] in canvas?.zoomToSelection() }
        // `AppCanvasPresenter` *calls* `onScrollTo` from two
        // places — `zoomTo(markupID:)`, and the search reveal for a hit that is page text rather
        // than a markup (`ZenitPDFProjectDocument.reveal(_:)`) — and nothing in the repository
        // ever installed it. A text hit therefore changed page and never scrolled to the word.
        // Revealing a page rect already has one meaning in this product, and it is the one
        // `onRevealPageRect` above and `⌘*` both use: fit the rect with padding.
        //
        // The `flash` argument now means something. Until 2026-08-26 it was dropped, because
        // there was no highlight affordance on the canvas; `CanvasPageView.searchHighlights` is
        // that affordance, and `flash` decides whether the revealed rect is marked out.
        //
        // Revealing scrolls at the current zoom rather than fitting. A search hit on a
        // short word used to magnify the canvas to roughly 500 %,
        // because fitting a word-sized rect to a viewport is an enormous zoom. `zoomTo(markupID:)`
        // still comes through here, and a markup is usually big enough that scrolling shows it;
        // when it is not, `revealPageRect` zooms out to fit and never in.
        core.canvas.onScrollTo = { [weak canvas] rect, flash in
            canvas?.revealPageRect(rect, highlight: flash)
        }
        // Leaving calibration — by finishing it or by Escape. The toolbar's selection ring
        // follows the armed tool on its own now: the chips observe the toolbar model, so the
        // no-op `syncSelection()` call that ended this closure is gone (R-089).
        canvas.onCalibrationEnd = { [weak document] collected in
            guard let document else { return }
            // A Scale Region's destination survives only into `finishCalibration`. Left
            // behind by Escape, it silently redirected the NEXT Measure ▸ Calibrate Scale…
            // into the old region — the page stayed "No scale" and every measurement inside
            // the region changed value (CR-149).
            if !collected {
                // Every borrowed pick goes, not only Verify Scale and Split Area (R-001).
                PendingPointPicks.disarmAll(document)
                // A sheet that stepped aside for points comes back as it was; otherwise the
                // abandoned destination goes (CR-149).
                if let sheet = ScaleSheetCoordinator.active(for: document), sheet.pendingPick != nil {
                    sheet.pickingAbandoned()
                } else {
                    document.pendingScaleCalibration = nil
                }
            }
        }
        canvas.dropBehaviorProvider = { [weak document] optionHeld in
            guard let document else { return .open }
            // `⌥` adds the drawing as a revision of the current document, so Revision
            // Compare has something to compare against. A plain drop opens the file;
            // the badge always says which, so the modifier is discoverable.
            return (optionHeld && document.drawing != nil) ? .addAsRevision : .open
        }
        canvas.onDropFiles = { [weak self, weak document] urls, behavior in
            guard let self, let document else { return false }
            return self.handleCanvasDrop(urls: urls, behavior: behavior, document: document)
        }
        viewModeCoordinator.onLeave = { [weak self] _, token in
            guard let self, let token, let documentID = token.documentID else { return }
            self.contents[documentID]?.canvas.restore(
                zoom: token.viewport.zoom,
                visiblePageRect: token.viewport.visiblePageRect
            )
        }
        // Split Canvas and Revision
        // Overlay run on the *shell's* coordinator — `viewModeCoordinator` above only ever sees
        // the Revision Compare sheet — and this is the hook the shell publishes for the app to
        // put the canvas back with. It was never assigned, so the return token those two modes
        // capture on entry was computed and dropped. Until now that cost nothing, because the
        // canvas view is never rebuilt and a mode that touched it did not exist; a mode whose
        // panes drive the real canvas, which is what the rest of this wiring makes true, is a
        // different matter. Escape now puts the zoom and the scroll position back explicitly.
        //
        // `onLeaveCanvasMode` rather than `canvasModes.onLeave`: the shell owns that one and
        // unregisters the mode from it, so assigning over it would leave the registry holding a
        // mode nobody is in — which is a dead end, the exact rule this hook exists to keep.
        shell.onLeaveCanvasMode = { [weak self, weak document] _, token in
            guard let self, let document, let token else { return }
            // The page first: focusing a Split pane turned the real canvas to that pane's page,
            // and restoring only zoom and scroll left it there with the other page's scroll
            // rect (BH-369).
            if document.core?.document.currentPageID != token.viewport.pageID {
                document.core?.document.goToPage(id: token.viewport.pageID)
            }
            self.contents[document.documentIdentity]?.canvas.restore(
                zoom: token.viewport.zoom,
                visiblePageRect: token.viewport.visiblePageRect
            )
        }
        // Split Canvas: the panes are the document, and moving one moves the canvas behind it.
        // `document.shell` rather than the `shell` parameter in both closures: the controller
        // these are installed on is owned *by* the shell, so capturing it strongly here would be
        // a cycle that keeps every closed document's shell alive.
        shell.splitCanvas.onPaneChange = { [weak self, weak document] pane in
            guard let self, let document, let shell = document.shell else { return }
            self.applySplitCanvasPane(pane, shell: shell, document: document)
        }
        shell.splitCanvas.onFocusChange = { [weak self, weak document] paneID in
            guard let self, let document, let shell = document.shell else { return }
            self.applySplitCanvasPane(shell.splitCanvas.pane(paneID), shell: shell, document: document)
        }
        // LT-24: an occupied pane draws the drawing itself. The shell owns the mode chrome
        // and the pane arrangement; only the app can rasterise a page, so the live pane
        // content is injected here. Without this hook every pane showed the labelled
        // placeholder card forever — the mode named the drawing and never drew it.
        shell.splitCanvasPaneContent = { [weak self, weak document] pane in
            guard let self, let document, let shell = document.shell,
                  let renderSource = self.splitPaneRenderSource(for: pane) else { return nil }
            return AnyView(SplitCanvasPaneLiveContent(
                pane: pane,
                renderSource: renderSource,
                controller: shell.splitCanvas
            ))
        }
        observeCanvasModes(shell: shell, document: document)
        // nl-ux: the Export chooser and the other window hooks (UX/NLUXWindowWiring.swift).
        wireNextLevelUX(shell: shell, document: document)
        // nl-documents: arranging the set from the Navigator (Window/ProjectWindowController+Documents.swift).
        wireNextLevelDocuments(shell: shell, document: document)
        // nl-markup: tool style defaults, the canvas context menu, the markup clipboard
        // (Markup/ProjectWindowController+Markup.swift).
        wireNextLevelMarkup(shell: shell, document: document)
        // r2-platform: the author directory, the office tool library (Platform/ProjectWindowController+Platform.swift).
        wireR2Platform(document: document, canvas: canvas)

        // Real Navigator thumbnails: the provider is the engine-barrier-wrapped,
        // LRU-cached bridge thumbnail, injected so the shell never sees PDFKit.
        if let rasterSource {
            shell.navigatorThumbnails.provider = { pageIndex, maximumPixelSize in
                try? await rasterSource.thumbnail(
                    pageIndex: pageIndex,
                    maximumPixelSize: maximumPixelSize
                )
            }
            // Each card of a project of several drawings shows its own drawing (NL-DOCS-04).
            wireDrawingSetThumbnails(shell: shell, document: document)
        }
        // Navigator drops insert at the drop position.
        shell.onNavigatorDropFiles = { [weak self, weak document] urls, index in
            guard let self, let document else { return false }
            return self.handleNavigatorDrop(urls: urls, insertionIndex: index, document: document)
        }
        // Layer toggles re-render this document's canvas (gap 10).
        document.onLayerRenderingChange = { [weak self, weak document] filtering in
            guard let self, let document else { return }
            self.contents[document.documentIdentity]?.canvas.setLayerFiltering(filtering)
        }
        // The page's extracted linework becomes the canvas's vector underlay: a sharp
        // skeleton under the page while a new raster is in flight.
        document.onVectorUnderlayReady = { [weak self, weak document] page, extraction in
            guard let self, let document else { return }
            self.contents[document.documentIdentity]?.canvas
                .prepareVectorUnderlay(page: page, extraction: extraction)
        }
        // The tab strip drives the window, not the presenter's local list — except while
        // this document's Split Canvas is up, where the empty pane's own instruction is
        // "pick one from the document tabs": a click then fills a pane instead of silently
        // tearing the split down and navigating the single canvas (LT-25).
        shell.tabBar.onSelect = { [weak self, weak document] id in
            guard let self else { return }
            if let document, self.fillSplitPane(withTab: id, for: document) { return }
            self.activateTab(id: id)
        }
        shell.tabBar.onClose = { [weak self] id in self?.requestCloseTab(id: id) }
        shell.tabBar.onNewTab = { NSDocumentController.shared.openDocument(nil) }

        // The layout store is named explicitly rather than left to
        // `ProjectWindowLayoutController`'s default, which is `ProjectWindowLayoutStore()`,
        // which is `UserDefaults.standard`. That default put *product* code inside the user's
        // real preference domain from every app-tier test that opened a window, so a run's
        // split proportions, collapsed panes and detached ledger were inherited by the next one
        // — a test-state leak, in shipping code. ``ZenitProcessDefaults/layout`` is the
        // real domain in the assembled bundle and a self-emptying scratch suite everywhere
        // else, decided structurally by the bundle identifier rather than by an opt-in.
        let controller = ProjectWindowLayoutController(
            environment: shell,
            // `.firstLaunch`: with nothing stored, the Quantity Ledger opens as its bar, as the
            // default design has it; a stored layout is restored exactly as before.
            // A second window on the document keeps its own layout (NL-UX-20).
            store: ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout).withFallback(.firstLaunch)
                .keyed(layoutStoreKey(for: document)),
            canvasProvider: { canvas }
        )
        // ADR-0030 §5.7, §5.8 (K-02): the window leaves a tool key to the canvas by the canvas's
        // own rule — every tool key during a pick, a typed length or a shape a switch would lose.
        controller.canvasOwnsToolKey = { [weak canvas] characters, modifiers in
            canvas?.ownsToolKey(characters: characters, modifiers: modifiers) ?? false
        }
        shell.externalCommandHandler = { [weak self, weak document] command in
            guard let self, let document else { return }
            self.perform(external: command, for: document)
        }
        contents[document.documentIdentity] = DocumentContent(
            layout: controller,
            canvas: canvas,
            undoFeed: CanvasUndoStateFeed(undoManager: document.undoManager, state: shell.canvasUndoState)
        )
        // The first-run author question, as a sheet over the drawing it will sign, one turn
        // after the drawing is on screen (IM-160).
        DispatchQueue.main.async { [weak self] in
            AuthorNamePrompt.presentIfNeeded(on: self?.window)
        }
    }

    /// Puts one document's content on screen, keeping the window frame it already has.
    func present(content: DocumentContent) {
        guard contentViewController !== content.layout else { return }
        // The navigator reads as ONE pane across tabs, so a tab switch must never yank its
        // section out from under the person. Each tab's layout restores its own persisted
        // section when it is first built — which is how clicking a drawing in the Files list
        // landed the newly fronted tab on the Search page (found live, 2026-08-29).
        // The outgoing tab's visible section wins, always.
        if let outgoing = contentViewController as? ProjectWindowLayoutController {
            content.layout.panelState.navigatorSection = outgoing.panelState.navigatorSection
        }
        // Assigning `contentViewController` resizes the window to the new content's fitting
        // size — which is the panes' minimums, a 788 pt sliver, not a workspace. Keep the
        // frame the window already has; `configure` then restores the user's autosaved one.
        let frameBeforeInstall = window?.frame
        contentViewController = content.layout
        placeholderController = nil
        if let window {
            if let frameBeforeInstall { window.setFrame(frameBeforeInstall, display: false) }
            content.layout.configure(window: window)
        }
    }

    private var subtitle: String {
        switch activeDocument?.mode {
        case .project:
            // NL-COLLAB-12 (r2-platform): who else is reviewing, and on which sheet.
            if let document = activeDocument, let presence = SharedReviewAutoSync.presenceText(for: document) {
                return DocumentOpenMode.project.displayName + " · " + presence
            }
            return DocumentOpenMode.project.displayName
        case .quickPDF: return DocumentOpenMode.standalonePDF.displayName
        case nil: return ""
        }
    }

    /// A drawing that failed to open gets the repair offer: repair a *copy*
    /// through the sandboxed `RepairService`, never touch the original. Anything that is
    /// not a repairable PDF keeps the plain error.
    private func presentLoadFailure(_ error: any Error, for document: ZenitPDFProjectDocument?) {
        guard let window else { return }
        // LT-38: a refused password — cancelled or wrong — fails the open in words and
        // then really fails it: the tab is closed rather than left as a blank sheet that
        // reads as an empty drawing. Neither refusal is damage, so no repair offer.
        switch error {
        case ZenitDocumentError.passwordRequired, ZenitDocumentError.wrongPassword:
            presentErrorClosingFailed(error, document: document)
            return
        default:
            break
        }
        guard let document, let source = document.fileURL else {
            // A failed document must not stay as the active tab with no content: title,
            // undo, menus and Escape would serve it while the previous drawing stays
            // visible (CR-151).
            presentErrorClosingFailed(error, document: document)
            return
        }
        switch ZenitPDFProjectDocument.diagnoseLoadFailure(for: source, error: error) {
        case .unreadable:
            presentUnreadableDrawing(source: source, failed: document)
            return
        case .damaged:
            break
        case .plain:
            presentErrorClosingFailed(error, document: document)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "“%@” is damaged and cannot be opened as it is.",
                comment: "Alert title when a PDF fails to parse; the file name"
            ),
            source.lastPathComponent
        )
        alert.informativeText = NSLocalizedString(
            "Zenit PDF can rebuild a repaired copy and open that instead. The original file is not touched.",
            comment: "Alert detail offering to repair a copy of a damaged PDF"
        )
        alert.addButton(withTitle: NSLocalizedString("Repair a Copy…", comment: "Alert button: repair a damaged PDF into a copy"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        ZenitModalPresenter.runAlert(
            alert,
            identifier: Self.damagedDrawingModalIdentifier,
            sheetedOn: window,
            answerWithoutAUser: .dismissed
        ) { [weak self, weak document] answer in
            guard answer == .button(0) else {
                // Cancel keeps nothing: the tab with no content goes (CR-151).
                if let self, let document { self.closeFailedDocument(document) }
                return
            }
            self?.repairAndReopen(source: source, failed: document)
        }
    }

    /// Says why an open failed, and closes the failed document — in the order that keeps the
    /// words on screen.
    ///
    /// When the failed drawing is the window's only document, closing it takes the window
    /// down, and an error sheeted on that window a line earlier went with it: LT-38's "fails
    /// the open in words" was never readable (BH-370). Close first, then present — on the
    /// window when it survives, application-modal when it does not.
    func presentErrorClosingFailed(_ error: any Error, document: ZenitPDFProjectDocument?) {
        let windowSurvives = document.map { failed in documents.contains { $0 !== failed } } ?? true
        let host = windowSurvives ? window : nil
        if let document { closeFailedDocument(document) }
        ZenitErrorPresenter.present(error, in: host)
    }

    /// Closes a document whose load was refused, whether it joined this window as a tab
    /// or still owns the controller alone — the same teardown the repair and grant-access
    /// flows use for the tab they replace.
    private func closeFailedDocument(_ document: ZenitPDFProjectDocument) {
        if documents.contains(where: { $0 === document }) {
            finalizeClose(of: document)
        } else {
            document.close()
        }
    }

    /// The 12.6 half of the load-failure story: the file is fine, this process simply
    /// may not read it. The offer is an open panel aimed at the file — selecting it
    /// grants the sandbox extension — and the drawing then opens normally. No talk of
    /// damage, no repair of a file that cannot even be read.
    private func presentUnreadableDrawing(source: URL, failed document: ZenitPDFProjectDocument?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "Zenit PDF does not have permission to read “%@”.",
                comment: "Alert title when a PDF exists but cannot be read; the file name"
            ),
            source.lastPathComponent
        )
        alert.informativeText = NSLocalizedString(
            "The file itself looks fine. Choose Grant Access and select the drawing to let Zenit PDF read it.",
            comment: "Alert detail offering to grant read access to an unreadable PDF"
        )
        alert.addButton(withTitle: NSLocalizedString("Grant Access…", comment: "Alert button: open a panel to grant read access"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        ZenitModalPresenter.runAlert(
            alert,
            identifier: Self.unreadableDrawingModalIdentifier,
            sheetedOn: window,
            answerWithoutAUser: .dismissed
        ) { [weak self, weak document] answer in
            guard answer == .button(0) else {
                // Cancel, or nobody there to answer: the tab with no content goes (BH-371).
                if let self, let document { self.closeFailedDocument(document) }
                return
            }
            self?.grantAccessAndReopen(source: source, failed: document)
        }
    }

    /// Runs the open panel that carries the grant, then reopens the drawing through the
    /// ordinary drop path and closes the failed tab.
    private func grantAccessAndReopen(source: URL, failed document: ZenitPDFProjectDocument?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.message = String(
            format: NSLocalizedString(
                "Select “%@” to grant Zenit PDF permission to read it.",
                comment: "Open panel message when granting access to an unreadable PDF; the file name"
            ),
            source.lastPathComponent
        )
        ZenitModalPresenter.runOpenPanel(
            panel,
            identifier: Self.grantAccessModalIdentifier,
            sheetedOn: window
        ) { [weak self, weak document] answer in
            guard let granted = answer.firstURL else {
                // The panel was cancelled: nothing reopens, so the dead tab goes (BH-371).
                if let self, let document { self.closeFailedDocument(document) }
                return
            }
            DroppedFileBookmarks.remember(granted, defaults: ZenitProcessDefaults.bookmarks)
            // The failed document is closed FIRST. It is still registered with the document
            // controller under the very URL just granted, so opening before closing found it,
            // merely showed its window, and then closed it: the grant flow could never
            // reopen anything (BH-076).
            if let document, let self {
                self.closeFailedDocument(document)
            } else {
                document?.close()
            }
            Self.openDropped(urls: [granted])
        }
    }

    /// Runs the repair, opens the repaired copy, and closes the failed tab.
    private func repairAndReopen(source: URL, failed document: ZenitPDFProjectDocument?) {
        Task { @MainActor [weak self] in
            do {
                let repaired = try await ZenitPDFProjectDocument.repairCopy(of: source)
                Self.openDropped(urls: [repaired])
                if let document, let self {
                    if self.documents.contains(where: { $0 === document }) {
                        self.finalizeClose(of: document)
                    } else {
                        document.close()
                    }
                }
            } catch {
                // The repair failed: say so, and do not keep the dead tab (BH-371).
                if let self {
                    self.presentErrorClosingFailed(error, document: document)
                } else {
                    ZenitErrorPresenter.present(error, in: nil)
                }
            }
        }
    }

    // MARK: - Canvas view modes

    /// True while the panes are being filled *from* the document, so the pane-change hook does
    /// not immediately push the document's own state back at it.
    private var isFillingCanvasPanes = false

    /// Watches the shell's canvas-mode coordinator and fills the mode's panes when one opens.
    ///
    /// Observation rather than a call after `shell.perform(_:)`, deliberately. Split Canvas can
    /// be entered from the menu, from the command table and from inside the shell itself, and a
    /// fill hung off one of those routes is a fill the other two skip — which is the exact shape
    /// of the defect this closes. `withObservationTracking` fires once and has to be re-armed,
    /// which is what the continuation does; the read inside the `apply` block is what registers
    /// the dependency and is not dead code. The work is deferred onto the main actor so it runs
    /// *after* `enterCanvasMode` has finished building the mode, not half way through it.
    private func observeCanvasModes(
        shell: ProjectShellEnvironment,
        document: ZenitPDFProjectDocument
    ) {
        withObservationTracking {
            _ = shell.canvasModes.activeMode
        } onChange: { [weak self, weak shell, weak document] in
            Task { @MainActor [weak self, weak shell, weak document] in
                guard let self, let shell, let document else { return }
                self.fillCanvasMode(shell: shell, document: document)
                self.observeCanvasModes(shell: shell, document: document)
            }
        }
    }

    /// Gives the active canvas view mode real content.
    ///
    /// Both modes are filled here now. Revision Overlay used to be the exception — a labelled
    /// placeholder, deliberately, because a compositor that
    /// can stack two rasterised sheets under a hand-built alignment did not exist. It does:
    /// ``RevisionOverlayCompositing`` drives the compare engine's ``OverlayCompositor`` through
    /// the same comparator, and therefore the same out-of-process page raster, that Revision
    /// Compare runs on.
    ///
    /// Leaving is handled by the same `onLeaveCanvasMode` hook Split Canvas uses, so Escape
    /// restores the zoom and scroll position the mode was entered from.
    func fillCanvasMode(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        switch shell.canvasModes.activeMode {
        case .splitCanvas:
            overlayCompositors[document.documentIdentity]?.detach()
            overlayCompositors[document.documentIdentity] = nil
            fillSplitCanvasPanes(shell: shell, document: document)
        case .revisionOverlay:
            // Split Canvas has ended: its detached panes come back with it (S-022).
            closePaneWindows(of: shell.splitCanvas)
            fillRevisionOverlay(shell: shell, document: document)
        case .revisionCompare, .none:
            closePaneWindows(of: shell.splitCanvas)
            overlayCompositors[document.documentIdentity]?.detach()
            overlayCompositors[document.documentIdentity] = nil
        }
    }

    /// The live compositor behind each document's Revision Overlay, while that mode is open.
    private var overlayCompositors: [UUID: RevisionOverlayCompositing] = [:]

    /// Stacks the document's revisions into the overlay pane.
    ///
    /// The revision list is discovered asynchronously — the baseline has to be opened through
    /// the compare provider before it is a revision at all — so the shell's model is seeded
    /// again here rather than only in `enterCanvasMode`, which runs before any of that can have
    /// happened. `setRevisions` keeps every colour and opacity the person has already chosen.
    ///
    /// A single-revision document is not an error and is not a dead end: the pane says how many
    /// revisions there are and how to add another, which is the no-dead-ends rule applied
    /// to an empty state rather than to a modal.
    private func fillRevisionOverlay(
        shell: ProjectShellEnvironment,
        document: ZenitPDFProjectDocument
    ) {
        let identity = document.documentIdentity
        overlayCompositors[identity]?.detach()
        overlayCompositors[identity] = nil

        guard let comparator = document.revisionComparator else { return }
        let model = shell.revisionOverlay
        let compositor = RevisionOverlayCompositing(
            producer: ComparatorOverlayProducer(
                comparator: comparator,
                // The sheet on screen now in *this* window, for every revision (BH-386, T-011).
                pages: { [weak self, weak document] in
                    guard let self, let document else { return [:] }
                    return self.overlayPages(for: document)
                },
                // Counted without pairing, so a count never posts a pairing warning (U-014).
                registeredIDs: { [weak document] in
                    Set(document?.revisionPages.keys.map { $0 } ?? [])
                }
            ),
            model: model,
            requestedScale: { [weak self, weak document] in
                self?.overlayRequestedScale(for: document) ?? 2
            }
        )
        overlayCompositors[identity] = compositor
        // L-57: the pane adds a revision itself — the file panel, then the new layer stacked —
        // rather than leaving the ⌥ drop from Finder as the only way in.
        model.onAddRevision = { [weak self, weak document] in
            guard let self, let document else { return }
            AddRevisionCommand.choose(document: document, sheetedOn: self.window) { [weak self, weak document] added in
                guard added, let self, let document,
                      let shell = self.windowShell(for: document) ?? document.shell,
                      shell.canvasModes.activeMode == .revisionOverlay else { return }
                shell.revisionOverlay.setRevisions(document.comparePresenter?.revisions ?? [])
                self.overlayCompositors[document.documentIdentity]?.requestComposite(immediately: true)
            }
        }

        Task { @MainActor [weak self, weak document, weak shell] in
            guard let document, let shell else { return }
            var baselineFailed = false
            do {
                try await document.registerCurrentDrawingAsBaseline()
            } catch {
                // Not fatal, and not silent: the pane reports the real cause, and attach below
                // keeps it on the pane rather than overwriting it with "there is 0" (BH-906).
                model.setCompositeStatus(.failed(RevisionOverlayEngine.sentence(for: error)))
                baselineFailed = true
            }
            guard shell.canvasModes.activeMode == .revisionOverlay else { return }
            model.setRevisions(document.comparePresenter?.revisions ?? [])
            self?.overlayCompositors[document.documentIdentity]?.attach(composeNow: !baselineFailed)
            self?.observeOverlayViewport(document: document)
        }
    }

    /// Recomposes the overlay when this window's canvas turns the page or zooms (BH-386,
    /// T-011), for as long as the document's compositor exists.
    private func observeOverlayViewport(document: ZenitPDFProjectDocument) {
        guard let core = windowCore(for: document), overlayCompositors[document.documentIdentity] != nil else { return }
        withObservationTracking {
            _ = core.document.currentPageID
            _ = core.canvas.viewport.zoom
        } onChange: { [weak self, weak document] in
            Task { @MainActor [weak self, weak document] in
                guard let self, let document,
                      let compositor = self.overlayCompositors[document.documentIdentity] else { return }
                compositor.viewportDidChange()
                self.observeOverlayViewport(document: document)
            }
        }
    }

    /// Pixels per PDF point the overlay should aim for: what the canvas is showing, at the
    /// resolution the display actually has. The plan reduces it when the whole sheet at that
    /// scale would not fit the pixel budget, and the pane states the reduction.
    func overlayRequestedScale(for document: ZenitPDFProjectDocument?) -> Double {
        // This window's zoom (T-011), not the focused window's.
        let zoom = Double(document.flatMap(windowCore(for:))?.canvas.viewport.zoom ?? 1)
        let backing = Double(window?.screen?.backingScaleFactor ?? window?.backingScaleFactor ?? 2)
        return max(0.05, zoom * max(1, backing))
    }

    /// Puts the real document, page, zoom and scroll position into the Split Canvas panes.
    ///
    /// Pane 1 is always what the canvas is showing right now. Pane 2 is the next thing a person
    /// opening Split Canvas plausibly wants beside it: another open drawing if one is open,
    /// otherwise the next page of this one. When there is neither — a single one-page drawing —
    /// the pane is left empty and the layout stays at one canvas, because two panes where one of
    /// them can only ever say "Empty pane" is worse than not splitting.
    private func fillSplitCanvasPanes(
        shell: ProjectShellEnvironment,
        document: ZenitPDFProjectDocument
    ) {
        guard let core = document.core else { return }
        let split = shell.splitCanvas
        isFillingCanvasPanes = true
        defer { isFillingCanvasPanes = false }

        let viewport = core.canvas.viewport
        let pages = core.document.pages
        let currentPage = pages.first { $0.id == viewport.pageID } ?? pages.first
        split.setContent(
            documentID: document.documentIdentity,
            documentTitle: paneTitle(of: document),
            page: currentPage,
            in: .first
        )
        split.setZoom(viewport.zoom, in: .first)
        split.setScrollOffset(
            PDFPointValue(x: viewport.visiblePageRect.minX, y: viewport.visiblePageRect.minY),
            in: .first
        )

        let otherDocument = documents.first { $0 !== document && $0.core != nil }
        if let otherDocument, let otherCore = otherDocument.core {
            let otherViewport = otherCore.canvas.viewport
            let otherPages = otherCore.document.pages
            split.setContent(
                documentID: otherDocument.documentIdentity,
                documentTitle: paneTitle(of: otherDocument),
                page: otherPages.first { $0.id == otherViewport.pageID } ?? otherPages.first,
                in: .second
            )
            split.setZoom(otherViewport.zoom, in: .second)
            split.setLayout(.twoColumns)
        } else if let currentPage, let next = pages.first(where: { $0.index == currentPage.index + 1 }) {
            split.setContent(
                documentID: document.documentIdentity,
                documentTitle: paneTitle(of: document),
                page: next,
                in: .second
            )
            split.setZoom(viewport.zoom, in: .second)
            split.setLayout(.twoColumns)
        } else {
            split.clearPane(.second)
            split.setLayout(.single)
        }
    }

    /// The render source behind one Split Canvas pane: the pane's page box and a region
    /// renderer aimed at the pane's own document — resolved **by identity** against the
    /// live tab set, so a pane showing another open drawing renders that drawing (LT-24).
    /// `nil` for an empty pane, or one whose document has since closed; the shell then
    /// draws its labelled placeholder, which is the honest state for either.
    func splitPaneRenderSource(for pane: SplitCanvasPaneState) -> SplitPaneRenderSource? {
        guard let documentID = pane.documentID,
              let pageID = pane.pageID,
              let target = documents.first(where: { $0.documentIdentity == documentID }),
              let core = target.core,
              // The pane's sheet renders from its own drawing (NL-DOCS-04).
              let rasterSource = target.loadedDrawing(forPage: pageID)?.rasterSource,
              let page = core.document.pages.first(where: { $0.id == pageID })
        else { return nil }
        let pageIndex = page.index
        let viewRotation = page.viewRotation
        return SplitPaneRenderSource(
            // The sheet's view, turned and cropped as on the canvas and in the Navigator
            // (NL-DOCS-07/16, T-003).
            pageBox: page.viewBox,
            rotation: page.displayRotation,
            identity: "\(documentID.uuidString)|\(pageID.uuidString)",
            render: { region, pixelsPerPoint in
                try? await rasterSource.renderRegion(
                    pageIndex: pageIndex,
                    region: PDFRect(
                        x: region.minX,
                        y: region.minY,
                        width: region.size.width,
                        height: region.size.height
                    ),
                    pixelsPerPoint: pixelsPerPoint,
                    viewRotation: viewRotation
                )
            }
        )
    }

    /// Routes a document-tab click into the Split Canvas while the split is up (LT-25).
    ///
    /// The receiving pane is the first **empty** visible pane — the one whose card says
    /// "pick one from the document tabs" — or the **focused** pane when every visible pane
    /// is full, and it becomes the focused pane so the next click knows where it went.
    /// Returns `false` when this document's split is not up, or when the clicked tab has
    /// no content to show yet; the click then means what it always meant: activate the tab.
    @discardableResult
    func fillSplitPane(withTab clickedID: UUID, for document: ZenitPDFProjectDocument) -> Bool {
        guard let shell = document.shell,
              shell.canvasModes.activeMode == .splitCanvas else { return false }
        guard let target = documents.first(where: { $0.documentIdentity == clickedID }),
              let core = target.core else { return false }
        let split = shell.splitCanvas
        let paneID = split.visiblePanes.first(where: \.isEmpty)?.id ?? split.focusedPaneID
        let viewport = core.canvas.viewport
        let pages = core.document.pages
        let page = pages.first { $0.id == viewport.pageID } ?? pages.first
        isFillingCanvasPanes = true
        split.setContent(
            documentID: target.documentIdentity,
            documentTitle: paneTitle(of: target),
            page: page,
            in: paneID
        )
        split.setZoom(viewport.zoom, in: paneID)
        split.setScrollOffset(
            PDFPointValue(x: viewport.visiblePageRect.minX, y: viewport.visiblePageRect.minY),
            in: paneID
        )
        isFillingCanvasPanes = false
        split.focusPane(paneID)
        return true
    }

    /// The name a pane header shows for a document.
    private func paneTitle(of document: ZenitPDFProjectDocument) -> String {
        document.displayName
            ?? document.drawing?.url.deletingPathExtension().lastPathComponent
            ?? NSLocalizedString("Untitled", comment: "Split Canvas pane header for an unsaved document")
    }

    /// Moves the real canvas behind a pane that changed.
    ///
    /// Only the *focused* pane drives a canvas: the followers are already being moved by the
    /// controller's own synchronisation, and letting each of them drive back would be the
    /// feedback loop `SplitCanvasController` documents itself as not having.
    private func applySplitCanvasPane(
        _ pane: SplitCanvasPaneState,
        shell: ProjectShellEnvironment,
        document: ZenitPDFProjectDocument
    ) {
        guard !isFillingCanvasPanes, shell.splitCanvas.focusedPaneID == pane.id else { return }
        guard let documentID = pane.documentID,
              let target = documents.first(where: { $0.documentIdentity == documentID }),
              let core = target.core else { return }
        if let pageID = pane.pageID, core.canvas.viewport.pageID != pageID {
            core.document.goToPage(id: pageID)
        }
        let size = core.canvas.viewport.visiblePageRect.size
        guard let canvas = contents[documentID]?.canvas else {
            core.canvas.setZoom(pane.zoom)
            return
        }
        canvas.restore(
            zoom: pane.zoom,
            visiblePageRect: PDFRectValue(
                x: pane.scrollOffset.x,
                y: pane.scrollOffset.y,
                width: size.width,
                height: size.height
            )
        )
    }

    // MARK: - Command routing

    /// The menu bar's action for every command that is not a standard AppKit selector.
    public func performZenitCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        focusThisWindow()
        if let appCommand = ZenitAppCommand(rawValue: raw) {
            perform(app: appCommand)
            return
        }
        guard let command = ZPDFCommandID(rawValue: raw) else { return }
        guard let activeDocument else { return }
        performShell(command, for: activeDocument)
    }

    /// NL-UX-20: the document's ``ZenitPDFProjectDocument/core`` and ``ZenitPDFProjectDocument/shell``
    /// answer for this window from here on — a command routed through this window acts on this
    /// window's page, selection and armed tool. Key and main status do the same; this covers the
    /// entry points too, so routing never depends on which window AppKit last made key.
    func focusThisWindow(on document: ZenitPDFProjectDocument? = nil) {
        guard let document = document ?? activeDocument else { return }
        document.focusedWindowView = windowViews[document.documentIdentity]
    }

    /// Runs a shell command against one document, waiting first for any in-flight vertex
    /// placement.
    ///
    /// `placePoint` is asynchronous, because the snap resolve it performs is. Pressing Return the
    /// instant after the last click would otherwise reach `commitActiveMeasurement()` while the
    /// point list is still one short, and the commit would be silently refused — the measurement
    /// would simply not appear, with nothing on screen to explain why.
    private func performShell(_ command: ZPDFCommandID, for document: ZenitPDFProjectDocument) {
        // Close needs no shell: a tab stuck loading has none, and the enabled Close that did
        // nothing was the dead end its own validation rules out (BH-372).
        if command == .closeTab, document.shell == nil {
            requestCloseTab(id: document.documentIdentity)
            return
        }
        guard let shell = document.shell else { return }
        guard command == .finishGeometry || command == .removeLastVertex,
              let measurement = document.core?.measurement else {
            shell.perform(command)
            return
        }
        // The fence is taken synchronously, in the key handler's turn: everything placed
        // up to this instant is what Finish acts on, and clicks that land while the snap
        // queue drains belong to the NEXT measurement. Without it the settle wait swept
        // after-Return clicks into the old polygon and then discarded them (LT-6: four
        // fast clicks after Return placed nothing).
        let fence = measurement.beginCommitFence()
        Task { @MainActor in
            await measurement.settleCommitFence(fence)
            shell.perform(command)
            measurement.releaseCommitFence(fence)
            // No updateChangeCount here: a commit that actually lands travels the command
            // bus, which already dirties the document. Marking unconditionally flipped the
            // tab to "• Edited" on a REFUSED finish and on remove-last-vertex, neither of
            // which changed the document (LT-34's edited-without-a-row half).
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        focusThisWindow()
        if menuItem.action == #selector(undo(_:)) {
            return activeDocument?.undoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redo(_:)) {
            return activeDocument?.undoManager?.canRedo ?? false
        }
        guard let raw = menuItem.representedObject as? String else { return true }
        // A pane toggle's title flips with the pane's state, so the View
        // menu answers "how do I get it back" with the sentence *Show Inspector* at exactly the
        // moment somebody goes looking. Done here rather than at build time because the menu is
        // built once per launch and the panes move all day.
        if let command = ZPDFCommandID(rawValue: raw),
           let surface = ZPDFClosableSurface(command: command) {
            let shell = activeDocument?.shell
            menuItem.title = surface.menuTitle(isVisible: shell?.isSurfaceVisible(surface) ?? false)
        }
        // The doors that park the main thread on the document activity stay shut while a
        // save runs (CR-147); the row says so before anybody reaches the spoken refusal.
        if let busy = activeDocument?.isSaveActivityBusy, busy,
           let command = ZPDFCommandID(rawValue: raw), [.save, .saveAs, .print].contains(command) {
            return false
        }
        // Application commands answer from their table (IM-183): enablement, the save-activity
        // door and the Lock/Unlock title all live in the command's one entry.
        if let appCommand = ZenitAppCommand(rawValue: raw) {
            return ZenitAppCommandTable.validate(
                appCommand,
                item: menuItem,
                state: ZenitAppCommandWindowState(controller: self)
            )
        }
        guard let command = ZPDFCommandID(rawValue: raw) else { return true }
        // Overlay/mode toggles carry a checkmark, or the person cannot tell whether the
        // second press turns the thing on or off. Coverage Map shipped with no state at
        // all — activating it changed nothing visible in the menu (LT-12, 2026-08-29).
        switch command {
        case .toggleCoverageMap, .splitCanvas, .revisionOverlay:
            menuItem.state = (activeDocument?.shell?.isPanelOpen(command) ?? false) ? .on : .off
        default:
            break
        }
        switch command {
        case .closeTab:
            // Close is available the moment a tab exists, loaded or not — a stuck load
            // with a disabled Close is a dead end.
            return activeDocument != nil
        case .finishGeometry:
            return activeDocument?.core?.measurement.canCommit ?? false
        case .removeLastVertex:
            return !(activeDocument?.core?.measurement.placedPoints.isEmpty ?? true)
        case .cancelTool:
            // What Escape treats as cancellable: an armed tool of either family, with or
            // without a vertex placed. The row was disabled over an armed empty tool or a
            // half-drawn callout (BH-907).
            guard let core = activeDocument?.core else { return false }
            return core.measurement.activeKind != nil
                || core.markup.activeKind != nil
                || !core.measurement.placedPoints.isEmpty
        case .export:
            return !(activeDocument?.core?.ledger.isEmpty ?? true)
        case .zoomToSelection:
            return !(activeDocument?.core?.canvas.selectedMarkupIDs.isEmpty ?? true)
        default:
            return activeDocument?.shell != nil
        }
    }

    /// Commands the shell forwards because they are not the window's to service.
    private func perform(external command: ZPDFCommandID, for document: ZenitPDFProjectDocument) {
        switch command {
        case .openDocument:
            NSDocumentController.shared.openDocument(nil)
        case .save:
            document.save(nil)
        case .saveAs:
            document.saveAs(nil)
        case .print:
            document.printDocument(nil)
        case .closeTab:
            requestCloseTab(id: document.documentIdentity)
        case .export:
            exportLedger(for: document)
        case .undo:
            document.undoManager?.undo()
        case .redo:
            document.undoManager?.redo()
        case .selectAll:
            selectAllMarkups(in: document)
        case .deleteSelection:
            deleteSelection(in: document)
        case .zoomToSelection:
            contents[document.documentIdentity]?.canvas.zoomToSelection()
        case .toolLibrary:
            // Opening reveals the Layers page as before; a second press closes the panel
            // (nl-ux) and leaves the Navigator where it is.
            if (document.shell?.modeRegistry ?? modeRegistry).exitRoute(for: WorkflowPanelKind.toolLibrary.id) == nil {
                contents[document.documentIdentity]?.layout.revealNavigatorSection(.layers)
            }
            presentToolLibrary(for: document)
        case .revisionCompare:
            presentRevisionCompare(for: document)
        case .cycleSnapCandidate:
            cycleSnapCandidate(in: document)
        case .calibrateScale:
            // The toolbar's Calibrate arms the shell tool and forwards here; without this
            // case the button highlighted but no click was ever collected (the menu path
            // worked, the toolbar path fell through `default`).
            beginPageCalibration(for: document)
        default:
            break
        }
    }

    private func perform(app command: ZenitAppCommand) {
        // The table says what each command does and whether it needs a document in front:
        // Import Zenit JSON is the one that runs with nothing open (IM-183).
        ZenitAppCommandTable.perform(command, controller: self, document: activeDocument)
    }

    /// Whether every selected markup is locked.
    static func selectionIsLocked(_ core: AppCoreEnvironment) -> Bool {
        let selected = core.canvas.selectedMarkupIDs
        let markups = core.snapshot.markups.filter { selected.contains($0.id) }
        return !markups.isEmpty && markups.allSatisfy(\.locked)
    }

    /// Locks/unlocks or hides the selection through the bus: one undo step each (IM-023).
    func applyLockOrHide(for document: ZenitPDFProjectDocument, lock: Bool? = nil, hide: Bool? = nil) {
        guard let core = document.core else { return }
        let ids = core.canvas.selectedMarkupIDs
        guard !ids.isEmpty else { return }
        // The one implementation the Inspector header's switches run too (R-041).
        Task { @MainActor in
            await ZenitPDFProjectDocument.performLockHide(ids: ids, lock: lock, hide: hide, core: core)
        }
    }

    /// Shows every hidden markup, as one undo step.
    func showHiddenMarkups(in document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let ids = core.snapshot.markups.filter(\.hidden).map { MarkupID($0.id) }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await core.commands.perform(.setHidden(ids: ids, hidden: false))
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }

    /// Fronts the tab `offset` places from the one in front, wrapping at either end (IM-182).
    public func activateAdjacentTab(offset: Int) {
        guard documents.count > 1 else { return }
        let current = documents.firstIndex { $0 === activeDocument } ?? 0
        let count = documents.count
        let next = ((current + offset) % count + count) % count
        activateTab(id: documents[next].documentIdentity)
    }

    /// A Window-menu tab row.
    @objc func activateTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        activateTab(id: id)
    }

    // MARK: - Document commands

    private func selectAllMarkups(in document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        core.canvas.select(markupIDs: Set(core.canvas.visibleMarkups.map(\.id)), additive: false)
    }

    private func deleteSelection(in document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        // A focused vertex of the selected markup goes first (NL-MEASURE-06).
        if contents[document.documentIdentity]?.canvas.removeFocusedVertex() == true { return }
        let selected = core.canvas.selectedMarkupIDs
        guard !selected.isEmpty else { return }
        // Cleared *now*, not when the task finishes: a key-repeat or a second Delete read the
        // same IDs, re-deleted markups that were already gone and reported a false refusal
        // (BH-908). A refusal puts the selection back so the person sees what stayed.
        core.canvas.clearSelection()
        Task { @MainActor in
            do {
                // One batch: one ⌘Z brings back everything one Delete removed, one refresh,
                // and a refusal applies nothing (IM-051, BH-373). The command bus registers the
                // undo, and the document counts that change itself — an explicit changeDone on
                // top left the tab edited after ⌘Z back to clean (BH-375).
                try await core.commands.performBatch(
                    Self.deleteCommands(for: selected, parents: CarriedCutouts.parents(in: core.snapshot.markups)),
                    actionName: selected.count == 1
                        ? NSLocalizedString("Delete Markup", comment: "Undo action name for deleting one markup")
                        : String(
                            format: NSLocalizedString(
                                "Delete %d Markups",
                                comment: "Undo action name for deleting several markups"
                            ),
                            selected.count
                        )
                )
            } catch {
                // Said, not swallowed — and the selection comes back, so the person can see
                // what was refused (CR-156).
                core.canvas.select(markupIDs: selected, additive: false)
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
    }

    /// The batch a Delete of `selected` performs, in a stable order. A cutout whose parent is
    /// also selected is left out: removing the parent removes it, and its own command then threw
    /// `unknownMarkup` and rolled the whole Delete back whenever the parent's UUID sorted first
    /// (X-003). `parents` maps each cutout to its parent.
    static func deleteCommands(for selected: Set<UUID>, parents: [UUID: UUID]) -> [DocumentCommand] {
        CarriedCutouts.roots(of: selected.sorted { $0.uuidString < $1.uuidString }) { parents[$0] }
            .map { .removeMarkup(MarkupID($0)) }
    }

    /// The forwarded Cycle Snap Candidate command: the canvas's one implementation (V-071).
    private func cycleSnapCandidate(in document: ZenitPDFProjectDocument) {
        contents[document.documentIdentity]?.canvas.cycleSnapCandidate(forward: true)
    }

    /// Edit ▸ Undo.
    ///
    /// `undo:` and `redo:` are not implemented by any AppKit class between the canvas and
    /// `NSApplication`, so a document application has to answer them itself. `NSTextView` answers
    /// first while a field is editing, which is what keeps text undo separate from takeoff undo.
    @objc func undo(_ sender: Any?) {
        focusThisWindow()
        activeDocument?.undoManager?.undo()
        refreshAfterUndoRedo()
    }

    /// Edit ▸ Redo.
    @objc func redo(_ sender: Any?) {
        focusThisWindow()
        activeDocument?.undoManager?.redo()
        refreshAfterUndoRedo()
    }

    private func refreshAfterUndoRedo() {
        guard let document = activeDocument, let core = document.core else { return }
        let canvas = contents[document.documentIdentity]?.canvas
        Task { @MainActor in
            // The bus's revert already publishes `.everything`, which refreshes the snapshot;
            // a second `core.refresh()` here rebuilt the whole snapshot again per ⌘Z (IM-252).
            await core.commands.settle()
            canvas?.refresh()
        }
    }

    // MARK: - Calibration

    /// Measure ▸ Calibrate Scale… and the toolbar's Calibrate: the page's default scale.
    /// A destination left behind by an abandoned Scale Regions calibration must not
    /// redirect this one (CR-149); the panel's own path sets its target and then calls
    /// `beginCalibration()` directly.
    func beginPageCalibration(for document: ZenitPDFProjectDocument) {
        document.pendingScaleCalibration = nil
        // This calibration's points are the page's, never a pick left armed (R-001).
        PendingPointPicks.disarmAll(document)
        beginCalibration(for: document)
    }

    func beginCalibration(for document: ZenitPDFProjectDocument) {
        guard let canvas = contents[document.documentIdentity]?.canvas else { return }
        // LT3-06: Measure ▸ Calibrate Scale… (⌥⌘K) and the Scale Regions flow reach here without
        // passing the toolbar, so the chip of the tool armed before — Area, say — stayed lit
        // beside a canvas that was calibrating. The toolbar path armed Calibrate first; every
        // path does now. `arm` ignores a repeat, so the toolbar path is unchanged.
        document.shell?.toolbar.selectTool(.calibrate)
        canvas.beginCalibration()
        document.core?.status.dismissAllWarnings()
    }

    func finishCalibration(points: [PDFPointValue], for document: ZenitPDFProjectDocument) {
        // The points belong to the calibration sheet (NL-MEASURE-01): either the sheet stepped
        // aside for them ("Pick points"), or the toolbar's Calibrate collected them first and
        // the sheet opens with the line filled in. The known-length alert is gone.
        if VerifyScale.isArmed(document) {
            VerifyScale.finish(points: points, document: document, window: window)
            return
        }
        if AreaSplitFlow.isArmed(document) {
            Task { @MainActor in await AreaSplitFlow.finish(points: points, document: document) }
            return
        }
        if CurveEdgePick.isArmed(document) {
            // r2-measure (NL-MEASURE-05): Measure ▸ Curve an Edge.
            Task { @MainActor in await CurveEdgePick.finish(points: points, document: document) }
            return
        }
        if FencePick.isArmed(document) {
            // r2-measure (NL-MEASURE-11): Measure ▸ Draw Fence Line.
            FencePick.finish(points: points, document: document, canvas: canvasController(for: document))
            return
        }
        if FallLinePick.isArmed(document) {
            // r2-measure (NL-MEASURE-07): Inspector ▸ Pick Fall Line….
            Task { @MainActor in await FallLinePick.finish(points: points, document: document) }
            return
        }
        if let sheet = ScaleSheetCoordinator.active(for: document), sheet.receive(points: points) {
            return
        }
        guard points.count == 2 else {
            // Never leave a region target armed on a calibration that cannot finish.
            document.pendingScaleCalibration = nil
            return
        }
        guard presentScaleSheet(for: document, points: points) != nil else {
            document.pendingScaleCalibration = nil
            return
        }
    }

    /// The layout controller of one attached document, so the document can open a panel it
    /// does not own. Returns `nil` before the document's content is installed.
    func layoutController(for document: ZenitPDFProjectDocument) -> ProjectWindowLayoutController? {
        contents[document.documentIdentity]?.layout
    }

    /// The canvas of one attached document, so what the pointer is wearing can be asked of the
    /// shipping object rather than of a stand-in. Returns `nil` before the content is installed.
    func canvasController(for document: ZenitPDFProjectDocument) -> PDFCanvasViewController? {
        contents[document.documentIdentity]?.canvas
    }

    // MARK: - Workflow sheets

    /// Presents a workflow sheet and registers it as a mode with an exit route, so `Escape`
    /// at the window level and the quit path can both back out of it.
    /// Returns the presented sheet, so the join it installs can be driven and asserted.
    /// `nil` when the panel is already open or the document has no core yet.
    @discardableResult
    func presentToolLibrary(for document: ZenitPDFProjectDocument) -> WorkflowSheet.ToolLibrarySheet? {
        guard let core = document.core, let window else { return nil }
        let kind = WorkflowPanelKind.toolLibrary
        // nl-ux: the Tool Library is a non-modal panel now (UX/ToolChestPanel.swift), so the
        // chip can be pressed while it is open — and pressing it again is the way back. It is
        // registered with the *shell's* mode registry, which is the one the chip's open state
        // and the window's Escape read; the controller's own registry lit nothing.
        let modeRegistry = document.shell?.modeRegistry ?? self.modeRegistry
        if let route = modeRegistry.exitRoute(for: kind.id) {
            route.performExit()
            return nil
        }
        let chest = ToolChestPanel(
            parent: window,
            presenter: core.toolLibrary,
            selectedMarkup: core.canvas.selectedMarkups.first,
            // The panel's edits reach the presenter that arms
            // the canvas *and* the `tool_preset` table, through the document's single door.
            onPresetsChanged: { [weak document] presets in
                document?.applyToolPresets(presets)
            },
            // The file-chooser flow ADR-0011 §4 left out. The editor chooses a
            // PDF page or an image; the document compiles it through `StampArtworkImporter` and
            // stores it in the project's content-addressed artwork table.
            onImportArtwork: { [weak document] choice in
                guard let document else {
                    return .refused(NSLocalizedString(
                        "This project is no longer open.",
                        comment: "Artwork import refusal when the document has gone"
                    ))
                }
                return await document.importPresetArtwork(choice)
            },
            // An unreadable `.zpdftools` file was once refused in silence. The presenter is the one door every application-tier error
            // is shown through, so the refusal now reaches the same alert every other failed
            // import in the product raises.
            onImportFailure: { [weak window] failure in
                ZenitErrorPresenter.present(failure, in: window)
            },
            undoManager: document.undoManager,
            onEnd: { [weak modeRegistry, weak document] in
                modeRegistry?.unregister(id: kind.id)
                if let document { ToolChestPanel.open.removeValue(forKey: ObjectIdentifier(document)) }
            }
        )
        ToolChestPanel.open[ObjectIdentifier(document)] = chest
        modeRegistry.register(kind.makeRegistration(onClose: { [weak chest] in chest?.close() }))
        chest.show()
        return WorkflowSheet.ToolLibrarySheet(window: chest.panel, model: chest.model)
    }



    /// The batch-apply model for a document, fully wired to the engine — **without opening
    /// anything**.
    ///
    /// Split out from ``presentBatchApply(for:)`` deliberately. The thing worth proving about
    /// this feature is the join: that the sheet's four hooks reach the real planner, the real
    /// runner and the real cancel. Proving it by putting a sheet on screen would mean a test
    /// that opens a window on the user's screen, which the test rules forbid outright — and
    /// an `NSWindow.beginSheet` in a headless test process hangs waiting for a run loop that
    /// nobody is pumping, which is how this was found. So the wiring is a value-returning
    /// function and the presentation is a thin shell around it.
    ///
    /// **Which stamp.** The armed preset when one is armed and it is a stamp; otherwise the
    /// first stamp preset in the library. Never a non-stamp preset: a batch of "Polygon
    /// Area" would place 312 empty rectangles, and refusing is the only honest answer.
    ///
    /// - Returns: the wired model and the run-state box its cancel path shares, or `nil` when
    ///   there is nothing to stamp or nowhere to stamp it.
    func makeBatchApplyModel(
        for document: ZenitPDFProjectDocument
    ) -> (model: BatchApplyModel, runState: BatchRunState, presetName: String)? {
        guard let core = document.core else { return nil }

        let armed = core.toolLibrary.activePreset
        // With nothing armed, the person's own stamp before the shipped review stamps (NL-PDF-22).
        guard let preset = (armed?.stamp != nil ? armed : nil)
            ?? core.toolLibrary.presets.first(where: { $0.stamp != nil && $0.provenance.origin != .builtIn })
            ?? core.toolLibrary.presets.first(where: { $0.stamp != nil })
        else { return nil }
        guard !core.snapshot.pages.isEmpty else { return nil }

        let model = BatchApplyModel(anchorCorner: Self.batchStampDefaultAnchor)
        model.placementPrompt = preset.stamp?.placementPrompt
        model.rangeThrough = core.snapshot.pages.count
        model.navigatorSelection = selectedNavigatorPageIDs(in: document)

        // One producer per preview so the prompted text the person is typing is the text the
        // preview describes; the run then builds its own with the same values plus the one
        // instant every stamp in the batch resolves its date against.
        model.onPlan = { [weak core] values in
            guard let core,
                  let producer = core.stampBatchProducer(for: preset, promptedText: values.promptedText)
            else { return nil }
            return core.planBatchApply(producer, request: BatchApplyRequest(
                scope: values.scope,
                anchor: values.anchor,
                skipPagesAlreadyCarrying: values.skipPagesAlreadyCarrying,
                searchMatchedPageIDs: values.searchMatchedPageIDs
            ))
        }

        // The search-term scope, joined to the real FTS5 index. Without this the scope was
        // reachable and inert: the sheet took a term and placed nothing, which is worse
        // than not offering the scope at all because the person believes they chose it.
        wireSearchScope(on: model, document: document)

        let runState = BatchRunState()
        model.onRun = { [weak core, weak model] plan, promptedText in
            guard let core,
                  let producer = core.stampBatchProducer(for: preset, promptedText: promptedText)
            else { return BatchApplyReceipt() }
            let task = Task { @MainActor in
                await core.runBatchApply(
                    producer,
                    plan: plan,
                    progress: ProgressSink { progress in
                        Task { @MainActor in
                            model?.report(fraction: progress.fraction, detail: progress.detail)
                        }
                    }
                )
            }
            runState.task = task
            return await task.value
        }
        model.onCancel = { runState.task?.cancel() }
        return (model, runState, preset.name)
    }

    /// The corner a batch stamp opens on: top right. A drawing's title block sits in the
    /// bottom-right corner, and the old bottom-right default laid "REVIEWED … Sheet 1" over its
    /// scale and format cells (L-58). The person can still choose any corner.
    static let batchStampDefaultAnchor: BatchAnchorCorner = .topRight

    /// Tools ▸ Batch Stamp… — the scoped batch apply.
    ///
    /// The same stamp on every sheet with one click. This is the caller that makes it exist. Everything that decides *what happens*
    /// is in ``makeBatchApplyModel(for:)``; this adds the window, the mode registration and the
    /// exit route every workflow surface has.
    @discardableResult
    func presentBatchApply(for document: ZenitPDFProjectDocument) -> BatchApplyModel? {
        guard let window else { return nil }
        let kind = WorkflowPanelKind.batchApply
        guard modeRegistry.exitRoute(for: kind.id) == nil else { return nil }
        guard let wired = makeBatchApplyModel(for: document) else { return nil }

        let sheetWindow = WorkflowSheet.presentBatchApply(
            in: window,
            model: wired.model,
            title: String(
                format: NSLocalizedString(
                    "Batch Stamp: %@",
                    comment: "Batch apply sheet title. %@ is the stamp preset's name"
                ),
                wired.presetName
            ),
            onEnd: { [weak self] in
                wired.runState.task?.cancel()
                self?.modeRegistry.unregister(id: kind.id)
            }
        )
        modeRegistry.register(kind.makeRegistration(onClose: { [weak window, weak sheetWindow] in
            guard let window, let sheetWindow else { return }
            window.endSheet(sheetWindow)
        }))
        return wired.model
    }

    /// Connects a batch scope to the document’s search index.
    func wireSearchScope(on model: BatchApplyModel, document: ZenitPDFProjectDocument) {
        model.onResolveSearchScope = { [weak document] term in
            guard let document else {
                return .unavailable(
                    term: term,
                    reason: NSLocalizedString(
                        "Search is unavailable for this drawing, so this scope cannot be previewed.",
                        comment: "Batch apply search scope when the document has gone away"
                    )
                )
            }
            return await document.pageIDsContaining(term)
        }
    }

    /// The pages the Navigator has selected, for the navigator-selection scope.
    ///
    /// This read `core.canvas.viewport.pageID` until 2026-08-25, so the scope saw exactly
    /// one page — the one on screen — however many thumbnails the person had
    /// Command-clicked. It now reads ``AppDocumentPresenter/selectedPageIDs``, which is the
    /// selection the Navigator actually draws.
    ///
    /// Empty when nothing is selected, which the scope resolver turns into an empty batch —
    /// and the preview then says "no page matches this scope" rather than quietly meaning
    /// "all of them".
    func selectedNavigatorPageIDs(in document: ZenitPDFProjectDocument) -> [UUID] {
        guard let core = document.core else { return [] }
        let live = Set(core.snapshot.pages.map(\.id))
        return core.document.selectedPageIDs.filter { live.contains($0) }
    }

    /// Read Text from Scanned Pages.
    ///
    /// `OCRRunModel`, `OCRRunSheet` and `OCRService` were all finished and tested, and nothing in
    /// the application could start a run. This is the missing caller: it builds the model over
    /// the document's real pages, hands Start to the engine, records every page as it is
    /// committed with the confidence the index actually stored, and makes Cancel real.
    ///
    /// What the sheet says about the result is not decoration. Recognised text is a **search
    /// aid**, not a certified transcription; the sheet states that before the run and the search
    /// panel states it again whenever a result came from recognition, because a room number a
    /// machine read off a faint scan is not evidence for a bid.
    func presentOCRRun(for document: ZenitPDFProjectDocument) {
        guard let core = document.core, let window else { return }
        let kind = WorkflowPanelKind.ocrRun
        guard modeRegistry.exitRoute(for: kind.id) == nil else { return }

        let pages = core.snapshot.pages
        guard !pages.isEmpty else { return }
        let model = makeOCRRunModel(for: document, pages: pages)
        let sheet = WorkflowSheet.presentOCRRun(
            in: window,
            model: model,
            onEnd: { [weak self, weak document, weak model] in
                // A run sent to the background keeps going with the sheet closed (IM-152).
                if model?.isInBackground != true { document?.cancelTextRecognition() }
                self?.modeRegistry.unregister(id: kind.id)
            }
        )
        modeRegistry.register(kind.makeRegistration(onClose: { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }))
    }

    /// The run model, wired to the document's recognition engine.
    ///
    /// Separated from the presentation so the whole Start → per-page → finish cycle is testable
    /// without a window: the app suite drives this model directly.
    func makeOCRRunModel(
        for document: ZenitPDFProjectDocument,
        pages: [ZPDFUIPresentation.PageDescriptor]
    ) -> OCRRunModel {
        let available = ZenitPDFProjectDocument.supportedRecognitionLanguages()
        let languages = available.isEmpty
            ? OCRLanguage.commonLanguages
            : available.map(OCRLanguage.init(id:))
        // "This page" is a position in `pages` (the set order), never the PDF-local index the
        // viewport carries: in a rearranged set or a project of several drawings that index
        // named another sheet (W-016).
        let current = document.core?.document.currentPageID
        let model = OCRRunModel(
            pages: pages,
            currentPageIndex: pages.firstIndex { $0.id == current } ?? 0,
            availableLanguages: languages
        )
        // Keyed by identity (W-016): a page index is PDF-local, so in a project of several
        // drawings two sheets share it, and a dictionary keyed by index trapped on the duplicate.
        let pageByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        model.onStart = { [weak document, weak model] request in
            guard let document, let model else { return }
            let documentName = document.displayName
            let chosen = request.pageIDs.compactMap { pageByID[$0] }
            for page in chosen {
                model.record(
                    OCRPageStatusSummary(
                        id: page.id,
                        pageLabel: page.label,
                        pageIndex: page.index,
                        status: .indexing,
                        languageIDs: request.languageIDs
                    )
                )
            }
            document.runTextRecognition(
                pageIDs: chosen.map(\.id),
                languageIDs: request.languageIDs,
                skipsPagesWithText: request.skipsPagesWithText,
                onPage: { [weak model, weak document] pageID, recognized in
                    guard let model, let page = pageByID[pageID] else { return }
                    // A page that produced nothing says so. Counting it as "text found" would be
                    // the search index claiming coverage it does not have. "Nothing" is the
                    // service's skip reason, not a zero token count: text Vision returned
                    // without word boxes is indexed and searchable with no tokens (S-103).
                    let status: OCRPageStatus = recognized.skipReason == nil ? .indexed : .noTextFound
                    model.record(
                        OCRPageStatusSummary(
                            id: page.id,
                            pageLabel: page.label,
                            pageIndex: page.index,
                            status: status,
                            confidence: recognized.averageConfidence,
                            recognizedWordCount: recognized.tokenCount,
                            languageIDs: request.languageIDs
                        )
                    )
                    if model.isInBackground {
                        document?.core?.status.setActiveToolNote(Self.backgroundRecognitionNote(model))
                    }
                },
                onFinish: { [weak model, weak document] error in
                    guard let model else { return }
                    defer {
                        if model.isInBackground {
                            document?.core?.status.setActiveToolNote(Self.backgroundRecognitionNote(model))
                        }
                    }
                    if let error {
                        model.fail(
                            ZPDFUserFacingError(
                                kind: .ocrUnavailable,
                                subject: documentName,
                                technicalDetail: String(describing: error)
                            )
                        )
                    } else {
                        model.finish()
                    }
                }
            )
        }
        model.onCancel = { [weak document] in document?.cancelTextRecognition() }
        // Continue in Background: the status bar carries the progress the sheet did (IM-152).
        model.onContinueInBackground = { [weak document, weak model] in
            guard let model else { return }
            document?.core?.status.setActiveToolNote(Self.backgroundRecognitionNote(model))
        }
        return model
    }

    /// The status bar's words for a recognition run with its sheet closed.
    static func backgroundRecognitionNote(_ model: OCRRunModel) -> String {
        switch model.phase {
        case .finished:
            return NSLocalizedString("Text recognition finished.", comment: "Status after a background OCR run")
        case .failed:
            return NSLocalizedString("Text recognition stopped.", comment: "Status after a background OCR run failed")
        default:
            return String(
                format: NSLocalizedString(
                    "Reading text in the background: %1$ld of %2$ld pages",
                    comment: "Status while an OCR run continues with its sheet closed; done and total"
                ),
                model.pageResults.filter { $0.status != .indexing }.count,
                model.pageResults.count
            )
        }
    }

    /// Converts an area in square PDF points to the project's area unit through a scale;
    /// `nil` for an uncalibrated page, so the view keeps its pt² reading.
    nonisolated static func projectAreaFormatter(
        scale: ScaleSummary?,
        unit: ZPDFUIPresentation.AreaUnit,
        decimals: Int
    ) -> (Double) -> String? {
        guard let scale, scale.areaFactor > 0, scale.areaFactor.isFinite else { return { _ in nil } }
        let perUnit = NSDecimalNumber(decimal: unit.squareMetresPerUnit).doubleValue
        guard perUnit > 0 else { return { _ in nil } }
        let places = max(0, min(decimals, 6))
        return { squarePoints in
            let value = squarePoints * scale.areaFactor / perUnit
            guard value.isFinite else { return nil }
            return value.formatted(.number.precision(.fractionLength(places))) + " " + unit.symbol
        }
    }

    /// Presents Revision Compare and returns the sheet, so the three hooks it installs can be
    /// driven and asserted without a pointer. `nil` when the sheet is already open or the
    /// document has no comparison presenter yet — the same contract ``presentToolLibrary(for:)``
    /// has, and for the same reason: a join a caller cannot reach is a join a test cannot see.
    @discardableResult
    func presentRevisionCompare(
        for document: ZenitPDFProjectDocument
    ) -> WorkflowSheet.RevisionCompareSheet? {
        guard let presenter = document.comparePresenter, let window,
              let core = document.core else { return nil }
        let kind = WorkflowPanelKind.revisionCompare
        guard modeRegistry.exitRoute(for: kind.id) == nil else { return nil }
        // Capture the exact view to come back to before the mode takes the canvas.
        viewModeCoordinator.enter(
            .revisionCompare,
            returning: CanvasReturnToken(
                documentID: document.documentIdentity,
                viewport: core.canvas.viewport
            )
        )
        let sheet = WorkflowSheet.presentRevisionCompare(
            in: window,
            presenter: presenter,
            // Difference areas in the project's own unit at the page's scale, pt² kept as the
            // fallback (IM-230, host half).
            projectArea: Self.projectAreaFormatter(
                scale: core.measurement.activeScale,
                unit: core.snapshot.units.area,
                decimals: core.snapshot.units.metricDecimalPlaces
            ),
            onEnd: { [weak self] in
                guard let self else { return }
                self.modeRegistry.unregister(id: kind.id)
                self.viewModeCoordinator.leave()
            }
        )
        let model = sheet.model
        // `onSettingsChange`: the tolerance slider withdrew the standing verdict and never
        // asked the core to re-detect, so moving it emptied the review and left it empty.
        // It now sets the presenter's detection settings and runs the comparison those
        // settings describe.
        model.onSettingsChange = { [weak self, weak presenter, weak model] settings in
            guard let self, let presenter, let model else { return }
            self.runRevisionCompare(presenter: presenter, model: model, settings: settings)
        }
        // `onFocusDifference`: clicking a difference, or Next/Previous, moved the review's
        // cursor and never told the canvas, so "3 of 17" pointed at a sheet showing something
        // else entirely. The reveal is the one this product already has a meaning for — fit
        // the page rect with padding, as `⌘*` and the Scale Regions overlap reveal do.
        model.onFocusDifference = { [weak self, weak document] diff in
            guard let self, let document else { return }
            // The comparison's bounds when the region exists there, the baseline's when the
            // change is a removal and it does not. A region with neither is not a place on a
            // sheet, and scrolling somewhere arbitrary would be worse than not scrolling.
            guard let bounds = diff.comparisonBounds ?? diff.baselineBounds else { return }
            self.contents[document.documentIdentity]?.canvas.zoom(toPageRect: bounds)
        }
        // L-57/L-93: the sheet adds a revision itself. With none, Compare opened two empty
        // "Choose…" pop-ups; now the empty sheet and the revision bar offer Add Revision…, and
        // the comparison runs as soon as the new revision makes a pair.
        model.onAddRevision = { [weak self, weak document, weak presenter, weak model, weak sheetWindow = sheet.window] in
            guard let document else { return }
            AddRevisionCommand.choose(document: document, sheetedOn: sheetWindow ?? self?.window) { [weak self, weak presenter, weak model] added in
                guard added, let self, let presenter, let model else { return }
                self.runRevisionCompare(presenter: presenter, model: model, settings: model.settings)
            }
        }
        // The review opens on a comparison that has actually run, when there is one to run.
        // Without this the only way to reach a verdict would be to move the slider, which
        // would make the *absence* of a difference indistinguishable from never having looked.
        runRevisionCompare(presenter: presenter, model: model, settings: model.settings)
        modeRegistry.register(kind.makeRegistration(onClose: { [weak window, weak sheetWindow = sheet.window] in
            guard let window, let sheetWindow else { return }
            window.endSheet(sheetWindow)
        }))
        return sheet
    }

    /// Runs one Revision Compare detection at the review's current settings and records the
    /// run on the review model when it lands.
    ///
    /// The recorded ``RevisionCompareRun`` is what makes a verdict presentable at all — every
    /// verdict API in `RevisionCompareModel` takes one as a required parameter, precisely so a
    /// count cannot be rendered for a comparison that never happened. The run is only recorded
    /// when the revision pair the person is looking at is still the pair this detection was
    /// started for: a result that arrives after the pickers moved describes two other sheets.
    func runRevisionCompare(
        presenter: AppComparePresenter,
        model: RevisionCompareModel,
        settings: RevisionCompareSettings
    ) {
        // The detection settings are installed first and unconditionally. They describe how the
        // detector is to behave, which is true whether or not there is a pair selected right
        // now; deferring them behind the pair would mean the slider silently did nothing until
        // two revisions happened to be chosen, which is the defect this method exists to close
        // wearing a different hat.
        presenter.setDetection(
            tolerance: settings.tolerance,
            minimumRegionAreaPoints: settings.minimumRegionAreaPoints
        )
        guard let baseline = presenter.baselineRevisionID,
              let comparison = presenter.comparisonRevisionID else { return }
        presenter.compare()
        guard let task = presenter.compareTask else { return }
        Task { @MainActor [weak presenter, weak model] in
            await task.value
            guard let presenter, let model,
                  presenter.baselineRevisionID == baseline,
                  presenter.comparisonRevisionID == comparison,
                  model.settings == settings else { return }
            model.recordRun(RevisionCompareRun(
                baselineRevisionID: baseline,
                comparisonRevisionID: comparison,
                settings: settings
            ))
        }
    }

    // MARK: - Escape routing

    /// The window-level `Escape`: backs out one level, always in the same order — the canvas
    /// (calibration, in-progress measurement, armed tool) answers first because it is the
    /// first responder; whatever reaches here pops the newest panel or mode. There is no
    /// screen in Zenit PDF where `Escape` does nothing.
    public override func cancelOperation(_ sender: Any?) {
        focusThisWindow()
        // The mode a person can SEE wins over whatever the registry has stacked. A mode
        // that was closed by its own window control can leave a registration behind, and
        // Escape then popped that ghost while Revision Overlay stayed on screen — the key
        // looked dead (RT-13, retest of LT-28).
        if let shell = activeDocument?.shell, shell.canvasModes.isInMode {
            shell.leaveCanvasMode()
            return
        }
        if modeRegistry.escapeBacksOutOneLevel() { return }
        // Nothing is stacked: as a last resort a stray armed tool is disarmed, so the key
        // never silently no-ops while the toolbar shows a tool armed. Both families count —
        // a half-drawn callout is as stuck as a half-drawn polygon.
        guard let activeDocument, let core = activeDocument.core else { return }
        if core.measurement.activeKind != nil || core.markup.activeKind != nil {
            performShell(.cancelTool, for: activeDocument)
        }
    }

    // MARK: - Termination support

    /// Clears everything that could sit above — or under — the unsaved-changes review, so
    /// quitting is never blocked on a question the user cannot see.
    ///
    /// Called by the application delegate before termination review begins: every panel and
    /// mode exits through its registered route, any straggler sheet is ended, a minimised
    /// window is restored, and an edited document's window comes forward.
    public func prepareForTermination() {
        // The whole window, recorded before the quit review starts closing tabs: each reviewed
        // document used to leave through `finalizeClose` → `syncTabs` → `recordSession`, so the
        // stored session shrank by every tab saved in the review (R-022). A cancelled quit
        // thaws it again (``terminationCancelled()``).
        freezeSessionForClose()
        modeRegistry.exitAll()
        if let window {
            // Bounded: `attachedSheet` clearing is AppKit's business, and a sheet that
            // refuses to detach must not turn quitting into an infinite loop.
            var remaining = 16
            while let sheet = window.attachedSheet, remaining > 0 {
                window.endSheet(sheet, returnCode: .cancel)
                remaining -= 1
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if documents.contains(where: { $0.isDocumentEdited }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Drag and drop

    /// Performs a canvas drop. All files are handled in the order Finder supplied them.
    private func handleCanvasDrop(
        urls: [URL],
        behavior: CanvasDropBehavior,
        document: ZenitPDFProjectDocument
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        // The bookmark is taken at drop time, while the sandbox's implicit access is alive —
        // afterwards is too late and the file would silently fail to reopen next session.
        for url in urls { DroppedFileBookmarks.remember(url, defaults: ZenitProcessDefaults.bookmarks) }
        switch behavior {
        case .addAsRevision:
            // Only a drawing can be a revision; a dropped project package still opens.
            for url in urls {
                if url.pathExtension.lowercased() == ZenitAppInfo.projectExtension {
                    Self.openDropped(urls: [url])
                } else {
                    document.addRevision(fromDroppedFile: url)
                }
            }
            return true
        case .open:
            Self.openDropped(urls: urls)
            return true
        case .placeImages:
            // r2-markup (NL-UX-15): images dropped on the sheet become image markups.
            return placeDroppedImages(urls, document: document)
        }
    }

    /// Performs a Navigator drop: a drawing dropped on an open project is added to
    /// the project as a new document; anything else opens as a tab. The insertion index
    /// followed the drop location in the page column.
    func handleNavigatorDrop(
        urls: [URL],
        insertionIndex: Int,
        document: ZenitPDFProjectDocument
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        for url in urls { DroppedFileBookmarks.remember(url, defaults: ZenitProcessDefaults.bookmarks) }
        // NL-DOCS-03, honest drop: every dropped file opens as
        // its own drawing, listed in the Navigator as its own section (LT3-11). It used to be
        // copied into the package as `documents/added-<id>.pdf` — which nothing ever opened
        // again — while the original opened as an unrelated tab, the insertion line promised a
        // page insertion that never happened, and the project was marked edited with no undo.
        //
        // NL-DOCS-04 (round 2): a project now holds several drawings, so a PDF dropped on a
        // project's pages is added to it at the drop line — copied into the package, its sheets
        // inserted there, one undo step. Anything else still opens as its own drawing.
        if document.mode == .project, document.drawingSet != nil {
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            let others = urls.filter { $0.pathExtension.lowercased() != "pdf" }
            if !pdfs.isEmpty {
                Task { @MainActor [weak document] in
                    // In reverse at one position, so the drawings land in the order dropped.
                    for url in pdfs.reversed() {
                        _ = await document?.addDrawingToSet(fileAt: url, at: insertionIndex)
                    }
                }
            }
            if !others.isEmpty { Self.openDropped(urls: others) }
            return true
        }
        Self.openDropped(urls: urls)
        return true
    }

    /// Opens dropped files, selecting the existing tab or window for any file that is
    /// already open instead of opening a duplicate.
    public static func openDropped(urls: [URL]) {
        dropOpener(urls)
    }

    /// How dropped, granted and repaired files are opened. The shipping value opens them in
    /// the document controller, which puts a window on screen; a test replaces it to observe
    /// the order of the grant flow without ever showing one (BH-076).
    static var dropOpener: @MainActor ([URL]) -> Void = { urls in openThroughDocumentController(urls) }

    private static func openThroughDocumentController(_ urls: [URL]) {
        let controller = NSDocumentController.shared
        for url in urls {
            if let existing = controller.document(for: url) {
                existing.showWindows()
                continue
            }
            controller.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { ZenitErrorPresenter.present(error) }
            }
        }
    }

    /// Document actions (`save:`, `saveAs:`, Print…) reach the *active tab's* document.
    ///
    /// Nil-target dispatch walks the responder chain and supplements the window
    /// controller with `windowController.document` — always the first-opened tab, the
    /// dead-⌘Z disease on every document selector at once: ⌘S with any attached tab in
    /// front ran the *owner's* save panel ("Untitled", no drawing — found live on
    /// 2026-08-24). This is AppKit's designed
    /// hook for exactly this supplement, so the answer becomes the active tab's
    /// document whenever it can perform the action.
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let active = activeDocument, active.responds(to: action) {
            return active
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: - NSWindowDelegate

    /// `⌘Z` reaches the *active tab's* undo stack, not the stack of whichever document
    /// happens to own the window controller. `undo:` travels the responder chain and ends
    /// at `NSWindow.undoManager`; without this override that resolves through
    /// `windowController.document` — always the first-opened tab — so a measurement drawn
    /// on any attached tab was registered on its own document's undo manager and Edit ▸
    /// Undo stayed disabled (found live, 2026-08-24). A field
    /// editor's text undo is untouched: `NSTextView` answers `undoManager` itself before
    /// the question ever reaches the window.
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        activeDocument?.undoManager
    }

    /// The document identities the in-flight window-close review still has to visit,
    /// maintained so a review that can never finish is detectable.
    private var windowCloseReviewRemainingIDs: Set<UUID> = []

    /// A window close reviews *every* attached document, not only the one that owns the
    /// window controller — AppKit's own path would ask the owner alone and silently drop
    /// the other tabs' unsaved work.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if documents.isEmpty { return true }
        // NL-UX-20: a second window whose document another window still shows just closes —
        // no review, the document stays open. As the document's last window it closes like any
        // window, through the review below.
        if isSecondWindow, closeSecondWindowKeepingDocument() { return true }
        // The whole set, before the close review starts taking tabs away (NL-DOCS-14).
        if !windowCloseReviewInProgress { freezeSessionForClose() }
        if windowCloseReviewInProgress {
            // The latch used to be forever. One document whose `canClose`
            // never answered — a review that lost its callback — ate every later ⌘W. The
            // latch stays honest while the review is genuinely pending: the guard clears
            // only when the document set has moved on since the review chain last looked
            // (the wedged tab was closed some other way, or a new tab arrived), which is
            // proof the pending chain's answer can no longer be the whole story. No
            // timeout, and nothing is auto-discarded — the fresh review re-asks.
            let currentIDs = Set(documents.map(\.documentIdentity))
            if currentIDs == windowCloseReviewRemainingIDs { return false }
            windowCloseReviewInProgress = false
        }
        windowCloseReviewInProgress = true
        windowCloseReviewRemainingIDs = Set(documents.map(\.documentIdentity))
        // A re-armed review starts a new chain; the old chain's verdict, if it still lands,
        // is recognised by its generation and dropped rather than closing or re-asking in
        // parallel with the new one (BH-910).
        windowCloseReviewGeneration &+= 1
        if windowCloseReviewGeneration == 0 { windowCloseReviewGeneration = 1 }
        let generation = windowCloseReviewGeneration
        // The review starts on the next runloop turn, not in this callout. Now that the
        // controller's document is the active tab, `NSWindow.performClose` runs the
        // document's own save-if-necessary *before* asking this delegate, and this
        // callout executes inside that file-access activity — entering
        // `canClose(withDelegate:)` synchronously here parks the main thread on the
        // document serialization semaphore forever (a live hang, 2026-08-24: ⌘W on a
        // clean project never returned). One hop lets the
        // enclosing activity unwind first; the review itself is unchanged.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowCloseReviewGeneration == generation else { return }
            self.reviewNextDocumentForWindowClose()
        }
        return false
    }

    /// The window-close review chain now running; bumped each time a review is (re)armed.
    private(set) var windowCloseReviewGeneration = 0

    /// Whether a `canClose` verdict belongs to the chain now running.
    func isCurrentWindowCloseReview(_ contextInfo: UnsafeMutableRawPointer?) -> Bool {
        Int(bitPattern: contextInfo) == windowCloseReviewGeneration
    }

    private func reviewNextDocumentForWindowClose() {
        guard let document = documents.first else {
            windowCloseReviewInProgress = false
            windowCloseReviewRemainingIDs = []
            window?.close()
            return
        }
        // A drawing another window still shows is not asked about and not closed: it moves to
        // that window, and the chain goes on with the next one (NL-UX-20).
        if handOverToAnotherWindow(document) {
            windowCloseReviewRemainingIDs = Set(documents.map(\.documentIdentity))
            reviewNextDocumentForWindowClose()
            return
        }
        // The question is asked over the tab it is about (CR-157).
        activateTab(id: document.documentIdentity)
        document.canClose(
            withDelegate: self,
            shouldClose: #selector(reviewedForWindowClose(_:shouldClose:contextInfo:)),
            contextInfo: UnsafeMutableRawPointer(bitPattern: windowCloseReviewGeneration)
        )
    }

    @objc private func reviewedForWindowClose(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        // A verdict from a chain that was re-armed since: the running chain asks for itself.
        guard isCurrentWindowCloseReview(contextInfo) else { return }
        guard let document = document as? ZenitPDFProjectDocument else {
            windowCloseReviewInProgress = false
            windowCloseReviewRemainingIDs = []
            return
        }
        guard shouldClose else {
            // The user pressed Cancel in a sheet they could see: the window stays, with
            // every remaining tab intact — and its session follows it again (R-022).
            windowCloseReviewInProgress = false
            windowCloseReviewRemainingIDs = []
            thawSession()
            return
        }
        if document.windowControllers.contains(where: { $0 === self }) {
            // Ownership must not migrate here: the window is going away, and a migrated
            // controller would drag the next document's close into a recursive window close.
            document.removeWindowController(self)
        }
        detach(document)
        document.close()
        // The chain has moved on; the latch guard in `windowShouldClose` compares against
        // what the chain still holds, so its record has to move with it.
        windowCloseReviewRemainingIDs = Set(documents.map(\.documentIdentity))
        reviewNextDocumentForWindowClose()
    }

    public func windowWillClose(_ notification: Notification) {
        for content in contents.values {
            content.layout.persistLayoutState()
        }
        // Nothing of this window outlives it: its detached Split Canvas panes, its Review Lists
        // and its Takeoff Assistant Inboxes close with it (S-022, S-010).
        closePaneWindows()
        ReviewListWindow.forget(self)
        AssistantInboxWindow.forget(self)
        // A second window's views leave their documents' windows (NL-UX-20).
        releaseSecondWindowViews()
        releaseSessionFreeze()
        if Self.tabHost === self { Self.tabHost = nil }
    }
}
