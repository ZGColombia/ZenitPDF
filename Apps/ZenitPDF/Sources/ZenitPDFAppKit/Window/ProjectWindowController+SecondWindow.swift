import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFVectorExtraction

// MARK: - NL-UX-20: a second window on the same project
//
// Window ▸ New Window for Project (⌃⌘N) opens the document in front in another window, the macOS
// convention for several windows on one document:
//
// - **One takeoff.** The document keeps its one core (`ZenitPDFProjectDocument.primaryCore`): the
//   session, the command bus and therefore the undo stack, the History, the review threads and
//   the save. A second window's core is a *view* of it (`AppCoreEnvironment.makeWindowView(of:)`)
//   built over those same instances, so an edit in either window lands on the one bus, is undone
//   by one ⌘Z in either window, and refreshes both.
// - **Per-window state.** Each window has its own `ProjectShellEnvironment` (panels, toolbar,
//   Navigator, Inspector, ledger, status strip) over its own presenters, and its own canvas: the
//   sheet on screen, the viewport, the selection and the armed tool are the window's.
// - **Routing.** `ZenitPDFProjectDocument.core` and `.shell` answer for the window the person is
//   working in (`focusedWindowView`): key and main status move it, and every command routed
//   through a window moves it first, so a menu command, a key or a panel in the second window
//   acts on the second window's page and selection.
// - **Closing.** Closing one window keeps the document open: a second window just goes, and a
//   first window hands a document that another window still shows over to that window instead
//   of reviewing it. The window that is the document's last runs the normal close and review.
// - **Layout.** A second window persists its panel layout under its own key.

/// One second window's view of a document: its core view, its shell, and the window-level
/// callbacks its canvas installed on the document.
@MainActor
final class DocumentWindowView {
    /// The document this window shows.
    weak var document: ZenitPDFProjectDocument?
    /// The window's presenters over the document's one core (``AppCoreEnvironment/isWindowView``).
    let core: AppCoreEnvironment
    /// The window's panels, toolbar and tab strip.
    let shell: ProjectShellEnvironment
    /// The window showing this view. Cleared when the window closes.
    weak var controller: ProjectWindowController?
    /// Which of the document's windows this is: 2 for the first second window, and so on.
    let number: Int
    /// What this window's canvas installed in the document's window-level callbacks.
    var slots = DocumentWindowSlots()
    /// This window's back and forward through jumps (C-07): its own, as its page and viewport are.
    var navigationHistory = NavigationHistory()

    init(document: ZenitPDFProjectDocument, core: AppCoreEnvironment, shell: ProjectShellEnvironment, number: Int) {
        self.document = document
        self.core = core
        self.shell = shell
        self.number = number
    }
}

/// The document's window-level callbacks — the closures a window installs on the document so
/// document-side code can reach *a* canvas. With one window they are the window's own; while
/// second windows are open the document holds dispatchers: the focused window answers a
/// request (calibrate, reveal, zoom to the selection, where the canvas is looking), and every
/// window hears a broadcast (a layer render reset, the vector underlay, the drawing set). A layer
/// filter is not broadcast: it belongs to one page, so each window's is built from that window's
/// own page and delivered to it alone (``ZenitPDFProjectDocument/layerRenderingTargets``, S-009).
@MainActor
struct DocumentWindowSlots {
    var onBeginCalibration: (@MainActor () -> Void)?
    var onRevealPageRect: (@MainActor (PDFRectValue) -> Void)?
    var onZoomToSelection: (@MainActor () -> Void)?
    var currentPlaceProvider: (@MainActor () -> NavigationPlace?)?
    var onLayerRenderingChange: (@MainActor (LayerFilteredPageRenderer.Filtering?) -> Void)?
    var onVectorUnderlayReady: (@MainActor (ZPDFContracts.PageDescriptor, VectorPageExtraction) -> Void)?
    var onDrawingSetChange: (@MainActor () -> Void)?
}

