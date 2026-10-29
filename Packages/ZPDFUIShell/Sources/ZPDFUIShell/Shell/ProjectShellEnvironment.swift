import AppKit
import Foundation
import Observation
import SwiftUI
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// A request to regroup the docked Quantity Ledger, raised by a panel that is not the ledger.
///
/// The pane owns its `LedgerPaneModel` privately — it is the pane's `@State` — so a panel on the
/// other side of the window cannot reach in and regroup it. This is the one-way channel that
/// lets Project Zones say "now group by zone" without either side knowing about the other.
@MainActor
@Observable
public final class LedgerGroupingRequest {

    /// The grouping asked for, or `nil` when nothing is outstanding.
    public private(set) var pending: [LedgerColumnID]?
    /// Bumped on every request, so two requests for the same grouping are both delivered.
    public private(set) var token: Int = 0

    /// Creates an empty request channel.
    public init() {}

    /// Asks for a grouping.
    public func request(_ columns: [LedgerColumnID]) {
        pending = columns
        token += 1
    }

    /// Takes the outstanding request, leaving the channel empty.
    public func take() -> [LedgerColumnID]? {
        defer { pending = nil }
        return pending
    }
}

/// The drawing-set facts the application writes after a refresh and the Navigator draws — the
/// sheets removed from the set, the sheets without a scale, whether a previous revision exists.
///
/// Its own `@Observable` box, like ``InspectorPhotoTick``, because ``ProjectShellEnvironment`` is
/// not observable: a view body reading a plain stored property on it was not re-evaluated when
/// the property changed (R-075).
@MainActor
@Observable
public final class NavigatorSetState {
    public var removedSheets: [NavigatorRemovedSheet] = []
    public var unscaledPageIDs: Set<UUID> = []
    public var hasPreviousRevision = false
    /// The drawing's bookmarks for the Pages Index (S-049): the application writes a refined
    /// list — left/top destinations, per-drawing groups — after an `await`, when the Index may
    /// already be on screen.
    public var navigatorBookmarks: [NavigatorBookmark] = []

    public init() {}
}

/// Everything a project window's views need, in one place.
///
/// The shell is built against the `ZPDFUIPresentation` protocols only. Handing the whole set
/// around as one object keeps every panel's initializer short and makes the whole window
/// constructible from `MockPresenters` in a preview or a test.
@MainActor
public final class ProjectShellEnvironment {

    /// Open documents, pages, zones and Scale Regions.
    public let document: any DocumentPresenting
    /// Viewport, visible markups, selection and snap feedback.
    public let canvas: any CanvasPresenting
    /// The Quantity Ledger.
    public let ledger: any LedgerPresenting
    /// Saved tool presets.
    public let toolLibrary: any ToolLibraryPresenting
    /// Search across text, OCR text, markups and custom fields.
    public let search: any SearchPresenting
    /// Revision Compare.
    public let compare: any ComparePresenting
    /// The measurement palette and the measurement in progress.
    public let measurement: any MeasurementToolPresenting
    /// The status bar and the warning tray.
    public let status: any StatusPresenting

    /// Toolbar state, including the two palettes' last-used memory.
    public let toolbar: ZenitToolbarModel
    /// Document tab bar state.
    public let tabBar: DocumentTabBarModel
    /// Thumbnails for the Navigator's Files section — one per open drawing, keyed by tab id.
    /// Separate from the Pages loader because the two answer different questions of different
    /// documents, and a provider swap on tab-switch would flush the wrong cache.
    public let drawingThumbnails = NavigatorThumbnailLoader()

    /// Handles a warning's action button. The application tier owns what an action *does*;
    /// the tray only knows the button's title.
    ///
    /// Until 2026-08-29 the tray's action closure was a literal `{}` — a button that did
    /// nothing, on the one surface whose whole job is telling the user something needs doing.
    /// Found while wiring the scale proposal, whose Apply is the first real action through it.
    public var onWarningAction: (@MainActor (AppWarning) -> Void)?

    /// Feature 15 — site photographs. The application wires all three in Project Mode and
    /// leaves them `nil` in Quick PDF Mode, which is how the Inspector knows to offer the
    /// affordance only where a package exists to keep the pixels crash-safe.
    /// One row per photograph attached to the given markup.
    @ObservationIgnored
    public var photoAttachments: (@MainActor (UUID) -> [InspectorPhotoRow])?
    /// Asks the person for an image file and attaches it to the markup.
    @ObservationIgnored
    public var onAttachPhoto: (@MainActor (UUID) -> Void)?
    /// Detaches one photograph (markup id, attachment id).
    @ObservationIgnored
    public var onRemovePhoto: (@MainActor (UUID, UUID) -> Void)?

    /// Sets a markup's `Repeat ×` count. The engine and command were proven long before any
    /// editor existed — double-click in the ledger cell did nothing and the Inspector row was
    /// read-only, so the whole feature was unreachable live (LT-7, 2026-08-29). The Inspector
    /// stepper is the editor; the app tier routes this through `editCustomValue`.
    ///
    /// Answers whether the edit landed (W-039): a refused count never reaches the snapshot, and
    /// the stepper drops the asks it was waiting on rather than showing a count never stored.
    public var onSetRepeatCount: (@MainActor (_ markupID: UUID, _ count: Int) async -> Bool)?
    /// NL-QTY-15 phase 2: picks closed project files and summarises them (the app tier owns
    /// the open panel), and saves such a summary as a workbook. `nil` hides both buttons.
    public var onBatchProjectSummary: (@MainActor () async -> LedgerBatchSummary?)?
    public var onExportBatchSummary: (@MainActor (LedgerBatchSummary) -> Void)?
    /// NL-QTY-07 round 2: imports a `.zpdfassembly` file into the office library and answers the
    /// recipes now on offer; saves the library as one. `nil` hides both buttons.
    public var onImportAssemblyRecipes: (@MainActor () async -> [LedgerAssemblySummary]?)?
    public var onExportAssemblyRecipes: (@MainActor () -> Void)?
    /// The observable tick the Inspector re-renders photo rows off — the environment
    /// itself is not `@Observable`, so the tick lives in its own box.
    public let photoTick = InspectorPhotoTick()

