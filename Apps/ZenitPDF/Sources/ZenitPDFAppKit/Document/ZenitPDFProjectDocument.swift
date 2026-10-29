import AppKit
import Foundation
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
import ZPDFVectorExtraction

/// The root of one open drawing or project.
///
/// One class serves both document modes, because they are the same document at two stages
/// of its life: Quick PDF Mode is a drawing with a takeoff that has nowhere to live yet, and
/// Project Mode is the same drawing after the user has said where. Promoting one to the other must
/// not close and reopen the window, so it cannot be two classes.
///
/// `NSDocument` is what supplies Open, Save, Save As, autosave, Versions, print, the edited dot,
/// the close-without-saving sheet and multiple open projects. None of that is reimplemented here.
@MainActor
public final class ZenitPDFProjectDocument: NSDocument {

    /// Which of the two modes the document is in.
    public enum Mode: String, Sendable {
        /// A PDF opened directly. Measurements exist in memory and in autosave only.
        case quickPDF
        /// A `.zpdfproj` package.
        case project
    }

    // MARK: - State

    /// The mode the document is in. A quick PDF becomes a project through
    /// ``createProject(at:)``, never by opening a second window.
    public private(set) var mode: Mode = .project

    /// The engine session and its presenters, as the window the person is working in sees them.
    /// `nil` until the drawing has finished opening.
    ///
    /// NL-UX-20: with one window this is ``primaryCore``, exactly as before. While a second window
    /// shows the document, it is the core view of the window that has focus
    /// (``focusedWindowView``): every view shares the session, the command bus, the undo stack,
    /// the History and the save, and keeps its own page, viewport, selection and armed tool.
    public var core: AppCoreEnvironment? { focusedWindowView?.core ?? primaryCore }

    /// What the window the person is working in renders (NL-UX-20: the focused window's shell,
    /// else ``primaryShell``).
    public var shell: ProjectShellEnvironment? { focusedWindowView?.shell ?? primaryShell }

    /// The document's own core: built by the load, owner of the bus hooks, the audit trail and
    /// every window's shared state. The first window shows it.
    public private(set) var primaryCore: AppCoreEnvironment?

    /// The first window's shell. Built once, before the drawing arrives, so the window can open
    /// immediately on an empty state rather than after a 400-page parse.
    public private(set) var primaryShell: ProjectShellEnvironment?

    /// NL-UX-20: the views of the second windows open on this document, oldest first
    /// (`Window/ProjectWindowController+SecondWindow.swift`).
    var windowViews: [DocumentWindowView] = []

    /// NL-UX-20: the second window whose view ``core`` and ``shell`` answer for — the one the
    /// person last worked in. `nil` means the first window's.
    weak var focusedWindowView: DocumentWindowView? {
        // S-033: the shared Search panel's "Current Page" is the sheet of the window worked in.
        didSet { core?.takeSearchFocus() }
    }

    /// NL-UX-20: the first window's slots, kept while second windows share the document's
    /// window-level callbacks through dispatchers. `nil` with one window.
    var firstWindowSlots: DocumentWindowSlots?

    /// The window cores whose snap-toggle handler already mirrors into the others (C-07).
    var snapMirroredCores: Set<ObjectIdentifier> = []

    /// The opened drawing: pages, raster source, digest.
    public private(set) var drawing: LoadedDrawing?

    /// Every drawing of the project and which one each page comes from (NL-DOCS-04). Its
    /// primary member is ``drawing``. See `ZenitPDFProjectDocument+DrawingSet.swift`.
    var drawingSet: DrawingSet?
    /// Raised after a drawing joined the set, so the window can re-point its canvas and
    /// Navigator at the new drawing's pages (NL-DOCS-04).
    var onDrawingSetChange: (@MainActor () -> Void)?
    /// Back and forward through the jumps (NL-DOCS-09), of the window the person is working in:
    /// a second window keeps its own (C-07), so ⌘[ in one window never goes back to a place a jump
    /// in the other window left. The first window's is ``firstWindowNavigationHistory``.
    var navigationHistory: NavigationHistory {
        get { focusedWindowView?.navigationHistory ?? firstWindowNavigationHistory }
        set {
            if let view = focusedWindowView { view.navigationHistory = newValue } else { firstWindowNavigationHistory = newValue }
        }
    }
    /// The first window's jumps.
    var firstWindowNavigationHistory = NavigationHistory()
    /// Where the canvas is looking, for the history. Wired by the window.
    var currentPlaceProvider: (@MainActor () -> NavigationPlace?)?
    /// Backing store for ``windowSearchSources``.
    var drawingSetWindowSources: [ZPDFUIPresentation.ProjectSearchSource] = []

    /// The open project package, in Project Mode.
    public private(set) var projectPackage: ProjectPackage?

    /// Feature 15: the project's site-photograph sidecar, mounted inside the package's
    /// `attachments/` member at open. `nil` in Quick PDF Mode — a bare PDF has no package
    /// to keep photographs crash-safe in.
    public private(set) var photoStore: PhotoStore?

    /// True while the drawing is being read.
    public private(set) var isLoading = false

    /// Whether `close()` has run. A load still awaiting when the tab closed must not finish
    /// on this document (CR-150), and a save still writing must not adopt its package (CR-152).
    public private(set) var isClosed = false

    /// Releases the security-scoped access the document controller began for a file that
    /// arrived by drop in an earlier session. Balanced in ``shutDownStorage()`` (CR-163).
    var scopedAccessRelease: (() -> Void)?

    /// The most recent load failure, kept so the window can present it once it exists.
    public private(set) var loadFailure: (any Error)?

    /// Raised whenever the document's readiness changes, so the window controller can rebuild.
    public var onStateChange: (@MainActor () -> Void)?

    /// The window this document lives in as a tab. Set by ``ProjectWindowController/attach(document:)``.
    public internal(set) weak var hostWindowController: ProjectWindowController?

    /// The per-document layer visibility of gap 10. Empty until the drawing's layer
    /// catalogue has been read; a drawing with no `/OCProperties` keeps it empty forever.
    public let layerVisibility = DocumentLayerVisibility()

    /// Automation's per-document state: the layer-aware extraction store and the person's
    /// automation choices (nl-automation, `Automation/AutomationExtractionStore.swift`).
    let automation = DocumentAutomationState()

    /// Raised after a layer toggle changed what the canvas may draw: the window controller
    /// re-renders the canvas through the content-stream path when overrides differ from
    /// the document default, and natively when they no longer do.
    var onLayerRenderingChange: (@MainActor (LayerFilteredPageRenderer.Filtering?) -> Void)?

    /// Raised once the first page's vector geometry has been extracted, so the canvas can
    /// compile the vector underlay from the same scan the snap index was built from.
    var onVectorUnderlayReady: (@MainActor (ZPDFContracts.PageDescriptor, VectorPageExtraction) -> Void)?

    /// What the next calibration is for: the page default, a Scale Region, or the panel's
    /// draft. Set by the Scale Regions panel before the flow starts and read when it ends.
    public internal(set) var pendingScaleCalibration: ScaleCalibrationTarget?

    /// Starts the two-click calibration flow. Set by ``ProjectWindowController``, which owns
    /// the canvas the two clicks land on.
    var onBeginCalibration: (@MainActor () -> Void)?

    /// Scrolls the canvas so a page-space rectangle is visible. Used by the Scale Regions
    /// panel's overlap warning, which reveals the shared area and never resolves it.
    var onRevealPageRect: (@MainActor (PDFRectValue) -> Void)?
    /// Fits the canvas to the current selection. Installed by the window controller.
    var onZoomToSelection: (@MainActor () -> Void)?

    /// Opens the Scale Regions panel if it is not already open.
    ///
    /// Called when a measurement raises a crossing: the question cannot be answered from a
    /// panel nobody can see, and a modal in front of the drawing mid-measurement is its own
    /// defect (`CORE_LOOP.md`), so the floating panel is opened instead.
    func presentScaleRegionsPanel() {
        guard let layout = focusedWindowController?.layoutController(for: self) else { return }
        guard !layout.isShowingScaleRegionsPanel else { return }
        layout.toggleScaleRegionsPanel()
    }

    /// Per-page extractions taken with hidden optional content included, cached for layer
    /// re-renders and snap rebuilds, keyed by zero-based page index. Built lazily, page by page,
    /// as layer overrides meet each page. It used to hold page 0 only, so a layer toggle
    /// re-rendered every sheet from the first sheet's linework (nl-ux).
    private var layerAwareExtractions: [Int: VectorPageExtraction] = [:]

    /// NL-UX-04: the drawing's own annotations as last read by Make Drawing Annotations
    /// Editable, and the markup identities that command adopted. The originals' visibility is
    /// derived from these and the markups present (UX/DrawingAnnotationAdoption.swift).
    var adoptionReading: ReviewAnnotationReader.Reading?
    var adoptionTouchedIDs: Set<UUID> = []

    private var pendingURL: URL?
    private var loadTask: Task<Void, Never>?

    /// The empty untitled document AppKit opens at a launch with nothing to reopen, and the
    /// `zenitpdf://new` link opens when nothing is open: no file, no drawing, nothing edited.
    /// It is a start screen with an Open… door, never a project — Save refuses it and nothing
    /// can be added to it — so the first drawing that opens into its window takes its place
    /// (``ProjectWindowController/retireUntouchedStartDocuments()``, L-40).
    var isUntouchedStartDocument: Bool {
        fileURL == nil && pendingURL == nil && drawing == nil && !isDocumentEdited && !isClosed
    }
    /// Quick PDF Mode's container-side takeoff storage: the autosave
    /// package and the audit-trail database both live under
    /// ``quickPDFAutosaveDirectory`` until the user chooses a real home for the takeoff.
    /// One serialized type, so create, save and retire can never interleave (IM-181).
    private(set) lazy var quickStorage: QuickTakeoffStorage = makeQuickStorage()
    /// Completion of an in-flight Save panel started by the close review.
    private var quickSaveCompletion: (@MainActor (Bool) -> Void)?
    /// The Search panel's presenter.
    ///
    /// This was a `MockSearchPresenter` over a hard-coded hit list until 2026-08-24: the shipping
    /// panel answered every query with results belonging to a sample project, in front of a
    /// person looking at their own drawing. A fabricated result is the same defect class as a
    /// quantity computed without a scale, and it is now an ``AppSearchPresenter`` over the real
    /// FTS5 index — or, when the index cannot be opened at all, an
    /// ``UnavailableSearchPresenter`` that says so instead of inventing an answer.
    public private(set) var searchPresenter: any SearchPresenting = UnavailableSearchPresenter(
        reason: NSLocalizedString(
            "Search becomes available once the drawing has finished opening.",
            comment: "Search panel state before a drawing has been opened"
        )
    )

    /// The drawing's text index: page text, recognised text and markup text, in the container.
    public private(set) var searchIndex: DocumentSearchIndex?

    /// Resolves a batch sheet's search term into the pages that contain it, or `nil` when
    /// this drawing has no index and the scope therefore has no answer to give.
    ///
    /// Built beside the search presenter and from the same identity map, so the pages the
    /// batch scope counts are the pages the Search panel would list.
    public private(set) var batchSearchScopeResolver: BatchSearchScopeResolver?

    /// Debounced re-index of the markup half after an edit.
    private var markupIndexTask: Task<Void, Never>?

    /// The background read of the drawing's own text layer. Cancelled when the document closes:
    /// a 400-page extraction must not outlive the window that started it, and it must not still
    /// be writing when the index database is closed underneath it.
    private var textIndexTask: Task<Void, Never>?

    /// The in-flight recognition run, so the sheet's Cancel really cancels.
    private var ocrRunTask: Task<Void, Never>?

    /// The provider Revision Compare's comparator reads pages through. Kept so a dropped
    /// revision (the `⌥` drop) can be opened into the same provider.
    private(set) var compareProvider: PDFKitDocumentProvider?
    /// Revision Compare's presenter. Public so the window can hand the concrete type to the
    /// compare view, which is generic over its presenter.
    public private(set) var comparePresenter: AppComparePresenter?

    /// The comparator both Revision Compare and Revision Overlay run through.
    ///
    /// Kept here rather than reached through the presenter because Revision Overlay needs
    /// ``RevisionComparator/overlay(references:alignments:model:plan:)`` and the presenter
    /// exposes only `compare`. It is the **same instance**, over the same
    /// `ServiceBackedRevisionDocumentSource`, so the overlay reads its rasters through
    /// `GeometryService` exactly as the comparison does — there is deliberately no second
    /// parsing path, and this property is what makes that a fact rather than an intention.
    public private(set) var revisionComparator: RevisionComparator?

    /// The page each registered revision points at. The presenter keeps its own copy for
    /// the comparison it runs; the overlay needs the whole list at once, in stack order.
    public internal(set) var revisionPages: [RevisionSummary.ID: RevisionPageReference] = [:]
    /// Each dropped revision's page labels, for pairing by sheet number (see
    /// `ZenitPDFProjectDocument+Revisions.swift`).
    var revisionPageLabels: [RevisionSummary.ID: [String]] = [:]
    /// The revision-and-sheet pairings already said to have no partner, so Revision Overlay
    /// says each once (U-014; `+Revisions.swift`).
    var revisionPairingsWarned: Set<String> = []
    /// Each revision's confirmed pairing: set page identity → revision page index (NL-DOCS-11).
    var revisionSheetPairs: [RevisionSummary.ID: [UUID: Int]] = [:]
    /// How each of those pairs was decided, as stored with it (U-080): the set compare report's
    /// Pairing column reads it rather than guessing from the labels.
    var revisionSheetPairEvidence: [RevisionSummary.ID: [UUID: RevisionSheetRecord.Evidence]] = [:]
    /// The drawing each carried-to revision became in the set (NL-DOCS-12).
    var carriedRevisionDrawings: [RevisionSummary.ID: DocumentID] = [:]
    /// The `revision_entry` row each kept revision was stored as.
    var persistedRevisionIDs: [RevisionSummary.ID: String] = [:]
    /// True while stored revisions are re-registered after an open, so they are not stored twice.
    var restoringRevisions = false

    // MARK: - NSDocument

    public override class var autosavesInPlace: Bool { true }
    public override class var preservesVersions: Bool { true }
    public override class var readableTypes: [String] { ZenitDocumentController.readableTypeIdentifiers }
    public override class var writableTypes: [String] { [ZenitAppInfo.projectTypeIdentifier] }

    public override class func isNativeType(_ type: String) -> Bool {
        type == ZenitAppInfo.projectTypeIdentifier
    }

    public override func makeWindowControllers() {
        // A second opened document becomes a chip in the existing window's tab strip,
        // not a second window. Only a window that is actually on screen may
        // host: in tests and during teardown there is none, and each document keeps the
        // one-window behaviour NSDocument expects. The host is *resolved*, not read from
        // the one weak registration — LT-33: a stale registration pushed every later open,
        // a reopened `.zpdfproj` included, into a ghost window stacked over the real one.
        if let host = ProjectWindowController.resolveTabHost() {
            host.attach(document: self)
        } else {
            let controller = ProjectWindowController(document: self)
            addWindowController(controller)
        }
        startLoadingIfNeeded()
    }

    /// Fronts this document's tab rather than a window of its own: a document attached as
    /// a tab owns no window controller, so `super` would silently show nothing.
    public override func showWindows() {
        if let hostWindowController {
            hostWindowController.activateTab(id: documentIdentity)
            hostWindowController.showWindow(nil)
        } else {
            super.showWindows()
        }
    }

    /// Sheets hang from the window the person is working in: with a second window on the
    /// document focused (NL-UX-20), that window; otherwise AppKit's answer, as before.
    public override var windowForSheet: NSWindow? {
        if let focused = focusedWindowView?.controller?.window { return focused }
        return super.windowForSheet
    }