/// One window's canvas as a layer-filter destination: the core whose page the filter is built
/// for, and the slot that hands it to that window's canvas (S-009).
@MainActor
struct LayerRenderingTarget {
    let core: AppCoreEnvironment
    let deliver: @MainActor (LayerFilteredPageRenderer.Filtering?) -> Void
}

// MARK: - The document's side

extension ZenitPDFProjectDocument {

    /// Every window's core: the document's own first, then each second window's view.
    var allWindowCores: [AppCoreEnvironment] {
        [primaryCore].compactMap { $0 } + windowViews.map(\.core)
    }

    /// Every window's shell, in the same order.
    var allWindowShells: [ProjectShellEnvironment] {
        [primaryShell].compactMap { $0 } + windowViews.map(\.shell)
    }

    /// The window the person is working in: the focused second window, else the host.
    var focusedWindowController: ProjectWindowController? {
        focusedWindowView?.controller ?? hostWindowController
    }

    /// Whether a window other than `controller` shows this document.
    func isShown(inAnotherWindowThan controller: ProjectWindowController) -> Bool {
        if let host = hostWindowController, host !== controller, host.documents.contains(where: { $0 === self }) {
            return true
        }
        return windowViews.contains { view in
            guard let other = view.controller else { return false }
            return other !== controller
        }
    }

    /// Whether the host window shows this document through the document's own core — false once
    /// the first window has closed and a second window became the host.
    private var hostShowsFirstView: Bool {
        guard let host = hostWindowController else { return false }
        return host.windowViews[documentIdentity] == nil && host.documents.contains { $0 === self }
    }

    /// The per-window environment factory: a core view over the document's one core and a shell
    /// over that view, wired to the document exactly as the first window's shell is
    /// (``wireWindowShell(_:core:isFirstWindow:)``). `nil` before the drawing has opened, or
    /// when the document closed while the view was being built.
    ///
    /// - Parameter source: the core of the window the command came from; the new window opens on
    ///   the sheet that window shows.
    func makeWindowView(startingFrom source: AppCoreEnvironment? = nil) async -> DocumentWindowView? {
        guard let primary = primaryCore, let compare = comparePresenter, !isClosed else { return nil }
        guard let viewCore = try? await AppCoreEnvironment.makeWindowView(of: primary) else { return nil }
        guard !isClosed else {
            viewCore.unlinkWindowView()
            return nil
        }
        let shell = ProjectShellEnvironment(
            document: viewCore.document,
            canvas: viewCore.canvas,
            ledger: viewCore.ledger,
            toolLibrary: viewCore.toolLibrary,
            search: searchPresenter,
            compare: compare,
            measurement: viewCore.measurement,
            status: viewCore.status
        )
        let number = (windowViews.map(\.number).max() ?? 1) + 1
        let view = DocumentWindowView(document: self, core: viewCore, shell: shell, number: number)
        windowViews.append(view)
        // One Tool Library: a change made in this window reaches the others and is persisted once.
        viewCore.toolLibrary.onPresetsChanged = { [weak self, weak viewCore] presets in
            guard let self, let viewCore else { return }
            self.toolPresetsChangedInWindow(presets, from: viewCore)
        }
        viewCore.toolLibrary.onSetModesChanged = primary.toolLibrary.onSetModesChanged
        wireWindowShell(shell, core: viewCore, isFirstWindow: false)
        // The per-page hooks the first window's core got in `adopt(_:)`: Vector Snap on every
        // sheet (the session keeps the indexes, so a sheet the first window indexed is ready),
        // layer overrides that follow the page, and the per-sheet scale proposal.
        viewCore.snapIndexSource = { [weak self] page in
            await self?.buildSnapIndex(for: page, isFirstSheet: false) ?? AppCoreEnvironment.SnapIndexBuild()
        }
        let pageChange = viewCore.document.onPageChange
        viewCore.document.onPageChange = { [weak self, weak viewCore] page in
            pageChange?(page)
            // Only this window's canvas: the others show their own sheets (S-009).
            guard let viewCore else { return }
            self?.layerPageDidChange(in: viewCore)
        }
        viewCore.afterPageChange = { [weak self] page in self?.proposeScale(forPageID: page.id) }
        if let page = source?.document.currentPageID, page != viewCore.document.currentPageID {
            viewCore.document.goToPage(id: page)
        }
        // The snap toggles are the session's (C-07): a toggle in one window's status strip is
        // shown in every window's, not only in the one it was clicked in.
        mirrorSnapToggles(from: primary)
        mirrorSnapToggles(from: viewCore)
        viewCore.status.adoptSnapToggles(primary.status.toggles)
        applyNavigatorLayerRows()
        return view
    }