    /// Review threads for the Comments tab (NL-COLLAB-01/02). The application wires it; unset,
    /// the tab shows each markup's note alone and offers no reply field.
    @ObservationIgnored
    public var review: (any ReviewThreadPresenting)?

    /// Exports the Review List's visible rows as a review report (NL-COLLAB-16), in their order.
    /// The application wires it; unset, the Review List offers no report.
    @ObservationIgnored
    public var onExportReviewReport: (@MainActor (_ markupIDs: [UUID]) -> Void)?

    /// Whether this person asked to be notified about review activity (NL-COLLAB-15), and the
    /// switch. Turning it on is what asks the system for permission — never at launch.
    @ObservationIgnored
    public var reviewNotificationsEnabled: (@MainActor () -> Bool)?
    @ObservationIgnored
    public var setReviewNotificationsEnabled: (@MainActor (Bool) -> Void)?

    /// Feature 19 — the ledger's count-symbol legend. The application derives the rows
    /// from the placed marks (never from the live presets, which may have been edited
    /// since placement); `nil` or empty renders no legend.
    @ObservationIgnored
    public var countSymbolLegend: (@MainActor () -> [LedgerSymbolLegendRow])?
    /// The menu and keyboard table in force for this window's hints, palette and tooltips.
    ///
    /// Read at the moment of use: ``ZPDFCommandTable/effective`` unless a table was injected, so a
    /// shortcut changed in Settings ▸ Shortcuts reaches every open window without reopening it
    /// (R-074). It used to be a `let` snapshot taken when the window opened.
    public var commands: ZPDFCommandTable { injectedCommands ?? .effective }

    /// A table a test or preview pins; `nil` follows the effective table.
    private let injectedCommands: ZPDFCommandTable?

    /// Commands the shell cannot service on its own — file operations, export, printing.
    /// The app target sets this; until it does, those commands are quietly ignored rather
    /// than crashing a half-assembled window.
    public var externalCommandHandler: (@MainActor (ZPDFCommandID) -> Void)?

    /// Shows the list of every export the document offers — the Quantity Ledger and each
    /// drawing export — for the toolbar's Export chip (nl-ux). The app target sets it; unset,
    /// the chip falls back to ``perform(_:)`` with `.export`.
    ///
    /// The chip used to run `.export` directly, which is the ledger export alone, so a person
    /// looking for the marked-up PDF behind a button labelled "Export" got a spreadsheet.
    public var onPresentExportChooser: (@MainActor () -> Void)?

    /// The status strip's Unit menu (NL-UX-19): sets the takeoff's output units. The app wires
    /// it to the session's display units; unset, the read-out stays plain text.
    public var onSetOutputUnits: (@MainActor (StatusUnitChoice) -> Void)?

    /// Command palette (NL-UX-05): rows the app tier adds — its own application commands —
    /// beside the shell's command table, presets, pages and subjects.
    public var commandPaletteExtraItems: (@MainActor () -> [CommandPaletteItem])?
    /// Whether a shell command can run now, as its menu row would say. Unset, every row is
    /// offered enabled.
    public var commandPaletteValidator: (@MainActor (ZPDFCommandID) -> Bool)?

    /// Opens the scale sheet for the page on screen — the status strip's Scale segment
    /// (LT3-08: clicking "Scale No scale" did nothing). The app target sets it; unset, the
    /// segment stays a plain readout rather than a button that does nothing.
    public var onScaleSegmentPressed: (@MainActor () -> Void)?

    /// Sets the page on screen to the drawing ratio 1:`denominator` — the status strip's Scale
    /// menu (NL-UX-19). The app wires it to the undoable preset-scale command; unset, the Scale
    /// segment stays the plain button that opens the sheet.
    public var onApplyScaleRatio: (@MainActor (_ denominator: Int) -> Void)?

    /// The drawing ratios the Scale menu offers, as denominators of 1:n.
    public static let scaleRatioChoices = [1, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]

    /// "1:50".
    public static func ratioTitle(_ denominator: Int) -> String { "1:\(denominator)" }

    // MARK: Colour palette (NL-MARKUP-01)

    /// Presents the colour palette a swatch opens. A transient `NSPopover` in the product;
    /// the hit-target probe injects an off-screen presenter so it can click the real palette
    /// without putting anything on screen.
    public var colourPalettePresenter: any ZPDFPopoverPresenting = ZPDFSystemPopoverPresenter()

    /// Drives the system colour panel for the palette's "More Colours…".
    public var colourPanel: ZPDFColourPanelController = .shared

    /// The colours most recently applied from a palette, shared by every window.
    public var recentColours: ZPDFRecentColours = ProjectShellEnvironment.sharedRecentColours

    /// The company's own colours (NL-MARKUP-14), shared by every window.
    public var companyColours: ZPDFCompanyColours = ProjectShellEnvironment.sharedCompanyColours

    /// The palette's eyedropper. `NSColorSampler` in the product; a test injects one that
    /// answers at once, so no loupe appears during a test run (NL-MARKUP-14).
    public var colourSampler: any ZPDFColourSampling = ZPDFSystemColourSampler()

    /// The colours this project's markups already use, for the palette's "In This Project" row.
    /// The app wires it from the document's markups; unset, the row is left out.
    @ObservationIgnored
    public var projectColours: (@MainActor () -> [ColorRGBA])?

    /// The docked Tool Library the Inspector's Tools tab shows (NL-UX-06). The app wires it
    /// with the library view over its own editing model; unset, the tab explains it is waiting.
    @ObservationIgnored
    public var toolLibraryDock: (@MainActor () -> AnyView)?

    /// One company-colours list for the process, persisted like the recent colours.
    public static let sharedCompanyColours = ZPDFCompanyColours(
        defaults: ZPDFShellAutosaveName.appKitAutosavesEnabled ? .standard : nil
    )