    /// Records what to open. The actual read happens off the main thread in ``startLoadingIfNeeded()``.
    ///
    /// `NSDocument` calls this synchronously on the main thread. Parsing a large drawing here would
    /// block the run loop for as long as it takes, so nothing is parsed: the URL is recorded and
    /// the window opens on its empty state while the pages are read.
    public override nonisolated func read(from url: URL, ofType typeName: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ZenitDocumentError.unsupportedFileType(url.lastPathComponent)
        }
        // `canConcurrentlyReadDocuments` is false, so AppKit calls this on the main thread; the
        // assumption is checked at runtime rather than assumed away.
        MainActor.assumeIsolated {
            mode = (typeName == ZenitAppInfo.projectTypeIdentifier) ? .project : .quickPDF
            pendingURL = url
        }
    }

    public override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        false
    }

    /// Quick PDF Mode has nothing to write in place; Project Mode writes through ``ProjectPackage``.
    ///
    /// `NSDocument`'s file-wrapper and data paths are both wrong for a package whose save is an
    /// atomic sibling-and-replace with hashing and WAL checkpointing, so the whole
    /// save is taken over here.
    public override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // The activity stays marked for the whole asynchronous save, not only while a
        // panel is up: a synchronous AppKit entry raised in the gap between the panel
        // closing and the write finishing is the deadlock (RT-14, CR-147). Every operation
        // — ⌘S, Save As, an autosave tick, the quit-time autosave — comes through this one
        // primitive, so this flag is the truth about whether the activity is held.
        isSaveTaskRunning = true
        let isAutosave = Self.isAutosave(saveOperation)
        let creatingProject = mode == .quickPDF && !isAutosave
        // Said while it runs, and when it is done (IM-177). An autosave works quietly and
        // only reports its finish.
        if !isAutosave {
            publishSaveNote(creatingProject
                ? NSLocalizedString("Creating project…", comment: "Status while Create Project writes the new package")
                : NSLocalizedString("Saving…", comment: "Status while a save runs"))
        }
        Task { @MainActor in
            defer { self.isSaveTaskRunning = false }
            do {
                try await performSave(to: url, operation: saveOperation)
                // K-05: the picture the Quick Look extension reads, markups included, the
                // package's Finder icon (NL-UX-17, U-020) and NL-PLAT-21: the Space-bar preview's
                // sheet and totals — one render of the first sheet for all three (T-014;
                // Document/ZenitPDFProjectDocument+PackageThumbnail.swift).
                let packageURL = url.pathExtension.lowercased() == ProjectPackageLayout.fileExtension
                    ? url : url.appendingPathExtension(ProjectPackageLayout.fileExtension)
                self.writeSavedPicturesAfterSave(at: packageURL, operation: saveOperation)
                self.publishSaveNote(Self.savedNote(autosave: isAutosave, at: Date()))
                completionHandler(nil)
            } catch {
                self.publishSaveNote(nil)
                completionHandler(error)
            }
        }
    }

    nonisolated static func isAutosave(_ operation: NSDocument.SaveOperationType) -> Bool {
        switch operation {
        case .autosaveInPlaceOperation, .autosaveElsewhereOperation, .autosaveAsOperation: return true
        default: return false
        }
    }

    /// "Saved 14:32" or "Autosaved 14:32", in the person's own time format.
    nonisolated static func savedNote(autosave: Bool, at date: Date) -> String {
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return String(
            format: autosave
                ? NSLocalizedString("Autosaved %@", comment: "Status after an autosave; the time")
                : NSLocalizedString("Saved %@", comment: "Status after a save; the time"),
            time
        )
    }

    /// Posts a save phase to the status bar's note, replacing only a note it posted itself —
    /// a tool's message or a warning's detail is never overwritten by bookkeeping (IM-177).
    func publishSaveNote(_ note: String?) {
        guard let status = core?.status else { return }
        let current = status.snapshot.activeToolNote
        guard current == nil || current == lastSaveNote else { return }
        lastSaveNote = note
        status.setActiveToolNote(note)
    }

    /// The save note this document last posted.
    private(set) var lastSaveNote: String?

    /// Create Project's stages, named as they run: "Creating project (2 of 3): writing the
    /// takeoff".
    func publishCreateProjectStage(_ stage: Int, _ name: String) {
        publishSaveNote(String(
            format: NSLocalizedString(
                "Creating project (%1$ld of 3): %2$@",
                comment: "Status while Create Project runs; stage number and stage name"
            ),
            stage, name
        ))
    }

    /// File ▸ Save.
    ///
    /// In Quick PDF Mode there is nowhere to save *to* yet, and the one place there must never be
    /// is the drawing itself: the original PDF is never overwritten without an explicit command
    /// and a confirmation. So the first save of a quick takeoff is the
    /// `Create Zenit PDF Project` offer, not a write.
    public override func save(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        guard drawing != nil else {
            // The untitled launch window, or a drawing still opening: a Save panel here
            // ended in "The drawing is still opening" AFTER the panel (CR-161).
            core?.status.setActiveToolNote(NSLocalizedString(
                "Nothing to save yet — open a drawing first.",
                comment: "Status note when Save is invoked with no drawing loaded"
            ))
            return
        }
        guard mode == .quickPDF else {
            super.save(sender)
            return
        }
        createProject()
    }

    // MARK: - The synchronous doors (CR-147)
    //
    // `saveDocumentAs:`, `saveDocumentTo:`, `duplicateDocument:`, `moveDocument:`,
    // `renameDocument:` and `revertDocumentToSaved:` each wrap themselves in
    // `performActivityWithSynchronousWaiting:YES` — the main thread parks on the document's
    // serialization semaphore until the current activity ends. Our activity ends on the main
    // actor, so with a save still running each of them is the RT-14 freeze under another
    // menu title. They are refused in words while a save runs; the menu items are disabled
    // for the same span by `validateUserInterfaceItem`.

    public override func saveAs(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.saveAs(sender)
    }

    public override func saveTo(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.saveTo(sender)
    }

    public override func duplicate(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.duplicate(sender)
    }

    public override func move(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.move(sender)
    }

    public override func rename(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.rename(sender)
    }

    public override func revertToSaved(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        super.revertToSaved(sender)
    }

    /// The actions that park the main thread on the document activity. Disabled while a
    /// save runs so the menu says so before anyone reaches the refusal. The list lives in
    /// the one command table (IM-183).
    static var saveActivityActions: [Selector] { ZenitDocumentActionTable.saveActivityActions }

    /// Revert to Saved and a Versions restore would call `read(from:ofType:)`, which only
    /// records a URL — nothing reloads once a session exists — and AppKit then marks the
    /// document clean. The unsaved takeoff stayed on screen reading as saved, close skipped the
    /// review and a Quick PDF deleted its crash-survival copy (BH-355). Until a reload path
    /// exists the two are refused in words and their menu items are disabled; the takeoff's
    /// own ⌘Z and History are the way back.
    public override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        guard core == nil else { throw ZenitDocumentError.revertUnavailable }
        try super.revert(toContentsOf: url, ofType: typeName)
    }

    static var revertActions: [Selector] { ZenitDocumentActionTable.revertActions }

    /// The rules — revert refused while a session exists (BH-355), save-activity doors
    /// disabled with a reason while a save runs (CR-147, IM-177) and with nothing loaded
    /// (CR-161) — live in the one command table (IM-183).
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let verdict = ZenitDocumentActionTable.validate(
            item,
            hasSession: core != nil,
            isSaveActivityBusy: isSaveActivityBusy,
            // The tooltip names a print as a print (S-017); a save, when there is one, wins.
            isPrintInPreparation: printActivityInFlight && !isSaveInFlight,
            hasDrawing: drawing != nil
        ) {
            return verdict
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Autosave in place is for project packages only.
    ///
    /// `autosavesInPlace` is `true` because a project must survive a crash. Returning `nil` here
    /// for a quick PDF is what stops AppKit from applying that policy to the drawing the user
    /// opened, which would write a takeoff into somebody's original file.
    public override nonisolated var autosavingFileType: String? {
        // AppKit asks for this off the main actor during a save cycle; `mode` only ever changes on
        // the main actor, in `read(from:ofType:)` and at the end of a successful package save.
        MainActor.assumeIsolated { mode == .project ? ZenitAppInfo.projectTypeIdentifier : nil }
    }

    /// NSDocument autosave is a no-op for a Quick PDF — its crash-survival copy is the
    /// container autosave store, written continuously by the session.
    ///
    /// This matters at quit: `-[NSApplication _shouldTerminate]` autosaves every dirty
    /// document *before* `applicationShouldTerminate` is consulted, and with
    /// `autosavingFileType == nil` that attempt degraded into the silent non-panel save
    /// `performSave` refuses in words — so ⌘Q died on an error alert and the
    /// Save / Don't Save / Cancel review in `canClose` never ran (found
    /// live). Completing without writing lets termination reach the review while the
    /// document honestly stays edited. (Reporting `hasUnautosavedChanges == false`
    /// instead made the entire quit path treat the takeoff as clean and discard it
    /// silently — also found live.)
    public override func autosave(
        withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        NSLog("ZENIT-QUIT autosave(withImplicitCancellability:) mode=%@", String(describing: mode))
        guard mode == .quickPDF else {
            // A periodic, cancellable autosave takes the light path in `performPackageSave`:
            // the live database is already current, so it writes the recovery snapshot, not
            // the nine-step package save with a version rotation (IM-049). The non-cancellable
            // autosave AppKit runs at close and quit keeps the full save.
            isLightAutosaveInFlight = autosavingIsImplicitlyCancellable
            super.autosave(
                withImplicitCancellability: autosavingIsImplicitlyCancellable,
                completionHandler: { [weak self] error in
                    self?.isLightAutosaveInFlight = false
                    completionHandler(error)
                }
            )
            return
        }
        completionHandler(nil)
    }

    /// Set while a periodic (implicitly cancellable) autosave is running (IM-049).
    private var isLightAutosaveInFlight = false

    /// Light autosaves and full saves performed. Test seams for IM-048/IM-049.
    private(set) var lightAutosaveCountForTesting = 0
    private(set) var fullPackageSaveCountForTesting = 0

    /// Drives the periodic-autosave path directly, as the autosave timer does. Test seam.
    func performLightAutosaveForTesting() async throws {
        guard let package = projectPackage, fileURL != nil else { return }
        isLightAutosaveInFlight = true
        defer { isLightAutosaveInFlight = false }
        try await lightAutosave(into: package, revisionAtSnapshot: localChangeRevision)
    }

    /// The periodic autosave: the takeoff into the live database, a recovery snapshot, and
    /// the change count marked autosaved. No manifest, no version rotation, no PDF hashing.
    ///
    /// Marked autosaved only as far as what was written (S-008, the light half of R-031):
    /// `revisionAtSnapshot` is the edit counter the caller read before the takeoff snapshot,
    /// and an edit that arrived while the archive and the recovery copy were being written
    /// leaves the document with unautosaved changes, so the next autosave picks it up.
    private func lightAutosave(into package: ProjectPackage, revisionAtSnapshot: Int) async throws {
        await packageSaveWillWriteHook?()
        try await writeTakeoffArchive(into: package)
        try await package.writeAutosave()
        lightAutosaveCountForTesting += 1
        if localChangeRevision == revisionAtSnapshot { updateChangeCount(.changeAutosaved) }
    }

    public override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        false
    }

    /// Every error AppKit raises against this document goes through ``ZenitErrorPresenter``.
    ///
    /// Diagnosed by `sample(1)` on two hung runs of
    /// `Scripts/build-app-package.sh`: an autosave failure reached
    /// `-[NSDocument presentError:]`, which ran `-[NSAlert runModal]` inside a headless
    /// test process. A modal loop with no user is a loop with no exit, so the gate hung
    /// instead of failing — and the same escalation in the shipping app would put a modal
    /// alert in front of the estimator at quit.
    ///
    /// Overriding here, rather than only fixing the one call site, is deliberate: the
    /// hanging call was **AppKit's**, made from inside `_saveIfNecessaryWithDelegate:`,
    /// and no amount of care at our own call sites would have caught it.
    ///
    /// The assembled app is unchanged: it still gets `NSDocument`'s own alert, sheeted on
    /// the document's window and carrying the recovery attempter, which is better than
    /// anything reconstructed here. Only the process that must not block is diverted, and
    /// `false` is returned there because nothing was recovered — claiming recovery would
    /// let AppKit continue an operation that actually failed.
    @discardableResult
    public override func presentError(_ error: any Error) -> Bool {
        guard ZenitErrorPresenter.presentsThroughAppKit else {
            ZenitErrorPresenter.present(error, in: windowForSheet)
            return false
        }
        return super.presentError(error)
    }

    /// AppKit's own Save-As panel, diverted in any process that has no user.
    ///
    /// `-[NSDocument runModalSavePanel:...]` is not a call site we own: AppKit
    /// reaches it from ⌘S on an unsaved document, from `saveDocumentAs:` and from the
    /// autosave machinery, and in a `swift test` process it puts a real save panel on the
    /// user's screen. Overriding here is the same reasoning `presentError` above records —
    /// *"the hanging call was AppKit's, and no amount of care at our own call sites would
    /// have caught it."*
    ///
    /// The delegate is answered with `didSave: false`, which is the truth: nothing was saved.
    /// Claiming otherwise would let AppKit close a document whose contents never reached disk.
    public override func runModalSavePanel(
        for saveOperation: NSDocument.SaveOperationType,
        delegate: Any?,
        didSave didSaveSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        // Re-entrancy is the freeze (RT-14): the second call blocks the main thread on the
        // document's activity semaphore and nothing can ever release it. No operation is
        // exempt — the earlier `.saveAsOperation` exception was the door CR-147 found open.
        // Checked before the divert below so the refusal is the same in the app and in a
        // test process.
        guard !refuseIfSaveActivityBusy() else {
            deliverSaveVerdict(
                false,
                delegate: delegate,
                selector: didSaveSelector,
                contextInfo: contextInfo
            )
            return
        }
        guard ZenitModalPresenter.canPresentModally, ZenitModalPresenter.handler == nil else {
            ZenitModalPresenter.recordDivertedAppKitPanel(Self.appKitSavePanelModalIdentifier)
            deliverSaveVerdict(
                false,
                delegate: delegate,
                selector: didSaveSelector,
                contextInfo: contextInfo
            )
            return
        }
        savePanelActivityInFlight = true
        super.runModalSavePanel(
            for: saveOperation,
            delegate: delegate,
            didSave: didSaveSelector,
            contextInfo: contextInfo
        )
        // `super` returns when the panel closes. Cancel leaves no save behind; a Save that
        // is now running holds `isSaveTaskRunning` and reopens the doors in its own
        // completion, so the panel's own flag can drop here unconditionally.
        savePanelActivityInFlight = false
    }

    /// AppKit's own print panel, diverted for the same reason and in the same way.
    public override func runModalPrintOperation(
        _ printOperation: NSPrintOperation,
        delegate: Any?,
        didRun didRunSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        // The print panel is run inside the same synchronous activity wait (CR-147). Only a
        // save shuts this door: the print that got here is the one ⌘P is preparing (R-045).
        guard !refuseIfSaveInFlight() else {
            deliverSaveVerdict(
                false,
                delegate: delegate,
                selector: didRunSelector,
                contextInfo: contextInfo
            )
            return
        }
        guard ZenitModalPresenter.canPresentModally, ZenitModalPresenter.handler == nil else {
            ZenitModalPresenter.recordDivertedAppKitPanel(Self.appKitPrintPanelModalIdentifier)
            deliverSaveVerdict(
                false,
                delegate: delegate,
                selector: didRunSelector,
                contextInfo: contextInfo
            )
            return
        }
        super.runModalPrintOperation(
            printOperation,
            delegate: delegate,
            didRun: didRunSelector,
            contextInfo: contextInfo
        )
    }

    /// The stable names of the two panels AppKit itself runs against this document.
    public static let appKitSavePanelModalIdentifier = "appkit.savePanel"
    public static let appKitPrintPanelModalIdentifier = "appkit.printPanel"

    /// Calls a `document:didSave:contextInfo:`-shaped delegate back, the shape AppKit expects
    /// from both diverted panels above. Same mechanism as ``deliverCloseVerdict``.
    private func deliverSaveVerdict(
        _ succeeded: Bool,
        delegate: Any?,
        selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let selector, let object = delegate as? NSObject else { return }
        guard let method = object.method(for: selector) else { return }
        typealias Verdict = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Verdict.self)(object, selector, self, succeeded, contextInfo)
    }

    /// The sheet-presenting form, for the same reason.
    ///
    /// A sheet does not block a run loop, so this form never caused the 15.8 hang — but it
    /// is the same door and belongs behind the same seam, so a test's error is recorded
    /// rather than drawn. In the app `super` runs, which is also what answers
    /// `didPresentSelector` correctly; reconstructing that callback here would have to
    /// forge a `BOOL` argument through `perform(_:with:with:)`, which passes a pointer.
    public override func presentError(
        _ error: any Error,
        modalFor window: NSWindow,
        delegate: Any?,
        didPresent didPresentSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard ZenitErrorPresenter.presentsThroughAppKit else {
            ZenitErrorPresenter.present(error, in: window)
            return
        }
        super.presentError(
            error,
            modalFor: window,
            delegate: delegate,
            didPresent: didPresentSelector,
            contextInfo: contextInfo
        )
    }

    public override func close() {
        isClosed = true
        // The shared-review watcher holds its timer and file presenter until it is stopped;
        // only Disconnect stopped it, so a closed project's watcher ran on (R-030).
        SharedReviewAutoSync.stop(document: self)
        // Judged now, before AppKit's close runs: the clean-takeoff rule of
        // ``shutDownStorage(discardingCleanQuickAutosave:)``.
        let discardAutosave = hasDisposableQuickAutosave
        let shutdown = Task { @MainActor in
            await self.shutDownStorage(discardingCleanQuickAutosave: discardAutosave)
        }
        // Registered so quit can *await* it: `ProjectPackage.close()` is what disarms
        // the crash marker, and a process that exits before the task runs leaves a
        // cleanly-quit project claiming it crashed (the false recovery
        // prompt).
        Self.registerStorageShutdown(shutdown)
        super.close()
    }

    /// Whether the document still holds storage whose closing matters at quit.
    public var hasOpenStorage: Bool {
        drawing != nil || projectPackage != nil
            || quickStorage.holdsStorage
            || searchIndex != nil
            || pendingLoad?.holdsResources == true
    }

    /// Whether this document's container autosave holds nothing worth keeping: a quick takeoff
    /// that is clean — saved, discarded, or never edited. An edited one keeps its autosave: that
    /// is the crash-survival copy (a restored takeoff counts as edited until it is saved).
    var hasDisposableQuickAutosave: Bool {
        mode == .quickPDF && !isDocumentEdited
    }

    /// Closes every storage handle this document holds, awaited. Closing the project
    /// package is what removes `recovery/crash-marker`; a clean quit must wait for it.
    /// Idempotent: a second call finds the fields already nil.
    ///
    /// A clean quick takeoff also leaves nothing behind in the container (L-31). Quit calls
    /// this, not ``close()``, for every document its review left open — and those are exactly
    /// the clean ones — so the rule lives here rather than in ``close()`` alone, where it used
    /// to: a quick PDF still open at a clean quit kept `Autosave/<UUID>/history.sqlite`.
    public func shutDownStorage() async {
        await shutDownStorage(discardingCleanQuickAutosave: hasDisposableQuickAutosave)
    }

    /// ``shutDownStorage()`` with the clean-takeoff verdict given: ``close()`` judges it before
    /// AppKit's close runs, and the shutdown task runs after.
    func shutDownStorage(discardingCleanQuickAutosave discardAutosave: Bool) async {
        loadTask?.cancel()
        scopedAccessRelease?()
        scopedAccessRelease = nil
        quickStorage.cancelScheduled()
        markupIndexTask?.cancel()
        textIndexTask?.cancel()
        ocrRunTask?.cancel()
        let source = drawing?.rasterSource
        let addedDrawings = drawingSet
        drawingSet = nil
        let package = projectPackage
        let index = searchIndex
        // A load still running holds its own resources, not the document's (IM-047); they
        // are closed here too, or quit would leave a package that is still opening armed.
        let loading = pendingLoad
        // The drawing's password goes with the drawing (BH-069).
        drawingPassword = nil
        drawing = nil
        projectPackage = nil
        searchIndex = nil
        batchSearchScopeResolver = nil
        await source?.close()
        await addedDrawings?.closeAdded()
        try? await package?.close()
        // Queued behind a container autosave still writing, never under it (IM-181).
        await quickStorage.shutDown(discardingDirectory: discardAutosave)
        await index?.shutDown()
        await loading?.shutDown()
    }

    /// In-flight storage shutdowns from ``close()``. Termination drains this so the
    /// process never exits between a window closing and its crash marker coming down.
    private static var pendingStorageShutdowns: [Task<Void, Never>] = []

    static func registerStorageShutdown(_ task: Task<Void, Never>) {
        pendingStorageShutdowns.append(task)
        // A finished shutdown leaves the list, so `hasPendingStorageShutdowns` means pending,
        // not "ever registered" (BH-336's termination guard reads it).
        Task { @MainActor in
            await task.value
            pendingStorageShutdowns.removeAll { $0 == task }
        }
    }

    /// Awaits every registered shutdown, including any that arrive while waiting.
    ///
    /// The list is emptied *after* the wait, not before it. Taking the tasks out first made a
    /// second, overlapping drain see an empty list and return immediately — while the closes
    /// it was supposed to be waiting for were still running. That is the difference between
    /// "every crash marker is down" and "somebody else is bringing them down", and the second
    /// one is not what this method's callers are promised. It showed up as an intermittent
    /// failure in the quit-review test, which assessed a project package a few milliseconds
    /// before its own close had disarmed the marker.
    /// Whether any storage shutdown is still queued — possibly for a document already gone
    /// from the controller (BH-336).
    public static var hasPendingStorageShutdowns: Bool { !pendingStorageShutdowns.isEmpty }

    public static func drainStorageShutdowns() async {
        while true {
            let tasks = pendingStorageShutdowns
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
            let completed = Set(tasks)
            pendingStorageShutdowns.removeAll { completed.contains($0) }
        }
    }

    public override var displayName: String! {
        get {
            if let url = fileURL ?? pendingURL {
                return url.deletingPathExtension().lastPathComponent
            }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    // MARK: - Loading

    /// Opens the recorded URL, or builds an empty session when the document is untitled.
    public func startLoadingIfNeeded() {
        guard core == nil, loadTask == nil else { return }
        isLoading = true
        onStateChange?()
        // Everything the load builds lives in this value until one synchronous adopt (IM-047).
        let state = LoadedDocumentState()
        let pipeline = makeLoadPipeline()
        pendingLoad = state
        loadTask = Task { @MainActor [weak self] in
            guard let self else {
                await state.shutDown()
                return
            }
            do {
                try await pipeline.run(into: state)
                // The last check. Nothing awaits between it and the end of `adopt(_:)`, so a
                // document can no longer close between a resource arriving and its adoption.
                try await self.abortLoadIfClosed(discarding: state)
                self.adopt(state)
            } catch is CancellationError {
                // Closed mid-load. Not a failure, and nothing to present.
            } catch {
                self.loadFailure = error
            }
            self.pendingLoad = nil
            self.isLoading = false
            self.loadTask = nil
            self.onStateChange?()
        }
    }

    /// How the password of an encrypted drawing is asked for (LT-38). The shipping value
    /// runs ``DrawingPasswordPrompt`` through the one modal door; a test injects the
    /// outcome here — the password is a value no `ZenitModalAnswer` can carry, so this
    /// seam sits above the panel, like the recovery prompt's does. Tests restore it in a
    /// `defer`; nothing under `Apps/ZenitPDF/Sources` may reassign it.
    public static var passwordPrompt: (@MainActor (_ fileName: String) -> String?) = { fileName in
        DrawingPasswordPrompt.ask(fileName: fileName)
    }

    /// The load still running, if any: what it has built so far is its own until
    /// ``adopt(_:)``, and ``shutDownStorage()`` closes it (IM-047).
    private(set) var pendingLoad: LoadedDocumentState?

    /// Runs at every load checkpoint (``DocumentLoadStage``) before the "closed yet?" check.
    /// A test seam: set it before ``startLoadingIfNeeded()`` to fail the load, or close the
    /// document, at one stage. Nothing under `Apps/ZenitPDF/Sources` sets it.
    var loadStageHook: (@MainActor (DocumentLoadStage, LoadedDocumentState) async throws -> Void)?

    /// The load, as a pipeline that never touches this document: what it needs is handed
    /// over here, and what it builds comes back in a ``LoadedDocumentState``.
    private func makeLoadPipeline() -> DocumentLoadPipeline {
        var pipeline = DocumentLoadPipeline(
            request: DocumentLoadPipeline.Request(
                url: pendingURL,
                mode: mode,
                promptURL: fileURL ?? pendingURL,
                displayName: displayName,
                undoManager: undoManager ?? UndoManager(),
                toolPresetContainer: toolPresetContainer
            ),
            // A tab closed while the load is still awaiting must not finish loading (CR-150).
            isAbandoned: { [weak self] in (self?.isClosed ?? true) || Task.isCancelled },
            // The key is a claim, not a resource: it is set on the document during the load so
            // a second document opening the same drawing at the same moment sees it (BH-358).
            claimSearchIndexKey: { [weak self] digest, projectID in
                guard let self else { return digest }
                let key = Self.searchIndexKey(
                    digest: digest,
                    projectID: projectID,
                    documentIdentity: self.documentIdentity,
                    keysInUse: Self.liveSearchIndexKeys(excluding: self)
                )
                self.searchIndexKey = key
                return key
            }
        )
        pipeline.stageHook = loadStageHook
        return pipeline
    }

    /// A tab closed while the load was still running must not finish loading: before CR-150
    /// the raster source, session, FTS index, history database and index tasks were all
    /// created on a closed document and never torn down, and reopening the same drawing
    /// shared the SQLite file the zombie was still writing. The pipeline checks at every
    /// stage; this is the last check, right before adoption, and it discards the whole value.
    private func abortLoadIfClosed(discarding state: LoadedDocumentState) async throws {
        guard isClosed || Task.isCancelled || state.isShutDown else { return }
        await state.shutDown()
        throw CancellationError()
    }

    /// Takes over everything one load built, in one synchronous step on the main actor
    /// (IM-047), and wires it into the window's environment. There is no await in here: a
    /// document is either fully loaded or holds nothing the load built.
    func adopt(_ state: LoadedDocumentState) {
        guard let session = state.session, let environment = state.environment,
              let library = state.toolLibrary else {
            // Unreachable: the pipeline returns only a complete value. Never half-adopt one.
            assertionFailure("adopt(_:) was handed an incomplete load")
            Task { await state.shutDown() }
            return
        }
        let pages = state.pages
        projectPackage = state.projectPackage
        photoStore = state.photoStore
        photoStoreFailure = state.photoStoreFailure
        drawing = state.drawing
        drawingPassword = state.drawingPassword
        adoptDrawingSet(from: state)   // NL-DOCS-04, before `markAdopted` empties the state
        if let restored = state.restoredAutosave {
            quickStorage.adoptRestored(package: restored.package, directory: restored.directory)
        }
        restoredFromAutosave = state.restoredFromAutosave
        hydrationStartedAt = state.hydrationStartedAt
        searchIndexOpenStartedAt = state.searchIndexOpenStartedAt
        importedLedgerColumns.append(contentsOf: state.importedColumns)
        let index = state.searchIndex
        let searchIndexFailed = state.searchIndexFailed
        let conflictFolderUnchecked = state.conflictFolderUnchecked
        state.markAdopted()

        primaryCore = environment
        // A photo sidecar that refused to open before the core existed says so now (BH-359).
        if let photoStoreFailure { environment.document.post(Self.photoStoreWarning(photoStoreFailure)) }
        // X-049: a folder the open could not look in is said, never passed off as "no copies".
        if let conflictFolderUnchecked {
            ConflictFolderAccess.postFolderNotChecked(besides: conflictFolderUnchecked, document: self, core: environment)
        }
        // A restored takeoff is unsaved work: the document says so from the first frame.
        if restoredFromAutosave { updateChangeCount(.changeDone) }
        // The three facts a stamp's dynamic fields resolve against. They
        // live in the document, not in the core, so they are handed over here rather than
        // reached for: a stamp that says "Block C" says it because the document was called
        // that when the stamp was placed, and the value is frozen into the markup from there.
        environment.documentDisplayName = displayName ?? ""
        environment.projectDisplayName = displayName ?? ""
        environment.documentRevisionName = ""
        environment.document.setTabs([tabSummary(pageCount: pages.count)], active: documentIdentity)

        // The Tool Library's saved presets. Adopted here, *before* the shell
        // is built, because `ProjectShellEnvironment.init` seeds the toolbar's Count palette from
        // `toolLibrary.presets`: loading them afterwards would fill the panel and leave the
        // palette empty. The write half is `onPresetsChanged` below — the presenter fires it on
        // a favourite or a reorder, and `applyToolPresets(_:)` is the door the Tool Library
        // panel's own editing model comes through.
        //
        // Two stores, not one: the person's sets come
        // from the application container and the project's set from the `.zpdfproj`, merged
        // under `ToolPresetScopeRule`. The load is total — a project opens even when the
        // personal library is unreadable — so a failure arrives as a warning below and never as
        // a document that refuses to open. Quick PDF Mode has no package and still gets the
        // person's tools, which it never did before.
        //
        // The shipped set, seeded once. `DefaultToolSet.seeding` is a no-op the moment any of
        // the six is already present, so this runs on a library that has never seen them and
        // never again — including for an estimator who deleted all six, which is a decision and
        // not a state to be repaired. A seeded library is persisted immediately, or the six
        // would reappear as "new" on every launch and the first favourite would look like the
        // thing that created them.
        // The review stamps (NL-PDF-22) seed on their own identity, once, so a library that
        // already had the six tools still gains them.
        let seeded = DefaultToolSet.seedingReviewStamps(DefaultToolSet.seeding(library.presets))
        environment.toolLibrary.setPresets(seeded)
        // Legacy project-scoped rows this package carried before the two-store split (CR-3):
        // remembered so a save routes them back into the package, never into the container.
        legacyProjectPresetIDs = library.legacyProjectPresetIDs
        // What the *project* held when it was opened. `persistToolPresets(_:)` marks the document
        // edited by comparing against this, so a write that only touches the person's container
        // library cannot dirty a drawing nobody has drawn on. Recorded before the seeding write,
        // because the seeded six are container-scoped and must not read as a project change.
        persistedProjectPresets = Self.projectScoped(library.presets)
        if seeded.count != library.presets.count {
            persistToolPresets(seeded)
        }
        // Which mode each set is in, remembered across launches.
        let modeStore = ToolSetModeStore(defaults: toolSetModeDefaults)
        environment.toolLibrary.adoptSetModes(modeStore.read())
        environment.toolLibrary.onSetModesChanged = { modes in
            modeStore.write(modes)
        }
        if let failure = library.containerFailure {
            postToolLibraryWarning(
                environment: environment,
                title: NSLocalizedString(
                    "Your personal Tool Library could not be read.",
                    comment: "Warning shown when the app-container tool preset store is unreadable"
                ),
                message: String(
                    format: NSLocalizedString(
                        "This project's own tools are available. The saved personal library was left untouched: %@",
                        comment: "Detail of the container tool library read failure"
                    ),
                    failure
                )
            )
        }
        environment.toolLibrary.onPresetsChanged = { [weak self, weak environment] presets in
            guard let self, let environment else { return }
            // Persisted, and shown in any second window on the document (NL-UX-20).
            self.toolPresetsChangedInWindow(presets, from: environment)
        }

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        compareProvider = provider
        // Revision Compare opens a SECOND untrusted PDF — the one being compared against — so its
        // page raster and page-box reads cross into GeometryService.xpc rather than parsing inside
        // this process (security finding S17-02). `.automatic()` uses the service in the assembled
        // bundle and falls back in-process under `swift test`, where there is no service to reach.
        let compareSource = ServiceBackedRevisionDocumentSource.automatic()
        assert(compareSource.isolation == .outOfProcess || NSClassFromString("XCTest") != nil,
               "Revision Compare must parse the compared document out of process in a real bundle")
        let comparator = RevisionComparator(source: compareSource)
        revisionComparator = comparator
        let compare = AppComparePresenter(comparator: comparator)
        comparePresenter = compare
        // Accept and Accept All in Revision Compare once ticked the difference and created
        // nothing. `AppComparePresenter` calls
        // `onPromoteDiff` from both (`AppComparePresenter.swift:135` and `:145`) and nothing
        // ever assigned it, so the review's whole purpose — turning a found change into a
        // markup somebody downstream can see — stopped at a checkmark in a sheet the person
        // was about to close.
        //
        // Routed through the command bus rather than written directly, so a promoted
        // difference is one undoable step like every other markup, and lands in the audit
        // trail with the same provenance.
        compare.onPromoteDiff = { [weak self] diff in
            self?.promoteCompareDifference(diff)
        }

        // Search over the real index. Adopted before the shell so the
        // panel is never handed a placeholder it would have to be swapped out of later.
        adoptSearchIndex(index, failed: searchIndexFailed, pages: drawing?.pages ?? pages, documentID: state.documentID)
        openDrawingSetSearch()   // NL-DOCS-04: the project's other drawings, searched with it
        LedgerNumberComposition.install()
        let shellEnvironment = ProjectShellEnvironment(
            document: environment.document,
            canvas: environment.canvas,
            ledger: environment.ledger,
            toolLibrary: environment.toolLibrary,
            search: searchPresenter,
            compare: compare,
            measurement: environment.measurement,
            status: environment.status
        )
        primaryShell = shellEnvironment
        // Everything a window's shell takes from the document. A second window's shell goes
        // through the same function (NL-UX-20, `Window/ProjectWindowController+SecondWindow.swift`).
        wireWindowShell(shellEnvironment, core: environment, isFirstWindow: true)

        // The snap index is built after the window is live: Vector Snap is unavailable until it
        // finishes, which the status bar says out loud, and that is better than a window that
        // will not appear until every edge of a 400-page set has been indexed. Every sheet gets
        // its own index the first time it is on screen (K-01); the environment asks for the
        // sheet on screen now as soon as the source is installed.
        let firstSheetID = pages.first?.id
        environment.snapIndexSource = { [weak self] page in
            await self?.buildSnapIndex(for: page, isFirstSheet: page.id == firstSheetID) ?? AppCoreEnvironment.SnapIndexBuild()
        }

        // Layer catalogue (gap 10): read `/OCProperties` through the engine barrier and
        // wire the Navigator's toggles into the real per-document visibility set. A
        // drawing with no layers leaves the model empty and the
        // Navigator on its markup-derived fallback.
        layerVisibility.onVisibilityChange = { [weak self] in self?.layerVisibilityChanged() }
        // nl-ux: layer overrides follow the page. The render filter and the snap index are
        // per page, so a page turn while a layer is hidden recomputes both for the new page.
        let pageChange = environment.document.onPageChange
        environment.document.onPageChange = { [weak self, weak environment] page in
            pageChange?(page)
            // Only this window's canvas: another window shows its own sheet (S-009).
            guard let environment else { return }
            self?.layerPageDidChange(in: environment)
        }
        refreshSymbolLegend()
        offerDrawingFileScale()   // NL-PLAT-06
        offerDrawingFileContents()   // NL-PDF-03 restore + NL-PDF-15 signatures (Workflows/EmbeddedTakeoffRestore.swift)
        if let source = drawing {
            Task { @MainActor [weak self] in
                let tree = try? await source.rasterSource.layerTree()
                guard let self else { return }
                self.layerVisibility.adopt(tree: tree)
                // R-205: a project's hidden layers stay hidden across save and reopen.
                if self.mode == .project, let package = self.projectPackage {
                    await self.layerVisibility.attach(archive: LayerOverrideArchive(package: package))
                }
                self.applyNavigatorLayerRows()
            }
        }

        // The scale proposal, per sheet (nl-automation): the sheet on screen
        // and every sheet turned to, each read from its own positioned text, the title block
        // preferred. Never applied by itself — CORE_LOOP.md's first silent-wrongness entry is a
        // scale nobody chose — and applying runs the ordinary calibrate bus. Reading page 0 only
        // offered nothing on a set whose first page is a cover sheet
        // (`Automation/ZenitPDFProjectDocument+SheetScale.swift`).
        if let first = pages.first { proposeScale(for: first) }
        environment.afterPageChange = { [weak self] page in self?.proposeScale(forPageID: page.id) }

        // The History tab's audit store: the package database in
        // Project Mode, the container autosave database in Quick PDF Mode.
        Task { @MainActor [weak self] in
            await self?.attachHistoryStore()
        }
        // Revisions kept with the project.
        restorePersistedRevisions()
    }

    /// Everything one window's shell takes from the document: the author badge, Scale Regions
    /// and Project Zones, the review threads, the Pages Index bookmarks, the Inspector's
    /// measurement rows, the Navigator's layer toggles, photographs, the warning tray's actions
    /// and the count-symbol legend.
    ///
    /// The first window's shell is wired by ``adopt(_:)``; NL-UX-20's second windows call it with
    /// their own shell over their own core view, so every window gets the same panels. The review
    /// look and the bookmark read happen once per document, for the first window; a second window
    /// takes the bookmarks the first one already has.
    func wireWindowShell(_ shell: ProjectShellEnvironment, core: AppCoreEnvironment, isFirstWindow: Bool) {
        // The top bar's author badge shows the name new markups are signed with — Settings ▸
        // General ▸ Author name, else the account name — not the machine's answer alone.
        shell.toolbar.authorNameProvider = { AuthorIdentity.current() }

        // Scale Regions and Project Zones. Both panels have existed with
        // no caller since they were written; this is the call that gives them a document.
        wireProjectStructure(shell: shell, core: core)
        // Text-box text and review threads (nl-collaboration; ZenitPDFProjectDocument+Review).
        wireReview(shell: shell, core: core, restoringLook: isFirstWindow)
        // The drawing's own bookmarks for the Pages Index (nl-documents, NL-DOCS-06).
        if !isFirstWindow, let first = primaryShell {
            shell.navigatorBookmarks = first.navigatorBookmarks
        } else if let drawing {
            shell.navigatorBookmarks = DocumentSessionLoader.navigatorBookmarks(
                for: drawing, password: drawingPassword
            )
        }
        if isFirstWindow { refineNavigatorBookmarks() }   // NL-DOCS-06: with each destination's left/top

        // The inspector's Measurement control rows. Subject edits go through
        // the command bus so they are undoable and audited; precision is display formatting
        // only — it changes the session's output units and re-snapshots, never a stored SI
        // value. The popup is seeded from the units actually in force, so it never claims a
        // precision the ledger is not using.
        shell.inspectorEditing.activePrecision =
            .decimalPlaces(core.snapshot.units.metricDecimalPlaces)
        shell.inspectorEditing.onEditSubject = { [weak core] (markupIDs: Set<UUID>, subject: String) in
            guard let core else { return }
            Task { @MainActor in
                await Self.applySubjectEdit(markupIDs: markupIDs, subject: subject, core: core)
            }
        }
        shell.inspectorEditing.onSetDecimalPrecision = { [weak core] (places: Int) in
            guard let core else { return }
            Task { @MainActor in
                var units = await core.session.displayUnits
                units.metricDecimalPlaces = max(0, min(9, places))
                try? await core.session.setUnits(units)
                await core.refresh()
            }
        }

        shell.navigatorLayers.onSetVisible = { [weak self] layerID, visible in
            self?.layerVisibility.setVisible(visible, layerID: layerID)
        }
        shell.navigatorLayers.onSetMeasureLock = { [weak self] layerID in
            self?.layerVisibility.setMeasureLock(layerID)
        }
        wirePhotoAttachments(into: shell)
        // The warning tray's action button. The callback existed and NOTHING assigned it,
        // so "Apply 1:50" called a nil closure — two presses, no scale, no words (LT-4,
        // 2026-08-29; the proposal machinery itself was proven by tests all along).
        shell.onWarningAction = { [weak self] warning in
            guard let self else { return }
            if self.holdsScaleProposal(warningID: warning.id) {
                self.applyScaleProposal(warningID: warning.id)
            } else if self.handleAutomationWarningAction(warning.id) {
                // An automation offer (nl-automation): islands deducted as cutouts.
            } else if self.handleDrawingFileScaleAction(warning.id) {
                // NL-PLAT-06: the scale the PDF's own measure dictionaries state.
            } else if self.handleScaleRegionOffer(warning.id) {
                // NL-AUTO-19 / NL-MEASURE-16: a Scale Region with its own ratio (Measure/ScaleRegionOffers.swift).
            } else if ConflictFolderAccess.handleNoteAction(warning.id, document: self) {
                // X-049: Allow Access… on "the project's folder was not checked".
            } else {
                ExportCompletion.handleAction(for: warning.id, document: self)
            }
        }
        shell.countSymbolLegend = { [weak self] in self?.symbolLegendRows ?? [] }
    }

    // MARK: - Layer visibility (gap 10)

    /// Pushes the effective layer rows into the Navigator — of every window (NL-UX-20).
    func applyNavigatorLayerRows() {
        let rows = layerVisibility.items.map { item in
            NavigatorLayerRow(
                id: item.id,
                name: item.name,
                isVisible: item.isVisible,
                isLocked: item.isLocked
            )
        }
        for shell in allWindowShells {
            shell.navigatorLayers.apply(rows: rows)
            shell.navigatorLayers.applyMeasureLock(layerVisibility.measureLockLayerID)
        }
    }

    /// One layer toggle, three consequences, in order: the snap index is rebuilt without
    /// the hidden layers, the canvas re-renders — through the content-stream path when the
    /// overrides differ from the document default — and the Navigator shows the state
    /// actually in force.
    private func layerVisibilityChanged() {
        applyNavigatorLayerRows()
        guard drawing != nil, let core else { return }
        // Invariant: a lock is named wherever the tool is named, or a snap that finds
        // nothing looks broken.
        if let lockName = layerVisibility.measureLockLayerName {
            core.status.setActiveToolNote(String(
                format: NSLocalizedString(
                    "Measuring on %@ only",
                    comment: "Status note while measuring is locked to one layer"
                ),
                lockName
            ))
        } else if layerVisibility.measureLockLayerID == nil {
            // Lifting the lock clears the note rather than leaving a stale claim.
            core.status.setActiveToolNote(nil)
        }
        // The other sheets' snap indexes were built under the old layer state (K-01): drop them,
        // and each is rebuilt the next time it is on screen. The sheet on screen is rebuilt below.
        if let primary = drawing?.documentID {
            let onScreen = core.document.currentPageID.map(PageID.init)
            let session = core.session
            Task { await session.discardSnapIndexes(ofDrawing: primary, keeping: onScreen) }
        }
        refreshLayerRendering(includesAnnotations: true)
    }

    /// Re-renders the canvas after the drawing's annotation display state changed outside a
    /// layer toggle (NL-UX-04's hidden originals): through the layer path when overrides are in
    /// force, otherwise by handing the canvas the native render again, which drops its tiles.
    func rerenderAfterAnnotationDisplayChange() {
        if layerVisibility.matchesDocumentDefault && layerVisibility.measureLockLayerID == nil {
            onLayerRenderingChange?(nil)
        } else {
            refreshLayerRendering(includesAnnotations: false)
        }
    }

    /// A page turn: while any override or a measure lock is in force, the new page needs its
    /// own filter and snap index (nl-ux). With the document default in force there is nothing
    /// to recompute — the native render and the load-time index are already truthful.
    ///
    /// - Parameter windowCore: the core of the window whose page turned; only that window's
    ///   canvas is refiltered (S-009). `nil` refilters every window.
    func layerPageDidChange(in windowCore: AppCoreEnvironment? = nil) {
        guard !layerVisibility.matchesDocumentDefault || layerVisibility.measureLockLayerID != nil else {
            return
        }
        refreshLayerRendering(includesAnnotations: false, onlyIn: windowCore)
    }

    /// The zero-based index of the page `windowCore`'s window shows, or 0 before any page is shown.
    func layerPageIndex(on windowCore: AppCoreEnvironment) -> Int {
        guard let drawing, let current = windowCore.document.currentPageID,
              let page = drawing.pages.first(where: { $0.id.rawValue == current }) else { return 0 }
        return page.index
    }

    /// The per-page half of a layer change, for the page on screen in each window: the snap
    /// index is rebuilt without the hidden layers and each canvas re-renders — through the
    /// content-stream path, with **its own page's** extraction, when the overrides hide marked
    /// content on it.
    ///
    /// Until nl-ux this used page 0 for all three: the hidden names, the extraction and the snap
    /// rebuild. On sheet 3 with a layer hidden, the canvas drew sheet 1's linework.
    ///
    /// Per window since S-009: one filter used to be built for the focused window's page and
    /// broadcast to every window, and a canvas replaces its single filter with each call and
    /// applies it only on that filter's page. So a page turn in window B gave window A, on
    /// another sheet, B's filter, and A's hidden layer showed again.
    private func refreshLayerRendering(includesAnnotations: Bool, onlyIn windowCore: AppCoreEnvironment? = nil) {
        guard let drawing else { return }
        // Layers are the primary drawing's (NL-DOCS-04): a window on a sheet of another drawing
        // keeps its native render and snap index.
        let plans: [(target: LayerRenderingTarget, pageIndex: Int, hidden: Set<String>, snapHidden: Set<String>)] =
            layerRenderingTargets
                .filter { windowCore == nil || $0.core === windowCore }
                .filter { target in
                    let page = target.core.document.currentPageID.flatMap(loadedDrawing(forPage:)) ?? drawing
                    return page.documentID == drawing.documentID
                }
                .map { target in
                    let pageIndex = layerPageIndex(on: target.core)
                    // Feature 30: the snap index alone honours the measure lock. The render keeps
                    // the person's visibility, so locking changes what snaps, never what they see.
                    return (
                        target,
                        pageIndex,
                        layerVisibility.hiddenMarkedContentNames(onPageIndex: pageIndex),
                        layerVisibility.snapHiddenMarkedContentNames(onPageIndex: pageIndex)
                    )
                }
        guard !plans.isEmpty else { return }
        let hiddenIDs = layerVisibility.hiddenLayerIDs
        let matchesDefault = layerVisibility.matchesDocumentDefault
        Task { @MainActor [weak self] in
            var annotationsPending = includesAnnotations
            for plan in plans {
                guard let self else { return }
                let core = plan.target.core
                let pageIndex = plan.pageIndex
                guard let extraction = await self.layerAwareExtraction(drawing: drawing, pageIndex: pageIndex) else { continue }
                // The person turned this window's page while the extraction ran: that turn
                // scheduled its own refresh, and this one would file the old page's filter
                // against the new page.
                guard self.layerPageIndex(on: core) == pageIndex else { continue }
                // Snap: a hidden layer is structurally absent from the rebuilt index (S23).
                if drawing.pages.indices.contains(pageIndex) {
                    let availability = try? await core.session.buildSnapIndex(
                        page: drawing.pages[pageIndex],
                        extraction: extraction,
                        hiddenLayerIDs: plan.snapHidden
                    )
                    core.setVectorSnapAvailability(availability)
                }
                if annotationsPending {
                    annotationsPending = false
                    await self.applyAnnotationLayerVisibility(drawing: drawing, hiddenIDs: hiddenIDs)
                }
                // Render path. The content-stream path exists because the native renderers honour
                // only the file's *default* configuration for marked content — but it renders
                // monochrome linework and drops annotations, so it is engaged only when a hidden
                // layer actually binds marked content on the page. A drawing whose layers bind only
                // annotations keeps the native render, in colour, with `shouldDisplay` doing the
                // hiding.
                let filtering = (matchesDefault || plan.hidden.isEmpty)
                    ? nil
                    : LayerFilteredPageRenderer.Filtering(extraction: extraction, hiddenLayerIDs: plan.hidden, pageIndex: pageIndex)
                plan.target.deliver(filtering)
                // Layer visibility is view state; nothing of it is persisted, so it must not
                // mark the document edited (CR-155).
            }
        }
    }

    /// The annotation half of a layer toggle, for every page at once.
    private func applyAnnotationLayerVisibility(drawing: LoadedDrawing, hiddenIDs: Set<PDFLayerID>) async {
        if self.annotationLayerBindings == nil {
            let report = try? await drawing.rasterSource.annotationLayerBindingReport()
            self.annotationLayerBindings = report?.bindings ?? []
            // Said, not hidden: a walk cut short leaves some annotations outside every
            // layer, so hiding a layer may not hide all of it (BH-177, host
            // half).
            if report?.wasTruncated == true {
                self.core?.document.post(AppWarning(
                    id: UUID(),
                    severity: .warning,
                    title: NSLocalizedString(
                        "Not every layer assignment in this drawing could be read.",
                        comment: "Warning when the annotation-layer walk was cut short"
                    ),
                    message: NSLocalizedString(
                        "Hiding a layer may leave some of its annotations visible.",
                        comment: "Detail of the truncated annotation-layer warning"
                    ),
                    source: NSLocalizedString("Layers", comment: "Warning source: drawing layers"),
                    timestamp: Date()
                ))
            }
        }
        if let bindings = self.annotationLayerBindings, !bindings.isEmpty {
            let changed = (try? await drawing.rasterSource.applyAnnotationLayerVisibility(
                bindings: bindings,
                hiddenLayerIDs: hiddenIDs
            )) ?? 0
            // The Navigator keeps its own images: without this, every row already drawn
            // went on showing the annotations the layer just hid (BH-886).
            if changed > 0 { self.invalidateThumbnailsAfterLayerChange() }
        }
    }

    /// Drops the Navigator's cached page images after a layer toggle changed what PDFKit
    /// draws, so each row re-requests under the new display state (BH-886).
    func invalidateThumbnailsAfterLayerChange() {
        for shell in allWindowShells { shell.navigatorThumbnails.invalidate() }   // NL-UX-20: every window
        layerThumbnailInvalidationCount += 1
    }

    /// How many times a layer toggle flushed the Navigator's images. Test affordance.
    private(set) var layerThumbnailInvalidationCount = 0

    /// The annotation→layer bindings, read once per drawing. `nil` until first read; empty when
    /// the drawing has none, so the read is not repeated.
    private(set) var annotationLayerBindings: [AnnotationLayerBindingReader.Binding]?

    /// The first page's snap index build, once it has finished. A test seam for BH-069.
    private(set) var firstPageSnapIndexResult: DocumentSessionLoader.SnapIndexResult?

    /// The password that unlocked an encrypted drawing: memory only, for this document's
    /// lifetime — the export and print drawer (BH-079) and every vector-extraction request
    /// (BH-069) need it. Never persisted, logged or cached; dropped in ``shutDownStorage()``.
    private(set) var drawingPassword: String?

    /// Builds one sheet's snap index for the environment (K-01), from that sheet's own drawing
    /// (NL-DOCS-04). While PDF layers are overridden on the primary drawing it is the same
    /// layer-aware build a layer change runs, so the two give one index whichever lands last and
    /// a hidden layer never becomes snappable (S23).
    func buildSnapIndex(for page: ZPDFContracts.PageDescriptor, isFirstSheet: Bool) async -> AppCoreEnvironment.SnapIndexBuild {
        guard let core, let source = loadedDrawing(forPage: page.id.rawValue) else { return AppCoreEnvironment.SnapIndexBuild() }
        if let drawing, source.documentID == drawing.documentID,
           !layerVisibility.matchesDocumentDefault || layerVisibility.measureLockLayerID != nil {
            let hidden = layerVisibility.snapHiddenMarkedContentNames(onPageIndex: page.index)
            let extraction = await layerAwareExtraction(drawing: drawing, pageIndex: page.index)
            let availability = try? await core.session.buildSnapIndex(page: page, extraction: extraction, hiddenLayerIDs: hidden)
            return AppCoreEnvironment.SnapIndexBuild(availability: availability)
        }
        let result = await DocumentSessionLoader.buildSnapIndex(
            for: page,
            documentURL: source.url,
            session: core.session,
            password: drawingPassword(forPage: page.id.rawValue)
        )
        if isFirstSheet {
            firstPageSnapIndexResult = result
            // The same extraction feeds the canvas's vector underlay. One scan, two uses.
            if let extraction = result.extraction { onVectorUnderlayReady?(page, extraction) }
        }
        return AppCoreEnvironment.SnapIndexBuild(availability: result.availability, failureReason: result.failureReason)
    }

    /// The extraction layer re-renders and rebuilds run on: taken once with hidden
    /// optional content included, so a default-hidden layer can be turned *on* as well.
    private func layerAwareExtraction(drawing: LoadedDrawing, pageIndex: Int) async -> VectorPageExtraction? {
        if let cached = layerAwareExtractions[pageIndex] { return cached }
        let extraction = try? await GeometryExtraction.client.extractPageGeometry(
            documentAt: drawing.url,
            pageIndex: pageIndex,
            options: GeometryWireOptions(includesHiddenOptionalContent: true, password: drawingPassword)
        )
        layerAwareExtractions[pageIndex] = extraction
        return extraction
    }

    // MARK: - Search

    /// Where drawing text indexes live. Overridable so tests keep out of the real container.
    public static var searchIndexRootOverride: URL?

    /// `Application Support/Zenit PDF/Search`, or a per-process temporary directory outside the
    /// assembled bundle — the same rule ``quickPDFAutosaveRoot`` follows, and for the same reason:
    /// a test process must never write into the user's real Application Support.
    ///
    /// The process identifier is part of the path outside the bundle because the index file is
    /// named after the drawing's SHA-256, and every test in this repository opens the *same*
    /// fixture bytes. Without it, two concurrently running test processes would share one index
    /// database and interfere with each other for no reason at all.
    public static var searchIndexRoot: URL {
        if let searchIndexRootOverride { return searchIndexRootOverride }
        if Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base
                .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
                .appendingPathComponent("Search", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
            .appendingPathComponent("Search-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// The index file this document uses.
    private(set) var searchIndexKey: String?

    /// Which index file a document opens.
    ///
    /// The index keeps the drawing's text *and* its markups, and markups are per takeoff. Keyed
    /// by the drawing's SHA alone, two documents over byte-identical PDFs — the same drawing in
    /// a second tab, or two projects made from one file — shared one database, and each
    /// reindex deleted the other's markup rows: search in A showed B's subjects (BH-358). A
    /// project keys by its own id (persistent across reopen); a Quick PDF keeps the SHA key —
    /// so a recognition run still survives quitting — unless another open document holds it.
    static func searchIndexKey(
        digest: String,
        projectID: String?,
        documentIdentity: UUID,
        keysInUse: Set<String>
    ) -> String {
        if let projectID { return "\(digest)-project-\(projectID)" }
        guard keysInUse.contains(digest) else { return digest }
        return "\(digest)-\(documentIdentity.uuidString)"
    }

    /// The index keys other open documents hold.
    static func liveSearchIndexKeys(excluding document: ZenitPDFProjectDocument) -> Set<String> {
        Set(NSDocumentController.shared.documents.compactMap { other in
            guard let other = other as? ZenitPDFProjectDocument, other !== document else { return nil }
            return other.searchIndexKey
        })
    }

    /// Opens the drawing's index and puts the real presenter behind the Search panel.
    ///
    /// The index is keyed by the file's SHA-256, so reopening an unchanged drawing re-reads
    /// nothing and a recognition run survives quitting. A failure here is reported to the panel
    /// as "search is unavailable", never as "no results" — the two are different answers and the
    /// second one is a lie.
    /// The working PDF's digest when the package opened under a verified integrity verdict —
    /// the hash that verdict already computed — or `nil`, which makes the provider hash.
    static func verifiedWorkingDigest(of package: ProjectPackage?, workingURL: URL) async -> FileDigest? {
        guard let package else { return nil }
        // The open hashes every member; the working PDF is trusted when it matched, even if
        // the database did not (a session that did not finish only leaves project.sqlite off).
        let verdict = await package.integrityVerdict
        guard verdict.isVerified || (
                  verdict.outcome == .damaged
                      && !verdict.mismatchedMembers.contains(ProjectPackageLayout.workingPDF)
                      && verdict.mismatchedMembers.allSatisfy { $0 == ProjectPackageLayout.database }
              ),
              let integrity = await package.integrity,
              let size = (try? FileManager.default.attributesOfItem(atPath: workingURL.path))?[.size] as? NSNumber
        else { return nil }
        return FileDigest(sha256: integrity.workingPdfSha256, byteCount: size.intValue)
    }

    /// When the background open began. IM-179's test reads it against hydration.
    private(set) var searchIndexOpenStartedAt: Date?
    /// When the stored takeoff began hydrating into the session, if there was one.
    private(set) var hydrationStartedAt: Date?

    /// Puts the real presenter behind the Search panel over the index the load opened, or
    /// says search is unavailable when the index could not be opened. Part of ``adopt(_:)``:
    /// the open itself ran in the load pipeline (IM-047, IM-179).
    private func adoptSearchIndex(
        _ index: DocumentSearchIndex?,
        failed: Bool,
        pages: [ZPDFContracts.PageDescriptor],
        documentID: DocumentID
    ) {
        guard let drawing else { return }
        let name = displayName ?? drawing.url.deletingPathExtension().lastPathComponent
        guard let index else {
            guard failed else { return }
            batchSearchScopeResolver = nil
            searchPresenter = UnavailableSearchPresenter(
                reason: NSLocalizedString(
                    "Search is unavailable for this drawing: its text index could not be opened.",
                    comment: "Search panel state when the index could not be opened"
                )
            )
            return
        }
        searchIndex = index
        let identity = index.identityMap(
            documentUUID: documentID.rawValue,
            documentTitle: name,
            pages: pages,
            currentPageIndex: 0
        )
        batchSearchScopeResolver = BatchSearchScopeResolver(
            service: index.service,
            projectID: index.projectKey,
            documentID: index.documentKey,
            identity: identity,
            // The set's added drawings too, as every other batch scope covers them (V-040).
            addedDrawings: { [weak self] in await self?.batchSearchScopeDrawings() ?? [] }
        )
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: identity
        )
        presenter.onReveal = { [weak self] hit in self?.reveal(hit) }
        // Search options ▸ Delete Search Index and Recognised Text… (V-079).
        presenter.onRequestIndexDeletion = { [weak self] in self?.confirmSearchIndexDeletion() }
        // "Current Page" follows the sheet on screen (R-048).
        core?.attachSearch(presenter)
        searchPresenter = presenter
        onSearchPresenterReady?()
        reindexDrawingText()
    }

    /// Reads the drawing's own text layer into the index, then the markups — at the open, and
    /// again after the index was deleted (V-079). ``settleTextIndexing()`` waits for it.
    ///
    /// The text layer is read in the background: the window must not wait on a 400-page
    /// extraction, and an index that is still filling reports honestly empty results.
    /// Utility priority: reading a 400-page text layer must never compete with the
    /// canvas, the save pipeline or the quit review for the machine.
    func reindexDrawingText() {
        guard let index = searchIndex else { return }
        textIndexTask?.cancel()
        textIndexTask = Task(priority: .utility) { @MainActor [weak self] in
            _ = try? await index.indexDrawingText()
            guard !Task.isCancelled else { return }
            await self?.reindexMarkups()
        }
    }

    /// The pages whose text contains `term`, for the batch sheet's search-term scope.
    ///
    /// Waits for the background read of the drawing's own text layer before answering. The
    /// Search panel deliberately does not wait — a panel that reports honestly empty
    /// results while an index fills is fine, because the person can search again. A batch
    /// preview is not fine: it is the number the person checks before placing 312 stamps,
    /// and a count that was short because the index was half-read is the exact class of
    /// quiet wrongness this scope was rebuilt to remove.
    func pageIDsContaining(_ term: String) async -> BatchSearchScopeResolution {
        guard let batchSearchScopeResolver else {
            return .unavailable(
                term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: NSLocalizedString(
                    "Search is unavailable for this drawing, so this scope cannot be previewed.",
                    comment: "Batch apply search scope when the drawing has no text index"
                )
            )
        }
        await settleTextIndexing()
        return await batchSearchScopeResolver.resolve(term: term)
    }

    /// Waits for the background read of the drawing's own text layer to finish.
    ///
    /// The panel never waits on this — an index that is still filling reports honestly empty
    /// results, which is the point. Tests do, and they must: the extraction runs at `.utility`
    /// priority on the main actor, so a suite that is loading documents in six other suites at
    /// once can starve it for tens of seconds. Polling for a hit with a timeout turned a real
    /// assertion into a coin flip (observed: the same test 0.08 s alone, 23.5 s and failing in
    /// the full run). Awaiting the task itself is the same assertion without the coin.
    ///
    /// Returns immediately when there is no index, so a caller cannot hang on a drawing whose
    /// index failed to open.
    func settleTextIndexing() async {
        await textIndexTask?.value
    }

    // MARK: - Site photographs (feature 15)

    /// The Inspector's photo rows, mirrored from the actor-isolated store so the panel can
    /// read them synchronously. Rebuilt after every add and remove.
    private var photoRowsByMarkup: [UUID: [InspectorPhotoRow]] = [:]

    /// How "Attach Photograph…" asks for a file. Injectable so a test can answer without a
    /// panel — a test may never put a window or a sheet on screen.
    static var photoFileChooser: (@MainActor (NSWindow?) async -> URL?) = { window in
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.message = NSLocalizedString(
                "Choose a photograph to attach to the selected markup.",
                comment: "Open panel message for attaching a site photograph"
            )
            ZenitModalPresenter.runOpenPanel(
                panel,
                identifier: "photo.attach.openPanel",
                sheetedOn: window
            ) { answer in
                continuation.resume(returning: answer.firstURL)
            }
        }
    }

    /// Mounts the site-photograph sidecar inside the package's `attachments/` member, so
    /// the save pipeline's tree sync and version clones carry it. The open-time sweep
    /// reclaims blobs a crash left unreferenced. Called from both roads into Project Mode:
    /// opening a package and Save As from Quick PDF.
    private func mountPhotoStore(packageURL: URL) {
        switch Self.openPhotoStore(packageURL: packageURL) {
        case .success(let store):
            photoStoreFailure = nil
            photoStore = store
        case .failure(let error):
            // The store refuses to open empty over real photographs — a corrupt or newer
            // manifest — and that refusal was swallowed: the project opened with no photo UI
            // and nothing said why (BH-359). Said now; the blobs stay untouched on disk.
            photoStoreFailure = error
            core?.document.post(Self.photoStoreWarning(error))
        }
    }

    /// Opens the photo sidecar of the package at `packageURL` and starts its open-time sweep.
    /// Shared by ``mountPhotoStore(packageURL:)`` and the load pipeline (IM-047), which holds
    /// the store until the document adopts it.
    static func openPhotoStore(packageURL: URL) -> Result<PhotoStore, any Error> {
        let photosDirectory = packageURL
            .member(ProjectPackageLayout.attachments)
            .appendingPathComponent(PhotoStore.sidecarDirectoryName, isDirectory: true)
        let store: PhotoStore
        do {
            store = try PhotoStore(directory: photosDirectory)
        } catch {
            return .failure(error)
        }
        Task.detached(priority: .utility) { _ = try? await store.sweepUnreferencedBlobs() }
        return .success(store)
    }

    /// Why the photo sidecar could not be opened, when it could not. BH-359's seam.
    private(set) var photoStoreFailure: (any Error)?

    static let photoStoreWarningID = UUID(uuidString: "B7E1C9A2-4F63-4E1D-9A0B-2C5D8E7F6A13")!

    /// The warning for a photo sidecar that would not open.
    static func photoStoreWarning(_ error: any Error) -> AppWarning {
        AppWarning(
            id: photoStoreWarningID,
            severity: .warning,
            title: NSLocalizedString(
                "This project's photographs could not be opened.",
                comment: "Warning headline when the photo sidecar manifest cannot be read"
            ),
            message: String(
                format: NSLocalizedString(
                    "The photos are still in the project folder and nothing was deleted. Photo rows are hidden until this is fixed. Reason: %@",
                    comment: "Warning detail for an unreadable photo sidecar; the reason"
                ),
                String(describing: error)
            ),
            source: NSLocalizedString("Photos", comment: "Warning source for photo attachments"),
            isDismissible: true,
            timestamp: Date()
        )
    }

    private func wirePhotoAttachments(into environment: ProjectShellEnvironment) {
        guard photoStore != nil else { return }
        environment.photoAttachments = { [weak self] markupID in
            self?.photoRowsByMarkup[markupID] ?? []
        }
        environment.onAttachPhoto = { [weak self] markupID in
            self?.attachPhotograph(to: markupID)
        }
        environment.onRemovePhoto = { [weak self] markupID, attachmentID in
            self?.removePhotograph(attachmentID, from: markupID)
        }
        Task { @MainActor [weak self] in await self?.refreshPhotoRows() }
    }

    private func refreshPhotoRows() async {
        guard let photoStore else { return }
        let attachments = await photoStore.allAttachments()
        var rows: [UUID: [InspectorPhotoRow]] = [:]
        for attachment in attachments {
            rows[attachment.markupID.rawValue, default: []].append(InspectorPhotoRow(
                id: attachment.id.rawValue,
                label: Self.photoRowLabel(for: attachment)
            ))
        }
        photoRowsByMarkup = rows
        // The rows live on the document; the panel re-renders off this observable tick — in
        // every window (NL-UX-20).
        for shell in allWindowShells { shell.photoTick.revision &+= 1 }
    }

    /// What the Inspector's photo row says about one attachment.
    ///
    /// LT-31: the row used to show only "320 × 240 px", so several photos on one markup
    /// were indistinguishable. The caption leads when there is one — and since
    /// ``attachPhotograph(to:)`` seeds the caption with the source file's name, a freshly
    /// attached photo reads as "IMG_0142.jpeg · 320 × 240 px" rather than as bare pixels.
    /// The dimensions stay on every row because they are the one fact that tells two
    /// same-named files apart. Attachments from before the filename seeding fall back to
    /// the capture date, then to the dimensions alone — their filename was never stored
    /// and cannot be invented now.
    static func photoRowLabel(for attachment: PhotoAttachment) -> String {
        let dimensions = "\(attachment.pixelWidth) × \(attachment.pixelHeight) px"
        if let caption = attachment.caption, !caption.isEmpty {
            return "\(caption) · \(dimensions)"
        }
        if let captured = attachment.capturedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "\(formatter.string(from: captured)) · \(dimensions)"
        }
        return dimensions
    }

    private func attachPhotograph(to markupID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let photoStore = self.photoStore else { return }
            guard let url = await Self.photoFileChooser(self.windowForSheet) else { return }
            do {
                // Through the store's bounded read: loading the whole file first allocated a
                // 1.5 GB scan before the 128 MiB budget refused it (BH-360). The source file's
                // name becomes the initial caption, which the row label leads with (LT-31).
                _ = try await photoStore.addPhoto(
                    contentsOf: url,
                    to: MarkupID(markupID),
                    caption: url.lastPathComponent
                )
                await self.projectPackage?.registerEdit()
                self.updateChangeCount(.changeDone)
                await self.refreshPhotoRows()
            } catch let refusal as PhotoImportRefusal {
                // The budget's refusals carry their numbers; say them, never store anyway.
                self.core?.status.setActiveToolNote(refusal.reason)
            } catch {
                self.core?.status.setActiveToolNote(String(describing: error))
            }
        }
    }

    private func removePhotograph(_ attachmentID: UUID, from markupID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let photoStore = self.photoStore else { return }
            let attachments = await photoStore.attachments(forMarkup: MarkupID(markupID))
            guard let match = attachments.first(where: { $0.id.rawValue == attachmentID }) else { return }
            do {
                try await photoStore.removeAttachment(match.id)
            } catch {
                // Refused: say so, and do not mark a document changed that did not change
                // (BH-893).
                self.core?.status.setActiveToolNote(String(describing: error))
                await self.refreshPhotoRows()
                return
            }
            await self.projectPackage?.registerEdit()
            self.updateChangeCount(.changeDone)
            await self.refreshPhotoRows()
        }
    }

    /// Raised when the drawing's real search presenter replaces the placeholder, so the
    /// window can rewire every open drawing's project-wide search sources.
    var onSearchPresenterReady: (@MainActor () -> Void)?

    /// Raised when the person picks a hit that lives in another open drawing. The window
    /// owns the tabs, so the window is the one that can switch to it.
    var onRevealForeignHit: (@MainActor (ZPDFUIPresentation.SearchHit) -> Void)?

    /// This drawing as a search source for the other drawings' "All Drawings" fan-out,
    /// or `nil` while the index is still opening.
    func projectSearchSource() -> ZPDFUIPresentation.ProjectSearchSource? {
        guard let presenter = searchPresenter as? AppSearchPresenter else { return nil }
        let name = displayName ?? drawing?.url.deletingPathExtension().lastPathComponent ?? ""
        return ZPDFUIPresentation.ProjectSearchSource(
            documentID: documentIdentity,
            title: name,
            search: { [weak presenter] text, options in
                await presenter?.hitsForProjectSearch(text, options: options) ?? []
            }
        )
    }

    /// Installs the other open drawings as this drawing's fan-out sources.
    func installProjectSearchSources(_ sources: [ZPDFUIPresentation.ProjectSearchSource]) {
        windowSearchSources = sources
        // The project's other drawings are searched with it (NL-DOCS-04).
        (searchPresenter as? AppSearchPresenter)?.externalSources = sources + (drawingSet?.searchSources ?? [])
    }

    /// The other open tabs' sources, as the window last installed them.
    var windowSearchSources: [ZPDFUIPresentation.ProjectSearchSource] {
        get { drawingSetWindowSources }
        set { drawingSetWindowSources = newValue }
    }

    /// The window hands a foreign hit back to the drawing it belongs to through this.
    func revealFromProjectSearch(_ hit: ZPDFUIPresentation.SearchHit) {
        reveal(hit)
    }

    /// Scrolls the canvas to a search hit and selects the markup it came from, when it came
    /// from one.
    private func reveal(_ hit: ZPDFUIPresentation.SearchHit) {
        // A hit from another drawing cannot be revealed here — its page ids belong to that
        // drawing. The window switches tabs and forwards it to its owner.
        if let foreign = hit.sourceDocumentID, foreign != documentIdentity {
            onRevealForeignHit?(hit)
            return
        }
        guard let core else { return }
        // A search hit is a jump: ⌘[ comes back here (NL-DOCS-09).
        if let place = currentPlaceProvider?() { navigationHistory.willJump(from: place) }
        core.document.goToPage(id: hit.pageID)
        if let markupID = hit.markupID {
            core.canvas.select(markupIDs: [markupID], additive: false)
            core.canvas.zoomTo(markupID: markupID)
            return
        }
        if let bounds = hit.boundsInPageSpace {
            core.canvas.onScrollTo?(bounds, true)
        } else if let presenter = searchPresenter as? AppSearchPresenter {
            // A hit this drawing listed in another drawing's "All Drawings" search carries no
            // rectangle; it is located now that the person asked for it (R-153).
            Task { @MainActor [weak self] in
                guard let bounds = await presenter.projectSearchBounds(forHit: hit.id) else { return }
                self?.core?.canvas.onScrollTo?(bounds, true)
            }
        }
    }

    /// Rewrites the markup half of the index from the session's own markups.
    ///
    /// Called after the drawing opens and, debounced, after every edit. Without it a search for a
    /// subject the estimator typed a minute ago would find nothing while the panel claimed to be
    /// searching markups.
    // MARK: - Count-symbol legend (feature 19)

    /// The ledger legend's rows, mirrored from the actor-isolated session so the pane can
    /// read them synchronously. Derived from placed marks — never from the live presets.
    private(set) var symbolLegendRows: [LedgerSymbolLegendRow] = []

    /// Rebuilds the count-symbol legend. An edit asks for it debounced: every record crossed
    /// the actor on each keystroke of a subject, geometry included (IM-247). A stream of edits
    /// now costs one read after it pauses.
    private func refreshSymbolLegend(debounced: Bool = false) {
        symbolLegendTask?.cancel()
        symbolLegendTask = Task { @MainActor [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            guard let self, let core = self.core else { return }
            self.symbolLegendReadCountForTesting += 1
            let markups = await core.session.orderedMarkups
            guard !Task.isCancelled else { return }
            self.symbolLegendRows = CountSymbolLegend.entries(markups: markups).map { entry in
                LedgerSymbolLegendRow(
                    id: entry.id,
                    subject: entry.subject,
                    symbolName: entry.symbolDisplayName,
                    markCount: entry.markCount
                )
            }
        }
    }

    private var symbolLegendTask: Task<Void, Never>?
    /// How many times the legend read the session's markups. IM-247's counter.
    private(set) var symbolLegendReadCountForTesting = 0

    func reindexMarkups() async {
        guard let index = searchIndex, let core else { return }
        let state = await core.session.takeoffState()
        // Each drawing's markups go into that drawing's index (NL-DOCS-04): a page index names
        // a page only within its own PDF.
        let primaryID = drawing?.documentID
        let own = state.pages.filter { $0.documentID == primaryID || primaryID == nil }
        let ownIDs = Set(own.map(\.id))
        // S-035: custom values and zone names feed the Search panel's Custom Fields source.
        _ = try? await index.indexMarkups(state.markups.filter { ownIDs.contains($0.pageID) }, pages: own,
                                          columns: state.customColumns, zones: state.projectZones)
        if let set = drawingSet {
            for (documentID, memberIndex) in set.searchIndexes {
                let pages = state.pages.filter { $0.documentID == documentID }
                let ids = Set(pages.map(\.id))
                _ = try? await memberIndex.indexMarkups(state.markups.filter { ids.contains($0.pageID) }, pages: pages,
                                                        columns: state.customColumns, zones: state.projectZones)
            }
        }
    }

    /// Coalesces edits into one re-index. Search is not worth a database write per keystroke.
    private func scheduleMarkupReindex() {
        guard searchIndex != nil else { return }
        markupIndexTask?.cancel()
        markupIndexTask = Task(priority: .utility) { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.reindexMarkups()
        }
    }

    // MARK: - Text recognition

    /// The languages this Mac's recogniser offers, filtered to the ones the sheet knows how to
    /// name. Empty when Vision reports nothing, which the sheet shows as "no languages".
    public static func supportedRecognitionLanguages() -> [String] {
        DocumentSearchIndex.supportedRecognitionLanguages()
    }

    /// Runs recognition for the OCR sheet.
    ///
    /// The model owns the sheet's state; this owns the engine. Each page is reported back as it
    /// is committed, so the sheet's per-page confidence is the confidence the index actually
    /// stored, and cancelling stops the run at a page boundary rather than mid-write.
    ///
    /// Pages are named by identity, never by index (W-016): a page index is a key within one
    /// PDF, so page 0 of the primary drawing and page 0 of an added drawing share it. Each
    /// drawing's pages are read into that drawing's own index, one drawing after another, and
    /// every committed page is reported under the identity it was asked for. A drawing whose
    /// index could not be opened is left unread — the sheet then shows its pages "Not read
    /// yet" — and a run none of whose drawings has an index fails as not ready.
    ///
    /// - Parameters:
    ///   - pageIDs: the pages to read, by identity.
    ///   - languageIDs: BCP-47 identifiers, in priority order.
    ///   - skipsPagesWithText: leave pages that already carry a real text layer alone.
    ///   - onPage: one committed page, with the identity it was asked for.
    ///   - onFinish: `nil` on success, or the failure to show.
    public func runTextRecognition(
        pageIDs: [UUID],
        languageIDs: [String],
        skipsPagesWithText: Bool,
        onPage: @escaping @MainActor (UUID, DocumentSearchIndex.RecognizedPage) -> Void,
        onFinish: @escaping @MainActor ((any Error)?) -> Void
    ) {
        let batches = recognitionBatches(for: pageIDs)
        guard !batches.isEmpty else {
            onFinish(ZenitDocumentError.documentNotReady)
            return
        }
        ocrRunTask?.cancel()
        ocrRunGeneration &+= 1
        let generation = ocrRunGeneration
        ocrRunTask = Task { @MainActor [weak self] in
            do {
                var read = false
                for batch in batches {
                    try Task.checkCancellation()
                    guard let index = await self?.searchIndex(forDrawing: batch.documentID) else { continue }
                    read = true
                    let pageIDByIndex = batch.pageIDByIndex
                    _ = try await index.recognize(
                        pageIndices: batch.pageIndices,
                        languageIDs: languageIDs,
                        skipsPagesWithText: skipsPagesWithText,
                        progress: { page in
                            Task { @MainActor in
                                if let id = pageIDByIndex[page.pageIndex] { onPage(id, page) }
                            }
                        }
                    )
                }
                onFinish(read ? nil : ZenitDocumentError.documentNotReady)
            } catch {
                onFinish(Task.isCancelled ? nil : error)
            }
            // Only the run that is still current clears the handle: a cancelled run finishing
            // late used to nil out its replacement, and Cancel went inert for the rest of that
            // run (BH-361).
            if self?.ocrRunGeneration == generation { self?.ocrRunTask = nil }
        }
    }

    /// Identifies the current recognition run (BH-361).
    private var ocrRunGeneration = 0

    /// Whether a recognition run is in flight. BH-361's seam.
    var isRecognizingText: Bool { ocrRunTask != nil }

    /// Stops a recognition run. The page in flight finishes so its rows are whole.
    public func cancelTextRecognition() {
        ocrRunTask?.cancel()
    }

    /// Stops a recognition run and waits for the page in flight to be committed, so nothing a
    /// run recognised can land after the recognised text was deleted (V-079).
    func stopTextRecognition() async {
        ocrRunTask?.cancel()
        await ocrRunTask?.value
    }

    // MARK: - Revisions

    /// Adds a dropped drawing as a new revision of this document (the `⌥`
    /// drop), so Revision Compare has something to compare against.
    ///
    /// The first added revision also installs the current drawing as the baseline. A failure
    /// is reported in one sentence and leaves the existing document untouched.
    public func addRevision(fromDroppedFile url: URL, label: String? = nil, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let compare = comparePresenter, let provider = compareProvider, let drawing else {
            completion?(false)
            return
        }
        Task { @MainActor in
            do {
                try await self.registerCurrentDrawingAsBaseline()
                let opened = try await provider.open(fileAt: url)
                let name = label ?? url.deletingPathExtension().lastPathComponent
                let summary = RevisionSummary(
                    id: UUID(),
                    documentID: drawing.documentID.rawValue,
                    name: name,
                    revisionLabel: name,
                    author: "",
                    pageCount: opened.descriptor.pageCount,
                    isBaseline: false,
                    colorRGBA: ColorRGBA(red: 0.94, green: 0.56, blue: 0.30),
                    fileName: url.lastPathComponent
                )
                let page = RevisionPageReference(
                    document: opened.handle,
                    pageIndex: 0,
                    fileURL: url,
                    label: name
                )
                compare.addRevision(summary, page: page)
                self.revisionPages[summary.id] = page
                // In Project Mode the revision is kept in the
                // package (a real edit, so the document is marked edited there); a Quick PDF has
                // no package and the revision stays for this session only, unedited (CR-155).
                await self.keepRevision(
                    summaryID: summary.id, url: url, handle: opened.handle, provider: provider, label: name
                )
                completion?(true)
            } catch {
                ZenitErrorPresenter.present(error, in: self.windowForSheet)
                completion?(false)
            }
        }
    }

    /// The bounds a promoted cloud uses. On the baseline's own page, the baseline's page space
    /// comes first: the comparison's bounds are in the comparison's page space, which stops
    /// matching the sheet the moment an alignment or a different MediaBox origin applies
    /// (BH-894). An addition has no baseline bounds, so the comparison's are the only place.
    nonisolated static func cloudBounds(for diff: CompareDiffSummary, placedOnBaseline: Bool) -> PDFRectValue? {
        placedOnBaseline
            ? (diff.baselineBounds ?? diff.comparisonBounds)
            : (diff.comparisonBounds ?? diff.baselineBounds)
    }

    /// Turns one accepted Revision Compare difference into a revision cloud on the drawing.
    ///
    /// A revision cloud is the trade's own notation for "this part of the
    /// sheet changed", which is exactly what the review just asserted, so nothing is invented
    /// by the promotion: the geometry is the difference's own page bounds and the subject
    /// names the revision it came from.
    ///
    /// **Which page.** The baseline is this document's own drawing (see
    /// ``registerCurrentDrawingAsBaseline()``), so the difference's page is the baseline
    /// reference's page. When there is no baseline reference — a comparison between two
    /// dropped revisions — the cloud goes on the page the canvas is showing, because that is
    /// the only page of *this* document the person is looking at, and refusing to place it at
    /// all would put the control straight back where it started.
    func promoteCompareDifference(_ diff: CompareDiffSummary) {
        guard let core, let drawing else { return }
        let baselinePageIndex = comparePresenter?.baselineRevisionID
            .flatMap { revisionPages[$0] }?
            .pageIndex
        // The sheet by identity, never by set position (X-012): both indices are PDF-local —
        // the baseline's is an index into the primary drawing's file, the viewport's the sheet
        // on screen's own — and `snapshot.pages` is in set order, so once the set was
        // rearranged, or another drawing's sheets came first, the cloud landed on another sheet
        // at this one's coordinates, or the Accept was silently dropped.
        let page: ZPDFContracts.PageDescriptor?
        if let baselinePageIndex {
            page = drawing.pages.first { $0.index == baselinePageIndex }
        } else {
            page = pageDescriptor(forPage: core.canvas.viewport.pageID)
        }
        guard let page, core.snapshot.pages.contains(where: { $0.id == page.id.rawValue }) else {
            core.status.setActiveToolNote(NSLocalizedString(
                "The difference was not marked: its sheet is not in this project's set.",
                comment: "Status note: a Revision Compare difference could not be placed on a sheet"
            ))
            return
        }
        let pageID = page.id
        // Neither bounds means the difference names no place on a sheet and there is nothing
        // honest to cloud.
        guard let bounds = Self.cloudBounds(for: diff, placedOnBaseline: baselinePageIndex != nil) else { return }
        let now = Date()
        let subject = String(
            format: NSLocalizedString(
                "Revision Compare · %@",
                comment: "Subject of a markup promoted from a Revision Compare difference"
            ),
            diff.pageLabel.isEmpty ? diff.changeKind.displayName : diff.pageLabel
        )
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: page.documentID,
            pageID: pageID,
            kind: .revisionCloud,
            subject: subject,
            label: diff.changeKind.displayName,
            style: MarkupStyle(color: .init(red: 0.94, green: 0.56, blue: 0.30, alpha: 1), lineWidth: 1.5),
            geometry: MeasurementGeometry(pageID: pageID, points: [
                PDFPoint(x: bounds.origin.x, y: bounds.origin.y),
                PDFPoint(x: bounds.origin.x + bounds.size.width, y: bounds.origin.y + bounds.size.height)
            ]),
            createdAt: now,
            modifiedAt: now
        )
        Task { @MainActor [weak self] in
            do {
                // The bus counts the change; an extra changeDone left ⌘Z short of clean (R-018).
                try await core.commands.perform(.addMarkup(record))
                await core.refresh()
            } catch {
                ZenitErrorPresenter.present(error, in: self?.windowForSheet)
            }
        }
    }

    /// Registers the open drawing as the baseline revision, if nothing has been registered yet.
    ///
    /// Revision Overlay needs this as much as the `⌥` drop does. A person who opens the mode on
    /// a single drawing has *one* revision, and the pane's job is then to say so and offer the
    /// way to add a second — which it cannot do over an empty list, because an empty list looks
    /// like a failure rather than like a starting point.
    ///
    /// One registration at a time (L-57): the check for an empty list and the registration are
    /// separated by the open of the drawing, so Revision Overlay filling its pane and Add
    /// Revision… started together both found the list empty and registered two baselines. A
    /// second caller now waits for the registration in flight and registers nothing.
    @discardableResult
    public func registerCurrentDrawingAsBaseline() async throws -> Bool {
        if let running = baselineRegistration {
            _ = try await running.value
            return false
        }
        let registration = Task { @MainActor in try await self.registerBaselineNow() }
        baselineRegistration = registration
        defer { baselineRegistration = nil }
        return try await registration.value
    }

    /// The baseline registration in flight, if any (L-57).
    private var baselineRegistration: Task<Bool, any Error>?

    /// The registration itself: the open drawing becomes the baseline revision when the list
    /// is empty.
    private func registerBaselineNow() async throws -> Bool {
        guard let compare = comparePresenter, let provider = compareProvider, let drawing else {
            return false
        }
        guard compare.revisions.isEmpty else { return false }
        let label = NSLocalizedString("Current", comment: "Revision label for the open drawing")
        let baseline = try await provider.open(fileAt: drawing.url)
        let summary = RevisionSummary(
            id: UUID(),
            documentID: drawing.documentID.rawValue,
            name: displayName ?? drawing.url.deletingPathExtension().lastPathComponent,
            revisionLabel: label,
            author: "",
            pageCount: drawing.pages.count,
            isBaseline: true,
            colorRGBA: ColorRGBA(red: 0.30, green: 0.69, blue: 0.94),
            fileName: drawing.url.lastPathComponent
        )
        let page = RevisionPageReference(
            document: baseline.handle,
            pageIndex: core?.canvas.viewport.pageIndex ?? 0,
            fileURL: drawing.url,
            label: label
        )
        compare.addRevision(summary, page: page)
        revisionPages[summary.id] = page
        return true
    }

    /// Every revision's page for the sheet on screen now (BH-386). The baseline was frozen
    /// at the page it was registered on and dropped revisions always used page 0, so after a
    /// page turn the overlay kept stacking the first sheet. Each revision follows the canvas's
    /// page index, clamped to its own page count.
    ///
    /// Paired by sheet number, because the page index alone put a
    /// different sheet under every sheet after an inserted one (`+Revisions.swift`).
    ///
    /// `core` is the window whose sheet the overlay follows (T-011); `nil` is the focused one.
    func overlayPages(for core: AppCoreEnvironment? = nil) -> [RevisionSummary.ID: RevisionPageReference] {
        labelPairedOverlayPages(for: core ?? self.core)
    }

    /// Stable identity of this document in the tab bar.
    public private(set) lazy var documentIdentity: UUID = UUID()

    /// This document's chip in the tab strip. The window controller aggregates one of
    /// these per attached document.
    func makeTabSummary() -> DocumentTabSummary {
        tabSummary(pageCount: core?.snapshot.pages.count ?? drawing?.pages.count ?? 0)
    }

    private func tabSummary(pageCount: Int) -> DocumentTabSummary {
        DocumentTabSummary(
            id: documentIdentity,
            title: displayName ?? NSLocalizedString("Untitled", comment: "Fallback document title"),
            fileName: (fileURL ?? pendingURL)?.lastPathComponent ?? "",
            fileURL: fileURL ?? pendingURL,
            pageCount: pageCount,
            hasUnsavedChanges: isDocumentEdited,
            isActive: true,
            mode: mode == .project ? .project : .standalonePDF,
            symbolName: mode == .project ? "folder" : "doc.richtext"
        )
    }

    /// Refreshes the tab strip after a save, a rename or an edit. In a window that hosts
    /// several documents the whole strip is re-aggregated; a lone document keeps the
    /// single-summary behaviour so it stays testable without a window.
    public func refreshTabSummary() {
        // NL-UX-20: a second window on this document shows the same dot and title.
        for view in windowViews where view.controller !== hostWindowController {
            view.controller?.refreshTabState()
        }
        if let hostWindowController {
            // The cheap refresh: an edit, a save or a rename changes the dot, the title and
            // perhaps the path, never the window's set of drawings (R-021).
            hostWindowController.refreshTabState()
            return
        }
        guard let core else { return }
        core.document.setTabs([tabSummary(pageCount: core.snapshot.pages.count)], active: documentIdentity)
    }

    /// The scale proposal waiting for the user's Apply, keyed by the warning that offers it.
    var pendingScaleProposals: [UUID: (proposal: ScaleProposal, pageID: ZPDFContracts.PageID)] = [:]

    /// Offers a found scale through the warning tray.
    ///
    /// An `.info` row, dismissible, with the Apply action carrying the ratio in its title so the
    /// decision is legible before the press. Skipped entirely when the page already has a scale:
    /// proposing 1:100 over a calibration the estimator made by hand would be the tool second-
    /// guessing the person.
    func presentScaleProposal(_ proposal: ScaleProposal, pageID: ZPDFContracts.PageID) {
        guard let core else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let existing = await core.session.scale(onPage: pageID)
            guard existing == nil else { return }
            let warningID = UUID()
            self.pendingScaleProposals[warningID] = (proposal, pageID)
            core.document.post(AppWarning(
                id: warningID,
                severity: .info,
                title: String(
                    format: NSLocalizedString(
                        "The drawing says %@.",
                        comment: "Scale proposal title; the ratio, e.g. 1:100"
                    ),
                    proposal.displayString
                ),
                message: proposal.needsUserChoice
                    ? NSLocalizedString(
                        "More than one scale is printed on this sheet; the best match for the sheet size is offered. Check the title block before applying.",
                        comment: "Scale proposal detail when the sheet names several scales"
                    )
                    : String(
                        format: NSLocalizedString(
                            "Found in the title block (%@). Apply it, or calibrate by hand as usual.",
                            comment: "Scale proposal detail; the matched text"
                        ),
                        proposal.evidence.matchedText
                    ),
                source: NSLocalizedString("Scale proposal", comment: "Warning source"),
                actionTitle: String(
                    format: NSLocalizedString("Apply %@", comment: "Scale proposal action; the ratio"),
                    proposal.displayString
                ),
                isDismissible: true,
                timestamp: Date()
            ))
        }
    }

    /// Applies a proposed scale as the drawing ratio it is (ADR-0019).
    ///
    /// Through the bus, so the audit trail, undo and the per-page scale are a calibration's —
    /// but as `setPresetScale`: `source == .preset` and no calibration evidence. It used to
    /// calibrate from two synthetic points (0,0)-(100,0), so the stored scale claimed a
    /// two-point calibration and every derivation cited two points nobody picked.
    func applyScaleProposal(warningID: UUID) {
        guard let core, let pending = pendingScaleProposals.removeValue(forKey: warningID) else { return }
        Task { @MainActor in
            // Re-checked at the press, not only at the offer. The offer is posted while the page
            // is uncalibrated, but the estimator can calibrate by hand while the banner sits
            // there — and Apply must never overwrite a calibration a person made. The banner
            // simply comes down.
            if await core.session.scale(onPage: pending.pageID) != nil {
                core.document.dismissWarning(id: warningID)
                return
            }
            do {
                _ = try await core.commands.setPresetScale(
                    page: pending.pageID,
                    ratioNumerator: Decimal(pending.proposal.ratio.numerator),
                    ratioDenominator: Decimal(pending.proposal.ratio.denominator),
                    label: pending.proposal.displayString
                )
            } catch {
                // A refused calibrate used to vanish with the banner: no scale, and nothing said
                // so (BH-895, the CR-156 gap). The offer stays up and the refusal is named.
                self.pendingScaleProposals[warningID] = pending
                core.document.post(AppWarning(
                    id: UUID(),
                    severity: .warning,
                    title: NSLocalizedString(
                        "The suggested scale was not applied.",
                        comment: "Warning when applying a detected scale proposal was refused"
                    ),
                    message: error.localizedDescription,
                    source: NSLocalizedString("Scale", comment: "Warning source: drawing scale"),
                    timestamp: Date()
                ))
                return
            }
            core.document.dismissWarning(id: warningID)
            await core.refresh()
        }
    }

    /// Whether a warning is a scale proposal this document is holding.
    func holdsScaleProposal(warningID: UUID) -> Bool {
        pendingScaleProposals[warningID] != nil
    }

    /// Bumped by every edit, undo and redo of this document (not by saves or autosaves). The
    /// shared-review watcher's "changed here" signal: it used to hash every markup, reply and
    /// page scale every four seconds to find out (R-036).
    private(set) var localChangeRevision = 0

    /// AppKit's token half of change counting — the delegate save path and the autosave
    /// cycle both bracket `save(to:ofType:for:completionHandler:)` with it — never calls
    /// `updateChangeCount(_:)`, so an edited-state move made on that side reached the
    /// window chrome but not the tab strip: the chip's dot went stale (LT-32's second
    /// mechanism). Re-aggregating here closes that hole for every token adjustment.
    public override func updateChangeCount(
        withToken changeCountToken: Any,
        for saveOperation: NSDocument.SaveOperationType
    ) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        refreshTabSummary()
    }

    public override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        // Every edit, undo and redo made here — the bus's undo groups and the review's replies
        // reach this through the document's undo manager — as one cheap counter.
        switch NSDocument.ChangeType(rawValue: change.rawValue & 0xFF) {
        case .changeDone, .changeUndone, .changeRedone: localChangeRevision &+= 1
        default: break
        }
        refreshTabSummary()
        if change == .changeDone {
            // A subject typed a minute ago must be findable. The re-index is debounced, so a
            // stream of edits costs one database write rather than one per keystroke.
            scheduleMarkupReindex()
            refreshSymbolLegend(debounced: true)
        }
        if mode == .quickPDF, change == .changeDone {
            scheduleQuickPDFAutosave()
        }
    }

    // MARK: - Quick PDF Mode container storage

    /// Where quick takeoffs autosave. Overridable so tests keep out of the real container.
    public static var quickPDFAutosaveRootOverride: URL?

    /// The app container's autosave home for takeoffs that have no project yet:
    /// `Application Support/Zenit PDF/Autosave`. Under the sandbox this resolves inside
    /// the container; nothing under it is ever a sibling of the user's drawing.
    ///
    /// Outside the assembled bundle — `swift test`, `swift run` — the root falls back to
    /// the temporary directory: a test process must never write into the user's real
    /// Application Support, and only the real app has the container this path promises.
    public static var quickPDFAutosaveRoot: URL {
        if let quickPDFAutosaveRootOverride { return quickPDFAutosaveRootOverride }
        let base: URL
        if Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent(ZenitAppInfo.displayName, isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    /// This takeoff's own autosave directory inside the container.
    public var quickPDFAutosaveDirectory: URL {
        quickStorage.directory
    }

    /// Builds the one Quick PDF storage this document delegates to (IM-181). The closures
    /// hold the document weakly: a queued write that outlives it answers "not ready".
    private func makeQuickStorage() -> QuickTakeoffStorage {
        let identity = documentIdentity
        let storage = QuickTakeoffStorage(
            defaultDirectory: {
                Self.quickPDFAutosaveRoot.appendingPathComponent(identity.uuidString, isDirectory: true)
            },
            origin: { [weak self] in
                guard let self else { throw ZenitDocumentError.documentNotReady }
                guard self.mode == .quickPDF else { throw ZenitDocumentError.quickModeRequiresProject }
                guard let drawing = self.drawing else { throw ZenitDocumentError.documentNotReady }
                return QuickTakeoffStorage.Origin(
                    originalPDF: drawing.url,
                    pageCount: drawing.pages.count,
                    displayName: self.displayName ?? "Takeoff"
                )
            },
            writeArchive: { [weak self] package in
                guard let self else { throw ZenitDocumentError.documentNotReady }
                try await self.writeTakeoffArchive(into: package)
            }
        )
        storage.didWrite = { [weak self] fullSave in
            if fullSave {
                self?.fullPackageSaveCountForTesting += 1
            } else {
                self?.lightAutosaveCountForTesting += 1
            }
        }
        return storage
    }

    /// Whether this document's takeoff came from a container autosave.
    public private(set) var restoredFromAutosave = false

    /// One container autosave that could be restored for a drawing.
    typealias RestorableQuickAutosave = QuickTakeoffStorage.Restorable

    /// The most recent container autosave written for a drawing with this digest by a
    /// session that is not running any more (CR-153).
    ///
    /// Autosaves that belong to documents open in this process are skipped — the same
    /// drawing in a second tab must not steal the first tab's work.
    static func restorableQuickAutosave(matchingDigest digest: String) -> RestorableQuickAutosave? {
        QuickTakeoffStorage.restorable(
            matchingDigest: digest,
            in: quickPDFAutosaveRoot,
            sparing: liveQuickAutosavePaths()
        )
    }

    /// The launch-time sweep, off the main thread (IM-237): the live set is read here, on the
    /// main actor, and the enumeration and removals run at utility priority.
    @discardableResult
    static func sweepStaleQuickAutosavesInBackground(
        olderThan age: TimeInterval = 30 * 24 * 3600
    ) -> Task<[URL], Never> {
        let root = quickPDFAutosaveRoot
        let live = liveQuickAutosavePaths()
        return Task.detached(priority: .utility) {
            removeStaleQuickAutosaves(in: root, sparing: live, olderThan: age, now: Date())
        }
    }

    /// The autosave directories documents open in this process hold — including one a load
    /// still running is restoring from, which is not the document's until it adopts (IM-047).
    private static func liveQuickAutosavePaths() -> Set<String> {
        var live: Set<String> = []
        for case let document as ZenitPDFProjectDocument in NSDocumentController.shared.documents {
            live.insert(document.quickPDFAutosaveDirectory.resolvingSymlinksInPath().path)
            if let claimed = document.pendingLoad?.claimedAutosaveDirectory {
                live.insert(claimed.resolvingSymlinksInPath().path)
            }
        }
        return live
    }

    nonisolated static func removeStaleQuickAutosaves(
        in root: URL,
        sparing live: Set<String>,
        olderThan age: TimeInterval,
        now: Date
    ) -> [URL] {
        QuickTakeoffStorage.removeStale(in: root, sparing: live, olderThan: age, now: now)
    }

    /// Debounced container autosave: edits coalesce for a moment, then land as one save.
    private func scheduleQuickPDFAutosave() {
        quickStorage.schedule()
    }

    /// Writes the quick takeoff into its container autosave package and returns where.
    ///
    /// This is the storage for an unsaved Quick PDF takeoff:
    /// the data lives in the app container until the user explicitly chooses a location
    /// through `Create Zenit PDF Project`. Nothing is ever written next to the drawing.
    ///
    /// ### Two of these must never run at once
    ///
    /// The write has an await in the middle of a create-if-absent: it checks for a container
    /// package, deletes any stale package directory, and awaits `ProjectPackage.create`. Two
    /// calls interleaving there — the debounced autosave firing while the quit review, a
    /// promotion or a test asks for one explicitly — both see no package, and the second one
    /// deletes the directory the first has an open SQLite file in. The first then fails its
    /// next statement with `SQLite error 10: disk I/O error`, which is how this was found:
    /// intermittently, in the container-autosave test, roughly two runs in five under load.
    ///
    /// So callers queue, in ``QuickTakeoffStorage``'s one serial queue (IM-181), behind every
    /// other container operation — retire and shutdown included. Each caller still gets a
    /// real save of the state at its turn.
    @discardableResult
    public func autosaveQuickPDFTakeoff() async throws -> URL {
        try await quickStorage.flush()
    }

    /// The autosave itself, outside the queue. A test seam (IM-048); production writes go
    /// through ``QuickTakeoffStorage/flush()`` and its serial queue.
    func performQuickPDFAutosave() async throws -> URL {
        try await quickStorage.write()
    }

    /// The container autosave package, for IM-048's test.
    var quickAutosavePackageForTesting: ProjectPackage? { quickStorage.package }

    /// Removes the container autosave — Don't Save, or a completed promotion.
    private func retireQuickPDFStorage() async {
        await quickStorage.retire()
    }

    /// The key a Quick PDF's audit rows are written under: the drawing's SHA-256, which is
    /// the same in the session that crashed and the one that restores it. The per-open
    /// `DocumentID` it used to be is minted fresh on every open, so a restored takeoff's
    /// History pane was empty and Create Project carried none of its trail (BH-362).
    static func quickHistoryProjectID(digest: String?, fallback: UUID) -> String {
        if let digest, !digest.isEmpty { return "quick-\(digest)" }
        return fallback.uuidString
    }

    /// Points the History feed at the right audit database for the mode: the package's
    /// `project.sqlite` in Project Mode, the container autosave database in Quick PDF
    /// Mode (the pane read nothing before this existed).
    private func attachHistoryStore() async {
        guard let core else { return }
        do {
            switch mode {
            case .project:
                guard let package = projectPackage else { return }
                let projectID = await package.manifest.projectId
                let database = await package.database
                core.history.attach(database: database, projectID: projectID)
            case .quickPDF:
                // Queued with the container's autosave and retire (IM-181).
                let database = try await quickStorage.openHistoryDatabase()
                core.history.attach(
                    database: database,
                    projectID: Self.quickHistoryProjectID(digest: drawing?.digest.sha256, fallback: documentIdentity)
                )
            }
        } catch {
            // Without a store the History pane states its honest empty state; the takeoff
            // itself is unaffected.
        }
    }

    // MARK: - Closing (the quit dead-end)

    /// What the three-button review decided.
    public enum UnsavedTakeoffDecision: Sendable, Equatable {
        case save
        case discard
        case cancel
    }

    /// The review presenter, injectable so tests can script Save / Don't Save / Cancel.
    /// The default presents the classic three-button alert on the document's window.
    public var unsavedTakeoffReview: (@MainActor (
        ZenitPDFProjectDocument,
        @escaping @MainActor (UnsavedTakeoffDecision) -> Void
    ) -> Void)?

    /// NL-UX-20: a window on a document that another window still shows closes without the
    /// unsaved-changes review — closing one window keeps the document open, and the review runs
    /// when its last window closes.
    ///
    /// AppKit asks this before `windowShouldClose(_:)`. It reviews when the closing controller is
    /// the document's *last window controller*, and window-controller ownership in a tabbed window
    /// follows the front tab, so a document whose tab is behind another in its first window can
    /// hold only its second window's controller — and would have been reviewed, and closed, with
    /// the first window still showing it.
    public override func shouldCloseWindowController(
        _ windowController: NSWindowController,
        delegate: Any?,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        if let controller = windowController as? ProjectWindowController,
           isShown(inAnotherWindowThan: controller) {
            if let delegate {
                deliverCloseVerdict(true, delegate: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
            }
            return
        }
        super.shouldCloseWindowController(
            windowController,
            delegate: delegate,
            shouldClose: shouldCloseSelector,
            contextInfo: contextInfo
        )
    }

    /// An edited Quick PDF closes like any document: Save / Don't Save / Cancel.
    ///
    /// Before this override, AppKit's `autosavesInPlace` path silent-saved the takeoff —
    /// which for a quick PDF meant manufacturing `<drawing>.pdf.zpdfproj` next to the
    /// user's original; the sandbox refused, a raw "error 18" alert blocked ⌘Q, and
    /// File ▸ Close was inert. Save routes to the Create-Project panel,
    /// Don't Save discards the container autosave cleanly, Cancel keeps working.
    public override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        NSLog("ZENIT-QUIT canClose: mode=%@ edited=%d", String(describing: mode), isDocumentEdited ? 1 : 0)
        // `canCloseDocumentWithDelegate:` waits synchronously for the document activity, and
        // ⌘W / ⌘Q during a running save — an autosave tick included — is the RT-14 freeze
        // again (CR-147). Closing cannot be refused (a close that silently does nothing is
        // the other failure), so it waits, off the main thread's back, until the save has
        // delivered its completion, and then asks the same question.
        if isSaveTaskRunning {
            // Woken when the save delivers its completion, not by polling every 25 ms (IM-248).
            Task { @MainActor [weak self] in
                await self?.waitUntilSaveTaskIdle()
                self?.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            }
            return
        }
        guard mode == .quickPDF, isDocumentEdited else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let deliver: (@MainActor (Bool) -> Void) = { [weak self] shouldClose in
            guard let self else { return }
            self.deliverCloseVerdict(
                shouldClose,
                delegate: delegate,
                selector: shouldCloseSelector,
                contextInfo: contextInfo
            )
        }
        let review = unsavedTakeoffReview ?? Self.presentUnsavedTakeoffAlert
        review(self) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .cancel:
                deliver(false)
            case .discard:
                Task { @MainActor in
                    await self.retireQuickPDFStorage()
                    self.updateChangeCount(.changeCleared)
                    deliver(true)
                }
            case .save:
                self.saveQuickPDFAsProject { saved in deliver(saved) }
            }
        }
    }

    /// Discard All from the quit summary: the same retirement Don't Save performs (IM-238).
    public func discardQuickTakeoffForQuit() async {
        guard mode == .quickPDF else { return }
        await retireQuickPDFStorage()
        updateChangeCount(.changeCleared)
    }

    /// Calls the `canClose` delegate back with the verdict, in the shape AppKit expects:
    /// `document:shouldClose:contextInfo:`.
    private func deliverCloseVerdict(
        _ shouldClose: Bool,
        delegate: Any,
        selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let selector, let object = delegate as? NSObject else { return }
        guard let method = object.method(for: selector) else { return }
        typealias Verdict = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Verdict.self)(object, selector, self, shouldClose, contextInfo)
    }

    /// The default three-button review, worded per UX_COPY_STANDARD: what happens, then
    /// the choice. Presented as a sheet where the document has a window, modally otherwise.
    /// Internal rather than private so `ModalInjectionTests` can drive the **default**
    /// review — the branch a test that forgets to inject `unsavedTakeoffReview` lands on,
    /// which is the branch that once put a real alert on screen.
    static func presentUnsavedTakeoffAlert(
        for document: ZenitPDFProjectDocument,
        completion: @escaping @MainActor (UnsavedTakeoffDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "Do you want to save the takeoff on “%@”?",
                comment: "Close review title for an edited Quick PDF; the drawing name"
            ),
            document.displayName ?? ""
        )
        alert.informativeText = NSLocalizedString(
            "Save creates a Zenit PDF Project at a location you choose. If you don't save, the takeoff is discarded — the drawing itself is never changed.",
            comment: "Close review detail for an edited Quick PDF"
        )
        alert.addButton(withTitle: NSLocalizedString("Save…", comment: "Close review button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Close review button"))
        let dontSave = alert.addButton(withTitle: NSLocalizedString("Don't Save", comment: "Close review button"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        // It discards the takeoff: the destructive choice, marked as one (IM-178).
        dontSave.hasDestructiveAction = true
        // Before this went through the presenter, a document with no visible window fell to
        // `alert.runModal()` — a modal loop in a headless process, which is the autosave-error
        // hang above wearing the close review's clothes. A process with no user discards:
        // there is no person whose work could be lost, and refusing to close would wedge
        // every test that closes a Quick PDF document.
        ZenitModalPresenter.runAlert(
            alert,
            identifier: unsavedTakeoffModalIdentifier,
            sheetedOn: document.windowForSheet ?? document.hostWindowController?.window,
            answerWithoutAUser: .button(2)
        ) { answer in
            switch answer {
            case .button(0): completion(.save)
            case .button(2): completion(.discard)
            default: completion(.cancel)
            }
        }
    }

    /// The stable name of the unsaved-takeoff review, for `ZenitModalPresenter.didRequest(_:)`.
    public static let unsavedTakeoffModalIdentifier = "document.unsavedTakeoffReview"

    /// Runs the Create-Project save panel and reports whether a project was created.
    private func saveQuickPDFAsProject(completion: @escaping @MainActor (Bool) -> Void) {
        guard drawing != nil else {
            ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady, in: windowForSheet)
            completion(false)
            return
        }
        quickSaveCompletion = completion
        runModalSavePanel(
            for: .saveAsOperation,
            delegate: self,
            didSave: #selector(quickSavePanelDone(_:didSave:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func quickSavePanelDone(
        _ document: NSDocument,
        didSave: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let completion = quickSaveCompletion
        quickSaveCompletion = nil
        completion?(didSave)
    }

    // MARK: - Saving

    private func performSave(to url: URL, operation: NSDocument.SaveOperationType) async throws {
        guard let drawing else { throw ZenitDocumentError.documentNotReady }

        // Quick PDF Mode saves only through an explicit panel: the
        // takeoff's first save is the Create-Project offer, never a silent write beside
        // the drawing. Any other operation reaching here is the quit dead-end path and
        // is refused in words rather than performed wrongly.
        if mode == .quickPDF, operation != .saveAsOperation, operation != .saveToOperation {
            throw ZenitDocumentError.quickModeRequiresProject
        }

        do {
            try await performPackageSave(to: url, operation: operation, drawing: drawing)
        } catch let error as ZPDFPersistenceError {
            // The raw engine error ("error 18") is exactly what UX_COPY_STANDARD forbids
            // in an alert; say what failed and what to do about it instead.
            throw ZenitDocumentError.saveFailure(
                error,
                projectName: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    private func performPackageSave(
        to url: URL,
        operation: NSDocument.SaveOperationType,
        drawing: LoadedDrawing
    ) async throws {
        // The change count as of the snapshot this save writes. The save awaits the archive and
        // the package, and nothing stops an edit in between; clearing the count outright at the
        // end marked such an edit saved although it was not in the file (R-031). AppKit's own
        // token bookkeeping clears only up to here, and the whole save primitive is overridden,
        // so it is this method's to do.
        let token = changeCountToken(for: operation)
        let revisionAtSnapshot = localChangeRevision
        if let package = projectPackage, url == fileURL || SaveAsCarryOver.sameItem(url, fileURL) {
            if operation == .autosaveInPlaceOperation, isLightAutosaveInFlight {
                try await lightAutosave(into: package, revisionAtSnapshot: revisionAtSnapshot)
                return
            }
            await packageSaveWillWriteHook?()
            try await writeTakeoffArchive(into: package)
            _ = try await package.save()
            fullPackageSaveCountForTesting += 1
            // `save(to:ofType:for:completionHandler:)` is overridden wholesale, so none of
            // AppKit's post-save bookkeeping runs — the change-count accounting is this
            // method's to do, *per operation* (LT-32). Only a person's Save may clear the
            // edited state; the autosave cycle reaches this same branch (`autosavesInPlace`,
            // url == fileURL), and clearing there made the dot lie in the other direction.
            // An autosave records `.changeAutosaved`: the work is safe on disk, the
            // document is still edited, and `hasUnautosavedChanges` stops claiming
            // otherwise — measured before this split: one autosave left it true forever.
            // Only as far as what was written (R-031): a Save clears through the token taken
            // before the snapshot, and an autosave records `.changeAutosaved` only when no edit
            // arrived while it ran — otherwise the edit would count as autosaved without being
            // on disk, and no later autosave would pick it up.
            switch operation {
            case .saveOperation, .saveAsOperation:
                updateChangeCount(withToken: token, for: operation)
            case .autosaveInPlaceOperation, .autosaveElsewhereOperation, .autosaveAsOperation:
                if localChangeRevision == revisionAtSnapshot { updateChangeCount(.changeAutosaved) }
            default:
                break
            }
            noteFreshFileModificationDate(at: url)
            return
        }

        // Save As, Save To, or the first save of a Quick PDF Mode takeoff: build a new package.
        var source = mode == .project
            ? (fileURL?.member(ProjectPackageLayout.originalPDF) ?? drawing.url)
            : drawing.url
        let destination = url.pathExtension.lowercased() == ProjectPackageLayout.fileExtension
            ? url
            : url.appendingPathExtension(ProjectPackageLayout.fileExtension)
        // The package being replaced is the open one, spelled another way: that is an
        // in-place save, never delete-then-clone-out-of-what-was-deleted (BH-070).
        if let package = projectPackage, SaveAsCarryOver.sameItem(destination, fileURL) {
            await packageSaveWillWriteHook?()
            try await writeTakeoffArchive(into: package)
            _ = try await package.save()
            if operation != .saveToOperation { updateChangeCount(withToken: token, for: operation) }
            noteFreshFileModificationDate(at: destination)
            return
        }
        let sourcePackageURL = mode == .project ? fileURL : nil
        var stagedSource: URL?
        defer { if let stagedSource { try? FileManager.default.removeItem(at: stagedSource.deletingLastPathComponent()) } }

        if FileManager.default.fileExists(atPath: destination.path) {
            // Whatever is replaced must not be where the new package's PDF comes from.
            if SaveAsCarryOver.isInside(source, destination) {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zpdf-saveas-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let staged = staging.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: staged)
                source = staged
                stagedSource = staged
            }
            try FileManager.default.removeItem(at: destination)
        }
        publishCreateProjectStage(1, NSLocalizedString("copying the drawing", comment: "Create Project stage"))
        let package = try await ProjectPackage.create(
            at: destination,
            displayName: destination.deletingPathExtension().lastPathComponent,
            originalPDF: source,
            pageCount: drawing.pages.count
        )
        // A package the document does not go on with — a Save To copy, a failed or abandoned
        // write — takes its row map with it: the map is keyed by object identity, and a later
        // package at the same address must not find these rows (X-011).
        defer { if projectPackage !== package { drawingSet?.rowsByPackage[ObjectIdentifier(package)] = nil } }
        publishCreateProjectStage(2, NSLocalizedString("writing the takeoff", comment: "Create Project stage"))
        await packageSaveWillWriteHook?()
        try await writeTakeoffArchive(into: package)
        // Photographs and imported stamp artwork travel with the takeoff (BH-071).
        if let oldPackage = projectPackage {
            try await SaveAsCarryOver.copyArtwork(from: oldPackage, to: package)
        }
        if let sourcePackageURL, !SaveAsCarryOver.sameItem(sourcePackageURL, destination) {
            try SaveAsCarryOver.copyPhotos(fromPackage: sourcePackageURL, toPackage: destination)
        }
        // The revisions and their confirmed sheet pairings go with the takeoff (V-017).
        let carriedRevisions = try await carryRevisions(into: package, from: projectPackage)
        publishCreateProjectStage(3, NSLocalizedString("saving", comment: "Create Project stage"))
        _ = try await package.save()

        // "Don't Save" — or any close — that arrived while this write was running: the
        // project exists on disk, but the document is gone. Close the package so its crash
        // marker is disarmed, and leave nothing pointing at it (CR-152).
        if isClosed {
            try? await package.close()
            return
        }

        if operation != .saveToOperation {
            let wasQuickPDF = mode == .quickPDF
            // The audit trail moves into the new package before anything old is closed,
            // so Create Project never costs the user their history.
            if let core {
                let projectID = await package.manifest.projectId
                let database = await package.database
                core.history.migrate(to: database, projectID: projectID)
                await core.history.settle()
            }
            try? await projectPackage?.close()
            projectPackage = package
            // Every drawing's row is now the new package's (X-011).
            await adoptPackageRows(of: package)
            // The rows the session's revisions now have, in the package it now writes to.
            persistedRevisionIDs = carriedRevisions
            mode = .project
            fileURL = destination
            fileType = ZenitAppInfo.projectTypeIdentifier
            // Feature 15: a drawing that just became a project gains its photo sidecar the
            // same moment — Save As must leave the document with everything an opened
            // project has, or the Inspector's photo rows appear only after a reopen.
            mountPhotoStore(packageURL: destination)
            if let shell { wirePhotoAttachments(into: shell) }
            // R-205: the layer visibility in force moves into the new project with the rest.
            await layerVisibility.attach(archive: LayerOverrideArchive(package: package), restoringStored: false)
            // Only as far as the snapshot: an edit made during Create Project stays unsaved.
            updateChangeCount(withToken: token, for: operation)
            noteFreshFileModificationDate(at: destination)
            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            refreshTabSummary()
            if wasQuickPDF {
                // The takeoff has a real home now; the container autosave has served.
                await retireQuickPDFStorage()
            }
        } else {
            try? await package.close()
        }
    }

    /// Runs after a package save has taken its change-count token and before it snapshots the
    /// takeoff. A test seam, for an edit that lands while the save is running (R-031). Nothing
    /// under `Apps/ZenitPDF/Sources` sets it.
    var packageSaveWillWriteHook: (@MainActor () async -> Void)?

    /// Records the just-written package's modification date on the document.
    ///
    /// The whole save primitive is overridden, so AppKit never learns that the write it
    /// asked for happened — a stale `fileModificationDate` is what its "the file has been
    /// changed by another application" machinery keys on, and the package pipeline's
    /// sibling-and-replace moves the date on every save (LT-32's neighbourhood).
    private func noteFreshFileModificationDate(at url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        fileModificationDate = attributes?[.modificationDate] as? Date ?? Date()
    }

    /// Writes the whole in-session takeoff into the package's database (ADR-0009): every
    /// markup, its measurement values, the scale definitions and the draw order, one
    /// transaction — the same discipline the audit trail keeps. Runs before every
    /// `package.save()`, so the 6.4 pipeline snapshots a database that already holds the
    /// takeoff and old-or-new covers the markups too.
    ///
    /// This replaced the honest "measurements are not written yet" tray warning the
    /// moment it became a lie in the right direction.
    private func writeTakeoffArchive(into package: ProjectPackage) async throws {
        guard let core else { return }
        let state = await core.session.takeoffState()
        // A project of several drawings writes each drawing's share under its own row
        // (NL-DOCS-04); a project of one drawing is written exactly as before.
        if let rows = try await drawingSetRows(for: package) {
            try await TakeoffArchive.writeSet(state, into: package, documentRows: rows)
        } else {
            try await TakeoffArchive.write(state, into: package)
        }
        // The imported ledger columns now travel inside the archive with the rows that
        // reference them (BH-075); the interim attachments file is retired.
        ImportedLedgerColumnStore.retire(inPackage: package.url)
        // The Tool Library travels with the takeoff. Writing it from the same place is what makes
        // Save As and the Quick PDF Mode autosave carry the presets too, rather than only the
        // in-place write `persistToolPresets(_:)` performs.
        //
        // Split by scope: the project's set goes into this package, the person's into the
        // container. A Save As therefore copies the job's cost codes into the new package and
        // does *not* clone the estimator's standard into it — which is the whole point of two
        // scopes.
        try await ToolPresetLibraryStore.save(
            core.toolLibrary.presets,
            package: package,
            container: toolPresetContainer,
            legacyProjectPresetIDs: legacyProjectPresetIDs
        )
    }

    /// The Inspector's Subject field over a selection: one batch, one ⌘Z, and a refusal —
    /// a locked markup — said in the status bar rather than swallowed by `try?` while the
    /// field showed a subject that only some markups took (BH-357, IM-180).
    static func applySubjectEdit(markupIDs: Set<UUID>, subject: String, core: AppCoreEnvironment) async {
        guard !markupIDs.isEmpty else { return }
        do {
            try await core.commands.performBatch(
                markupIDs.sorted { $0.uuidString < $1.uuidString }
                    .map { .editSubject(id: MarkupID($0), subject: subject) },
                actionName: NSLocalizedString("Edit Subject", comment: "Undo action name for the Inspector subject edit")
            )
        } catch {
            reportRefusedEdit(error, core: core)
        }
    }

    /// A document that is renamed, moved, saved as or promoted to a project gets a new name,
    /// and the stamp fields that resolve "Document" and "Project" read it from the core. They
    /// were assigned once at load, so a stamp placed after Create Project still said the
    /// drawing's old name (BH-356).
    public override var fileURL: URL? {
        didSet {
            // AppKit sets the URL on the main thread for every path that renames a document
            // (this class refuses concurrent reads and asynchronous writes).
            guard fileURL != oldValue, Thread.isMainThread else { return }
            MainActor.assumeIsolated { refreshStampNameFields() }
        }
    }

    /// Pushes the current display name into the stamp dynamic fields.
    func refreshStampNameFields() {
        // Every window's core stamps with the same name (NL-UX-20).
        for core in allWindowCores {
            core.documentDisplayName = displayName ?? ""
            core.projectDisplayName = displayName ?? ""
        }
    }

    /// The newest structure-panel refresh (BH-916), per window's shell (NL-UX-20).
    var structureRefreshGenerations: [ObjectIdentifier: Int] = [:]

    /// The tail of the serialised Scale Region / Project Zone edits (BH-384).
    var structureEditTail: Task<Void, Never>?

    /// The last file any export wrote, for Share Last Export… (NL-PLAT-10, R-028).
    var lastExportURL: URL?

    /// The file the export confirmation on screen names, for its Show in Finder (IM-186). Kept
    /// apart from ``lastExportURL``: a drawing export written while a ledger confirmation still
    /// showed made that note's Show in Finder reveal the drawing (R-028).
    var announcedExportURL: URL?

    /// The ledger columns table imports added to this takeoff, persisted beside it (BH-075).
    private(set) var importedLedgerColumns: [LedgerColumnDefinition] = []

    /// Records columns a table import just added to the session.
    func noteImportedLedgerColumns(_ definitions: [LedgerColumnDefinition]) {
        importedLedgerColumns.append(contentsOf: definitions)
    }

    /// The ids of legacy `My Tools` rows the opened package carried (CR-3); see `load()`.
    private var legacyProjectPresetIDs: Set<UUID> = []

    // MARK: - Tool Library

    /// One stable identity for the preset-write warning, so a failing write replaces its own
    /// note in the tray rather than stacking a new one on every keystroke-sized edit.
    private static let toolPresetWriteWarningID = UUID()

    /// The same, for the personal library's read failure. A separate identity because the two
    /// say different things and one must not overwrite the other in the tray.
    private static let toolPresetReadWarningID = UUID()

    /// The person's Tool Library — the store beside the project package.
    ///
    /// **A test process never reaches the real container.** The guard is structural, the same
    /// one `ZenitErrorPresenter` uses for its modal: a `swift test` process cannot be the
    /// assembled bundle, so it is given a scratch directory whether or not anybody remembered to
    /// inject one. Without that, every existing app-suite test that touches a preset would write
    /// into the user's own tool library and carry state between runs — a test suite that edits
    /// the person's saved tools is not a test suite.
    ///
    /// **And a test document never reaches another test's library either (C-06).** The scratch
    /// directory used to be one per process, so every document of every suite in a run shared it:
    /// a preset one suite saved into the person's set was in the next suite's library, and two
    /// suites went red only in a full run for that reason (I-6 and I-13). Outside
    /// the assembled application each document now gets a fresh container of its own, made on
    /// first use and kept for the document's life, unless a test installs
    /// ``toolPresetContainerOverride`` because it is about the library outliving a document.
    var toolPresetContainer: ToolPresetContainerStore {
        if let override = Self.toolPresetContainerOverride { return override }
        guard !ZenitProcessDefaults.isAssembledApplication else { return Self.processToolPresetContainer }
        if let own = ownToolPresetContainer { return own }
        let own = ToolPresetContainerStore(
            directory: Self.scratchToolPresetDirectory
                .appendingPathComponent("document-\(UUID().uuidString)", isDirectory: true)
        )
        ownToolPresetContainer = own
        return own
    }

    /// The per-process scratch directory outside the assembled application: the process
    /// container, and each document's own container inside it (C-06).
    static let scratchToolPresetDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zenitpdf-tool-library-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// This document's own scratch container outside the assembled application (C-06). `nil`
    /// until first asked for, and never used in the product.
    private var ownToolPresetContainer: ToolPresetContainerStore?

    /// Where the per-set Draw / Apply / Place modes are remembered.
    ///
    /// A seam rather than `UserDefaults.standard` reached for directly, for the reason
    /// ``ZPDFDefaultsStoring`` exists: a test that writes the real preferences is a test that
    /// changes the user's machine.
    var toolSetModeDefaults: any ZPDFDefaultsStoring {
        Self.toolSetModeDefaultsOverride ?? Self.processToolSetModeDefaults
    }

    /// The defaults store this process may write set modes to: the real one in the assembled
    /// bundle, a per-process in-memory store anywhere else.
    ///
    /// **The twin of ``processToolPresetContainer``, and it was missing.** The seam above existed
    /// and every test was expected to remember to inject through it. One did not
    /// (`PresetApplySkipReportTests`, written 2026-08-25), so
    /// `ToolSetModeStore.write` put `{"myTools":"apply"}` into the **user's real preferences**,
    /// in the `swiftpm-testing-helper` domain, where it stayed. Every document opened by every
    /// later app-tier test — in that process and in every later run on that machine — then came
    /// up with My Tools in Apply, which disarms both drawing families: the Count tool placed no
    /// points and a markup preset armed nothing. `build-app-package.sh` was red three times for
    /// it, deterministically, and the cause was a preference file rather than any line of code
    /// under test.
    ///
    /// An opt-in seam is a rule somebody has to remember. This is the same rule enforced by
    /// construction, which is the only kind this repository has kept.
    static let processToolSetModeDefaults: any ZPDFDefaultsStoring = {
        guard Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier else {
            return ZPDFInMemoryDefaults()
        }
        return UserDefaults.standard
    }()

    /// Points every document in this process at one defaults store. Set by a test; `nil` in the
    /// product.
    static var toolSetModeDefaultsOverride: (any ZPDFDefaultsStoring)?

    /// Points every document in this process at one store. Set by a test; `nil` in the product.
    static var toolPresetContainerOverride: ToolPresetContainerStore?

    /// The container this process may write to: the real one in the assembled bundle, a
    /// per-process temporary directory anywhere else.
    static let processToolPresetContainer: ToolPresetContainerStore = {
        guard Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier else {
            return ToolPresetContainerStore(directory: scratchToolPresetDirectory)
        }
        return .standard()
    }()

    /// Posts one Tool Library note into the status tray.
    private func postToolLibraryWarning(
        environment: AppCoreEnvironment,
        title: String,
        message: String
    ) {
        environment.document.post(
            AppWarning(
                id: Self.toolPresetReadWarningID,
                severity: .warning,
                title: title,
                message: message,
                source: NSLocalizedString("Tool Library", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// The project-scoped presets as they were last written into the package.
    ///
    /// The baseline `persistToolPresets(_:)` compares against, so that a container-only write —
    /// seeding the shipped set, starring a personal preset — cannot mark the document edited.
    private var persistedProjectPresets: [ToolPresetSummary] = []

    /// The subset of a library that lives inside the `.zpdfproj`, in order.
    ///
    /// Split by `ToolPresetScopeRule` rather than by panel identity here, so this and
    /// `ToolPresetLibraryStore.save` can never disagree about which store a preset belongs to.
    private static func projectScoped(_ presets: [ToolPresetSummary]) -> [ToolPresetSummary] {
        presets.filter { ToolPresetScopeRule.scope(of: $0) == .project }
    }

    /// Adopts a library the Tool Library panel edited, and persists it.
    ///
    /// The panel edits a working copy (`ToolLibraryEditingModel`) whose own documentation says the
    /// host persists the change stream. Nothing was that host until this method: creating,
    /// renaming, duplicating, deleting and reordering all succeeded on screen and reached nothing.
    /// This is the single door — the presenter is brought level with the panel first, so the
    /// canvas can arm a preset the person just made without reopening the panel, and the package
    /// is written second.
    /// Compiles a chosen PDF page or image into preset artwork and stores it in this project
    /// (ADR-0011 §4).
    ///
    /// This is the caller the artwork importer was first shipped without. `StampArtworkImporter` has been able
    /// to turn a PDF page into unit-space geometry with no image in it, turn an image into a
    /// bounded orientation-correct mosaic, address either by SHA-256 and refuse eight classes of
    /// hostile input since then — and no surface in the application could reach it, so the
    /// eight refusals guarded a door nobody could open. The Tool Library's preset editor is the
    /// door, and this is what is behind it.
    ///
    /// Three things happen here and nowhere else, which is why it is one method:
    ///
    /// - **The security scope is held across the read.** A file chosen through `.fileImporter`
    ///   in a sandboxed application is readable only between `startAccessingSecurityScopedResource`
    ///   and its stop, and the compile is `async`, so the scope has to outlive an await.
    /// - **The refusal keeps its sentence.** `ArtworkImportRefusal.reason` has the number in it —
    ///   "this artwork has 41 208 contours; the limit is 20 000" — and the editor shows exactly
    ///   that. Flattening it to "Import failed" here would waste eight distinct measurements.
    /// - **Artwork lives in the project, so a project with nowhere to live refuses out loud.**
    ///   Quick PDF Mode has no package; storing the bytes in the container would hand a colleague
    ///   a project with holes in it, which is precisely the property ADR-0011 §1.1 chose against.
    public func importPresetArtwork(_ choice: ArtworkImportChoice) async -> ArtworkImportOutcome {
        // Inspection is answered before the package check, and deliberately: it stores nothing,
        // so a person in Quick PDF Mode still finds out how many pages their file has and why
        // the import will refuse — rather than being told "save first" by a sheet that never
        // opened. The refusal for actually importing is unchanged, below.
        if case let .inspectPDF(url) = choice {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let inspection = try StampArtworkImporter().inspectPDF(at: url)
                return .inspected(ArtworkSourceSummary(
                    fileName: inspection.fileName,
                    pageCount: inspection.pageCount
                ))
            } catch let refusal as ArtworkImportRefusal {
                return .refused(refusal.reason)
            } catch {
                return .refused(String(describing: error))
            }
        }
        guard let package = projectPackage else {
            return .refused(NSLocalizedString(
                "Save this drawing as a project first. Imported artwork is stored inside the project so it travels with it.",
                comment: "Artwork import refusal in Quick PDF Mode, which has no project package"
            ))
        }
        let url = choice.url
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let source: ArtworkSource
        switch choice {
        case let .pdfPage(url, pageIndex): source = .pdfPage(url: url, pageIndex: pageIndex)
        case let .image(url): source = .image(url: url)
        case .inspectPDF:
            // Answered above, before the package check. Unreachable, and spelled out rather
            // than defaulted so a fourth choice cannot be silently imported as nothing.
            return .refused(NSLocalizedString(
                "That file was inspected, not imported.",
                comment: "Artwork import refusal for an inspection that reached the import path"
            ))
        }
        do {
            let artwork = try await StampArtworkImporter().importArtwork(from: source)
            let descriptor = try await ProjectArtworkStore.store(artwork, in: package)
            // The bytes are in the package, so the package has changed.
            updateChangeCount(.changeDone)
            return .imported(descriptor)
        } catch let refusal as ArtworkImportRefusal {
            return .refused(refusal.reason)
        } catch {
            return .refused(String(describing: error))
        }
    }

    public func applyToolPresets(_ presets: [ToolPresetSummary]) {
        // Every window's Tool Library shows the one library (NL-UX-20).
        for core in allWindowCores { core.toolLibrary.setPresets(presets) }
        persistToolPresets(presets)
    }

    /// NL-UX-20: a preset change made in one window's Tool Library reaches the others and is
    /// persisted once, exactly as the first window's own change is.
    func toolPresetsChangedInWindow(_ presets: [ToolPresetSummary], from source: AppCoreEnvironment) {
        for core in allWindowCores where core !== source && core.toolLibrary.presets != presets {
            core.toolLibrary.setPresets(presets)
        }
        persistToolPresets(presets)
    }

    /// Writes the preset library into the open project package.
    ///
    /// Immediate rather than debounced: a library is a few kilobytes, the write is one
    /// transaction on the package actor, and the failure this closes is a person losing a tool
    /// they just made. Quick PDF Mode has no package yet, so its presets are held in memory and
    /// land in the container autosave — and in whatever package a Save creates — through
    /// ``writeTakeoffArchive(into:)``.
    private func persistToolPresets(_ presets: [ToolPresetSummary]) {
        // **A change to the person's library is not a change to the project.**
        //
        // This used to be an unconditional `updateChangeCount(.changeDone)`, and the shipped tool
        // set made that wrong the day it landed: opening any drawing on a machine whose personal
        // library had never been seeded wrote the six built-ins and marked the *document* edited,
        // so a drawing nobody had touched asked "save your takeoff?" on close. In the test process
        // the same alert is `NSAlert.runModal` with nobody to answer it, which hung
        // `build-app-package.sh` in `TabbedWindowTests.closingATabKeepsTheWindow` — one of three
        // runs, because which suite opens the process's first document varies.
        //
        // The document is therefore marked edited only when the set that travels *inside the
        // package* actually changes. `ToolPresetScopeRule` makes that decision, the same rule
        // `ToolPresetLibraryStore.save` splits on, so the dirty flag and the storage cannot
        // disagree.
        let projectScoped = Self.projectScoped(presets)
        if projectScoped != persistedProjectPresets {
            persistedProjectPresets = projectScoped
            updateChangeCount(.changeDone)
        }
        let package = projectPackage
        let container = toolPresetContainer
        Task { @MainActor [weak self] in
            do {
                // Both scopes, one call, the split made by `ToolPresetScopeRule` rather than
                // here. Quick PDF Mode passes `package: nil` and still saves the person's tools
                // — before the container store existed it saved nothing at all until a Save.
                try await ToolPresetLibraryStore.save(
                    presets,
                    package: package,
                    container: container,
                    legacyProjectPresetIDs: self?.legacyProjectPresetIDs ?? []
                )
            } catch {
                // The warning below tells the person to save the project to try again, and that
                // advice has to be true. A container-only write no longer marks the document
                // edited on success (see the head of this method), so on **failure** it must —
                // otherwise ⌘S is a no-op on a clean document and the only offered remedy does
                // nothing. Dirty on failure, never on success.
                self?.updateChangeCount(.changeDone)
                self?.core?.document.post(
                    AppWarning(
                        id: Self.toolPresetWriteWarningID,
                        severity: .warning,
                        title: NSLocalizedString(
                            "The Tool Library could not be saved.",
                            comment: "Warning shown when writing the tool presets failed"
                        ),
                        message: NSLocalizedString(
                            "Your tools are still here for this session. Save the project to try writing them again.",
                            comment: "Detail of the tool preset write failure warning"
                        ),
                        source: NSLocalizedString("Tool Library", comment: "Warning source"),
                        isDismissible: true,
                        timestamp: Date()
                    )
                )
            }
        }
    }

    // MARK: - Printing

    /// Prints the drawing: one sheet per page, **with its markups on it**.
    ///
    /// # The defect this closed
    ///
    /// Until 2026-08-26 this method rasterised `drawing.rasterSource.render(pageIndex:…)` per page
    /// and drew nothing else. Not one markup reached paper — no dimension line, no value pill, no
    /// count symbol — and nothing anywhere said so: the call returned an image, the sheet was
    /// appended, the operation ran, the printer produced the drawing exactly as it had arrived
    /// from the architect. An estimator printed a measured drawing and received a blank drawing.
    /// It was the largest functional gap in the build, and `MarkupRecord.printable` — a flag the
    /// contract froze specifically for this path — had never been read by anything.
    ///
    /// # What it does now
    ///
    /// Printing is the fourth consumer of the flatten path, and it goes through the
    /// same machinery as the flattened PDF export: ``FlattenedDrawingExport/job(for:artwork:)``
    /// gathers the sheets and applies `PDFFlattenPolicy`, ``DocumentPrintView`` paints each one
    /// through `FlattenedPDFWriter.paintSheet`, and the markups are drawn by the renderer that
    /// draws the canvas. Paper and screen cannot disagree, because there is one set of drawing
    /// instructions and both use it.
    ///
    /// It stays asynchronous for the reason it always was: the session is an actor and the page
    /// underlay may need the rasteriser, and blocking the main thread on either to satisfy a
    /// synchronous AppKit entry point is what the whole architecture is arranged to avoid. The
    /// panel appears once the sheets are ready rather than immediately over an empty preview.
    public override func printDocument(_ sender: Any?) {
        guard !refuseIfSaveActivityBusy() else { return }
        guard let drawing, !drawing.pages.isEmpty else {
            ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady, in: windowForSheet)
            return
        }
        // One print at a time, from ⌘P until the print panel is answered: a second ⌘P during a
        // slow preparation queued a second print operation, which could reach the panel's
        // synchronous activity wait while the first held it — RT-14's shape (R-045).
        printActivityInFlight = true
        Task { @MainActor in
            var handedToPrintPanel = false
            defer { if !handedToPrintPanel { self.printActivityInFlight = false } }
            let job: FlattenedDrawingExport.Job
            // A project of several drawings prints the whole set: composed
            // first, kept until the next print (Workflows/DrawingSetOutput.swift). One that could
            // not be composed is refused, never printed as its first drawing alone (U-019).
            let set: DrawingSetOutput?
            do {
                set = try await DrawingSetOutput.make(for: self)
                job = try await FlattenedDrawingExport.job(
                    for: self,
                    artwork: { [weak self] digest in
                        guard let package = self?.projectPackage else { return nil }
                        return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
                    },
                    set: set
                )
            } catch {
                ZenitErrorPresenter.present(error, in: self.windowForSheet)
                return
            }
            guard !job.pages.isEmpty else {
                ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady, in: self.windowForSheet)
                return
            }
            let content = if let set { await set.contentSource(for: self) } else {
                await FlattenedDrawingExport.contentSource(
                    for: self,
                    rasterFallbackPages: drawing.pages
                )
            }
            // Each sheet carries its calibrated ratio, so the paper states its scale (NL-PDF-06).
            let sheets = if let session = self.core?.session {
                await DocumentPrintView.sheets(for: job.pages, session: session)
            } else {
                job.pages.map { DocumentPrintView.Sheet(flatten: $0) }
            }
            let view = DocumentPrintView(sheets: sheets, content: content)
            // NL-PDF-06: scope, header and summary data for the print panel (Workflows/PrintExtras.swift).
            await self.preparePrintExtras(for: view)
            // Paper sized to the largest sheet, no margins: an ARCH-D drawing on the default
            // Letter paper printed its bottom-left corner (BH-363). A smaller paper chosen in
            // the panel fits each sheet instead of clipping it, and says so on the sheet.
            let printInfo = DocumentPrintView.printInfo(for: sheets, base: self.printInfo)
            let notes = await FlattenedDrawingExport.omissionNotes(for: self, content: content)
            FlattenedDrawingExport.postReport(
                FlattenedDrawingExport.Report(),
                notes: notes,
                title: NSLocalizedString(
                    "Not everything on the canvas is in the printout.",
                    comment: "Print report headline"
                ),
                core: self.core
            )
            let operation = NSPrintOperation(view: view, printInfo: printInfo)
            operation.jobTitle = self.displayName ?? ZenitAppInfo.displayName
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            // Scale, markups and tiling — the drawing's own section of the print panel.
            operation.printPanel.addAccessoryController(PrintOptionsAccessory(printView: view))
            // The panel's answer, or its refusal, ends the print activity (`document(_:didPrint:contextInfo:)`).
            handedToPrintPanel = true
            self.runModalPrintOperation(
                operation,
                delegate: self,
                didRun: #selector(self.document(_:didPrint:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    /// The print panel was answered, or the print refused: ⌘P may start the next one.
    @objc private func document(_ document: NSDocument, didPrint: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printActivityInFlight = false
    }

    /// A print is being prepared or its panel is up (R-045).
    private(set) var printActivityInFlight = false

    // MARK: - Mode promotion

    /// Whether a save panel raised by this document is on screen.
    ///
    /// `runModalSavePanel` wraps itself in `performActivityWithSynchronousWaiting:`, which
    /// blocks the MAIN thread on `_NSDocumentSerializationSemaphore` until the document's
    /// current activity ends. Our `save(to:ofType:for:completionHandler:)` finishes on the
    /// main actor, so a second panel raised while the first save is still running waits for
    /// a completion that can never be delivered — the whole application freezes with no
    /// window, no menu and no key that helps, and only a kill recovers it. Measured live on
    /// 2026-08-31 by sampling the frozen process (RT-14). This flag and
    /// ``isSaveTaskRunning`` together are the door that stays shut instead.
    private var savePanelActivityInFlight = false

    /// Whether the document activity is held — by a panel on screen or by a save whose
    /// completion has not been delivered. While this is true every AppKit entry that waits
    /// synchronously for the activity would freeze the application (CR-147).
    /// A print in preparation, or its panel, holds it too (R-045).
    var isSaveActivityBusy: Bool { isSaveInFlight || printActivityInFlight }

    /// A save panel is up or a save has not delivered its completion.
    private var isSaveInFlight: Bool { savePanelActivityInFlight || isSaveTaskRunning }

    /// Refuses, in words, an entry that would park the main thread on the document
    /// activity. Returns `true` when the caller must stop.
    ///
    /// Said out loud rather than queued: a second panel here deadlocks the process (RT-14),
    /// and a command that silently does nothing is the other failure this project refuses.
    private func refuseIfSaveActivityBusy() -> Bool {
        if refuseIfSaveInFlight() { return true }
        guard printActivityInFlight else { return false }
        core?.status.setActiveToolNote(NSLocalizedString(
            "A print is being prepared — wait for it to finish.",
            comment: "Status note when a save, print or close-related command is invoked while a print is being prepared"
        ))
        return true
    }

    /// The save half of ``refuseIfSaveActivityBusy()``.
    private func refuseIfSaveInFlight() -> Bool {
        guard isSaveInFlight else { return false }
        core?.status.setActiveToolNote(NSLocalizedString(
            "A save is already in progress — wait for it to finish.",
            comment: "Status note when a save, print or close-related command is invoked while a save is running"
        ))
        return true
    }

    /// Marks a save panel as up, and unmarks it when the panel is gone. Test seams.
    func beginSavePanelActivity() { savePanelActivityInFlight = true }
    func endSavePanelActivity() { savePanelActivityInFlight = false }

    /// Marks an asynchronous save as running, and unmarks it when it completes. Test seams:
    /// the shipping code sets ``isSaveTaskRunning`` only inside the save primitive.
    func beginSaveTaskActivity() { isSaveTaskRunning = true }
    func endSaveTaskActivity() { isSaveTaskRunning = false }

    /// Quick PDF Mode's `Create Zenit PDF Project`.
    public func createProject() {
        guard drawing != nil else {
            ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady, in: windowForSheet)
            return
        }
        guard !refuseIfSaveActivityBusy() else { return }
        runModalSavePanel(for: .saveAsOperation, delegate: nil, didSave: nil, contextInfo: nil)
    }

    /// Whether an asynchronous save started by ``save(to:ofType:for:completionHandler:)``
    /// has not delivered its completion yet. The one source of truth; the waiters below are
    /// resumed from here.
    private var isSaveTaskRunning = false {
        didSet {
            guard !isSaveTaskRunning, !saveIdleWaiters.isEmpty else { return }
            let waiters = saveIdleWaiters
            saveIdleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Callers waiting for the running save to finish (IM-248).
    private var saveIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many times a close waited on a save. IM-248's counter.
    private(set) var saveIdleWaitCountForTesting = 0

    /// Returns once no save task is running — at once when none is.
    func waitUntilSaveTaskIdle() async {
        guard isSaveTaskRunning else { return }
        saveIdleWaitCountForTesting += 1
        await withCheckedContinuation { continuation in
            saveIdleWaiters.append(continuation)
        }
    }

    public override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [ZenitAppInfo.projectType]
        savePanel.nameFieldStringValue = displayName ?? "Project"
        savePanel.message = NSLocalizedString(
            "Choose where to keep this takeoff.",
            comment: "Save panel message"
        )
        // Create Project starts beside the drawing it is about, not wherever the last panel
        // was (IM-249). The panel is powerbox-mediated: no entitlement is needed to show it.
        if let directory = Self.createProjectStartDirectory(mode: mode, drawingURL: drawing?.url) {
            savePanel.directoryURL = directory
        }
        return true
    }

    nonisolated static func createProjectStartDirectory(mode: Mode, drawingURL: URL?) -> URL? {
        guard mode == .quickPDF, let drawingURL else { return nil }
        return drawingURL.deletingLastPathComponent()
    }
}