    /// Chains one window core's snap-toggle handler so every other window's status strip adopts
    /// the new toggles. Once per core: the document's own core is chained when its first second
    /// window opens and stays chained.
    private func mirrorSnapToggles(from windowCore: AppCoreEnvironment) {
        guard !snapMirroredCores.contains(ObjectIdentifier(windowCore)) else { return }
        snapMirroredCores.insert(ObjectIdentifier(windowCore))
        let own = windowCore.status.onSnapSettingsChange
        windowCore.status.onSnapSettingsChange = { [weak self, weak windowCore] toggles in
            own?(toggles)
            guard let self, let windowCore else { return }
            for other in self.allWindowCores where other !== windowCore {
                other.status.adoptSnapToggles(toggles)
            }
        }
    }

    /// Installs a second window's canvas into the document's window-level callbacks: the first
    /// window's are kept aside, `install` runs with this window focused — so everything it reads
    /// through ``core`` and ``shell`` is this window's — and the document's slots become
    /// dispatchers over every window.
    func installWindowCallbacks(for view: DocumentWindowView, install: () -> Void) {
        if firstWindowSlots == nil { firstWindowSlots = captureWindowSlots() }
        // Emptied first, so what this install does not set stays empty in its own slots rather
        // than capturing a dispatcher that would call itself.
        applyWindowSlots(DocumentWindowSlots())
        focusedWindowView = view
        install()
        view.slots = captureWindowSlots()
        installWindowSlotDispatchers()
    }

    /// Takes a second window's view out of the document's windows: its core stops being
    /// refreshed, focus moves to a window still showing the document, and the first window's
    /// callbacks come back once no second window is left.
    func removeWindowView(_ view: DocumentWindowView) {
        view.core.unlinkWindowView()
        snapMirroredCores.remove(ObjectIdentifier(view.core))
        // The window's undo toast and workspace follower go with it (C-07).
        UndoToastFeed.detach(shell: view.shell)
        ZenitWorkspaceMenu.detachFollower(shell: view.shell)
        windowViews.removeAll { $0 === view }
        view.controller = nil
        if focusedWindowView === view || focusedWindowView == nil && !hostShowsFirstView {
            focusedWindowView = hostShowsFirstView ? nil : windowViews.first { $0.controller != nil }
        }
        if windowViews.isEmpty, let first = firstWindowSlots {
            applyWindowSlots(first)
            firstWindowSlots = nil
        }
    }

    private func captureWindowSlots() -> DocumentWindowSlots {
        DocumentWindowSlots(
            onBeginCalibration: onBeginCalibration,
            onRevealPageRect: onRevealPageRect,
            onZoomToSelection: onZoomToSelection,
            currentPlaceProvider: currentPlaceProvider,
            onLayerRenderingChange: onLayerRenderingChange,
            onVectorUnderlayReady: onVectorUnderlayReady,
            onDrawingSetChange: onDrawingSetChange
        )
    }