    /// One recent-colours list for the process. Persisted in `UserDefaults.standard` only in
    /// the assembled application (the same bundle-identifier rule as AppKit's autosaves), so a
    /// test or probe run can never leave a recent colour behind for the next one.
    public static let sharedRecentColours = ZPDFRecentColours(
        defaults: ZPDFShellAutosaveName.appKitAutosavesEnabled ? .standard : nil
    )

    /// The Navigator's page-thumbnail loader. The app tier injects its provider — the
    /// engine-barrier-wrapped `PageRasterSource.thumbnail` — once the drawing's raster
    /// source exists; until then rows render the proportioned placeholder sheet.
    public let navigatorThumbnails = NavigatorThumbnailLoader()

    /// The Navigator's document-layer list (gap 10 / S23). The app tier applies effective
    /// rows and services the toggles; the shell only renders them.
    public let navigatorLayers = NavigatorLayerListModel()

    /// The project's markup layers (ADR-0032): the Navigator's Layers page and the Inspector's
    /// Layer row read and request through it.
    public let markupLayers = MarkupLayerPanelModel()

    /// NL-UX-09 (r2-layers): told which markup's ledger row the pointer is over, `nil` when it
    /// leaves; the application outlines that markup on the canvas.
    public var onLedgerHover: (@MainActor (UUID?) -> Void)?

    /// The Inspector's Measurement-section edit hooks (Scale Region, Subject, Precision). The shell renders the control rows and fires these; the app tier services
    /// them through the document command bus. Unwired, the rows render but the edits are inert.
    public let inspectorEditing = InspectorEditing()

    /// The Scale Regions panel's controller: creating a region from a drawn polygon, its scale,
    /// priority, lock, and the crossing decision the engine refuses to make on its own.
    public let scaleRegions = ScaleRegionsPanelModel()

    /// The Project Zones panel's controller: creating, naming, colouring and nesting zones, and
    /// the action that regroups the Quantity Ledger by zone.
    public let projectZones = ProjectZonesPanelModel()

    /// Split Canvas: how many canvases, what each one shows, what is mirrored between them.
    public let splitCanvas = SplitCanvasController()

    /// Draws one **occupied** Split Canvas pane with the real drawing (LT-24).
    ///
    /// The shell cannot render a page — it has no raster source — so without this hook a
    /// pane shows the labelled placeholder card, which is exactly what shipped: Tools ▸
    /// Split Canvas opened panes that named the drawing and never drew it. The app tier
    /// installs a provider that resolves the pane's document and page to a live page view;
    /// `nil` from the provider (a document the window no longer has) falls back to the
    /// placeholder, and empty panes never consult it — their card is the honest state.
    @ObservationIgnored
    public var splitCanvasPaneContent: (@MainActor (SplitCanvasPaneState) -> AnyView?)?

    /// Revision Overlay: the stacked revisions and the alignment the person builds by hand.
    /// Rebuilt from the compare presenter's revision list the first time the mode is entered.
    public private(set) var revisionOverlay = RevisionOverlayModel()

    /// Every panel and mode the person is currently inside, newest last. `Escape` pops one
    /// level, and nothing can be registered without an exit route — the no-dead-ends guard.
    ///
    /// The app target may pass its own registry so that window-level `Escape` and the quit path
    /// see the shell's modes too; when it does not, the shell keeps one of its own and the
    /// mode's own Escape route and close control still work.
    public let modeRegistry: ZPDFModeExitRegistry

    /// Which canvas view mode owns the canvas, and the viewport to come back to.
    public let canvasModes = CanvasViewModeCoordinator()

    /// Regrouping requests aimed at the docked Quantity Ledger.
    public let ledgerGrouping = LedgerGroupingRequest()

    /// Whether the canvas bar's Undo and Redo have anything to act on. The shell cannot see the
    /// document's undo manager, so the app tier writes this whenever that stack changes; until
    /// it does, both stay `nil` and the buttons defer to the Edit menu's own validation.
    public let canvasUndoState = CanvasUndoState()
    /// NL-UX-12: the line over the canvas that says what an undo or redo just did.
    public let undoToast = UndoToastModel()

    /// Called when a canvas view mode ends, with the viewport captured on entry.
    ///
    /// The shell does not need this to restore the canvas — the canvas view is never removed,
    /// so it comes back exactly as it was (see ``CanvasPaneContainerViewController``). The hook
    /// exists for an app-tier canvas that *does* something on entry, such as suspending its
    /// render loop, and needs the symmetric call.
    public var onLeaveCanvasMode: (@MainActor (DismissibleCanvasMode, CanvasReturnToken?) -> Void)?

    /// Performs a drop of drawings on the Navigator's page column: opens or adds the files, inserting at the given position. Wired by the app
    /// target; until it is, the Navigator accepts no drops.
    public var onNavigatorDropFiles: (@MainActor (_ urls: [URL], _ insertionIndex: Int) -> Bool)?

    /// Whether a PDF dropped on the page column joins the project at the drop line (NL-DOCS-04):
    /// true for a project, where each card takes the drop and shows where the sheets will land;
    /// false for a Quick PDF, where a drop opens the drawing as one of its own.
    public var navigatorDropAddsToProject = false

    // MARK: Arranging the set, round 2 (NL-DOCS-07/11/12/16)

    /// Turns sheets on screen by a quarter turn, clockwise for 90, anticlockwise for -90.
    /// Display only; one undo step. Wired by the app target; until it is, no Rotate items.
    public var onRotatePages: (@MainActor (_ pageIDs: [UUID], _ degrees: Int) -> Void)?
    /// Removes sheets from the set (`true`) or puts removed ones back (`false`). Nothing is
    /// deleted; one undo step. Wired by the app target; until it is, no Remove item.
    public var onSetPagesRemoved: (@MainActor (_ pageIDs: [UUID], _ removed: Bool) -> Void)?
    /// Starts drawing a view crop on the canvas for a sheet (NL-DOCS-16).
    public var onCropPage: (@MainActor (_ pageID: UUID) -> Void)?
    /// Returns sheets to their whole page (NL-DOCS-16).
    public var onClearCrop: (@MainActor (_ pageIDs: [UUID]) -> Void)?
    /// The sheets removed from the set, listed under the cards with a Restore action.
    ///
    /// Stored in the observable ``navigatorSetState`` (R-075): the environment is not
    /// `@Observable`, so a view that read a plain stored property here was never told when the
    /// application wrote it — the Restore list appeared only after some unrelated re-render.
    public var removedSheets: [NavigatorRemovedSheet] {
        get { navigatorSetState.removedSheets }
        set { navigatorSetState.removedSheets = newValue }
    }
    /// Sheets with no scale of their own; their cards say "No scale" (NL-MEASURE-02).
    /// Observable through ``navigatorSetState`` (R-075), so the badge clears once a sheet is scaled.
    public var unscaledPageIDs: Set<UUID> {
        get { navigatorSetState.unscaledPageIDs }
        set { navigatorSetState.unscaledPageIDs = newValue }
    }
    /// The drawing-set facts the Navigator draws, in a box SwiftUI observes (R-075).
    public let navigatorSetState = NavigatorSetState()
    /// Opens the comparison of a sheet with its match in the previous revision (NL-DOCS-11).
    public var onCompareWithPreviousRevision: (@MainActor (_ pageID: UUID) -> Void)?
    /// Whether the project holds a revision to compare with; the card item shows only then.
    /// Observable through ``navigatorSetState`` (R-075).
    public var hasPreviousRevision: Bool {
        get { navigatorSetState.hasPreviousRevision }
        set { navigatorSetState.hasPreviousRevision = newValue }
    }
    /// Carries the takeoff on sheets forward onto their matches in the newest revision
    /// (NL-DOCS-12). Wired by the app target; the card item shows only with a revision.
    public var onCarryForward: (@MainActor (_ pageIDs: [UUID]) -> Void)?
    /// Adds every other open drawing, with its takeoff, to this project (NL-DOCS-04). Wired by
    /// the app target for a project; until it is, the file menu offers no Combine item.
    public var onCombineOpenDrawings: (@MainActor () -> Void)?
    /// Opens a bookmark at its left/top on its page, as a jump ⌘[ undoes (NL-DOCS-06/09).
    /// Wired by the app target; until it is, a bookmark turns to its page.
    public var onOpenBookmark: (@MainActor (NavigatorBookmark) -> Void)?
    /// Writes the arranged set — order, turns, sheet numbers as page labels — as a new PDF
    /// (NL-DOCS-08). Wired by the app target; until it is, the file menu offers no item.
    public var onExportArrangedSet: (@MainActor () -> Void)?
    /// Writes one PDF per sheet, named by sheet number (NL-DOCS-08).
    public var onSplitIntoSheets: (@MainActor () -> Void)?
    /// Writes the set compare report against the newest revision (NL-DOCS-13). Offered only
    /// with ``hasPreviousRevision``.
    public var onSetCompareReport: (@MainActor () -> Void)?
    /// Finds sheet references in the set's text and offers links to review (NL-DOCS-10).
    public var onLinkSheetReferences: (@MainActor () -> Void)?

    /// Moves pages within the set (NL-DOCS-07): the pages, in set order, land as one block
    /// starting at `toPosition`. One undo step. Wired by the app target to the undoable
    /// `.reorderPage` command; until it is, the Navigator offers no arrange items.
    public var onMovePages: (@MainActor (_ pageIDs: [UUID], _ toPosition: Int) -> Void)?

    /// Names a sheet by hand (NL-DOCS-05): its number and title, either may be empty; both
    /// empty clears the name. One undo step; a typed name is never replaced by an automatic
    /// reading. Wired by the app target; until it is, the card offers no Name Sheet item.
    public var onNameSheet: (@MainActor (_ pageID: UUID, _ number: String?, _ title: String?) -> Void)?

    /// Writes the given pages, in set order, to a new PDF the person chooses (NL-DOCS-08):
    /// labels, bookmarks and links carried, the issued drawing untouched. Wired by the app
    /// target; until it is, the card offers no Extract item.
    public var onExtractPages: (@MainActor (_ pageIDs: [UUID]) -> Void)?

    /// The drawing's own bookmarks (its PDF outline), for the Pages Index (NL-DOCS-06). Set by
    /// the app target when a drawing loads; empty when the drawing has none.
    ///
    /// Observable through ``navigatorSetState`` (S-049, the R-075 rule): the application writes
    /// the refined list after an `await`, and a plain stored property here never told an Index
    /// already on screen, which kept the synchronous first list until some unrelated re-render.
    public var navigatorBookmarks: [NavigatorBookmark] {
        get { navigatorSetState.navigatorBookmarks }
        set { navigatorSetState.navigatorBookmarks = newValue }
    }

    /// Set by ``ProjectWindowLayoutController`` so panel commands can reach the panes.
    weak var layoutController: ProjectWindowLayoutController?

    /// Creates an environment over an explicit set of presenters.
    public init(
        document: any DocumentPresenting,
        canvas: any CanvasPresenting,
        ledger: any LedgerPresenting,
        toolLibrary: any ToolLibraryPresenting,
        search: any SearchPresenting,
        compare: any ComparePresenting,
        measurement: any MeasurementToolPresenting,
        status: any StatusPresenting,
        toolbar: ZenitToolbarModel = ZenitToolbarModel(),
        tabBar: DocumentTabBarModel = DocumentTabBarModel(),
        // NL-UX-11: the table in force, the person's own shortcuts included. `nil` follows
        // ``ZPDFCommandTable/effective`` live (R-074); a table pins it.
        commands: ZPDFCommandTable? = nil,
        modeRegistry: ZPDFModeExitRegistry = ZPDFModeExitRegistry()
    ) {
        self.modeRegistry = modeRegistry
        self.document = document
        self.canvas = canvas
        self.ledger = ledger
        self.toolLibrary = toolLibrary
        self.search = search
        self.compare = compare
        self.measurement = measurement
        self.status = status
        self.toolbar = toolbar
        self.tabBar = tabBar
        self.injectedCommands = commands
        wireModels()
        followCurrentPage()
    }