    private func applyWindowSlots(_ slots: DocumentWindowSlots) {
        onBeginCalibration = slots.onBeginCalibration
        onRevealPageRect = slots.onRevealPageRect
        onZoomToSelection = slots.onZoomToSelection
        currentPlaceProvider = slots.currentPlaceProvider
        onLayerRenderingChange = slots.onLayerRenderingChange
        onVectorUnderlayReady = slots.onVectorUnderlayReady
        onDrawingSetChange = slots.onDrawingSetChange
    }

    /// The focused window's slots: a request goes to the window the person is working in.
    private var focusedWindowSlots: DocumentWindowSlots {
        focusedWindowView?.slots ?? firstWindowSlots ?? DocumentWindowSlots()
    }

    /// Each window's core with the slot through which that window's canvas takes a layer filter
    /// (S-009). A filter belongs to one page, so it is built from each window's own page and
    /// delivered to that window only. With one window: the document's core and its
    /// `onLayerRenderingChange`, read at delivery. While second windows are open: the first
    /// window's slot with the document's own core, then each second window's slot with its core.
    var layerRenderingTargets: [LayerRenderingTarget] {
        guard !windowViews.isEmpty else {
            guard let core else { return [] }
            return [LayerRenderingTarget(core: core, deliver: { [weak self] filtering in
                self?.onLayerRenderingChange?(filtering)
            })]
        }
        var targets: [LayerRenderingTarget] = []
        if let primary = primaryCore, let deliver = firstWindowSlots?.onLayerRenderingChange {
            targets.append(LayerRenderingTarget(core: primary, deliver: deliver))
        }
        for view in windowViews {
            guard let deliver = view.slots.onLayerRenderingChange else { continue }
            targets.append(LayerRenderingTarget(core: view.core, deliver: deliver))
        }
        return targets
    }

    /// Every window's slots: a broadcast reaches every canvas.
    private var everyWindowSlots: [DocumentWindowSlots] {
        [firstWindowSlots].compactMap { $0 } + windowViews.map(\.slots)
    }

    private func installWindowSlotDispatchers() {
        onBeginCalibration = { [weak self] in self?.focusedWindowSlots.onBeginCalibration?() }
        onRevealPageRect = { [weak self] rect in self?.focusedWindowSlots.onRevealPageRect?(rect) }
        onZoomToSelection = { [weak self] in self?.focusedWindowSlots.onZoomToSelection?() }
        currentPlaceProvider = { [weak self] in self?.focusedWindowSlots.currentPlaceProvider?() }
        onLayerRenderingChange = { [weak self] filtering in
            for slots in self?.everyWindowSlots ?? [] { slots.onLayerRenderingChange?(filtering) }
        }
        onVectorUnderlayReady = { [weak self] page, extraction in
            for slots in self?.everyWindowSlots ?? [] { slots.onVectorUnderlayReady?(page, extraction) }
        }
        onDrawingSetChange = { [weak self] in
            for slots in self?.everyWindowSlots ?? [] { slots.onDrawingSetChange?() }
        }
    }
}

// MARK: - The window's side

extension ProjectWindowController {