    #if DEBUG || ZPDF_MOCKS
    /// Builds an environment over `MockPresenters`, for previews and for the shell's own tests.
    /// Debug and test builds only, like the mocks it is built from (R-142).
    public static func mock(
        project: ZenitSampleProject = .shared,
        toolbar: ZenitToolbarModel = ZenitToolbarModel()
    ) -> ProjectShellEnvironment {
        let mocks = MockPresenters.makeEnvironment(project: project)
        return ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status,
            toolbar: toolbar
        )
    }
    #endif

    private func wireModels() {
        tabBar.source = { [weak self] in
            guard let self else { return .empty }
            return DocumentTabBarInput(
                tabs: self.document.tabs,
                activeTabID: self.document.activeTabID,
                revisions: self.compare.revisions
            )
        }
        tabBar.onSelect = { [weak self] id in self?.document.selectTab(id) }
        tabBar.onClose = { [weak self] id in self?.document.closeTab(id) }
        tabBar.onNewTab = { [weak self] in self?.perform(.openDocument) }
        tabBar.onRevealInFinder = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        tabBar.onCopyPath = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        toolbar.onCommand = { [weak self] command in
            guard let self else { return }
            // The Search chip toggles — it lights while Search is open, so pressing it again is
            // the way back. The ⌘F menu command does not: it always leaves
            // the caret in the field (IM-132). Two behaviours, so two routes.
            //
            // L-94 (live test 8): Project Zones and Scale Regions are the same pair of routes.
            // Their Panels menu items read "Show …" and used to toggle, so with the Zones page
            // already up "Show Project Zones" hid the whole Navigator. The menu now shows; the
            // chip, which lights while its panel is up, keeps the way back.
            switch command {
            case .find:
                self.layoutController?.toggleNavigatorSection(.search)
            case .projectZones:
                self.refreshProjectZones()
                self.layoutController?.toggleNavigatorSection(.zones)
            case .scaleRegions:
                self.refreshScaleRegions()
                self.layoutController?.toggleScaleRegionsPanel()
            default:
                self.perform(command)
            }
        }
        toolbar.onCountPreset = { [weak self] id in self?.toolLibrary.activatePreset(id: id) }
        // A tool the person chooses replaces the armed Tool Library preset (X-018). On the
        // choice itself, before the toolbar arms it and before its de-duplication.
        toolbar.onToolChosen = { [weak self] selection in self?.presetGivesWay(to: selection) }
        // The seam. Every arming path in the toolbar ends here, so the measurement
        // presenter and the status bar cannot fall out of step with the lit chip — which
        // is exactly what happened to Text, Callout and Shapes.
        // The markup family is armed by the canvas from the same selection; the shell has
        // no markup presenter of its own to drive.
        toolbar.onSelectionChange = { [weak self] selection in
            guard let self else { return }
            if let kind = selection.mode.measurementKind {
                self.measurement.activate(kind: kind)
            } else {
                // Leaving the measurement family disarms whatever was being drawn, so a
                // stray half-finished polygon never survives a tool switch.
                self.measurement.deactivate()
            }
            self.refreshArmedToolStatus()
            // The tool options bar appears for exactly the tools that need a value from
            // it, and gets out of the way for the other seventeen.
            self.layoutController?.updateToolOptionsBar()
        }
        toolbar.updateCountPalette(from: toolLibrary.presets)
        wirePanelModels()
        refreshArmedToolStatus()
    }

    /// Puts the armed Tool Library preset down because the person chose a tool (X-018), unless
    /// the choice is that preset itself — the Count palette arming the armed count preset again.
    ///
    /// Raised by ``ZenitToolbarModel/onToolChosen`` for every choice — chip, palette, menu
    /// command, key — before the toolbar arms it, and even when it is the tool already lit:
    /// pressing Length or L with the Kerb Length preset armed means a plain Length, and in Apply
    /// or Place a chip means drawing rather than applying. The preset used to stay armed through
    /// both, so the next Length was filed under "Kerb" with its status, label and ledger values,
    /// and the canvas kept sending every Apply click to the preset. A style re-arm (the
    /// Inspector restyling a markup calls ``ZenitToolbarModel/rememberStyle(_:kinds:)``), a
    /// restore and the core lighting the preset's own tool (``libraryArmed(_:)``) are not
    /// choices and never reach here, in any set mode.
    ///
    /// Disarming goes through `clearActivePreset()`, the one path that puts both families'
    /// preset defaults down. It runs before the chosen tool is armed, so a count in progress is
    /// finished under the preset that made it; and since the toolbar's selection names the
    /// armed preset (``libraryArmed(_:)``), the chosen selection always differs from it, so
    /// the seam re-arms the presenters the disarm put down.
    func presetGivesWay(to selection: ZenitToolSelection) {
        guard let preset = toolLibrary.activePreset, selection.presetID != preset.id else { return }
        toolLibrary.clearActivePreset()
    }

    /// Mirrors a Tool Library arming onto the toolbar: the tool the canvas will use, carrying
    /// the armed preset (X-018).
    ///
    /// The app core calls this from `AppCoreEnvironment.onLibraryArmedTool` after it has armed
    /// the presenters: the preset's drawing tool in Draw, Select when the preset arms none. Not
    /// a choice, so it keeps the preset it mirrors.
    public func libraryArmed(_ mode: ZenitToolMode) {
        toolbar.showLibraryArm(mode, preset: toolLibrary.activePreset)
    }

    /// Connects the panel controllers to the presenters and to each other.
    ///
    /// Only the shell-serviceable half is wired here — reading the presenters, and the one
    /// cross-panel action (Project Zones regrouping the Quantity Ledger). Everything that
    /// *mutates* a document — creating a region or a zone, assigning a scale, filing a
    /// selection — stays an unset hook the app tier fills, because those need the command bus
    /// and its undo inverses. A panel whose hook is unset refuses out loud rather than
    /// pretending, which is what the two panels' refusal enums are for.
    private func wirePanelModels() {
        refreshScaleRegions()
        refreshProjectZones()
        projectZones.onGroupLedger = { [weak self] column in
            self?.ledgerGrouping.request([column])
        }
        canvasModes.onLeave = { [weak self] mode, token in
            guard let self else { return }
            self.modeRegistry.unregister(id: mode.rawValue)
            self.onLeaveCanvasMode?(mode, token)
        }
    }

    /// Re-reads the document presenter into the Scale Regions panel.
    ///
    /// Called whenever the document's region set may have changed. The core is the authority on
    /// which regions exist and which of them overlap; the panel holds no opinion of its own.
    ///
    /// **The page id is passed, always.** `ScaleRegionsPanelModel` discards a draft that belongs
    /// to another page (CR-179), and without the id it has to infer the page from the regions it
    /// was handed — which works for every page that has one and fails for the page that has
    /// none. Turning from a page with a half-drawn boundary to an empty page is exactly the case
    /// the inference cannot see: an empty list says "no regions", never "a different page". The
    /// shell already knows which page it is showing, so it says so.
    public func refreshScaleRegions() {
        let pageID = document.currentPageID
        let onPage = pageID.map { document.scaleRegions(onPage: $0) } ?? document.scaleRegions
        scaleRegions.setRegions(onPage, pageID: pageID)
        scaleRegions.setPageDefaultScale(document.defaultScale)
        // Only scales calibrated on this sheet: its default and its own regions' scales. The
        // menus used to offer every region's scale in the document, and the core refuses a
        // scale from another page every time — with a UUID in the message (T-056).
        var scales: [ScaleSummary] = []
        if let pageDefault = document.defaultScale { scales.append(pageDefault) }
        for region in onPage where !scales.contains(where: { $0.id == region.scale.id }) {
            scales.append(region.scale)
        }
        scaleRegions.setAvailableScales(scales)
    }

    /// Everything the shell owns that is a fact about the page on screen.
    ///
    /// The Scale Regions panel is page-scoped: its list, its page default, and — since CR-179 —
    /// its draft. A page turn that does not reach it leaves a boundary drawn on the previous
    /// sheet armed over this one, and Create then files it against the page it was drawn on
    /// while the duplicate-name check runs against the page on screen.
    ///
    /// The application tier also refreshes after every command (`refreshProjectStructure`), so
    /// this is belt and braces there; it is the only path in a shell-only harness, and it is
    /// idempotent — the panel discards nothing when the page has not moved.
    public func pageDidChange() {
        refreshedPageID = document.currentPageID
        refreshScaleRegions()
    }

    /// The page ``pageDidChange()`` last refreshed for, so the page observer below does not
    /// refresh a second time for a turn that already went through ``turningPage(_:)``.
    private var refreshedPageID: PageDescriptor.ID?

    /// Refreshes the page-scoped panels whenever the document's page moves, however it moved
    /// (S-046).
    ///
    /// ``turningPage(_:)`` refreshes after the work it wraps, but some turns land later: a search
    /// hit whose rectangles are not resolved yet asks the search service first and turns the
    /// page when the answer comes back, after `turningPage` has returned — and the Scale Regions
    /// panel kept the previous sheet's regions and draft (the BH-296 shape). Following the page
    /// itself covers that and every other asynchronous turn. The change handler runs on the next
    /// main-actor turn, once the new page is in place.
    private func followCurrentPage() {
        withObservationTracking {
            _ = document.currentPageID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.document.currentPageID != self.refreshedPageID { self.pageDidChange() }
                self.followCurrentPage()
            }
        }
    }

    /// Re-reads the document presenter into the Project Zones panel.
    public func refreshProjectZones() {
        projectZones.setZones(document.zones)
        projectZones.setSelectedMarkupCount(canvas.selectedMarkupIDs.count)
    }

    // MARK: - Canvas view modes

    /// Enters a canvas view mode, capturing the viewport to come back to and registering the
    /// way out before anything covers the canvas.
    ///
    /// The order matters: the registration happens *first*, so there is no instant in which a
    /// mode is on screen without an exit route. That is the whole no-dead-ends guard, and it is
    /// why the registry's `register` takes the close action as a non-optional parameter.
    @discardableResult
    public func enterCanvasMode(_ mode: DismissibleCanvasMode) -> Bool {
        guard let layoutController else { return false }
        if canvasModes.activeMode == mode { return true }
        // A MODE-TO-MODE SWITCH RETIRES THE FIRST MODE'S EXIT ROUTE.
        //
        // `CanvasViewModeCoordinator.enter` replaces `activeMode` outright — deliberately, so the
        // return token stays the view the person had before *any* mode took the canvas — and
        // therefore never runs `onLeave` for the mode being displaced. `onLeave` is what
        // unregisters. Going straight from Split Canvas to Revision Overlay left `splitCanvas`
        // in the registry for the life of the window: Escape closed the overlay, the registry
        // still read `["splitCanvas"]` with no mode active, and the Panels menu kept offering
        // "Close Split Canvas" for a pane that was not there. Unregistering here — before the
        // new mode registers, so the two can never both be live — is the whole of CR-97. The
        // coordinator itself is in another package and keeps its one job.
        if let displaced = canvasModes.activeMode, displaced != mode {
            modeRegistry.unregister(id: displaced.rawValue)
        }
        canvasModes.enter(
            mode,
            returning: CanvasReturnToken(
                documentID: document.activeTabID,
                viewport: canvas.viewport
            )
        )
        modeRegistry.register(
            id: mode.rawValue,
            displayName: mode.displayName,
            exitRoute: ZPDFModeExitRoute(
                menuTitle: String(
                    format: NSLocalizedString("Close %@", comment: "Menu item: close a named canvas view mode"),
                    mode.displayName
                ),
                performExit: { [weak self] in self?.leaveCanvasMode() }
            )
        )
        switch mode {
        case .splitCanvas:
            layoutController.presentCanvasMode(mode) { leave in
                SplitCanvasModePane(
                    controller: self.splitCanvas,
                    paneContent: { [weak self] pane in self?.splitCanvasPaneContent?(pane) },
                    onClose: leave
                )
            }
        case .revisionOverlay:
            revisionOverlay = RevisionOverlayModel(revisions: compare.revisions)
            layoutController.presentCanvasMode(mode) { leave in
                RevisionOverlayModePane(model: self.revisionOverlay, onClose: leave)
            }
        case .revisionCompare:
            // Revision Compare is presented as a sheet by the app tier, which owns the compare
            // run. The registration and the return token still come from here so all three
            // modes leave the same way.
            break
        }
        return true
    }

    /// Leaves whatever canvas view mode is active. Safe to call when there is none.
    public func leaveCanvasMode() {
        guard canvasModes.isInMode else { return }
        layoutController?.dismissCanvasMode()
        // `leave()` runs `onLeave`, which unregisters the mode; the registry may also have
        // popped it already if Escape came through there. Both orders end in the same state.
        canvasModes.leave()
    }

    /// Names the armed tool in the status bar, together with the one thing it will not do
    /// yet — or, for the five parameter-hungry tools, the value it is still waiting for.
    ///
    /// The second half cannot live in ``ZenitToolMode/limitationNote``: that is a pure
    /// function of the mode, and "Volume has no depth *yet*" is a fact about the field the
    /// estimator is looking at, not about the tool.
    func refreshArmedToolStatus() {
        let mode = toolbar.activeSelection.mode
        status.setActiveTool(
            name: mode.displayName,
            // `armedToolNote`: why the tool cannot measure on this sheet at all (a circle under
            // separate X and Y scales, L-102), else the value it is still waiting for.
            note: mode.limitationNote ?? measurement.armedToolNote
        )
    }

    /// Sets the tool options bar's parameter field and re-states what the tool is waiting
    /// for. The single entry point the field's binding uses, so the status bar can never
    /// claim a depth is missing after one has been typed.
    public func setMeasurementParameterText(_ text: String) {
        measurement.setParameterText(text)
        refreshArmedToolStatus()
    }

    // MARK: - What is open

    /// Whether one closable surface is on screen.
    ///
    /// Reads the layout controller's observable mirror on ``ShellPanelState``, so a SwiftUI view
    /// that asks this question redraws when the answer changes — a plain call into the
    /// controller would be a snapshot nothing invalidates.
    public func isSurfaceVisible(_ surface: ZPDFClosableSurface) -> Bool {
        layoutController?.panelState.isVisible(surface) ?? false
    }

    /// Whether the panel a toolbar chip toggles is currently open.
    ///
    /// The Tool Library, Search and Compare chips show whether the panel is open, so pressing
    /// again is an obvious way back. The three answers come from three
    /// different places, and all three are observable: the mode registry knows which sheets are
    /// up, and the panel state knows which Navigator page is showing.
    public func isPanelOpen(_ command: ZPDFCommandID) -> Bool {
        switch command {
        case .toolLibrary:
            return modeRegistry.exitRoute(for: WorkflowPanelKind.toolLibrary.id) != nil
        case .revisionCompare:
            return modeRegistry.exitRoute(for: WorkflowPanelKind.revisionCompare.id) != nil
        case .scaleRegions:
            // Scale Regions opens a window of its own and registers a mode with an exit route,
            // exactly as Tool Library and Compare do — the answer was always available and simply
            // never asked for, so its chip could not light and pressing it again was not visibly
            // the way back. Found by `PanelSweepTests` on 2026-08-27.
            return modeRegistry.exitRoute(for: ProjectWindowLayoutController.scaleRegionsModeID) != nil
        case .find:
            // Search is a Navigator page, so "open" is "the Navigator is up, on that page".
            return isSurfaceVisible(.navigator)
                && layoutController?.panelState.navigatorSection == .search
        case .projectZones:
            return isSurfaceVisible(.navigator)
                && layoutController?.panelState.navigatorSection == .zones
        case .splitCanvas:
            return canvasModes.activeMode == .splitCanvas
        case .revisionOverlay:
            return canvasModes.activeMode == .revisionOverlay
        case .toggleCoverageMap:
            return canvas.showsCoverageMap
        default:
            if let surface = ZPDFClosableSurface(command: command) {
                return isSurfaceVisible(surface)
            }
            return false
        }
    }

    /// Routes a command.
    ///
    /// View, panel and measurement commands are serviced here because the shell owns those
    /// surfaces. Everything else is forwarded to ``externalCommandHandler``.
    public func perform(_ command: ZPDFCommandID) {
        switch command {
        case .zoomIn:
            canvas.setZoom(canvas.viewport.zoom * 1.25)
        case .zoomOut:
            canvas.setZoom(canvas.viewport.zoom / 1.25)
        case .fitWidth:
            canvas.zoomToFitWidth()
        case .actualSize:
            canvas.setZoom(1.0)
        case .fitPage:
            canvas.zoomToFit()
        case .nextPage:
            document.goToNextPage()
            pageDidChange()
        case .previousPage:
            document.goToPreviousPage()
            pageDidChange()
        case .firstPage:
            document.goToFirstPage()
            pageDidChange()
        case .lastPage:
            document.goToLastPage()
            pageDidChange()
        case .zoomToSelection:
            // Fitting a selection needs the scroll geometry only the canvas view owns, so
            // the app tier services the fit (`⌘*`) — after the shell has
            // turned to the sheet the selection is on (S-045).
            zoomToSelection()
        case .toggleNavigator:
            layoutController?.toggleNavigator()
        case .toggleInspector:
            layoutController?.toggleInspector()
        case .toggleQuantityLedger:
            layoutController?.toggleQuantityLedger()
        case .toggleHistory:
            layoutController?.toggleHistory()
        case .collapseQuantityLedger:
            layoutController?.toggleQuantityLedgerBar()
        case .detachQuantityLedger:
            layoutController?.toggleQuantityLedgerDetached()
        case .customizeToolbar:
            layoutController?.runToolbarCustomization()
        case .find:
            // Standard macOS find: ⌘F always ends with the caret in the search field. It used
            // to toggle, so ⌘F with Search already showing *hid the Navigator* — and the field
            // was never focused either way (IM-132). The toolbar chip keeps its toggle through
            // `toolbar.onCommand` (see `wireModels()`), which is where the way-back belongs.
            layoutController?.revealNavigatorSection(.search)
            layoutController?.panelState.requestSearchFieldFocus()
        case .projectZones:
            // The zones page is a Navigator page, so "show it" is "open the Navigator on it" —
            // and only that: Panels ▸ Show Project Zones with the page already up leaves it up
            // (L-94). The chip's toggle is `toolbar.onCommand`'s.
            refreshProjectZones()
            layoutController?.revealNavigatorSection(.zones)
        case .scaleRegions:
            // "Show Scale Regions" shows, and brings an open panel forward (L-94).
            refreshScaleRegions()
            layoutController?.showScaleRegionsPanel()
        case .splitCanvas:
            if canvasModes.activeMode == .splitCanvas {
                leaveCanvasMode()
            } else {
                enterCanvasMode(.splitCanvas)
            }
        case .revisionOverlay:
            if canvasModes.activeMode == .revisionOverlay {
                leaveCanvasMode()
            } else {
                enterCanvasMode(.revisionOverlay)
            }
        case .toggleCoverageMap:
            // A canvas overlay, not a canvas mode: it draws over whatever the canvas is doing
            // and steals no tool, so it toggles a presenter flag rather than entering a mode.
            canvas.showsCoverageMap.toggle()
        case .closeCanvasMode:
            leaveCanvasMode()
        case .toolLibrary:
            externalCommandHandler?(command)
        case .selectTool:
            toolbar.selectTool(.select)
        case .panTool:
            toolbar.selectTool(.pan)
        case .zoomTool:
            toolbar.selectTool(.zoom)
        case .textTool:
            toolbar.selectTool(.text)
        case .calloutTool:
            toolbar.selectTool(.callout)
        case .shapesTool:
            toolbar.activateLastUsedShape()
        case .measureTool:
            toolbar.activateLastUsedMeasurement()
        case .cutoutTool:
            toolbar.activateMeasurement(.polygonCutout)
        case .calibrateScale:
            // The calibration flow itself lives in the app tier; the shell arms the tool so
            // the toolbar reflects the mode while the flow runs.
            toolbar.selectTool(.calibrate)
            externalCommandHandler?(command)
        case .measureLength:
            toolbar.activateMeasurement(.length)
        case .measurePolylength:
            toolbar.activateMeasurement(.polylength)
        case .measureArea:
            toolbar.activateMeasurement(.area)
        case .measureCount:
            toolbar.activateLastUsedCount()
        case .finishGeometry:
            // Reuse Tool, honoured by the measurement family too.
            // `canCommit` is read *before* the commit because the commit clears the points:
            // a Finish that had nothing to finish must not disarm the tool the estimator is
            // still holding.
            let committed = measurement.canCommit
            // A refusal is spoken, never silent — Return doing nothing with nothing said is
            // the silent-commit defect, and it happened again (LT-9, 2026-08-29).
            if !committed, let reason = measurement.commitRefusalReason {
                status.setActiveToolNote(reason)
            }
            measurement.commitActiveMeasurement()
            if committed, !toolLibrary.markupCommitted() {
                toolbar.selectTool(.select)
            } else if committed {
                // Reuse Tool is on, so the tool stays armed and no `onSelectionChange` fires to
                // rewrite the status line. Without this the previous refusal — "Area needs 3
                // more points…" — sat under a measurement that had just succeeded, for as long
                // as the estimator kept measuring (CR-104). The disarming branch above gets the
                // same refresh for free, through `arm` → `onSelectionChange`.
                refreshArmedToolStatus()
            }
        case .cancelTool:
            // Escape backs out one level, and a canvas view mode is the outermost level the
            // shell owns: leaving Split Canvas must not also throw away the polygon someone
            // was drawing underneath it.
            if canvasModes.isInMode {
                leaveCanvasMode()
                return
            }
            // WORK IN PROGRESS WINS. Escape backs out the innermost thing first: a
            // half-drawn measurement is closer to the hand than any panel. Letting a
            // registered mode take the key first meant a Scale Regions panel left open
            // earlier in the session swallowed every Escape, and a half-drawn line could
            // not be cancelled at all (RT-1, 2026-08-31 — caused by the first attempt at
            // the LT-26/28 fix).
            if !measurement.placedPoints.isEmpty {
                measurement.cancelActiveMeasurement()
                if !toolLibrary.reuseToolEnabled { toolbar.selectTool(.select) }
                return
            }
            // Nothing in progress: the next level out is a registered workflow mode
            // (Revision Compare, Revision Overlay, Tool Library, Scale Regions…). Its own
            // chrome answers Escape only while the panel holds key focus; when the canvas
            // kept focus the key fell through to here and died, while the menus promised
            // "Escape returns to the drawing" (LT-26/LT-28).
            // Popped BEFORE it exits: an exit route that is a no-op for a stale registration
            // (a mode already closed by its own control) otherwise stays topmost for ever
            // and every later Escape returns here without doing anything (CR-98).
            if modeRegistry.escapeBacksOutOneLevel() { return }
            // Nothing stacked either: the armed tool itself is the last level, and it is put
            // down whether Reuse Tool is on or not (L-71). Reuse keeps the tool after a commit
            // and after the Escape that cancels a shape in progress (the rules every tool
            // shares, the branch above); an Escape or Cancel Tool over an armed tool with
            // nothing drawn is the person putting the tool down. With Reuse on — the default —
            // it used to leave the tool armed and say nothing. The canvas cancels its own markup
            // shape in progress itself and keeps the tool by the same rule.
            measurement.cancelActiveMeasurement()
            toolbar.selectTool(.select)
        case .removeLastVertex:
            measurement.removeLastPoint()
        case .cycleSnapCandidate:
            // Snap-candidate cycling belongs to the canvas renderer, which the app target
            // owns. Forward it; the window controller's external command handler routes it
            // to the canvas.
            externalCommandHandler?(command)
        case .openDocument, .save, .saveAs, .print, .export, .closeTab,
             .undo, .redo, .selectAll, .deleteSelection, .revisionCompare:
            externalCommandHandler?(command)
        }
    }
}