    /// How a second window reaches the screen. A test replaces it or leaves it to the bundle
    /// check: nothing is ordered front outside the assembled application.
    static var secondWindowPresenter: @MainActor (NSWindow) -> Void = { window in
        guard ZenitModalPresenter.canPresentModally else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Whether this window is a second window on its document.
    var isSecondWindow: Bool { !windowViews.isEmpty }

    /// This window's core for `document`: its own view in a second window, the document's own
    /// core in the first.
    func windowCore(for document: ZenitPDFProjectDocument) -> AppCoreEnvironment? {
        windowViews[document.documentIdentity]?.core ?? document.primaryCore
    }

    /// This window's shell for `document`.
    func windowShell(for document: ZenitPDFProjectDocument) -> ProjectShellEnvironment? {
        windowViews[document.documentIdentity]?.shell ?? document.primaryShell
    }

    /// The defaults key this window's panel layout lives under: the first window's key, or the
    /// second windows' own.
    func layoutStoreKey(for document: ZenitPDFProjectDocument) -> String {
        windowViews[document.documentIdentity] == nil
            ? ProjectWindowLayoutStore.defaultsKey
            : Self.secondWindowLayoutKey
    }

    /// Where a second window's panel layout is persisted.
    static let secondWindowLayoutKey = ProjectWindowLayoutStore.defaultsKey + ".SecondWindow"

    /// A second window's title: the drawing and which of its windows this is ("Plan — 2").
    var secondWindowTitle: String? {
        guard let document = activeDocument, let view = windowViews[document.documentIdentity] else { return nil }
        return String(
            format: NSLocalizedString(
                "%1$@ — %2$d",
                comment: "Title of a second window on a document: the document name, then the window's number"
            ),
            document.displayName ?? ZenitAppInfo.displayName,
            view.number
        )
    }

    /// Window ▸ New Window for Project: `document` in a new window of its own, over the same
    /// takeoff. Answers the new window's controller, or `nil` when the document has not finished
    /// opening or closed meanwhile.
    @discardableResult
    func openNewWindow(for document: ZenitPDFProjectDocument) async -> ProjectWindowController? {
        guard !document.isClosed, document.primaryCore != nil else { return nil }
        guard let view = await document.makeWindowView(startingFrom: windowCore(for: document)) else { return nil }
        guard !document.isClosed else {
            document.removeWindowView(view)
            return nil
        }
        let controller = ProjectWindowController(secondWindowFor: document, view: view)
        // NSDocument semantics: one document, several window controllers.
        document.addWindowController(controller)
        if let window = controller.window {
            // Sized before it is shown, so its panes and its page fit are laid out at the size
            // a person sees (L-96).
            window.setFrame(
                Self.secondWindowFrame(
                    from: self.window?.frame,
                    minimum: self.window?.minSize ?? window.minSize,
                    visible: (self.window?.screen ?? NSScreen.main)?.visibleFrame
                ),
                display: false
            )
            Self.secondWindowPresenter(window)
        }
        // The session now names this window too, so a relaunch reopens it (C-07).
        document.hostWindowController?.recordSession()
        return controller
    }

    /// Where a second window opens (L-96): at the size of the window it was opened from — never
    /// below that window's minimum — one title bar down and to the right of it, kept inside the
    /// screen's visible area. Pure, so the rule is testable without a screen.
    ///
    /// It used to open at whatever its loading placeholder had sized it to, because the frame
    /// autosave a first window restores from is held by that first window: 864 × 526 in the
    /// installed build, under the 1040 × 640 minimum, its navigator tabs truncated to one letter
    /// and the page fitted at 15 %.
    nonisolated static func secondWindowFrame(from source: NSRect?, minimum: NSSize, visible: NSRect?) -> NSRect {
        let cascade: CGFloat = 24
        var size = source?.size ?? NSSize(width: 1_360, height: 860)
        size.width = max(size.width, minimum.width)
        size.height = max(size.height, minimum.height)
        var origin = source.map { NSPoint(x: $0.minX + cascade, y: $0.minY - cascade) } ?? .zero
        if let visible, visible.width > 0, visible.height > 0 {
            size.width = min(size.width, max(visible.width, minimum.width))
            size.height = min(size.height, max(visible.height, minimum.height))
            if source == nil {
                origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            }
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return NSRect(origin: origin, size: size)
    }

    /// Fills a new second window: the document is its one tab, shown through `view`, with a
    /// canvas and layout of its own built by the same `install` every window uses.
    func adoptSecondWindow(document: ZenitPDFProjectDocument, view: DocumentWindowView) {
        documents = [document]
        activeDocument = document
        windowViews[document.documentIdentity] = view
        view.controller = self
        document.installWindowCallbacks(for: view) {
            install(shell: view.shell, core: view.core, for: document)
        }
        if let content = contents[document.documentIdentity] { present(content: content) }
        // The Whole Project panel, the office recipe library and the project-recipe edit hook,
        // on this window's ledger and shell — what `attach(document:)` gives a first window.
        refreshProjectLedgerSources()
        updateWindowChrome()
        refreshTabState()
    }

    /// A second window closing while another window still shows its document: its view leaves
    /// the document and the window goes, with no review. `false` when this is the document's
    /// last window, which closes through the ordinary review.
    func closeSecondWindowKeepingDocument() -> Bool {
        guard let document = documents.first, document.isShown(inAnotherWindowThan: self) else { return false }
        // Were this window the document's host (its first window closed earlier), the host role
        // moves on with the document.
        if document.hostWindowController === self,
           let heir = document.windowViews.lazy.compactMap(\.controller).first(where: { $0 !== self }) {
            detach(document)
            heir.becomeHost(of: document)
        }
        releaseSecondWindowViews()
        return true
    }

    /// Tears this window's views out of their documents: the window has closed, or is about to.
    func releaseSecondWindowViews() {
        // The hosts whose session names these windows: re-recorded once they are gone (C-07).
        // A host whose session a close or quit froze keeps what it recorded.
        let hosts = windowViews.values.compactMap { $0.document?.hostWindowController }.filter { $0 !== self }
        defer { for host in hosts { host.recordSession() } }
        for (id, view) in windowViews {
            let document = documents.first { $0.documentIdentity == id } ?? view.document
            contents[id]?.layout.persistLayoutState()
            contents[id] = nil
            if let document {
                // Leaving the document's controllers first keeps AppKit from closing a
                // document another window still shows when this window's close lands.
                if !document.isClosed, document.windowControllers.contains(where: { $0 === self }) {
                    document.removeWindowController(self)
                }
                document.removeWindowView(view)
                documents.removeAll { $0 === document }
                if activeDocument === document { activeDocument = nil }
            }
        }
        windowViews = [:]
    }

    /// The document leaves this window without closing, because another window still shows it:
    /// the tab strip's close and the window-close review hand it over. `false` when no other
    /// window shows it — then it closes as before.
    func handOverToAnotherWindow(_ document: ZenitPDFProjectDocument) -> Bool {
        guard document.hostWindowController === self,
              let heir = document.windowViews.lazy.compactMap(\.controller).first(where: { $0 !== self })
        else { return false }
        let wasActive = activeDocument === document
        if document.windowControllers.contains(where: { $0 === self }) {
            document.removeWindowController(self)
            // Outside a whole-window close, this window stays owned by a drawing it still shows.
            if !windowCloseReviewInProgress, let survivor = documents.first(where: { $0 !== document }) {
                survivor.addWindowController(self)
            }
        }
        detach(document)
        heir.becomeHost(of: document)
        if !windowCloseReviewInProgress {
            if wasActive, let next = documents.last {
                activateTab(id: next.documentIdentity)
            } else {
                updateWindowChrome()
                syncTabs()
            }
        }
        return true
    }

    /// Takes over as `document`'s host: the window its document-level hooks report to, and the
    /// window its core and shell answer for from now on.
    func becomeHost(of document: ZenitPDFProjectDocument) {
        document.hostWindowController = self
        document.onStateChange = { [weak self] in
            self?.updateWindowChrome()
            self?.refreshTabState()
        }
        document.onSearchPresenterReady = nil
        document.onRevealForeignHit = nil
        // Alone in this window: no other drawing's search results to fan out to.
        document.installProjectSearchSources([])
        document.focusedWindowView = windowViews[document.documentIdentity]
        updateWindowChrome()
        refreshTabState()
    }

    // MARK: Focus

    /// The window became key: its view is the one the document's core and shell answer for.
    public func windowDidBecomeKey(_ notification: Notification) {
        focusThisWindow()
    }

    /// The window became main — the one ⌘S and the other document actions reach.
    public func windowDidBecomeMain(_ notification: Notification) {
        focusThisWindow()
    }
}
