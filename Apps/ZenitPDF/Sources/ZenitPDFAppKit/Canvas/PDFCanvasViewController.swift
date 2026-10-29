import AppKit
import os
import Observation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFGeometry
import ZPDFMeasurementEngine
import ZPDFSnapEngine
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFVectorExtraction

/// The canvas pane: a scroll view over one rasterised page with the Zenit overlay on top.
///
/// This is the surface the whole application exists for, so three things are wired here and
/// nowhere else:
///
/// - **Page space is the only coordinate system that leaves this class.** Every pointer event is
///   converted through ``PageDisplayTransform`` before it reaches a presenter, so no engine ever
///   sees a view point.
/// - **Rasters are requested, never awaited.** A zoom change resizes the sheet immediately and the
///   sharper image replaces the stretched one when it arrives. The main thread never blocks on
///   PDFKit.
/// - **The armed tool decides what a click means.** With the pointer armed a click selects; with a
///   measurement armed it places a vertex; during calibration it places one of two reference
///   points.
@MainActor
public final class PDFCanvasViewController: NSViewController {

    /// Points of backdrop around the sheet.
    private static let margin: CGFloat = 24

    /// How much of the viewport is added as pannable space on **each** side of the sheet.
    ///
    /// 0.9 rather than 0.5 so an edge of the sheet can be dragged past the centre of the window
    /// and a little beyond — measuring along the bottom edge of a plan means wanting that edge
    /// in the middle of the screen, not at the bottom of it. See the note in `layoutPage()`.
    private static let panMarginFraction: CGFloat = 0.9

    let core: AppCoreEnvironment
    private let rasterSource: PageRasterSource?
    /// The project's drawings (NL-DOCS-04): a page's picture comes from the drawing the page
    /// comes from. `nil` for a canvas over one drawing, which renders from ``rasterSource``.
    weak var drawingSet: DrawingSet?
    /// Follows one of the drawing's own links (NL-DOCS-09). Wired by the window.
    var onFollowLink: (@MainActor (DrawingLink.Target) -> Void)?
    /// Follows a drawing's link with where it lands (NL-DOCS-09); when set, used instead of
    /// ``onFollowLink`` for the drawing's own links.
    var onFollowDrawingLink: (@MainActor (DrawingLink) -> Void)?
    /// The drawing's links, read once per page index.
    var drawingLinksByPage: [Int: [DrawingLink]] = [:]
    /// Pages whose links are being read for hover (NL-DOCS-09).
    var drawingLinkReads: Set<Int> = []
    /// Whether the last pointer move showed the pointing hand for a drawing link, so leaving the
    /// link puts the resting cursor back (R-010).
    var isOverDrawingLink = false
    /// Goes back (`true`) or forward through the jumps (NL-DOCS-09). Wired by the window.
    var onNavigateHistory: (@MainActor (_ back: Bool) -> Void)?
    /// A place to show once its sheet is laid out (NL-DOCS-06/09).
    var pendingDestination: (pageID: UUID, left: Double?, top: Double?)?
    /// Names a link target for the hover tooltip ("Go to A-201"). Wired by the window.
    var describeLinkTarget: (@MainActor (DrawingLink.Target) -> String)?
    private let toolbar: ZenitToolbarModel

    let scrollView = ZenitCanvasScrollView()
    let pageView = CanvasPageView()
    /// The scroll view's document: the raster layers under the page view (NL-PERF-05).
    private lazy var documentView = CanvasDocumentView(pageView: pageView)

    /// The shapes the canvas is currently drawing.
    ///
    /// Read-only and internal, so a test can assert what the estimator is looking at without
    /// reaching into the view hierarchy or reproducing `CanvasSceneBuilder`'s work. This is the
    /// accessor the stamp-artwork regression needed and did not have: the scene was private, so "the stamp
    /// draws as a box with text" was a thing a person could see and no test could say.
    var canvasShapes: [CanvasMarkupShape] { pageView.shapes }

    /// The flag `CanvasPageView.mouseDown` and `mouseUp` actually branch on for a snippet
    /// region. Exposed so a test can assert that arming the mode reached the *view*, not only
    /// the controller's own mirror of it — the distance between those two is where the last
    /// seven unwired features lived.
    var isPageViewCapturingRegion: Bool { pageView.isRegionCaptureTool }

    private var rasterTask: Task<Void, Never>?
    /// The canvas's tiled raster (IM-044).
    private let tileCache = CanvasTileCache()
    /// Bumped when the pixels a tile holds would change for the same key: layer filtering,
    /// annotation visibility.
    private var tileGeneration = 0
    /// The view each page's tiles were rendered for (NL-DOCS-07/16).
    private struct RenderedView: Equatable {
        var rotation = 0
        var crop: PDFRectValue?
    }
    private var renderedViews: [Int: RenderedView] = [:]
    /// Supersedes a raster render that a newer request replaced.
    private var rasterGeneration = 0
    private var thumbnailTask: Task<Void, Never>?
    /// When the last zoom step landed, for IM-170's coalescing.
    private var lastZoomStepAt: Date?
    /// Renders that failed. A test seam for BH-884.
    private(set) var rasterFailureCountForTesting = 0

    /// The tile cache, for IM-044's tests.
    var tileCacheForTesting: CanvasTileCache { tileCache }
    /// Renders actually started (after any gesture debounce). IM-170's counter.
    private(set) var rasterRenderStartCountForTesting = 0

    /// Waits for the in-flight raster render.
    func settleRasterForTesting() async {
        await rasterTask?.value
        await thumbnailTask?.value
        await levelQueue.settle()
    }

    // MARK: - Gesture-replay seams (NL-PERF-01)

    /// One render that landed on the main actor: how long the main actor spent putting it on
    /// screen, and whether that work invalidated the page view (whose redraw is then main-thread
    /// work too). Gate Z14's raw samples.
    struct RenderLandingSample: Sendable, Equatable {
        var milliseconds: Double
        var invalidatedPage: Bool
    }
    private(set) var renderLandingSamplesForTesting: [RenderLandingSample] = []
    /// Off in the product, so the sample list cannot grow for the life of a window.
    var recordsRenderLandingsForTesting = false

    /// Times one landing on the main actor and records it.
    private func recordLanding(_ body: () -> Void) {
        guard recordsRenderLandingsForTesting else {
            body()
            return
        }
        let invalidations = pageView.pageInvalidationCount
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        renderLandingSamplesForTesting.append(RenderLandingSample(
            milliseconds: milliseconds,
            invalidatedPage: pageView.pageInvalidationCount != invalidations
        ))
    }

    /// What a display-link tick does, for a test that has no display: applies the zoom
    /// accumulated since the last frame.
    func displayFrameForTesting() {
        applyLiveZoomFrame()
    }

    /// The fraction of the visible sheet some raster covers on the frame the display would show
    /// now. Gate Z12's measurement: below 99.9 % is a blank-paper frame.
    func visiblePageCoverageForTesting() -> Double {
        pageView.drawnRasterCoverage(of: scrollView.documentVisibleRect)
    }

    /// Whether the visible sheet is covered entirely by rasters made for the current zoom and
    /// placed 1:1 on whole device pixels. Gate Z13's end condition.
    var viewportIsSharpForTesting: Bool {
        guard liveZoom == nil, let transform = pageView.transform else { return false }
        let visibleSheet = scrollView.documentVisibleRect.intersection(transform.pageFrame)
        guard !visibleSheet.isNull, visibleSheet.width > 0 else { return false }
        let scale = pageView.effectiveBackingScale
        let exact = pageView.tileRasters
            .map { $0.placement(in: transform, backingScale: scale) }
            .filter(\.isPixelExact)
            .map(\.destination)
        return CanvasPageView.coveredFraction(of: visibleSheet, by: exact) >= 0.999
    }
    /// The plan whose raster is on screen, so a pan inside its margin costs nothing and a
    /// zoom always costs a re-render. It replaces the old `renderedScale` five-per-cent band,
    /// which existed to avoid re-rasterising the whole sheet and, above 122 % zoom where the
    /// pixel cap had already stopped the scale moving, quietly meant the canvas never
    /// re-rendered at all (the defect gate Z5 exists for).
    private var deliveredPlan: ViewportRasterPlan?
    /// The plan a render is already in flight for. A layout pass and the scroll observer both
    /// reach `requestRaster`, and without this the same raster would be started twice and the
    /// first cancelled by the second for nothing.
    private var pendingPlan: ViewportRasterPlan?
    private var renderedPageIndex: Int = -1
    /// The vector underlay, created only once a page's geometry has been extracted. It is not
    /// built at canvas construction because building it starts a Metal device and compiles
    /// shaders, and a canvas with no drawing in it has nothing to draw a skeleton of.
    private var vectorUnderlay: VectorUnderlay?
    /// The page the underlay was compiled for, and the geometry it was compiled from — kept so
    /// a layer toggle can recompile the skeleton against the new hidden set. A skeleton that
    /// still shows a layer the user has just hidden would be a lie, even for four milliseconds.
    private var underlayPage: ZPDFContracts.PageDescriptor?
    private var underlayExtraction: VectorPageExtraction?
    private var underlayTask: Task<Void, Never>?
    private var sceneTask: Task<Void, Never>?
    /// Bumped for every queued scene rebuild, so ``settleScene()`` can tell "the rebuild I
    /// awaited" from "another one arrived while I waited". `Task` is a struct and has no
    /// identity to compare.
    private var sceneGeneration: Int = 0
    /// When set, the page rasterises through the content-stream path instead of the
    /// native renderer, because the effective layer visibility differs from the document
    /// default and a native render would lie (gap 10).
    private var layerFiltering: LayerFilteredPageRenderer.Filtering?

    /// The zoom the current page transform was built at, so an externally driven zoom change
    /// (menu, status bar, a test) can be told apart from a layout pass at the same zoom.
    private var lastLayoutZoom: Double = 0
    /// The window point the next zoom change anchors to. Set by the pointer gestures;
    /// external zoom changes anchor to the viewport centre instead.
    private var pendingZoomAnchorWindowPoint: NSPoint?

    /// The anchor corner of a markup drag, kept until the release finishes it. A measurement
    /// drag's anchor is the input machine's (``measurementDragAnchor``).
    private var dragAnchorPoint: PDFPointValue?

    // MARK: Live zoom state (NL-PERF-04, NL-PERF-05)

    /// A zoom gesture in flight: the similarity the GPU applies on top of the laid-out page,
    /// display = scale × laid-out + offset, in the document view's coordinates.
    struct LiveZoom {
        var scale: CGFloat = 1
        var offset: CGPoint = .zero
        /// The window point of the latest input, which the commit keeps fixed.
        var anchorWindowPoint: NSPoint
        var needsApply = false
        var generation: Int

        var transform: CGAffineTransform {
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y)
        }
    }
    private(set) var liveZoom: LiveZoom?
    private var liveZoomGeneration = 0
    private var isCommittingLiveZoom = false
    /// The page point a committed gesture must leave under its window point.
    private var pendingZoomAnchor: (window: NSPoint, page: PDFPointValue)?
    private var liveZoomIdleTask: Task<Void, Never>?
    /// The gesture's display link, kept between gestures and paused (K-14, ``CanvasFrameClock``).
    let frameClock = CanvasFrameClock()
    private var lastLiveApply: ContinuousClock.Instant?
    /// Gesture frames applied, and layouts saved by not laying out per event. Test seams.
    private(set) var liveZoomFrameCountForTesting = 0
    private(set) var liveZoomCommitCountForTesting = 0

    /// Single-tile renders for the pyramid levels a gesture passes through (NL-PERF-06/07).
    let levelQueue = CanvasTileRenderQueue()
    /// What the last level scheduling asked for, so an unchanged frame costs one comparison.
    private var lastLevelSignature: LevelSignature?
    struct LevelSignature: Equatable {
        var exponent: Int
        var cells: [Int]
        var generation: Int
    }

    /// The tiles of the last *complete* delivery: the stand-in for the next zoom (NL-PERF-02).
    private var deliveredTiles: [PageRaster] = []
    /// The cache keys of the tiles on screen, which a memory warning keeps (NL-PERF-10).
    private var currentTileKeys: [CanvasTileCache.Key] = []

    // MARK: Input state machine (IM-019)

    /// Carries out what the measurement input machine decides, the way this canvas always has:
    /// commits through the shell's Finish, Escape through its Cancel, constrained points raw.
    private lazy var measurementDriver = CanvasMeasurementDriver(
        measurement: core.measurement,
        canvas: core.canvas,
        shellCommand: { [weak self] command in self?.onShellCommand?(command) }
    )

    /// Every measurement mouse and key event on this canvas goes through here (IM-019). The
    /// canvas classifies the gesture and publishes what the machine needs — the presenter's
    /// points, the snap candidate, Shift, the zoom-aware tolerances — and the machine decides
    /// what the event means. The canvas keeps no drawing transitions of its own.
    ///
    /// Announcements stay silent here: the canvas never spoke them, and turning VoiceOver
    /// announcements on is its own decision, not a side effect of routing.
    private lazy var measurementInput = MeasurementInputController(
        target: measurementDriver,
        configuration: measurementInputConfiguration,
        announcer: { _ in }
    )

    /// Carries out the calibration flow's effects: snapped, Shift-constrained reference points.
    private lazy var calibrationDriver = CanvasCalibrationDriver(
        place: { [weak self] point in self?.placeCalibrationPoint(at: point) },
        end: { [weak self] in
            guard let self, self.isCalibrating else { return }
            self.endCalibration()
        }
    )

    /// Calibration's clicks and Escape go through the same machine, as a two-point tool.
    private lazy var calibrationInput = MeasurementInputController(
        target: calibrationDriver,
        configuration: MeasurementInputConfiguration(
            angleIncrementDegrees: Self.shiftAngleIncrementDegrees,
            reusesToolAfterCommit: true
        ),
        announcer: { _ in }
    )

    /// Calibration placements whose snap is still resolving.
    private var calibrationPlacementsInFlight = 0

    /// The machine the measurement events are routed through. IM-019's test seam.
    var measurementInputForTesting: MeasurementInputController { measurementInput }
    /// The machine calibration's events are routed through. IM-019's test seam.
    var calibrationInputForTesting: MeasurementInputController { calibrationInput }
    /// Commits the measurement driver carried out or scheduled. IM-019's test seam.
    var routedCommitCountForTesting: Int { measurementDriver.commitCountForTesting }

    /// Produces the compiled artwork stored under a digest, or `nil` when the project has
    /// none. Installed by the host, which owns the package.
    ///
    /// A count mark can name imported artwork (ADR-0011 §2.1) and the picture lives in the
    /// project's content-addressed store, which this class has no access to. The hook is
    /// asked once per digest and the answer is cached: 312 marks made from one seal cost one
    /// read, and a project with no artwork never opens the table at all.
    public var onResolveArtwork: (@MainActor (String) async -> ArtworkGeometry?)?

    /// Resolves an inserted image's pixels by artwork digest (ADR-0043, L-81), or `nil` when the
    /// store holds none. Installed by the host, which owns the package; asked once per digest.
    public var onResolveInsertedImage: (@MainActor (String) async -> CGImage?)?
    /// Inserted-image pixels this canvas has resolved, keyed by digest, and the digests the store
    /// had none for.
    private var resolvedInsertedImages: [String: CGImage] = [:]
    private var missingInsertedImageDigests: Set<String> = []

    /// Compiled artwork this canvas has already resolved, keyed by digest.
    private var resolvedArtwork: [String: ArtworkGeometry] = [:]
    /// Digests the store answered `nil` for, so a missing picture is asked for once rather
    /// than on every scene rebuild.
    private var missingArtworkDigests: Set<String> = []

    /// The records the current scene was built from.
    ///
    /// Kept because two tools need the *stored geometry*, not the drawn outline: Select
    /// edits a vertex of it (`DocumentCommand.editVertices`) and Cutout resolves which area
    /// it is a hole in. Refreshed on every scene rebuild, which is every markup change.
    var sceneRecords: [MarkupRecord] = [] {
        // A new record set may name new authors (T-004).
        didSet { sceneAuthorsByIDCache = nil }
    }

    /// Compiled shapes reused across scene passes (IM-042).
    private let shapeCache = CanvasShapeCache()

    /// Records compiled into shapes since this canvas opened. IM-042's counter.
    var shapeCompileCountForTesting: Int { shapeCache.compileCount }

    /// Full page layouts run. IM-040's counter.
    private(set) var layoutCountForTesting = 0
    /// Scene fetches from the session. IM-040/IM-041's counter.
    private(set) var sceneFetchCountForTesting = 0

    /// What the last layout was computed from. A pointer move writes the cursor into the
    /// viewport and wakes the observation; only a change in *this* re-lays the page (IM-040).
    private struct LayoutKey: Equatable {
        var zoom: Double
        var pageID: UUID?
        var box: PDFRectValue?
        var rotation: Int
        var viewSize: CGSize
        var backingScale: CGFloat
    }
    private var lastLayoutKey: LayoutKey?

    /// What the last scene fetch was built from. The array comparison takes the identical-
    /// buffer fast path when the presenter has not replaced its list, so an unchanged scene
    /// costs one comparison and no actor hop (IM-041).
    private struct SceneKey: Equatable {
        var pageID: UUID?
        var markups: [MarkupSummary]
        var temporaries: [MarkupSummary]
        var showsCoverage: Bool
        var tintsByAuthor = false
        /// The markup layers, top first (ADR-0036): reordering them restacks the scene although
        /// no markup changed.
        var layerOrder: [LayerID] = []
        /// The markups the ledger filter dims (V-003): a Dim filter changes no visible markup,
        /// and the scene must still redraw.
        var dimmed: Set<UUID> = []
    }
    private var lastSceneKey: SceneKey?

    private var currentLayoutKey: LayoutKey {
        let page = core.document.currentPage
        return LayoutKey(
            // AppKit observes reads made by viewDidLayout. `viewport` also contains the
            // cursor, so reading its zoom made every pointer move invalidate window layout.
            // The geometry lane carries the same zoom without the per-move cursor state.
            zoom: core.canvas.layout.zoom,
            pageID: page?.id,
            // The sheet's view (NL-DOCS-07/16): a turn or a crop re-lays the page.
            box: page?.viewBox,
            rotation: page?.displayRotation ?? 0,
            viewSize: scrollView.contentSize,
            backingScale: view.window?.backingScaleFactor ?? 2
        )
    }

    private var currentSceneKey: SceneKey {
        SceneKey(
            pageID: core.document.currentPageID,
            markups: core.canvas.visibleMarkups,
            temporaries: core.measurement.temporaryMeasurements,
            showsCoverage: core.canvas.showsCoverageMap,
            tintsByAuthor: core.canvas.tintsByAuthor,
            layerOrder: core.snapshot.markupLayers.map(\.id),
            dimmed: core.canvas.dimmedMarkupIDs
        )
    }

    /// The area markups on this page a cutout could belong to.
    private var cutoutCandidates: [CutoutParentCandidate] = []

    /// What the Select tool's drag is doing. `nil` outside a select drag.
    private var selectDrag: SelectDrag?
    /// The vertex handle last clicked (or dragged, or inserted) on the selected markup, which
    /// Delete removes instead of the markup (NL-MEASURE-06,
    /// `PDFCanvasViewController+GeometryEditing.swift`).
    ///
    /// It lives exactly as long as what it points at is what the person sees selected: a Select
    /// click sets it from the handle under the pointer or clears it, and a selection change,
    /// Escape or a tool change clears it (T-001). The page view draws it as a filled handle, so
    /// Delete never acts on a focus nothing shows.
    var focusedVertex: (markupID: UUID, index: Int)? {
        didSet {
            pageView.focusedVertex = focusedVertex.map {
                CanvasPageView.FocusedVertex(markupID: $0.markupID, index: $0.index)
            }
        }
    }

    /// Captions the engine recomputed for the markups being dragged, keyed by markup.
    ///
    /// Measurements recompute live while a selection is dragged. The number is
    /// recomputed by the *measurement engine* on the session — not by any arithmetic in the
    /// canvas — and drawn in the same pill the committed value uses, so the estimator
    /// watches the quantity change as they drag the wall.
    private var liveCaptionOverride: [UUID: String] = [:]
    private var livePreviewTask: Task<Void, Never>?

    /// Whether Shift is held: the 45° straight-line constraint, applied
    /// live to the rubber band and to the committed point.
    var isShiftHeld = false
    /// Whether `⌥` is held. Read by the Area tool's three-point rectangle preview, which is
    /// the affordance that makes `⌥`-click discoverable before it is used.
    private var isOptionHeld = false
    /// Whether `⌘` is held: snapping is toggled for as long as it is (`SNAP_CONTRACT`), which
    /// suspends it when snapping is on.
    /// Every snap resolve the canvas starts carries it — the hover glyph,
    /// a click, an arc's through point and a calibration pick — and so does the input machine.
    private(set) var isCommandHeld = false
    /// The last raw pointer position in page space, kept so pressing or releasing Shift can
    /// re-derive the constrained cursor without waiting for the next pointer move.
    private var lastRawPointerPoint: PDFPointValue?
    /// The ``hoverSnapAnchor`` the latest hover resolve was started with, so a change of anchor
    /// under a still pointer is noticed and re-resolved (W-001; see ``reresolveHoverIfAnchorMoved()``).
    private var handedSnapAnchor: PDFPointValue?
    /// The length or angle being typed for the next segment (NL-MEASURE-18,
    /// `PDFCanvasViewController+TypedEntry.swift`). Empty when nothing is typed.
    var typedEntry = ""
    /// A parsed typed segment is being placed: the scale lookup is in flight (R-013).
    var typedEntryCommitInFlight = false
    /// A Return arrived while the typed vertex was in flight; it finishes the shape after it.
    var finishAfterTypedEntry = false
    /// Fence lines a person drew per page, closing openings for auto-trace (NL-MEASURE-11,
    /// `CanvasTraceFences.swift`). Scaffolding for the session: never saved, cleared on request.
    var traceFences: [UUID: [ProposedClosure]] = [:] {
        didSet { refreshTraceFenceLines() }
    }
    /// The measurement caption being dragged (NL-MEASURE-09, `CanvasCaptionPlacement.swift`).
    var captionDrag: (id: UUID, start: PDFPointValue)?
    /// The precision magnifier's view while it is shown (NL-MEASURE-15, `CanvasLoupe.swift`).
    var loupeHost: NSView?
    /// Where the magnifier's on/off preference is read. Tests inject a scratch suite.
    var loupeDefaults: UserDefaults = .standard
    /// How many snap landings re-rendered the lens's chip (V-007). A test seam.
    var loupeChipRefreshCountForTesting = 0
    /// The Shift angle increment: 45° — horizontal, vertical or diagonal
    /// (this replaces an earlier 15° increment).
    static let shiftAngleIncrementDegrees = MeasurementInputConfiguration.standard.angleIncrementDegrees

    /// How close an `⌥`-click must land, in *screen* points, to un-place a count mark.
    ///
    /// Screen rather than page units so the target stays the same size to the hand at every
    /// zoom; the caller divides by the zoom to reach page space. Eight is the committed
    /// dot's own diameter (`CanvasPageView.drawLiveMeasurement`), so the affordance is the
    /// mark the user can see and no larger.
    static let countRemovalToleranceScreenPoints: Double = 8

    /// Set while `Calibrate Scale…` is collecting its two reference points.
    private var calibrationPoints: [PDFPointValue] = []

    /// The calibration clicks collected so far. BH-343's test seam.
    var calibrationPointsForTesting: [PDFPointValue] { calibrationPoints }
    /// The in-flight snap resolve for a calibration click, chained so two fast clicks stay in
    /// order. See ``placeCalibrationPoint(at:)``.
    private var calibrationPlacementTask: Task<Void, Never>?
    /// Set when a new page is laid out, so the sheet is brought to the middle of the window once
    /// and then left where the reader puts it. See the pannable-margin note in `layoutPage()`.
    private var needsInitialCentring = true
    private var calibrationPlacementGeneration = 0
    /// Raised with the two page-space points once calibration has both of them.
    public var onCalibrationPointsCollected: (@MainActor ([PDFPointValue]) -> Void)?
    /// Raised the moment a calibration click lands, with its index (0 for the first point),
    /// before its snap resolves — while the viewport still has the zoom it was clicked at. A
    /// borrowed pick that judges its click in view points reads the zoom here (S-007).
    var onCalibrationClick: (@MainActor (_ index: Int) -> Void)?
    /// Raised whenever calibration ends, so the window can move the toolbar's selection
    /// ring back with the armed tool, so the ring never outlives the flow.
    /// `true` when calibration ended with its two points collected, `false` when it was
    /// abandoned (Escape). A destination chosen before the flow — a Scale Region's — is
    /// kept for the first and dropped for the second (CR-149).
    public var onCalibrationEnd: (@MainActor (_ collected: Bool) -> Void)?
    /// Raised when a canvas key needs a shell command run.
    public var onShellCommand: (@MainActor (ZPDFCommandID) -> Void)?
    /// Raised with a page-space rectangle once a snippet region has been dragged (ADR-0006 §1,
    /// the `.rect` region). The window controller renders and copies; the canvas only measures.
    public var onSnippetRegion: (@MainActor (PDFRectValue) -> Void)?

    /// Raised when region capture ends without a rectangle (Escape), so the caller can
    /// clear its status note.
    public var onSnippetRegionCancelled: (@MainActor () -> Void)?
    /// Decides what dropping drawings on the canvas will do. Wired by the window controller.
    public var dropBehaviorProvider: (@MainActor (_ optionHeld: Bool) -> CanvasDropBehavior)? {
        didSet { scrollView.dropBehaviorProvider = dropBehaviorProvider }
    }
    /// Performs a canvas drop. Wired by the window controller.
    public var onDropFiles: (@MainActor (_ urls: [URL], _ behavior: CanvasDropBehavior) -> Bool)? {
        didSet { scrollView.onDropFiles = onDropFiles }
    }
    /// r2-markup (NL-UX-15): a drop behaviour decided by what is dropped.
    var contentDropBehavior: (@MainActor (_ urls: [URL], _ optionHeld: Bool) -> CanvasDropBehavior?)? {
        get { scrollView.contentDropBehavior }
        set { scrollView.contentDropBehavior = newValue }
    }
    /// The page point the last drop landed on, or `nil`.
    var lastDropPagePoint: PDFPointValue? {
        guard let location = scrollView.lastDropLocationInWindow, let transform = pageView.transform else { return nil }
        return transform.pagePoint(from: pageView.convert(location, from: nil))
    }

    /// Whether the next two clicks are calibration reference points.
    public private(set) var isCalibrating = false

    /// Whether the next drag frames a snippet region rather than driving the armed tool.
    public private(set) var isCapturingSnippetRegion = false

    /// The toolbar selection this canvas has already applied to the presenters.
    ///
    /// Reconciling on *change* rather than on every refresh is what lets a caller arm a
    /// presenter directly — a test, or a Tool Library preset — without the next layout pass
    /// disarming it again.
    private var appliedSelection: ZenitToolSelection?

    /// The text box being typed into, or `nil`.
    public internal(set) var activeTextEntry: TextEntry?
    var textEditor: CanvasTextEditor?
    /// Round-2 markup state (in-place editing, the ⌘ modifier seam), in
    /// `Markup/PDFCanvasViewController+MarkupRound2.swift`.
    var markupRound2 = MarkupRound2CanvasState()

    /// What the Select tool's press-drag-release is doing.
    ///
    /// Decided once, at the press, from what is under the pointer — a vertex handle of a
    /// selected markup, a markup body, or empty page — and never re-decided mid-drag, so a
    /// move cannot turn into a marquee because the pointer left the shape.
    struct SelectDrag: Equatable, Sendable {

        /// The three things a drag on the pointer tool can mean.
        enum Mode: Equatable, Sendable {
            /// Rubber-band selection over empty page.
            case marquee
            /// Translate these markups.
            case move(ids: [UUID])
            /// Move one vertex of one markup, by its index in `MarkupVertexEditing`'s order.
            case vertex(markupID: UUID, index: Int)
            /// Turn one placed stamp about its own anchor.
            ///
            /// The rotation is not derived from `dx`/`dy` like the other two: a turn is an
            /// **angle**, and reading it off a translation is how a stamp ends up spinning
            /// faster the further the pointer is from the box.
            case rotateStamp(markupID: UUID)
            /// Turn a text box or shape about its box centre (NL-MARKUP-18, ADR-0029).
            case rotateMarkup(markupID: UUID)
        }

        var mode: Mode
        var origin: PDFPointValue
        var current: PDFPointValue
        /// A vertex drag's vertex where it stood before the press, which the drag never snaps
        /// back onto: the markup's own old corner is a snap target in the index (V-001).
        var vertexOrigin: PDFPointValue? = nil
        /// The vertex next to the dragged one, which the drag's snap measures perpendiculars and
        /// angles from, as a measurement measures them from its last placed point (V-001).
        var vertexAnchor: PDFPointValue? = nil

        var dx: Double { current.x - origin.x }
        var dy: Double { current.y - origin.y }

        /// The marquee, normalised.
        var rect: PDFRectValue {
            PDFRectValue(
                x: Swift.min(origin.x, current.x),
                y: Swift.min(origin.y, current.y),
                width: abs(current.x - origin.x),
                height: abs(current.y - origin.y)
            )
        }
    }

    /// A Text or Callout box with the caret in it.
    public struct TextEntry: Equatable, Sendable {
        /// Which markup the typed string will become.
        public var kind: ZPDFUIPresentation.MarkupKind
        /// Where the box is, in page space.
        public var box: PDFRectValue
        /// A callout's target point, or `nil` for plain text.
        public var target: PDFPointValue?
        /// The committed markup being edited in place, or `nil` for a new one (NL-MARKUP-08).
        public var editing: UUID? = nil
        /// How much larger than the tool's text size, in page points, a new box's words are
        /// stored, so they read at the tool's size at the zoom they were typed at (L-49). `1` at
        /// 100 % and closer; an in-place edit keeps its markup's own size.
        public var textScale: Double = 1
    }

    /// The raster source a page's picture comes from (NL-DOCS-04).
    func rasterSource(for page: ZPDFUIPresentation.PageDescriptor) -> PageRasterSource? {
        guard let drawingSet, rasterSource != nil else { return rasterSource }
        return drawingSet.rasterSource(forPage: page.id)
    }

    /// The number the raster caches key a page's picture by: its PDF index on a single drawing,
    /// and an index unique across the set otherwise, so page 1 of one drawing never shows page 1
    /// of another (NL-DOCS-04).
    func rasterKey(of page: ZPDFUIPresentation.PageDescriptor) -> Int {
        drawingSet?.rasterKey(forPage: page.id, index: page.index) ?? page.index
    }

    /// ``rasterKey(of:)`` for a contract page.
    func rasterKey(ofPage page: ZPDFContracts.PageDescriptor) -> Int {
        drawingSet?.rasterKey(forPage: page.id.rawValue, index: page.index) ?? page.index
    }

    /// The raster key of the page on screen.
    var currentRasterKey: Int? { core.document.currentPage.map(rasterKey(of:)) }

    public init(core: AppCoreEnvironment, rasterSource: PageRasterSource?, toolbar: ZenitToolbarModel) {
        self.core = core
        self.rasterSource = rasterSource
        self.toolbar = toolbar
        // The toolbar's opening selection is already in force: the window opens in Select
        // with nothing armed. Seeding it means the first layout pass reconciles nothing,
        // so a caller that armed a presenter directly — a Tool Library preset, a test —
        // is not disarmed by a refresh it did not ask for.
        self.appliedSelection = toolbar.activeSelection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // MARK: - View

    public override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ZPDFColor.nsColor(.canvasBackdrop)
        scrollView.allowsMagnification = false
        scrollView.documentView = documentView
        pageView.onWillBeginInteraction = { [weak self] in
            self?.commitLiveZoomIfNeeded()
            self?.applyArmedTool()
        }
        scrollView.onZoomGesture = { [weak self] factor, windowPoint, phase in
            self?.gestureZoom(by: factor, aboutWindowPoint: windowPoint, phase: phase)
        }
        frameClock.onFrame = { [weak self] in self?.applyLiveZoomFrame() }
        levelQueue.render = { [weak self] plan in
            guard let self, let page = self.core.document.currentPage, let rasterSource = self.rasterSource(for: page) else {
                return nil
            }
            return await self.rasterRenderer(page: page, rasterSource: rasterSource)(plan)
        }
        levelQueue.deliver = { [weak self] job, raster in self?.deliverLevelTile(job, raster) }
        CanvasMemoryPressure.install()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(memoryPressureDidChange(_:)),
            name: CanvasMemoryPressure.notification,
            object: nil
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        view = scrollView

        pageView.onClick = { [weak self] point, additive, optionHeld in
            self?.handleClick(at: point, additive: additive, optionHeld: optionHeld)
        }
        pageView.onDoubleClick = { [weak self] point in self?.handleDoubleClick(at: point) }
        pageView.onPointerMove = { [weak self] point in self?.handlePointerMove(point) }
        pageView.onKey = { [weak self] key in self?.handle(key: key) ?? false }
        pageView.onPanBy = { [weak self] delta in self?.scroll(by: delta) }
        pageView.onDragBegan = { [weak self] point in self?.handleDragBegan(at: point) }
        pageView.onDragMoved = { [weak self] point in self?.handleDragMoved(to: point) }
        pageView.onDragEnded = { [weak self] point in self?.handleDragEnded(at: point) }
        pageView.onDragCancelled = { [weak self] in self?.cancelSelectDrag() }
        pageView.onModifiersChanged = { [weak self] shiftHeld, optionHeld, commandHeld in
            self?.handleModifiers(shiftHeld: shiftHeld, optionHeld: optionHeld, commandHeld: commandHeld)
        }
        pageView.onSecondaryClick = { [weak self] _ in self?.handleSecondaryClick() ?? false }
        // nl-markup: the context menu and its selection rule (Markup/PDFCanvasViewController+ContextMenu.swift).
        pageView.onContextMenu = { [weak self] point in self?.markupContextMenu(at: point) }
        pageView.onSecondarySelect = { [weak self] point in self?.selectForContextMenu(at: point) }

        // ⌘[ and ⌘] go back and forward through the jumps (NL-DOCS-09).
        scrollView.onKeyEquivalent = { [weak self] event in self?.handleNavigationKey(event) ?? false }
        scrollView.onTurnPage = { [weak self] forward in
            self?.turnPage(forward: forward) ?? false
        }
        pageView.onPageTurn = { [weak self] turn in
            guard let self else { return }
            switch turn {
            case .next: _ = self.turnPage(forward: true)
            case .previous: _ = self.turnPage(forward: false)
            case .first: self.core.document.goToFirstPage(); self.restScroll(atTop: true)
            case .last: self.core.document.goToLastPage(); self.restScroll(atTop: true)
            }
        }
        pageView.onZoomMarquee = { [weak self] pageRect in self?.zoom(toPageRect: pageRect) }
        pageView.onZoomClick = { [weak self] windowPoint, zoomOut in
            // The zoom tool's click steps the zoom about the click, ⌥ inverts to out.
            self?.zoom(by: zoomOut ? 1 / 1.6 : 1.6, aboutWindowPoint: windowPoint)
        }
        pageView.onRegionCaptured = { [weak self] pageRect in
            guard let self else { return }
            self.endSnippetRegion()
            self.onSnippetRegion?(pageRect)
        }
        scrollView.enableFileDrops()

        // Selector-based, so the registration dies with the controller: the block form was
        // never removed, and one entry per canvas outlived every closed tab (CR-163).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        // A window layout pass runs for reasons that have nothing to do with the canvas — a
        // status-bar label changing width on every pointer move among them — and each one used
        // to re-lay the whole page (IM-040). Only a change in what the layout is computed from
        // re-lays it now.
        if core.canvas.viewSize != scrollView.contentSize {
            core.canvas.viewSize = scrollView.contentSize
        }
        if currentLayoutKey != lastLayoutKey { layoutPage() }
    }

    /// Whether the first appearance has fitted the page. Keyed on this rather than on
    /// `zoom == 1`: returning to a tab at exactly 100 % used to snap it back to fit (CR-160).
    private var hasFittedInitially = false

    public override func viewDidAppear() {
        super.viewDidAppear()
        core.canvas.viewSize = scrollView.contentSize
        let isFirstAppearance = !hasFittedInitially
        if !hasFittedInitially {
            hasFittedInitially = true
            core.canvas.zoomToFit()
        }
        observe()
        refresh()
        // The first appearance puts the keyboard on the canvas: it is the window's initial
        // focus, and AppKit would otherwise hand the keyboard to the first text field in the
        // key-view loop. A later appearance — the window coming back on screen or to the front,
        // a tab shown again, a Split closing — happens without a click, and must not take the
        // keyboard from a field the person is typing in: the Return that submits the canvas
        // bar's search then reached the canvas and finished the armed Count tool (L-17).
        if isFirstAppearance {
            view.window?.makeFirstResponder(pageView)
        } else {
            focusCanvasUnlessEditingText()
        }
    }

    /// Makes the canvas first responder unless text is being edited in its window — a field's
    /// editor, a text view, the canvas's own markup text editor (L-17). Returns whether the
    /// canvas holds the keyboard afterwards.
    @discardableResult
    func focusCanvasUnlessEditingText() -> Bool {
        guard let window = view.window else { return false }
        if window.firstResponder is NSText { return false }
        return window.makeFirstResponder(pageView)
    }

    /// A canvas that leaves the screen — a background tab, a closed Split — gives its raster
    /// back: tens of megabytes of tiles per open drawing otherwise stay resident for pages
    /// nobody can see (IM-241). Coming back re-renders the viewport, which is one render.
    public override func viewDidDisappear() {
        super.viewDidDisappear()
        commitLiveZoomIfNeeded()
        // Off screen the kept display link goes too; the next gesture on screen makes one.
        frameClock.invalidate()
        releaseRasters()
    }

    deinit {
        // The run loop holds the kept display link, and the link holds the clock; neither holds
        // this canvas, but the link must still leave the run loop (K-14).
        let clock = frameClock
        Task { @MainActor in clock.invalidate() }
    }

    /// Drops every bitmap the canvas holds for its page. Internal for IM-241's test.
    func releaseRasters() {
        rasterTask?.cancel()
        underlayTask?.cancel()
        thumbnailTask?.cancel()
        levelQueue.stop()
        tileCache.removeAll()
        pageView.tileRasters = []
        pageView.staleTileRasters = []
        pageView.levelTileRasters = []
        pageView.pageRaster = nil
        pageView.underlayRaster = nil
        pageView.baseRaster = nil
        baseRasters.removeAll()
        deliveredTiles = []
        currentTileKeys = []
        deliveredPlan = nil
        pendingPlan = nil
        renderedPageIndex = -1
    }

    @objc private func contentBoundsDidChange(_ note: Notification) {
        // A scroll posts a bounds change per event; the visible rect, the status refresh and
        // the raster planning run once per run-loop turn instead (IM-169).
        guard !visibleRectReportScheduled else { return }
        visibleRectReportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibleRectReportScheduled else { return }
            self.visibleRectReportScheduled = false
            self.reportVisibleRect()
        }
    }

    /// Whether a coalesced visible-rect report is waiting for the next turn.
    private var visibleRectReportScheduled = false
    /// How many visible-rect reports ran. IM-169's counter.
    private(set) var visibleRectReportCountForTesting = 0
    /// How many viewport changes re-ran the pointer path for a still pointer (W-002).
    private(set) var pointerReaimCountForTesting = 0

    // MARK: - Standard editing selectors (CR-158)
    //
    // Edit ▸ Select All and Delete Selection are built on the standard `selectAll:` and
    // `delete:` selectors with a nil target; nothing on the canvas's responder chain
    // implemented them, so both rows were permanently disabled. The page view's next
    // responder is this controller, and the commands go where the shell would send them.

    public override func selectAll(_ sender: Any?) {
        onShellCommand?(.selectAll)
    }

    @objc public func delete(_ sender: Any?) {
        // A focused vertex is what Delete removes, not the whole markup (NL-MEASURE-06).
        if removeFocusedVertex() { return }
        onShellCommand?(.deleteSelection)
    }

    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // nl-markup: Cut, Copy and Paste of markups (Markup/PDFCanvasViewController+Clipboard.swift).
        if let verdict = validateMarkupClipboardItem(item) { return verdict }
        if item.action == #selector(delete(_:)) {
            return !core.canvas.selectedMarkupIDs.isEmpty
        }
        if item.action == #selector(selectAll(_:)) {
            return !core.canvas.visibleMarkups.isEmpty
        }
        return true
    }

    // MARK: - Observation

    /// Re-renders whenever anything the canvas draws changes.
    ///
    /// `withObservationTracking` fires once and then has to be re-armed, which is why the
    /// continuation re-registers. Reading each property inside the `apply` block is what registers
    /// the dependency; the reads are not dead code.
    /// The generation of the observation chain that may re-arm itself.
    ///
    /// Every `observe()` starts a new chain and retires the old one. Before this token each
    /// `viewDidAppear` — every return to a tab — added one more permanent chain, and every
    /// pointer-rate change then ran N+1 refreshes for the rest of the session (CR-148).
    private var observationGeneration = 0

    private func observe() {
        observationGeneration &+= 1
        armObservation(generation: observationGeneration)
    }

    private func armObservation(generation: Int) {
        withObservationTracking {
            _ = core.canvas.viewport
            _ = core.canvas.visibleMarkups
            _ = core.canvas.selectedMarkupIDs
            _ = core.canvas.snapFeedback
            // The ledger filter's Dim set (V-003); Hide already moves `visibleMarkups`.
            _ = core.canvas.dimmedMarkupIDs
            // The coverage toggle redraws the page it is flipped on.
            _ = core.canvas.showsCoverageMap
            // Zone and region outlines and calibration picks (U-086): an eye toggle in a panel
            // changes no markup, and the outline must still appear or go.
            _ = core.canvas.boundaryMarks
            _ = core.measurement.placedPoints
            _ = core.measurement.activeKind
            _ = core.measurement.liveFields
            _ = core.measurement.liveCursorPoint
            // The arc in progress (NL-MEASURE-05): the pill's "Arc …" comes from its own preview
            // task, and the overlay draws the placed arcs and the through point. Unobserved, the
            // pill refreshed only when the main preview happened to land after the arc's.
            _ = core.measurement.liveArcSegmentField
            _ = core.measurement.isArcNextSegment
            _ = core.measurement.arcThroughPoint
            _ = core.measurement.placedArcBulges
            // The tape overlay is drawn from this list, so the canvas must wake when it moves —
            // committing a tape, promoting the batch, or Clear. Drawing unobserved state is how
            // Clear emptied the records while the screen kept the tape (TapeMeasureTests).
            _ = core.measurement.temporaryMeasurements
            _ = core.document.currentPageID
            _ = core.markup.activeKind
            _ = core.markup.placedPoints
            _ = core.markup.liveCursorPoint
            // The seam: the canvas observes the *selection*, not just which chip lit up,
            // so a style or parameter change reaches the tool as surely as a tool change
            // does. Observing only the lit chip is how style changes once missed the tool.
            _ = toolbar.activeSelection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.refreshFromObservation()
                self.armObservation(generation: generation)
            }
        }
    }

    /// An observed change, split into three lanes (IM-040).
    ///
    /// One observation block watches everything the canvas draws, and every change used to
    /// run the whole of ``refresh()``: a full layout (frame, transform, visible-rect report,
    /// raster planning) and a full scene rebuild (an actor hop for every record plus a
    /// complete scene build). A pointer move writes the cursor into the viewport and then the
    /// snap feedback, so each move cost two layouts and two rebuilds. Now the live lane always
    /// runs — it only assigns the live properties, which invalidate the overlay — and layout
    /// and scene run only when what they are computed from changed.
    func refreshFromObservation() {
        refreshCountForTesting &+= 1
        applyArmedSelection()
        if currentLayoutKey != lastLayoutKey { pageView.performRasterBatch { layoutPage() } }
        refreshLiveFeedback()
        if currentSceneKey != lastSceneKey { rebuildScene() }
    }

    // MARK: - The armed tool (the seam)

    /// What is armed *right now*, as one value.
    ///
    /// Derived from the presenters first and the toolbar second, so this answer is what the
    /// canvas will actually do rather than what the chip claims. A toolbar mode whose
    /// presenter is not armed — a markup family the product cannot draw yet — reads as
    /// Select here, and the status bar's note says why (`ZenitToolMode.limitationNote`).
    public var armedMode: ZenitToolMode {
        if isCalibrating { return .calibrate }
        if let kind = core.markup.activeKind { return .markup(kind) }
        if let kind = core.measurement.activeKind { return .measure(kind) }
        switch toolbar.activeSelection.mode {
        case .measure, .markup: return .select
        case let mode: return mode
        }
    }

    /// How the armed tool collects input.
    public var armedGesture: ZenitToolGesture { armedMode.gesture }

    /// The name the status bar shows for the tool the *user* armed — which is the chip's
    /// tool even when the canvas cannot draw it yet.
    public var armedToolName: String { toolbar.activeSelection.mode.displayName }

    /// Applies a toolbar selection to the presenters, once per change.
    ///
    /// This is the whole of the fix for styles and tools that never reached the canvas: exactly one place
    /// turns "which chip is lit" into "what the canvas collects", and it is total over
    /// `ZenitToolMode`, so a tool cannot be added without deciding what it arms.
    func applyArmedSelection() {
        let selection = toolbar.activeSelection
        guard selection != appliedSelection else { return }
        let previous = appliedSelection
        appliedSelection = selection
        // Switching tools abandons a half-drawn polygon and a select drag the pointer never
        // released. A text box being typed is **committed** instead, as clicking away and Escape
        // commit it: a toolbar chip takes no first responder, so the editor never resigned, and
        // the switch threw the typed words away with no warning (L-10). Empty text
        // still discards the box. The commit keeps the tool the person just chose.
        //
        // A *style* change is not a tool switch: the toolbar re-arms the same tool with a new
        // stroke, fill or text size (`ZenitToolbarModel.setStyle`), and that restyles what is
        // being drawn — the text box being typed takes the new size — rather than throwing it
        // away.
        let toolChanged = previous?.mode != selection.mode
            || previous?.variant != selection.variant
            || previous?.presetID != selection.presetID
            || previous?.countSymbolName != selection.countSymbolName
        if toolChanged {
            if activeTextEntry != nil { commitTextEntry(keepingTool: true) }
            selectDrag = nil
            liveCaptionOverride = [:]
            // A vertex focused under another tool is not what Delete means under this one (T-001).
            focusedVertex = nil
        }
        defer { if !toolChanged, activeTextEntry != nil { layoutTextEditor() } }
        switch selection.mode {
        case .select, .pan, .zoom, .calibrate:
            core.markup.deactivate()
            core.measurement.deactivate()
        case .measure(let kind):
            core.markup.deactivate()
            if core.measurement.activeKind != kind { core.measurement.activate(kind: kind) }
        case .markup(let kind):
            core.measurement.deactivate()
            guard ZenitToolMode.isDrawable(kind) else {
                // Honest refusal: the chip is lit, the status bar says the tool cannot
                // draw yet, and the canvas collects nothing rather than something else.
                core.markup.deactivate()
                return
            }
            core.markup.activate(kind: kind, style: styleForOpenTextEntry(selection.style), variant: selection.variant)
        }
    }

    /// The tool's style with a new text box's creation scale applied (L-49): a size picked in
    /// the strip while the box is typed is still read at this zoom.
    func styleForOpenTextEntry(_ style: ToolStyleSelection) -> ToolStyleSelection {
        guard let entry = activeTextEntry, entry.editing == nil, entry.textScale != 1 else { return style }
        var scaled = style
        scaled.fontSize = style.fontSize * entry.textScale
        return scaled
    }

    /// How much larger than the tool's text size, in page points, a box typed at `zoom` is stored
    /// (L-49). Text and callout sizes are page points, so 11 pt typed on a 2.7 m sheet shown at
    /// 9 % committed as a sub-pixel speck while the editor showed readable words: the box read
    /// as lost. Zoomed out, the size grows by the zoom so the words commit at the size the tool
    /// names on screen; at 100 % and closer the page size is the tool's size, unchanged.
    nonisolated static func textCreationScale(zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0, zoom < 1 else { return 1 }
        return 1 / zoom
    }

    /// Puts the armed markup tool back on the toolbar's own style once a scaled text box is
    /// committed or discarded (L-49), so the next box at another zoom starts from the tool's size.
    func restoreMarkupStyleAfterTextEntry(scale: Double) {
        guard scale != 1, let kind = core.markup.activeKind else { return }
        let selection = toolbar.activeSelection
        guard case .markup(let armed) = selection.mode, armed == kind else { return }
        core.markup.activate(kind: kind, style: selection.style, variant: selection.variant)
    }

    /// Applies the toolbar's tool to the presenters **and** to the page view's routing flags, in
    /// one step (L-36b). The window applies a toolbar change to the presenters synchronously
    /// (`wireNextLevelMarkup`), but the flags the page view routes a press by — Select, Zoom,
    /// Pan, press-drag — were set only by the live lane, one observation hop later. A press in
    /// between was routed by the previous tool: the first click with the Zoom tool just chosen
    /// was a Select click and zoomed nothing. Run before every press and key, and by the
    /// window on every tool change; the live lane compares before it assigns, so a call that
    /// changes nothing costs nothing.
    func applyArmedTool() {
        applyArmedSelection()
        guard isViewLoaded else { return }
        refreshLiveFeedback()
    }

    /// Pushes the current presenter state onto the view.
    public func refresh() {
        refreshCountForTesting &+= 1
        commitLiveZoomIfNeeded()
        applyArmedSelection()
        pageView.performRasterBatch { layoutPage() }
        refreshLiveFeedback()
        rebuildScene()
    }

    /// The live lane: the pointer-rate state the overlay draws, plus the tool flags and the
    /// selection. Cheap by construction — every assignment is compared before it invalidates.
    func refreshLiveFeedback() {
        let mode = armedMode
        let gesture = mode.gesture
        // The placement may have moved the hover's snap anchor under a still pointer (W-001).
        reresolveHoverIfAnchorMoved()
        dropStaleVertexFocus()
        dropStaleTypedEntry()
        pageView.selection = core.canvas.selectedMarkupIDs
        // U-086: the marks the snap boundary layer is fed from. The presenter replaces the
        // array only on a change, so the comparison is the identical-buffer fast path.
        pageView.boundaryMarks = core.canvas.boundaryMarks
        pageView.isSelectionTool = !gesture.collectsPoints
        pageView.isZoomTool = mode == .zoom
        pageView.isPanTool = mode == .pan
        pageView.cursorKind = resolveCursorKind(tool: mode, gesture: gesture)
        pageView.usesDragGesture = gesture.usesDragGesture
        updateGestureHint(mode: mode, gesture: gesture)
        pageView.dragToolPlacesClicks = gesture.dragAlsoPlacesClicks
        // The whole live overlay in one assignment: one equality check per group and one
        // dirty rectangle, instead of a repaint decision per property (IM-163).
        pageView.live = liveState(mode: mode, gesture: gesture)
        layoutTextEditor()
        // The magnifier leaves with its tool and names the snap that landed (V-006, V-007).
        refreshLoupeInLiveLane()
    }

    /// The live overlay's state for the armed tool, built in one place.
    ///
    /// The calibration cursor is the one field not derived here: the pointer handler sets it
    /// between refreshes, so it is carried over from what the view already holds.
    func liveState(mode: ZenitToolMode, gesture: ZenitToolGesture) -> CanvasLiveState {
        let isMarkup = mode.markupKind != nil
        var state = CanvasLiveState()
        state.drawing = CanvasLiveState.Drawing(
            points: isMarkup ? core.markup.placedPoints : core.measurement.placedPoints,
            // Arc segments while drawing (NL-MEASURE-05): the arcs placed so far and the through
            // point of the one in progress, so the overlay draws curves where the ledger will.
            bulges: isMarkup ? [] : liveArcBulges(),
            arcThroughPoint: isMarkup ? nil : core.measurement.arcThroughPoint,
            closesOutline: gesture.closesOutline,
            caption: liveCaptionText(),
            cursorPoint: gesture.collectsPoints
                ? (isMarkup ? core.markup.liveCursorPoint : core.measurement.liveCursorPoint)
                : nil,
            firstVertexCloseTarget: firstVertexCloseTarget(),
            dragAnchor: isMarkup ? nil : measurementDragAnchor,
            inferredQuad: liveInferredQuad(),
            isPointPlacement: gesture.isPointPlacement,
            markupKind: mode.markupKind,
            keyboardCursor: drawnKeyboardCursor
        )
        state.pointer = CanvasLiveState.Pointer(
            snapPoint: displayedSnapPoint(),
            selectionMarquee: selectDrag.flatMap { $0.mode == .marquee ? $0.rect : nil }
        )
        state.calibration = CanvasLiveState.Calibration(
            points: calibrationPoints,
            cursor: pageView.live.calibration.cursor
        )
        return state
    }

    /// The live state the canvas would assign right now. IM-163's test seam.
    func liveStateForTesting() -> CanvasLiveState {
        let mode = armedMode
        return liveState(mode: mode, gesture: mode.gesture)
    }

    /// What the view is drawing live right now. IM-163's test seam.
    var pageViewLiveStateForTesting: CanvasLiveState { pageView.live }

    /// The verb the pointer must wear, resolved from the armed tool **and** the armed set's
    /// mode.
    ///
    /// `CanvasCursorKind.resolve` is total over the tool and the mode, and this is the one place
    /// the canvas asks it. The single clause that is not `resolve`'s to know is the honest
    /// refusal: `ZenitToolMode.isDrawable` lets a markup family be armed that the canvas cannot
    /// yet collect points for, and a crosshair over a tool that draws nothing would promise a
    /// click that does not happen. That case keeps the Select pointer, exactly as it did before
    /// this method existed.
    func resolveCursorKind(tool: ZenitToolMode, gesture: ZenitToolGesture) -> CanvasCursorKind {
        let kind = core.toolLibrary.canvasCursorKind(tool: tool)
        if kind == .draw, !gesture.collectsPoints { return .select }
        return kind
    }

    /// The live caption: the running value, plus the exact constrained angle while Shift
    /// holds the segment straight — 0.0° / 45.0° / 90.0°, never 44.9°.
    private func liveCaptionText() -> String? {
        // NL-MEASURE-18: while a length is typed, the pill echoes it.
        if let echo = typedEntryEcho { return echo }
        var value = core.measurement.livePrimaryField?.displayTextWithUnit
        // NL-MEASURE-05: while an arc segment follows the pointer, the pill says the arc's own
        // length beside the running value (a Length's value already is the arc).
        if let arc = liveArcCaption() { value = value.map { "\($0)  \(arc)" } ?? arc }
        guard let degrees = constrainedAngleDegrees() else { return value }
        let angle = String(format: "%.1f°", degrees)
        guard let value else { return angle }
        return "\(value)  \(angle)"
    }

    /// The exact constrained direction while Shift is held over a segment tool, or `nil`.
    private func constrainedAngleDegrees() -> Double? {
        guard isShiftHeld, let raw = leadingRawPoint else { return nil }
        // One rule, in the package (U-073): no rose angle for a count mark or on a
        // rectangle's depth point — the ⌥ rectangle of Area included — which is held
        // perpendicular.
        return MeasurementInputStateMachine.constraintIndicatorDegrees(
            kind: core.measurement.activeKind,
            placedPoints: core.measurement.placedPoints,
            cursor: raw,
            optionHeld: isOptionHeld,
            incrementDegrees: measurementInputConfiguration.angleIncrementDegrees
        )
    }

    /// What Shift makes of `cursor` and of `snap` for the measurement being drawn, or `nil`
    /// while Shift is up or holds nothing (no tool, a count mark, nothing placed).
    ///
    /// The package's one Shift rule (U-073), asked with the machine's own increment and ray
    /// tolerance, so the rubber band, the snap glyph and the point a click places cannot
    /// disagree about the ray — or, on a rectangle's depth step, about the perpendicular.
    private func shiftPlacement(cursor: PDFPointValue, snap: PDFPointValue?) -> ShiftConstrainedPlacement? {
        guard isShiftHeld else { return nil }
        let configuration = measurementInputConfiguration
        return MeasurementInputStateMachine.shiftConstrainedPlacement(
            kind: core.measurement.activeKind,
            placedPoints: core.measurement.placedPoints,
            cursor: cursor,
            snap: snap,
            optionHeld: isOptionHeld,
            incrementDegrees: configuration.angleIncrementDegrees,
            rayTolerance: configuration.constrainedRayTolerance
        )
    }

    /// The snap glyph the canvas draws: where the click would land on the candidate. While
    /// Shift constrains the segment it is the candidate as the constraint holds it — its
    /// distance along the rose ray, hidden when it is off the ray and will not be used,
    /// or its projection onto the perpendicular of a rectangle's edge.
    ///
    /// Drawn only where the next click or release takes the snap (V-001): a measurement tool, a
    /// calibration pick (and the picks that borrow it) and a Select vertex drag. The ring used to
    /// be drawn for every tool, so a markup tool — which places the raw pointer by design — and
    /// the Select tool showed a snap they never took, and the ring stayed at a text box's
    /// position after the tool changed (L-12).
    private func displayedSnapPoint() -> PDFPointValue? {
        guard snapRingApplies else { return nil }
        if let drag = selectDrag, case .vertex = drag.mode {
            // The drag's own resolve, which never takes the vertex's old corner (V-001).
            return vertexDragSnap?.point
        }
        guard let snapped = core.canvas.snapFeedback?.pagePoint else { return nil }
        guard let raw = leadingRawPoint, let held = shiftPlacement(cursor: raw, snap: snapped) else {
            return snapped
        }
        return held.snap
    }

    /// Whether the next click or release takes the snap, which is when the ring is drawn.
    var snapRingApplies: Bool {
        if isCalibrating || core.measurement.activeKind != nil { return true }
        if let drag = selectDrag, case .vertex = drag.mode { return true }
        return false
    }

    /// The snap a vertex drag takes from a resolution: the winner, or — when the winner is the
    /// dragged vertex's own old position — the best ranked alternative that is not. The markup's
    /// own vertex is a snap target in the index and, as a markup vertex, outranks a drawing's
    /// corner: taking it pinned the vertex where it was for as long as the pointer stayed inside
    /// the snap radius, and dropping it for the raw pointer lost the corner next to it (V-001).
    /// `nil` when nothing else is in range.
    nonisolated static func vertexDragSnapPoint(
        in resolution: SnapResolution?, excluding origin: PDFPointValue?
    ) -> PDFPointValue? {
        guard let resolution, let winner = resolution.winner else { return nil }
        for candidate in [winner] + resolution.alternatives {
            let point = PDFPointValue(x: candidate.position.x, y: candidate.position.y)
            if let origin, point.distance(to: origin) <= 1e-6 { continue }
            return point
        }
        return nil
    }

    /// The last resolved snap of a vertex drag, with the pointer sample it was resolved for and
    /// the snap radius, so a move that stays inside the radius keeps it until its own resolve
    /// lands (V-001).
    struct VertexDragSnap: Equatable {
        var point: PDFPointValue
        var sample: PDFPointValue
        var tolerance: Double
    }

    /// The inferred quadrilateral of the three-point rectangle, following the cursor with
    /// its running area once the edge is placed.
    private func liveInferredQuad() -> [PDFPointValue]? {
        guard let kind = core.measurement.activeKind else { return nil }
        // Area previews the rectangle only while `⌥` is held, because until then those two
        // vertices are the start of a polygon. Holding `⌥` is therefore how the gesture
        // announces itself: the quadrilateral appears under the cursor before the click
        // that commits it. The package's depth-step rule decides, the one Shift reads.
        let placed = core.measurement.placedPoints
        guard MeasurementInputStateMachine.isRectangleDepthStep(
                  kind: kind, placedPointCount: placed.count, optionHeld: isOptionHeld
              ),
              let cursor = core.measurement.liveCursorPoint
        else { return nil }
        return AppMeasurementToolPresenter.inferredQuadrilateral(
            edgeStart: placed[0],
            edgeEnd: placed[1],
            depth: cursor
        )
    }

    /// The first vertex, when the next click would close the polygon on it
    /// (`MeasurementToolSemantics`). Tolerance is zoom-aware, so
    /// the affordance is a constant screen distance at every zoom.
    ///
    /// The probe composes snap the way the state machine does — the *snapped* point the
    /// click would place, falling back to the raw cursor. This is where closing was broken
    /// in the assembled app: the snap engine, whose tolerance is
    /// wider than this one, pulled the click onto the vector corner under the first vertex
    /// while the raw-cursor distance check missed, so the click stacked a duplicate vertex
    /// instead of closing.
    func firstVertexCloseTarget(probe explicitProbe: PDFPointValue? = nil) -> PDFPointValue? {
        let mode = armedMode
        let gesture = mode.gesture
        guard gesture.closesOnFirstVertex else { return nil }
        let points = mode.markupKind != nil ? core.markup.placedPoints : core.measurement.placedPoints
        guard points.count >= gesture.minimumPointCount, let first = points.first else { return nil }
        // An armed arc's next click is its through point, never a close — the machine's rule
        // (`awaitsArcThroughPoint`). Without it the ring promised a close the click would not
        // make (V-074).
        if mode.markupKind == nil, core.measurement.isArcNextSegment, core.measurement.arcThroughPoint == nil {
            return nil
        }
        let fallback = core.canvas.viewport.cursorPagePoint
        guard let probe = explicitProbe ?? core.canvas.snapFeedback?.pagePoint ?? fallback else { return nil }
        let tolerance = core.canvas.viewport.pageDistance(forViewPoints: 12)
        let dx = probe.x - first.x
        let dy = probe.y - first.y
        guard (dx * dx + dy * dy).squareRoot() <= tolerance else { return nil }
        return first
    }

    private func rebuildScene() {
        lastSceneKey = currentSceneKey
        // The snapshot's markups moved: the hidden set is recomputed on the next scene pass.
        sceneHiddenMarkupIDsCache = nil
        guard let pageID = core.document.currentPageID else {
            pageView.shapes = []
            sceneRecords = []
            cutoutCandidates = []
            return
        }
        let session = core.session
        sceneTask?.cancel()
        sceneGeneration &+= 1
        sceneFetchCountForTesting &+= 1
        sceneTask = Task { @MainActor [weak self] in
            // ADR-0036: the layer list sets the stacking, the markup order applies within a
            // layer; the hit test walks the same order top-down.
            let records = await session.drawOrderedMarkups
            guard !Task.isCancelled, let self else { return }
            // Page-scoped: the scene, the hit test, the vertex editor and the coverage map
            // only ever want this sheet's records (IM-041).
            self.sceneRecords = records.filter { $0.pageID.rawValue == pageID }
            await self.resolveArtwork(for: records)
            guard !Task.isCancelled else { return }
            self.applyScene()
        }
    }

    /// Awaits the in-flight scene rebuild.
    ///
    /// The scene is built from a `Sendable` snapshot fetched off the session actor, so
    /// "the markups are drawn" is one hop behind "the markups exist". A caller that has to
    /// see the drawn scene — the hit test, the cutout's parent list, a test — waits here
    /// rather than guessing at a number of run-loop turns.
    public func settleScene() async {
        while let task = sceneTask {
            let generation = sceneGeneration
            await task.value
            guard sceneGeneration == generation else { continue }
            sceneTask = nil
        }
    }

    /// Fetches any compiled artwork this scene's symbols name and has not seen before.
    ///
    /// Asked once per digest, ever. A digest the store cannot produce is remembered as missing,
    /// so a project whose artwork table was emptied by hand does not re-query it on every
    /// rebuild — it draws the fallback glyph, which is the visible answer.
    private func resolveArtwork(for records: [MarkupRecord]) async {
        guard let onResolveArtwork else { return }
        var wanted: Set<String> = []
        for record in records {
            // **Both** digests. A count mark names artwork through `MarkupRecord.symbol` and a
            // placed stamp names it through `MarkupRecord.stamp` — and only the first of the
            // two was ever asked for, which is why every stamp in the product drew as a box
            // with text in it however much artwork the import had compiled.
            for digest in [record.symbol?.artworkDigest, record.stamp?.artworkDigest] {
                guard let digest else { continue }
                guard resolvedArtwork[digest] == nil, !missingArtworkDigests.contains(digest) else {
                    continue
                }
                wanted.insert(digest)
            }
        }
        for digest in wanted.sorted() {
            if let geometry = await onResolveArtwork(digest) {
                resolvedArtwork[digest] = geometry
            } else {
                missingArtworkDigests.insert(digest)
            }
        }
        await resolveInsertedImages(for: records)
    }

    /// Fetches the pixels of every inserted raster image this scene draws and has not seen
    /// before, and hands them to the page view (ADR-0043, L-81).
    private func resolveInsertedImages(for records: [MarkupRecord]) async {
        guard let onResolveInsertedImage else { return }
        var wanted: Set<String> = []
        for record in records where record.kind == .image && record.symbol?.kind == .raster {
            guard let digest = record.symbol?.artworkDigest,
                  resolvedInsertedImages[digest] == nil, !missingInsertedImageDigests.contains(digest)
            else { continue }
            wanted.insert(digest)
        }
        for digest in wanted.sorted() {
            if let image = await onResolveInsertedImage(digest) {
                resolvedInsertedImages[digest] = image
            } else {
                missingInsertedImageDigests.insert(digest)
            }
        }
        if pageView.insertedImagePixels.count != resolvedInsertedImages.count {
            pageView.insertedImagePixels = resolvedInsertedImages
        }
    }

    /// The markups the scene leaves out — a hidden markup layer (ADR-0032) or the ledger
    /// filter's Hide — computed once per snapshot rebuild or hidden-set change. `applyScene`
    /// runs per pointer event during a Select drag, and rebuilt this from every markup in the
    /// project on each one (R-007). The by-name Navigator hide (CR-112) that also fed it could
    /// not be reached once a window installs the project's layers, and was deleted (X-009).
    private var sceneHiddenMarkupIDsCache: Set<UUID>?
    /// How many times the hidden set was computed. A test seam for R-007.
    private(set) var sceneHiddenComputationCountForTesting = 0

    private var sceneHiddenMarkupIDs: Set<UUID> {
        if let cached = sceneHiddenMarkupIDsCache { return cached }
        sceneHiddenComputationCountForTesting &+= 1
        let computed = layerHiddenMarkupIDs.union(ledgerFilterHiddenMarkupIDs())
        sceneHiddenMarkupIDsCache = computed
        return computed
    }

    /// The markups the ledger filter takes off the sheet under Hide (V-003): the canvas
    /// presenter's `filterHiddenMarkupIDs`, the one rule every snap resolve for this window
    /// excludes too, so nothing is snapped to that is not drawn.
    ///
    /// The presenter narrowed `visibleMarkups` and nothing drew from it — the scene is built from
    /// the session's records — so Hide left the filtered-out ink drawn, hittable and without its
    /// pill. A record the snapshot does not know yet (one hop behind the session) is kept.
    private func ledgerFilterHiddenMarkupIDs() -> Set<UUID> {
        core.canvas.filterHiddenMarkupIDs
    }

    /// Each scene record's author, built once per scene rebuild. A Select drag previews
    /// geometry, never an author, and `applyScene` rebuilt this map on every drag frame (T-004).
    private var sceneAuthorsByIDCache: [UUID: String]?
    /// How many times the author map was built. A test seam for T-004.
    private(set) var sceneAuthorsComputationCountForTesting = 0

    private var sceneAuthorsByID: [UUID: String] {
        if let cached = sceneAuthorsByIDCache { return cached }
        sceneAuthorsComputationCountForTesting &+= 1
        let computed = AuthorTint.authorsByID(sceneRecords)
        sceneAuthorsByIDCache = computed
        return computed
    }

    /// Tint by Author's colour table and what it was assigned from: the project's markups (every
    /// page, so a colour does not change with the sheet shown) and the person's own names.
    /// `applyScene` runs per Select-drag frame with the tint on, and each frame assigned the
    /// table afresh from every markup in the project — a set, a locale-aware sort and two
    /// dictionaries — although no author can change mid-drag (T-004, the R-007 pattern).
    private var authorTintColourCache: (
        markups: [MarkupSummary], aliases: Set<String>, colours: [String: ZenitNamedPalette.Entry]
    )?
    /// How many times the author colours were assigned. A test seam for T-004.
    private(set) var authorTintColourComputationCountForTesting = 0

    private func authorTintColours() -> [String: ZenitNamedPalette.Entry] {
        let markups = core.snapshot.markups
        let aliases = core.review.myNames
        // An unchanged snapshot shares the cached array's storage, so `==` answers without
        // walking it. A new snapshot with the same markups is walked once and then adopted, so
        // the next frame is the cheap case again.
        if var cache = authorTintColourCache, cache.aliases == aliases, cache.markups == markups {
            cache.markups = markups
            authorTintColourCache = cache
            return cache.colours
        }
        authorTintColourComputationCountForTesting &+= 1
        let colours = AuthorColors.assignments(for: markups.map(\.author), aliases: aliases)
        authorTintColourCache = (markups, aliases, colours)
        return colours
    }

    /// Draws the cached records, with the Select tool's drag applied on top.
    ///
    /// Synchronous and pure of the session, so a drag redraws at pointer rate without a hop
    /// through the actor. The *committed* geometry is untouched until the release; this is
    /// the preview, and it is built from the same `CanvasSceneBuilder` the committed shape
    /// will be built from, so what the user drags is what lands.
    private func applyScene() {
        guard let page = core.document.currentPage else { return }
        // ADR-0032: a hidden markup layer is not drawn (and so cannot be hit).
        let hidden = sceneHiddenMarkupIDs
        let shown = hidden.isEmpty ? sceneRecords : sceneRecords.filter { !hidden.contains($0.id.rawValue) }
        let previewed = shown.map(previewing(_:))
        var shapes = CanvasSceneBuilder.build(
            records: previewed,
            summaries: core.canvas.visibleMarkups,
            pageID: page.id,
            captionOverrides: liveCaptionOverride,
            artwork: resolvedArtwork,
            cache: shapeCache,
            segmentLabelling: segmentLabelling(forPage: page.id)   // NL-MEASURE-09
        )
        // NL-COLLAB-06: display-only author colours (Review/AuthorTint.swift), from inputs kept
        // across drag frames (T-004).
        if core.canvas.tintsByAuthor {
            shapes = AuthorTint.apply(to: shapes, authorByID: sceneAuthorsByID, colours: authorTintColours())
        }
        // The ledger filter's Dim (V-003): the markups it left out draw faintly.
        let dimmed = core.canvas.dimmedMarkupIDs
        if !dimmed.isEmpty {
            for index in shapes.indices where dimmed.contains(shapes[index].id) {
                shapes[index].isDimmed = true
            }
        }
        // The tape overlay. Temporary Measures live on the presenter, never in the session, so
        // the committed-record scene above cannot contain them — and until 2026-08-27 nothing
        // drew them at all: the second click landed and the measurement vanished, kept
        // faithfully in a list no view read. Appended last so the tape draws over the work,
        // flagged so it draws as a tape and not as a markup.
        let temporaries = CanvasSceneBuilder.build(
            records: core.measurement.temporaryOverlayRecords,
            summaries: core.measurement.temporaryMeasurements,
            pageID: page.id,
            captionOverrides: [:],
            artwork: [:]
        )
        for var shape in temporaries {
            shape.isTemporary = true
            shapes.append(shape)
        }
        pageView.shapes = shapes
        pageView.coverageOverlay = coverageOverlay(for: page)
        pageView.doubleCountHatch = Self.doubleCountHatch(core.doubleCountRegions[PageID(page.id)] ?? [])
        refreshTraceFenceLines()   // NL-MEASURE-11
        // The cutout parents depend on the committed geometry only, never on a drag preview:
        // rebuilt when the committed set changes, not per drag frame (IM-042).
        if selectDrag == nil || cutoutCandidateSource != sceneRecords.count {
            cutoutCandidateSource = sceneRecords.count
            rebuildCutoutCandidates(previewed, pageID: page.id)
        }
    }

    /// The committed record count the cutout candidates were built from.
    private var cutoutCandidateSource = -1

    // MARK: - Coverage map

    /// The last computed overlay, keyed by what it was computed from. `applyScene` runs at
    /// pointer rate during a drag, and the coverage union is Clipper work — recomputing it
    /// per frame is the class of mistake that once had the canvas refreshing ≈17 000 times a
    /// second. The key is the page, the committed record
    /// count and the newest modification stamp: any add, remove or geometry edit moves one
    /// of the three.
    private var coverageCache: (
        pageID: UUID, count: Int, newest: Date?, overlay: CanvasPageView.CoverageOverlay?
    )?

    /// The records the coverage map unions for one page: visible, polygon-bearing
    /// measurements **on that page**. `sceneRecords` is the whole document, and filtering on
    /// kind alone tinted page 2 with page 1's polygons and counted hidden ones (BH-062).
    static func coverageRecords(_ records: [MarkupRecord], onPage pageID: UUID) -> [MarkupRecord] {
        records.filter { record in
            record.kind == .measurement
                && record.pageID.rawValue == pageID
                && !record.hidden
                && !(record.geometry?.polygons.isEmpty ?? true)
        }
    }

    /// The coverage overlay for one page, or `nil` when the toggle is off.
    ///
    /// Covered regions come from the committed, quantity-producing area measurements on the
    /// page — decoration never tints. A page whose geometry the engine refuses shows the
    /// refusal in the badge rather than an overlay that quietly dropped a region: a dropped
    /// region would read as "unmeasured", which is the exact answer the person is looking for.
    private func coverageOverlay(
        for page: ZPDFUIPresentation.PageDescriptor
    ) -> CanvasPageView.CoverageOverlay? {
        guard core.canvas.showsCoverageMap else {
            coverageCache = nil
            return nil
        }
        let measured = Self.coverageRecords(sceneRecords, onPage: page.id)
        let newest = measured.map(\.modifiedAt).max()
        if let cache = coverageCache,
           cache.pageID == page.id, cache.count == measured.count, cache.newest == newest {
            return cache.overlay
        }

        let polygons = measured.flatMap { $0.geometry?.polygons ?? [] }
        let box = page.cropBox
        let extent = ZPDFContracts.PDFRect(
            x: box.origin.x, y: box.origin.y,
            width: box.size.width, height: box.size.height
        )
        let overlay: CanvasPageView.CoverageOverlay?
        do {
            let result = try CoverageMap().coverage(of: polygons, within: .pageBox(extent))
            var rings: [[PDFPointValue]] = []
            for polygon in result.coveredPolygons {
                rings.append(polygon.outer.points.map { PDFPointValue(x: $0.x, y: $0.y) })
                for hole in polygon.holes {
                    rings.append(hole.points.map { PDFPointValue(x: $0.x, y: $0.y) })
                }
            }
            let formatter = NumberFormatter()
            formatter.numberStyle = .percent
            formatter.maximumFractionDigits = result.coveredFraction < 0.1 ? 1 : 0
            let percent = formatter.string(from: NSNumber(value: result.coveredFraction))
                ?? "\(Int((result.coveredFraction * 100).rounded())) %"
            overlay = CanvasPageView.CoverageOverlay(
                rings: rings,
                label: String(
                    format: NSLocalizedString(
                        "Coverage %@ of page",
                        comment: "Coverage map badge: fraction of the page covered by measurements"
                    ),
                    percent
                )
            )
        } catch {
            overlay = CanvasPageView.CoverageOverlay(
                rings: [],
                label: NSLocalizedString(
                    "Coverage unavailable: a region could not be interpreted",
                    comment: "Coverage map badge when the geometry engine refuses a polygon"
                )
            )
        }
        coverageCache = (page.id, measured.count, newest, overlay)
        return overlay
    }

    /// One record with the in-flight select drag applied, or the record unchanged.
    private func previewing(_ record: MarkupRecord) -> MarkupRecord {
        guard let drag = selectDrag, let geometry = record.geometry else { return record }
        switch drag.mode {
        case .marquee:
            return record
        case let .move(ids):
            guard ids.contains(record.id.rawValue) else { return record }
            var moved = record
            moved.geometry = MarkupVertexEditing.translating(geometry, dx: drag.dx, dy: drag.dy)
            return moved
        case let .vertex(markupID, index):
            guard markupID == record.id.rawValue else { return record }
            guard let edited = MarkupVertexEditing.replacing(
                vertexAt: index,
                with: PDFPoint(shown: drag.current),
                in: geometry
            ) else { return record }
            var moved = record
            moved.geometry = edited
            return moved
        case let .rotateStamp(markupID):
            guard markupID == record.id.rawValue,
                  let rotation = rotation(ofStamp: record, draggedTo: drag.current)
            else { return record }
            var turned = record
            turned.stamp?.rotationDegrees = rotation
            return turned
        case let .rotateMarkup(markupID):
            guard markupID == record.id.rawValue,
                  let rotation = markupRotation(of: record, draggedTo: drag.current)
            else { return record }
            var turned = record
            turned.style.rotationDegrees = rotation == 0 ? nil : rotation
            return turned
        }
    }

    /// The rotation a stamp record would take if its knob were dragged to `point`.
    ///
    /// `nil` when the record is not a stamp with a usable box. Shift snaps to
    /// ``stampRotationSnapDegrees``, the same 15° every drawing tool in this product offers
    /// for an angle — a seal is squared to the sheet far more often than it is set to 37°.
    func rotation(ofStamp record: MarkupRecord, draggedTo point: PDFPointValue) -> Double? {
        guard let placement = CanvasSceneBuilder.placement(of: record) else { return nil }
        let raw = placement.rotation(draggingHandleTo: point)
        return isShiftHeld
            ? CanvasStampPlacement.snapped(raw, increment: Self.stampRotationSnapDegrees)
            : raw
    }

    /// The area markups a cutout could be a hole in, on the page being drawn on.
    ///
    /// Built from the *stored* rings rather than from anything on screen: the parent this
    /// resolves is the record `DocumentCommand.addCutout` will recompute, so the outline the
    /// containment test uses has to be that record's own. A cutout is never offered another
    /// cutout as a parent — a hole in a hole is a separate markup, not a nested boolean
    /// (`PolygonCutoutCalculator`).
    private func rebuildCutoutCandidates(_ records: [MarkupRecord], pageID: UUID) {
        cutoutCandidates = records.compactMap { record in
            guard record.pageID.rawValue == pageID, !record.hidden else { return nil }
            guard record.parentMarkupID == nil else { return nil }
            if let tool = record.tool, tool == .polygonCutout || tool == .ellipseCutout {
                return nil
            }
            guard let ring = record.geometry?.polygons.first?.outer.points, ring.count >= 3 else {
                return nil
            }
            return CutoutParentCandidate(
                markupID: record.id.rawValue,
                outerRing: ring.map { PDFPointValue(x: $0.x, y: $0.y) },
                subject: record.subject,
                label: record.label
            )
        }
    }

    // MARK: - Layout

    private func layoutPage() {
        // A zoom gesture still on the GPU is folded into the layout first: when the zoom in
        // the presenter is still the one the gesture started from, the gesture is committed
        // (a window resize mid-pinch keeps the pinch); when something else set a zoom — the
        // status-bar field, a menu — that zoom wins and the gesture is dropped.
        if liveZoom != nil, !isCommittingLiveZoom {
            if abs(core.canvas.viewport.zoom - lastLayoutZoom) < 1e-12 {
                commitLiveZoom()
                return
            }
            abandonLiveZoom()
        }
        let signpost = CanvasLog.signposter.beginInterval("LayoutPage")
        defer { CanvasLog.signposter.endInterval("LayoutPage", signpost) }
        layoutCountForTesting &+= 1
        let previousKey = lastLayoutKey
        lastLayoutKey = currentLayoutKey
        guard let page = core.document.currentPage else {
            pageView.transform = nil
            documentView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
            return
        }
        let zoom = CGFloat(core.canvas.viewport.zoom)

        // The page-point-under-the-anchor invariant: before the new
        // transform replaces the old one, remember which page point sits under the anchor —
        // the pointer for a gesture, the viewport centre for a menu or status-bar zoom — and
        // put it back under the same window point afterwards. Adjusting the scroll origin
        // *after* the change is what drifts by a pixel per event and slides the page.
        var anchorWindowPoint: NSPoint?
        var anchorPagePoint: PDFPointValue?
        let zoomChanged = lastLayoutZoom > 0 && abs(Double(zoom) - lastLayoutZoom) > 1e-12
        if zoomChanged, let explicit = pendingZoomAnchor {
            // A committed gesture names the page point it was showing under the fingers.
            anchorWindowPoint = explicit.window
            anchorPagePoint = explicit.page
        } else if let oldTransform = pageView.transform, zoomChanged {
            let windowPoint = pendingZoomAnchorWindowPoint ?? viewportCenterWindowPoint()
            if let windowPoint {
                let inPage = pageView.convert(windowPoint, from: nil)
                anchorWindowPoint = windowPoint
                anchorPagePoint = oldTransform.pagePoint(from: inPage)
            }
        }
        pendingZoomAnchorWindowPoint = nil
        pendingZoomAnchor = nil
        // LT3-10: a window resize or a panel toggle changes the viewport, the pan margins and
        // with them where the sheet sits in the document — and the scroll origin used to stay
        // put, so the sheet slid down and right, off centre, with its far edges cut off. The
        // page point that was at the centre of the view stays at the centre instead.
        let viewportChanged = previousKey != nil
            && previousKey?.pageID == page.id
            && previousKey?.viewSize != scrollView.contentSize
        let centreToKeep = (viewportChanged && !zoomChanged) ? lastVisibleCentrePagePoint : nil
        lastLayoutZoom = Double(zoom)
        // The sheet's view (NL-DOCS-07/16): turned and cropped for display; page space, and
        // every measurement in it, is unchanged, and hit testing inverts this same transform.
        let transform = PageDisplayTransform(
            pageBox: page.viewBox,
            rotation: page.displayRotation,
            zoom: zoom,
            origin: CGPoint(x: Self.margin, y: Self.margin)
        )
        // Room to pan **past** the sheet, on every side.
        //
        // A sheet must never feel locked in the middle of the window: Pan has to be able to move
        // it off centre. The content size used to be the larger of the
        // viewport and the sheet plus a 24 pt margin, so a sheet that fitted the window produced
        // a document exactly the size of the window — nothing to scroll, and Pan did nothing.
        // Even zoomed in, the sheet could never be dragged so that its edge sat in the middle of
        // the screen, which is where you want it when you are measuring along that edge.
        //
        // The margin is most of a viewport per side, so any part of the sheet can be brought to
        // any part of the window, and the sheet can be pushed aside to make room for a panel
        // without leaving the page.
        let panMargin = CGSize(
            width: max(Self.margin, scrollView.contentSize.width * Self.panMarginFraction),
            height: max(Self.margin, scrollView.contentSize.height * Self.panMarginFraction)
        )
        let contentSize = CGSize(
            width: transform.pageFrame.width + panMargin.width * 2,
            height: transform.pageFrame.height + panMargin.height * 2
        )
        // Centre the sheet when it is smaller than the viewport, which is what a page smaller than
        // the window should do rather than sitting in the top-left corner.
        let centred = PageDisplayTransform(
            pageBox: transform.pageBox,
            rotation: transform.rotation,
            zoom: zoom,
            origin: CGPoint(
                x: max(Self.margin, (contentSize.width - transform.pageFrame.width) / 2),
                y: max(Self.margin, (contentSize.height - transform.pageFrame.height) / 2)
            )
        )
        documentView.frame = CGRect(origin: .zero, size: contentSize)
        pageView.transform = centred
        pageView.accessibilityPageNumber = core.canvas.viewport.pageIndex + 1
        pageView.accessibilitySheetLabel = core.document.pages.first { $0.id == core.document.currentPageID }?.label

        // The pannable margin means the origin is no longer the top-left of the sheet, so a page
        // that has just been laid out for the first time has to be scrolled to. Only then: any
        // later layout must leave the reader where they were.
        if needsInitialCentring {
            needsInitialCentring = false
            let clip = scrollView.contentView
            pageView.scroll(NSPoint(
                x: max(0, centred.pageFrame.midX - clip.bounds.width / 2),
                y: max(0, centred.pageFrame.midY - clip.bounds.height / 2)
            ))
            scrollView.reflectScrolledClipView(clip)
        }

        if let anchorPagePoint, let anchorWindowPoint {
            let viewAfter = centred.viewPoint(from: anchorPagePoint)
            // Where the anchor sits *inside the visible rectangle*, not where it sits in the
            // clip view's coordinate space.
            //
            // `NSClipView.convert(_:from: nil)` returns a point in the clip view's **bounds**,
            // and a clip view's `bounds.origin` **is** the scroll offset. So the converted point
            // already carries how far the document is scrolled. Subtracting it whole — which is
            // what this did until 2026-08-26 — takes the scroll offset off a second time, and
            // the new origin lands `bounds.origin` closer to the top-left than it should.
            //
            // At the top-left corner the offset is zero and the arithmetic looked right, which
            // is why it survived: the further the reader had scrolled, the further every zoom
            // dragged them back towards the corner — when the point held under the pointer is
            // exactly where a zoom must land.
            let clip = scrollView.contentView
            pageView.scroll(ZoomMath.scrollOrigin(
                anchorInDocumentAfterZoom: viewAfter,
                anchorInClipBounds: clip.convert(anchorWindowPoint, from: nil),
                clipBoundsOrigin: clip.bounds.origin
            ))
            scrollView.reflectScrolledClipView(clip)
        } else if let centreToKeep {
            let clip = scrollView.contentView
            let centre = centred.viewPoint(from: centreToKeep)
            pageView.scroll(NSPoint(
                x: centre.x - clip.bounds.width / 2,
                y: centre.y - clip.bounds.height / 2
            ))
            scrollView.reflectScrolledClipView(clip)
        }
        // LT3-10: on any layout that changed the zoom, the viewport or the page, an axis on
        // which the whole sheet fits is centred on that axis — Fit Page lands centred, and a
        // small sheet is never left in a corner with empty backdrop on the other side. Panning
        // it aside afterwards is untouched: a pan is a scroll, not a layout.
        if zoomChanged || viewportChanged || previousKey?.pageID != page.id {
            centreAxesWhereTheSheetFits(centred)
        }

        let backingScale = view.window?.backingScaleFactor ?? 2
        let layout = PageViewLayout(
            anchor: centred.origin,
            zoom: Double(zoom),
            backingScale: Double(backingScale),
            isViewFlipped: true
        )
        core.canvas.layout = layout
        core.measurement.layout = layout
        core.canvas.viewSize = scrollView.contentSize
        // A destination waiting for this sheet — a link, a bookmark, ⌘[ (NL-DOCS-06/09).
        applyPendingDestination(on: page.id, transform: centred)
        reportVisibleRect()
        requestRaster(page: page, transform: centred, backingScale: backingScale)
    }

    /// Centres the sheet on every axis on which it fits the visible area (LT3-10).
    private func centreAxesWhereTheSheetFits(_ transform: PageDisplayTransform) {
        let clip = scrollView.contentView
        let visible = clip.bounds
        let frame = transform.pageFrame
        var origin = visible.origin
        if frame.width <= visible.width + 0.5 { origin.x = frame.midX - visible.width / 2 }
        if frame.height <= visible.height + 0.5 { origin.y = frame.midY - visible.height / 2 }
        guard origin != visible.origin else { return }
        pageView.scroll(origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The page point at the centre of the visible area after the last report, which a resize
    /// keeps at the centre (LT3-10).
    private var lastVisibleCentrePagePoint: PDFPointValue?

    private func reportVisibleRect() {
        visibleRectReportScheduled = false
        guard let transform = pageView.transform else { return }
        visibleRectReportCountForTesting += 1
        let visible = scrollView.documentVisibleRect
        if liveZoom == nil {
            lastVisibleCentrePagePoint = transform.pagePoint(from: CGPoint(x: visible.midX, y: visible.midY))
        }
        core.canvas.setVisiblePageRect(
            transform.pageRect(covering: visible),
            backingScaleFactor: Double(view.window?.backingScaleFactor ?? 2)
        )
        core.refreshStatus()
        // A region raster only covers where the window was. Scrolling past its margin has to
        // ask for the new region; scrolling inside the margin returns immediately from the
        // containment test in `requestRaster`.
        if let page = core.document.currentPage {
            requestRaster(
                page: page,
                transform: transform,
                backingScale: view.window?.backingScaleFactor ?? 2
            )
        }
        // The page moved under a still pointer — a scroll, a zoom step, a pinch's commit: the
        // magnifier shows what is under the pointer now, not the crop of before (V-006).
        refreshLoupeAfterViewportChange()
        // …and so does everything else the pointer feeds: the snap the next click takes, the
        // rubber band, the hover (W-002).
        refreshPointerAfterViewportChange()
    }

    /// Re-runs the pointer path for the page point now under a still pointer (W-002).
    ///
    /// A scroll, a ⌘+/⌘− step or a pinch's commit sends no `mouseMoved`, so the snap feedback
    /// still held the page point that was under the pointer before, and the next click — which
    /// takes the hover's candidate — placed the vertex there, away from the pointer. The page
    /// view records where the pointer rests; nothing runs while it is not resting over the view,
    /// mid-pinch (the transform is stale until the commit), while the keyboard cursor leads a
    /// measurement (a pointer move would end it), or when the page point did not change.
    private func refreshPointerAfterViewportChange() {
        guard liveZoom == nil, let windowPoint = pageView.hoverWindowLocation,
              !measurementInput.state.isKeyboardCursorActive else { return }
        let point = pageView.pagePoint(atWindowLocation: windowPoint)
        switch (point, lastRawPointerPoint) {
        case (nil, nil):
            return
        case let (point?, last?) where Swift.abs(point.x - last.x) < 1e-9 && Swift.abs(point.y - last.y) < 1e-9:
            return
        default:
            pointerReaimCountForTesting &+= 1
            handlePointerMove(point)
        }
    }

    /// Turns one page and lands the new sheet where the eye expects it.
    ///
    /// Returns `false` at either end of the document, which is what stops the scroll view from
    /// marking the gesture as having turned a page — so a person who keeps scrolling at the last
    /// sheet gets the ordinary rubber-band, not a silent no-op that feels like a freeze.
    ///
    /// Going forward the new page rests at its **top**, going backward at its **bottom**: that is
    /// continuous reading. Landing a backward turn at the top would put the reader above the
    /// content they were just scrolling up towards.
    @discardableResult
    private func turnPage(forward: Bool) -> Bool {
        let document = core.document
        guard forward ? document.canGoToNextPage : document.canGoToPreviousPage else {
            return false
        }
        if forward { document.goToNextPage() } else { document.goToPreviousPage() }
        clearSearchHighlights()
        needsInitialCentring = true
        restScroll(atTop: forward)
        return true
    }

    /// Puts the scroll origin at the top or the bottom of the page now on screen.
    ///
    /// Deferred by one run-loop turn: the page change re-lays out the document view, and setting
    /// the origin before that happens sets it against the *old* page's height.
    private func restScroll(atTop: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let transform = self.pageView.transform else { return }
            let document = self.scrollView.contentView.documentRect
            let visible = self.scrollView.contentView.bounds
            // A sheet that fits keeps the centring `layoutPage` just gave it.
            guard let y = Self.restingScrollY(
                pageFrame: transform.pageFrame,
                visibleHeight: visible.height,
                documentRect: document,
                atTop: atTop
            ) else { return }
            self.scrollView.contentView.scroll(to: CGPoint(x: visible.origin.x, y: y))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    /// Breathing room between the viewport edge and the sheet a page turn lands on.
    static let pageTurnRestingGap: CGFloat = 16

    /// Where a page turn rests the scroll origin: the **sheet's** top (or bottom) edge, a small
    /// gap inside the viewport — not the document view's edge. The document view carries a
    /// pan margin of 90 % of the viewport on every side, so resting at its edge showed the
    /// reader nine tenths of backdrop and a sliver of sheet (BH-342). `nil` when the sheet is
    /// no taller than the viewport, where the centring layout already chose stands.
    static func restingScrollY(
        pageFrame: CGRect,
        visibleHeight: CGFloat,
        documentRect: CGRect,
        atTop: Bool
    ) -> CGFloat? {
        guard pageFrame.height + 2 * pageTurnRestingGap > visibleHeight else { return nil }
        let wanted = atTop
            ? pageFrame.minY - pageTurnRestingGap
            : pageFrame.maxY + pageTurnRestingGap - visibleHeight
        let lowest = documentRect.minY
        let highest = max(documentRect.minY, documentRect.maxY - visibleHeight)
        return min(max(wanted, lowest), highest)
    }

    private func scroll(by delta: CGSize) {
        var origin = scrollView.documentVisibleRect.origin
        origin.x += delta.width
        origin.y += delta.height
        pageView.scroll(origin)
    }

    // MARK: - Zoom

    /// Applies a multiplicative zoom about a window point, clamped to 5 %–6400 %.
    ///
    /// This is the single zoom entry for every pointer gesture — `⌘`+scroll, `⌘`+wheel and
    /// pinch — so they cannot disagree about anchoring. The layout pass runs synchronously:
    /// each event leaves the page point under the cursor, which is what keeps a fast gesture
    /// from visibly sliding the page.
    ///
    /// Pointer gestures no longer come here: they go through ``gestureZoom(by:aboutWindowPoint:phase:)``,
    /// which composites the gesture on the GPU and lays out once at its end. This is the
    /// immediate path — the Zoom tool's click, a keyboard step, a test.
    public func zoom(by factor: Double, aboutWindowPoint windowPoint: NSPoint) {
        commitLiveZoomIfNeeded()
        let current = core.canvas.viewport.zoom
        let target = min(ViewportSnapshot.maximumZoom, max(ViewportSnapshot.minimumZoom, current * factor))
        guard abs(target - current) > 1e-12 else { return }
        pendingZoomAnchorWindowPoint = windowPoint
        // Only a *burst* of steps waits for the steps to pause (IM-170). A single step — the
        // Zoom tool's click — renders at once; it is not a gesture and gains nothing from the
        // 60 ms wait.
        let now = Date()
        zoomStepIsBurst = lastZoomStepAt.map { now.timeIntervalSince($0) < 0.12 } ?? false
        lastZoomStepAt = now
        core.canvas.setZoom(target)
        layoutPage()
    }

    /// Whether the last immediate zoom step followed another within 120 ms.
    private var zoomStepIsBurst = false

    /// The window point at the centre of the visible canvas — the anchor for zooms that have
    /// no pointer, such as `⌘+` and the status-bar field.
    private func viewportCenterWindowPoint() -> NSPoint? {
        guard view.window != nil else { return nil }
        let visible = scrollView.documentVisibleRect
        return pageView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
    }

    /// Restores an exact prior viewport — zoom and scroll position — after a canvas view
    /// mode exits (leaving Compare, Overlay or Split restores exactly the previous
    /// view).
    public func restore(zoom: Double, visiblePageRect: PDFRectValue) {
        commitLiveZoomIfNeeded()
        core.canvas.setZoom(zoom)
        layoutPage()
        guard let transform = pageView.transform else { return }
        // The rect's on-screen extent, built from its corners so `/Rotate` is honoured: the
        // page-space (minX, maxY) corner is the view's top-left only on an unrotated sheet,
        // and at 90° it is the top-RIGHT — the restore landed a whole viewport away (BH-063).
        let viewRect = Self.restoredViewRect(for: visiblePageRect, transform: transform)
        let topLeft = viewRect.origin
        // LT-27: the saved rectangle is clamped to the sheet (`PageDisplayTransform`'s
        // `pageRect(covering:)` never reports past the crop box), so whenever the sheet is
        // narrower or shorter than the viewport at this zoom the rect's top-left IS the
        // sheet's corner — and scrolling that corner into the clip's corner pins the sheet
        // to the window's left/top edge with the pannable margin as dead black space on
        // the other side. That is exactly the state Revision Compare's Done and Close
        // Canvas View Mode left the canvas in. Centre the shortfall instead: when the
        // saved rect filled the clip the adjustment is zero and the restore is exact; when
        // it cannot fill the clip, the sheet comes back centred, which is where every
        // other layout path puts it.
        let clipSize = scrollView.contentView.bounds.size
        let restoredSize = viewRect.size
        var origin = topLeft
        if restoredSize.width < clipSize.width {
            origin.x -= (clipSize.width - restoredSize.width) / 2
        }
        if restoredSize.height < clipSize.height {
            origin.y -= (clipSize.height - restoredSize.height) / 2
        }
        origin.x = max(0, origin.x)
        origin.y = max(0, origin.y)
        pageView.scroll(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // A programmatic viewport change is reported at once: the coalescing of IM-169 is for
        // bursts of scroll events, and a caller that restores a viewport reads it straight back.
        reportVisibleRect()
    }

    /// The flipped-view rectangle a page-space visible rect occupies under a transform.
    /// Pure, for BH-063's regression test.
    static func restoredViewRect(for visiblePageRect: PDFRectValue, transform: PageDisplayTransform) -> CGRect {
        transform.viewRect(from: visiblePageRect)
    }

    /// The current sheet's `/Rotate`, for the zoom arithmetic (BH-067).
    private var currentRotation: Int { pageView.transform?.rotation ?? 0 }

    /// `⌘*`: fits the selected markups in the viewport with padding. With nothing selected it
    /// does nothing — the menu item is disabled then, so
    /// reaching here selection-less is a keyboard race, not an error.
    public func zoomToSelection() {
        let bounds = core.canvas.selectedMarkups.map(\.boundsInPageSpace)
        guard let union = ZoomMath.union(of: bounds) else { return }
        zoom(toPageRect: union)
    }

    /// Marquee zoom's landing: fit a page-space rectangle with padding.
    public func zoom(toPageRect rect: PDFRectValue) {
        guard let fit = ZoomMath.fit(
            target: rect, in: scrollView.contentSize, rotation: currentRotation
        ) else { return }
        jump(zoom: fit.zoom, visiblePageRect: fit.visiblePageRect)
    }

    /// A programmatic zoom jump: interpolated over about 150 ms so a large jump keeps the
    /// reader oriented, or instant under Reduce Motion or with no visible window (IM-242).
    /// Raster requests wait for the last frame.
    func jump(zoom: Double, visiblePageRect: PDFRectValue) {
        commitLiveZoomIfNeeded()
        zoomAnimationTask?.cancel()
        isAnimatingZoom = false
        guard Self.animatesZoomJumps(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            windowVisible: view.window?.isVisible == true
        ), let transform = pageView.transform else {
            restore(zoom: zoom, visiblePageRect: visiblePageRect)
            return
        }
        let frames = Self.zoomAnimationFrames(
            fromZoom: core.canvas.viewport.zoom,
            toZoom: zoom,
            fromRect: transform.pageRect(covering: scrollView.documentVisibleRect),
            toRect: visiblePageRect,
            steps: 9
        )
        zoomAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAnimatingZoom = true
            for frame in frames.dropLast() {
                guard !Task.isCancelled else { break }
                self.restore(zoom: frame.zoom, visiblePageRect: frame.rect)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard !Task.isCancelled else { return }
            self.isAnimatingZoom = false
            self.restore(zoom: zoom, visiblePageRect: visiblePageRect)
        }
    }

    private var zoomAnimationTask: Task<Void, Never>?
    /// While a zoom jump animates, raster planning waits for the final frame.
    private var isAnimatingZoom = false

    nonisolated static func animatesZoomJumps(reduceMotion: Bool, windowVisible: Bool) -> Bool {
        !reduceMotion && windowVisible
    }

    /// The frames of a zoom jump: zoom and rectangle size interpolated geometrically, the
    /// centre linearly, on an ease-in-out curve; the last frame is the target exactly.
    nonisolated static func zoomAnimationFrames(
        fromZoom: Double, toZoom: Double,
        fromRect: PDFRectValue, toRect: PDFRectValue,
        steps: Int
    ) -> [(zoom: Double, rect: PDFRectValue)] {
        guard steps > 1, fromZoom > 0, toZoom > 0 else { return [(toZoom, toRect)] }
        func geometric(_ a: Double, _ b: Double, _ t: Double) -> Double {
            guard a > 0, b > 0 else { return a + (b - a) * t }
            return a * pow(b / a, t)
        }
        return (1...steps).map { step in
            let linear = Double(step) / Double(steps)
            let t = linear < 0.5 ? 2 * linear * linear : 1 - pow(-2 * linear + 2, 2) / 2
            if step == steps { return (toZoom, toRect) }
            let width = geometric(fromRect.size.width, toRect.size.width, t)
            let height = geometric(fromRect.size.height, toRect.size.height, t)
            let midX = fromRect.center.x + (toRect.center.x - fromRect.center.x) * t
            let midY = fromRect.center.y + (toRect.center.y - fromRect.center.y) * t
            return (
                geometric(fromZoom, toZoom, t),
                PDFRectValue(x: midX - width / 2, y: midY - height / 2, width: width, height: height)
            )
        }
    }

    /// Scrolls a page-space rectangle into view **at the current zoom**, and marks it.
    ///
    /// This is what a search hit gets, and it is deliberately not ``zoom(toPageRect:)``. Fitting
    /// a hit on one short word magnified the canvas to roughly 500 % — `fit` doing its job on a rectangle a few points across. The
    /// reader loses the drawing around the word, which is the one thing they were looking for it
    /// in. Zoom belongs to the reader; a search result is not a reason to take it.
    ///
    /// The single exception is a hit larger than the viewport, which cannot be shown by
    /// scrolling. That zooms **out** to fit — never in.
    public func revealPageRect(_ rect: PDFRectValue, highlight: Bool) {
        let zoom = core.canvas.viewport.zoom
        let rotation = currentRotation
        if ZoomMath.fits(target: rect, in: scrollView.contentSize, zoom: zoom, rotation: rotation) {
            if let visible = ZoomMath.centred(
                target: rect, in: scrollView.contentSize, zoom: zoom, rotation: rotation
            ) {
                jump(zoom: zoom, visiblePageRect: visible)
            }
        } else if let fit = ZoomMath.fit(target: rect, in: scrollView.contentSize, rotation: rotation) {
            jump(zoom: fit.zoom, visiblePageRect: fit.visiblePageRect)
        }
        pageView.searchHighlights = highlight ? [rect] : []
    }

    /// Test seam: the search highlights currently drawn, so a test can assert that revealing a
    /// hit marked it out rather than only that the canvas scrolled.
    var searchHighlightsForTesting: [PDFRectValue] { pageView.searchHighlights }

    /// Where the sheet sits inside the visible viewport, for LT-27's centring assertion:
    /// the page frame relative to the scrolled-to corner (`documentVisibleRect.origin`),
    /// because clip-bounds coordinates already carry the scroll offset and would read the
    /// same wherever the view is scrolled. A sheet narrower than the viewport whose
    /// `minX` hugs zero while dead space stretches to the right is the exact state
    /// Revision Compare's Done used to leave behind.
    var pageFrameInClipForTesting: CGRect? {
        guard let transform = pageView.transform else { return nil }
        let visibleOrigin = scrollView.documentVisibleRect.origin
        return transform.pageFrame.offsetBy(dx: -visibleOrigin.x, dy: -visibleOrigin.y)
    }

    /// Clears any search highlight. Escape, and any page change, both mean "I am done with that".
    public func clearSearchHighlights() {
        pageView.searchHighlights = []
    }

    // MARK: - Layer visibility (gap 10)

    /// Switches the page raster between the native renderer and the content-stream path.
    ///
    /// `nil` means the effective layer visibility matches the document default again and
    /// the native raster is truthful. Anything else re-renders through
    /// ``LayerFilteredPageRenderer`` immediately.
    func setLayerFiltering(_ filtering: LayerFilteredPageRenderer.Filtering?) {
        commitLiveZoomIfNeeded()
        let previous = layerFiltering
        layerFiltering = filtering
        // Every cached tile was rendered against the previous hidden set.
        invalidateRasterTiles()
        // So was the resident base raster of any page either filter describes: it stands under
        // every gesture, pan and page return, and the native one shows every default layer
        // (U-002, iteration 4). The next request rebuilds it under the filter now in force.
        var droppedCurrentBase = false
        for key in Array(baseRasters.keys)
        where previous?.applies(toPageIndex: key) == true || filtering?.applies(toPageIndex: key) == true {
            baseRasters.removeValue(forKey: key)
            baseRasterOrder.removeAll { $0 == key }
            if key == currentRasterKey { droppedCurrentBase = true }
        }
        if droppedCurrentBase || filtering?.applies(toPageIndex: currentRasterKey ?? -1) == true {
            thumbnailTask?.cancel()
            pageView.baseRaster = nil
        }
        // Force the next raster request through: the plan did not change, the truth did.
        deliveredPlan = nil
        pendingPlan = nil
        renderedPageIndex = -1
        // The skeleton was compiled against the previous hidden set; recompile it against this
        // one, and drop the stale one meanwhile rather than draw a layer that is now hidden.
        pageView.underlayRaster = nil
        underlayTask?.cancel()
        if let underlayPage, let underlayExtraction {
            prepareVectorUnderlay(page: underlayPage, extraction: underlayExtraction)
        }
        layoutPage()
    }

    /// Throws the tile cache away: the page's pixels changed under the same keys.
    func invalidateRasterTiles() {
        tileGeneration &+= 1
        tileCache.removeAll()
        levelQueue.stop()
        pageView.staleTileRasters = pageView.tileRasters
        pageView.tileRasters = []
        pageView.levelTileRasters = []
        deliveredTiles = []
        currentTileKeys = []
        deliveredPlan = nil
        pendingPlan = nil
    }

    // MARK: - Pointer

    func handlePointerMove(_ point: PDFPointValue?) {
        lastRawPointerPoint = point
        updateLoupe(at: point)   // NL-MEASURE-15
        updateHover(at: point)
        // A drawing's own link says where it goes (NL-DOCS-09).
        updateLinkHover(at: point)
        // The snap engine always sees the raw pointer; the constraint filters its answer.
        resolveHoverSnap(at: point)
        if core.markup.activeKind != nil {
            core.markup.updateLiveCursor(point.map(markupConstrainedCursor(from:)))
            return
        }
        if core.measurement.activeKind != nil {
            if let point { measurementInput.send(.pointerMoved(point)) }
            core.measurement.updateLiveCursor(point.map(constrainedCursor(from:)))
            return
        }
        if isCalibrating, let point { calibrationInput.send(.pointerMoved(point)) }
        // Calibration is a segment-drawing context like any other, and
        // it was the one that fed no live cursor: no segment between the clicks, and — because
        // neither presenter was armed — nothing on screen acknowledging the snap the click was
        // about to take.
        if isCalibrating {
            var cursor = point
            if let raw = point, isShiftHeld, let anchor = calibrationPoints.last {
                cursor = MeasurementInputStateMachine.constrain(
                    raw,
                    to: anchor,
                    incrementDegrees: Self.shiftAngleIncrementDegrees
                )
            }
            pageView.calibrationCursor = cursor
        }
    }

    /// The point the hover resolve measures perpendicular feet and tangents from (W-001): the
    /// last vertex of the placement the next click serves — a calibration pick's first point,
    /// or the measurement in progress's last vertex — and nothing under Select or a markup tool.
    ///
    /// It is derived at every resolve. It used to be stored by each click and cleared only when
    /// calibration ended, so it outlived the shape: after a commit, a cancel, Remove Last Point,
    /// a tool change or a page turn the hover still offered a perpendicular foot from a vertex
    /// that no longer existed, and the next click — which takes the hover's candidate — put the
    /// first vertex of a new measurement on it.
    var hoverSnapAnchor: PDFPointValue? {
        if isCalibrating { return calibrationPoints.last }
        guard core.markup.activeKind == nil, let kind = core.measurement.activeKind else { return nil }
        // While a click of this canvas is still resolving the machine leads the presenter, which
        // is `prepareMeasurementInput`'s rule too.
        if measurementInput.state.kind == kind, measurementDriver.hasWorkInFlight {
            return measurementInput.state.vertices.last
        }
        return core.measurement.placedPoints.last
    }

    /// Records the cursor with the canvas presenter and starts its snap resolve, anchored by
    /// ``hoverSnapAnchor`` as it is now. Every hover resolve the canvas starts goes through here.
    func resolveHoverSnap(at point: PDFPointValue?) {
        let anchor = hoverSnapAnchor
        handedSnapAnchor = anchor
        core.canvas.setSnapAnchor(anchor)
        core.canvas.updateCursor(pagePoint: point)
    }

    /// Re-runs the hover resolve at the resting pointer when ``hoverSnapAnchor`` has moved since
    /// the last one started (W-001).
    ///
    /// Deriving the anchor at every resolve was half of the rule: Remove Last Point, a commit by
    /// Return or a double-click, Escape, a tool switch and a calibration pick all move the anchor
    /// with no pointer move, and the ring resolved from the old anchor stayed — a perpendicular
    /// foot dropped from a vertex that no longer existed — until the next click took it, because
    /// it lies within the click's reach. The live lane runs after every one of those changes (the
    /// calibration pick calls this itself), so this is where the hover catches up. The re-resolve
    /// also hands the presenter the current anchor, which its own re-resolve after a ledger-filter
    /// change reads.
    func reresolveHoverIfAnchorMoved() {
        guard hoverSnapAnchor != handedSnapAnchor else { return }
        resolveHoverSnap(at: core.canvas.viewport.cursorPagePoint)
    }

    /// Shift holds a markup's segment straight too — the same 45° rose as a measurement;
    /// a rectangle or ellipse box is held square instead.
    private func markupConstrainedCursor(from raw: PDFPointValue) -> PDFPointValue {
        guard isShiftHeld, let kind = core.markup.activeKind,
              let anchor = core.markup.placedPoints.last
        else { return raw }
        if kind == .rectangle || kind == .ellipse || kind == .text {
            let side = Swift.max(abs(raw.x - anchor.x), abs(raw.y - anchor.y))
            return PDFPointValue(
                x: anchor.x + (raw.x < anchor.x ? -side : side),
                y: anchor.y + (raw.y < anchor.y ? -side : side)
            )
        }
        return MeasurementInputStateMachine.constrain(
            raw,
            to: anchor,
            incrementDegrees: Self.shiftAngleIncrementDegrees
        )
    }

    /// Applies the live Shift constraint to a raw cursor point:
    /// the rubber band follows the constrained point while Shift is held, and releasing
    /// Shift mid-draw returns to free movement. A rectangle's depth point — the ⌥ rectangle
    /// of Area included — is held to the perpendicular of its placed edge instead, so the
    /// preview is a true rectangle. The package's one rule (U-073), so the band holds to
    /// the ray the click holds to: the canvas's own copy left the Rectangle Area's first edge
    /// free while the click held it to the rose, and held the ⌥ rectangle's depth to the rose
    /// while the click held it square. A count mark is never held (BH-256).
    private func constrainedCursor(from raw: PDFPointValue) -> PDFPointValue {
        shiftPlacement(cursor: raw, snap: nil)?.cursor ?? raw
    }

    /// Shift pressed or released — mid-draw included: the rubber band re-derives from the
    /// last raw pointer position immediately, not on the next mouse move.
    ///
    /// `⌘` suspends snapping while it is held (V-070). Nothing used to carry it: the page view
    /// reported only Shift and `⌥`, and every resolve passed no keys, so a `⌘`-click still
    /// landed on the vector candidate and the glyph stayed up.
    func handleModifiers(shiftHeld: Bool, optionHeld: Bool = false, commandHeld: Bool = false) {
        guard isShiftHeld != shiftHeld || isOptionHeld != optionHeld || isCommandHeld != commandHeld
        else { return }
        let commandChanged = isCommandHeld != commandHeld
        isShiftHeld = shiftHeld
        isOptionHeld = optionHeld
        isCommandHeld = commandHeld
        if commandChanged {
            let keys: SnapModifiers = commandHeld ? .command : .none
            core.canvas.snapModifiers = keys
            core.measurement.snapModifiers = keys
            // The glyph follows at once, not on the next mouse move.
            resolveHoverSnap(at: core.canvas.viewport.cursorPagePoint)
        }
        if core.markup.activeKind != nil {
            core.markup.updateLiveCursor(lastRawPointerPoint.map(markupConstrainedCursor(from:)))
        }
        if core.measurement.activeKind != nil {
            measurementInput.send(.setModifiers(measurementInputModifiers))
            core.measurement.updateLiveCursor(leadingRawPoint.map(constrainedCursor(from:)))
        }
        // A modifier changes what the live lane draws — the constrained band, the angle, the
        // ⌥ rectangle, the snap glyph — and nothing a layout or a scene fetch is computed from.
        // A full `refresh()` here committed an in-flight pinch, re-laid the page and refetched
        // the scene on every ⇧/⌥ press (V-013). The one scene input a modifier moves is a
        // rotation drag's 15° step (`previewing`), re-previewed from the cached scene.
        refreshLiveFeedback()
        if selectDrag != nil { applyScene() }
    }

    /// The keys the canvas hands the input machine: Shift, and `⌘` while it suspends snapping.
    /// `⌥` is a gesture here (count removal, auto-trace, the three-point rectangle), never a
    /// snap bypass, so it is not handed over.
    private var measurementInputModifiers: MeasurementInputModifiers {
        var modifiers: MeasurementInputModifiers = []
        if isShiftHeld { modifiers.insert(.shift) }
        if isCommandHeld { modifiers.insert(.command) }
        return modifiers
    }

    // MARK: - Rasterising

    /// Asks for the raster this frame needs: the visible region of the page, at
    /// `zoom x backingScale`, on whole device pixels.
    ///
    /// Three things changed here and all three come out of the viewer benchmark:
    ///
    /// - the request is a **region**, not the sheet, so it costs what a window costs rather
    ///   than what an A1 costs, and it is renderable at 800 % where the sheet is not;
    /// - the scale is **never clamped**, so the settled page is sharp at every zoom (Z5);
    /// - the reuse test is **containment at the same scale**, not a five-per-cent scale band,
    ///   so panning inside the margin is free and zooming always re-renders.
    private func requestRaster(page: ZPDFUIPresentation.PageDescriptor, transform: PageDisplayTransform, backingScale: CGFloat) {
        guard let rasterSource = rasterSource(for: page), !isAnimatingZoom else { return }
        let pageKey = rasterKey(of: page)
        // A sheet whose view changed (NL-DOCS-07/16) keeps none of its old tiles.
        let view = RenderedView(rotation: page.viewRotation, crop: page.viewCrop)
        if renderedViews[pageKey, default: RenderedView()] != view {
            renderedViews[pageKey] = view
            tileGeneration &+= 1
            if renderedPageIndex == pageKey { renderedPageIndex = -1 }
        }
        let visible = pageView.visibleRect.isEmpty
            ? CGRect(origin: .zero, size: scrollView.contentSize)
            : pageView.visibleRect
        let plan: ViewportRasterPlan
        do {
            plan = try ViewportRasterPlanner.plan(
                transform: transform,
                visibleViewRect: visible,
                backingScale: backingScale
            )
        } catch {
            // Typed and never silent: a refusal leaves the previous raster on screen and says
            // so in the log rather than producing a soft one (gate Z8).
            CanvasLog.logger.error(
                "viewport raster refused: \(String(describing: error), privacy: .public)"
            )
            // And on the sheet: the log alone left the person looking at stale paper (IM-164).
            pageView.renderNotice = .refused
            return
        }

        if renderedPageIndex == pageKey {
            if let delivered = deliveredPlan, ViewportRasterPlanner.satisfies(delivered, plan) {
                // Back inside what is already on screen: ⌘+ then ⌘− before the ⌘+ render
                // landed, or a pan back into the margin. The render for the plan the view has
                // left is retired, and the delivered tiles come back from their stand-in role.
                // Before, the other zoom's render landed later and replaced these tiles with
                // ones at the wrong magnification over the wrong region, and nothing asked for
                // another until the next scroll (U-001, iteration 4).
                retireRenderInFlight()
                pageView.tileRasters = deliveredTiles
                pageView.staleTileRasters = []
                return
            }
            if pendingPlan == plan { return }
        }

        if renderedPageIndex != pageKey {
            // A new sheet: nothing of the old one may stay on screen (IM-045). Its cached tiles,
            // if the reader has been here before, or its base raster stand in until they land.
            pageView.pageRaster = nil
            pageView.staleTileRasters = []
            pageView.tileRasters = []
            pageView.levelTileRasters = []
            deliveredTiles = []
            // The delivered plan was the old sheet's. Kept, a same-sized new sheet "satisfied"
            // it, and the zoom-back path above would retire the new sheet's own first render
            // (U-001, iteration 4).
            deliveredPlan = nil
            currentTileKeys = []
            levelQueue.cancelQueued()
            showBaseRaster(page: page, rasterSource: rasterSource)
            scheduleRenderingNotice(pageIndex: pageKey)
        } else if let delivered = deliveredPlan, delivered.scale != plan.scale {
            // A zoom: the last *delivered* tiles stand in, scaled by the compositor, until
            // today's arrive. Not the current list: from the second zoom step on that list is
            // the new scale's (usually empty) cache hits, and copying it here is what wiped the
            // stand-in and flashed blank paper for the rest of the gesture (NL-PERF-02).
            if !deliveredTiles.isEmpty { pageView.staleTileRasters = deliveredTiles }
            pageView.tileRasters = []
        }
        renderedPageIndex = pageKey

        // The tile grid for this scale, anchored to the page (IM-044).
        let grid = CanvasTileCache.Grid(
            pageIndex: pageKey,
            scale: plan.scale,
            devicePage: CGRect(
                x: transform.pageFrame.minX * backingScale,
                y: transform.pageFrame.minY * backingScale,
                width: transform.pageFrame.width * backingScale,
                height: transform.pageFrame.height * backingScale
            ),
            generation: tileGeneration
        )
        let cells = grid.cells(covering: plan.deviceRect)
        let cached = cells.compactMap { tileCache.tile(for: grid.key(column: $0.column, row: $0.row)) }
        let missing = cells.filter { !tileCache.contains(grid.key(column: $0.column, row: $0.row)) }
        pageView.tileRasters = cached
        if missing.isEmpty {
            // Everything this view needs is in the cache: a pan back, a zoom back — no render.
            // A render still in flight is for a view the canvas has left; it must not land on
            // top of these tiles (U-001, iteration 4).
            retireRenderInFlight()
            deliveredPlan = plan
            pendingPlan = nil
            deliveredTiles = cached
            currentTileKeys = cells.map { grid.key(column: $0.column, row: $0.row) }
            pageView.staleTileRasters = []
            if liveZoom == nil { pageView.levelTileRasters = [] }
            pageView.underlayRaster = nil
            renderNoticeTask?.cancel()
            pageView.renderNotice = nil
            return
        }

        // One render for the bounding rectangle of the missing tiles.
        let union = missing
            .map { grid.deviceRect(column: $0.column, row: $0.row) }
            .reduce(CGRect.null) { $0.union($1) }
        let renderPlan: ViewportRasterPlan
        do {
            renderPlan = try ViewportRasterPlanner.plan(
                transform: transform,
                visibleViewRect: CGRect(
                    x: union.minX / backingScale,
                    y: union.minY / backingScale,
                    width: union.width / backingScale,
                    height: union.height / backingScale
                ),
                backingScale: backingScale,
                overscanViewPoints: 0
            )
        } catch {
            CanvasLog.logger.error(
                "tile raster refused: \(String(describing: error), privacy: .public)"
            )
            pageView.renderNotice = .refused
            return
        }

        pendingPlan = plan
        let index = pageKey
        rasterTask?.cancel()
        rasterGeneration &+= 1
        let generation = rasterGeneration
        requestUnderlay(plan: plan)
        let render = rasterRenderer(page: page, rasterSource: rasterSource)
        let debounce = zoomGestureDebounce()
        lastRasterDebounceForTesting = debounce
        rasterTask = Task { @MainActor [weak self] in
            if debounce > 0 {
                // A burst of immediate zoom steps: every step would start a render the next one
                // cancels. Wait for the steps to pause; the stand-ins hold the frame meanwhile
                // (IM-170).
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard !Task.isCancelled else { return }
            self?.rasterRenderStartCountForTesting += 1
            let signpost = CanvasLog.signposter.beginInterval("TileRender")
            let image = await render(renderPlan)
            CanvasLog.signposter.endInterval("TileRender", signpost)
            guard !Task.isCancelled, let self, self.rasterGeneration == generation else { return }
            guard self.currentRasterKey == index else { return }
            guard let image else {
                // A refused render must not leave this plan marked pending, or every retry of
                // the same viewport is swallowed by `pendingPlan == plan` (BH-884).
                self.pendingPlan = nil
                self.rasterFailureCountForTesting += 1
                self.pageView.renderNotice = .refused
                CanvasLog.logger.error("tile raster render failed for page \(index, privacy: .public)")
                return
            }
            // Cutting the render into tiles and copying each one is tens of megabytes of
            // memory traffic on a large display; it runs off the main actor, and the main actor
            // only files the finished tiles (NL-PERF-03).
            let sliced = await Task.detached(priority: .userInitiated) {
                CanvasTileCache.slice(
                    image,
                    renderedDeviceRect: renderPlan.deviceRect,
                    cells: missing,
                    grid: grid,
                    transform: transform,
                    backingScale: backingScale
                )
            }.value
            guard !Task.isCancelled, self.rasterGeneration == generation,
                  self.currentRasterKey == index else { return }
            // The tiles were cut for the page transform they were planned under. A layout that
            // moved on without starting a render of its own (a zoom jump still animating, a
            // refused plan) files them for a later return but never shows them at a
            // magnification they were not made for (U-001, iteration 4).
            guard self.pageView.transform == transform else {
                self.tileCache.insert(contentsOf: sliced)
                if self.pendingPlan == plan { self.pendingPlan = nil }
                return
            }
            self.recordLanding {
                self.tileCache.insert(contentsOf: sliced)
                self.pageView.performRasterBatch {
                    self.deliverTiles(cells: cells, grid: grid, plan: plan)
                }
            }
        }
    }

    /// Retires the render in flight, when there is one: its plan is for a view the canvas has
    /// already left, and letting it land would put that view's tiles over the ones on screen
    /// (U-001, iteration 4). Its skeleton was for the same plan and goes with it.
    private func retireRenderInFlight() {
        guard pendingPlan != nil else { return }
        rasterTask?.cancel()
        rasterGeneration &+= 1
        pendingPlan = nil
        underlayTask?.cancel()
        pageView.underlayRaster = nil
    }

    /// The render step for the current mode: the native renderer, or the layer-filtered
    /// content-stream renderer when per-project layer overrides are in force.
    private func rasterRenderer(
        page: ZPDFUIPresentation.PageDescriptor,
        rasterSource: PageRasterSource
    ) -> @MainActor (ViewportRasterPlan) async -> CGImage? {
        let index = page.index
        // nl-ux: a filter belongs to one page; another page renders natively until the
        // document hands over that page's filter. Keyed across the set (NL-DOCS-04): a filter
        // on the primary drawing never applies to another drawing's page of the same index.
        if let filtering = layerFiltering, filtering.applies(toPageIndex: rasterKey(of: page)) {
            // Content-stream path, off the main actor, abandoned when superseded: the detached
            // render used to run to the end after every pan or zoom that replaced it (IM-171).
            // The flag is lock-protected, so it is Sendable without an unchecked conformance.
            return { plan in
                let cancelled = OSAllocatedUnfairLock(initialState: false)
                return await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) {
                        LayerFilteredPageRenderer.render(
                            filtering: filtering,
                            page: page,
                            plan: plan,
                            isCancelled: { cancelled.withLock { $0 } }
                        )
                    }.value
                } onCancel: {
                    cancelled.withLock { $0 = true }
                }
            }
        }
        let viewRotation = page.viewRotation
        return { plan in
            try? await rasterSource.renderViewport(pageIndex: index, plan: plan, viewRotation: viewRotation)
        }
    }

    /// Puts the tiles a plan needs on screen, once they are all cached.
    private func deliverTiles(cells: [(column: Int, row: Int)], grid: CanvasTileCache.Grid, plan: ViewportRasterPlan) {
        let signpost = CanvasLog.signposter.beginInterval("TileDeliver")
        defer { CanvasLog.signposter.endInterval("TileDeliver", signpost) }
        pageView.tileRasters = cells.compactMap { tileCache.tile(for: grid.key(column: $0.column, row: $0.row)) }
        let complete = pageView.tileRasters.count == cells.count
        pendingPlan = nil
        if complete {
            renderNoticeTask?.cancel()
            pageView.renderNotice = nil
            deliveredPlan = plan
            deliveredTiles = pageView.tileRasters
            currentTileKeys = cells.map { grid.key(column: $0.column, row: $0.row) }
            pageView.staleTileRasters = []
            pageView.pageRaster = nil
            pageView.underlayRaster = nil
            // The exact pass has covered the viewport: the level tiles have done their job and
            // leave the screen (they stay in the cache for the next gesture). Mid-gesture they
            // are what the person is looking at, so they stay.
            if liveZoom == nil { pageView.levelTileRasters = [] }
        }
    }

    /// The long side of the resident base raster (NL-PERF-02): 2048 pixels, 11.9 MB for an A1.
    static let baseRasterPixelSize = 2048

    /// Base rasters by page, the current page and the last few visited.
    private var baseRasters: [Int: PageRaster] = [:]
    private var baseRasterOrder: [Int] = []

    /// The page's resident base raster (NL-PERF-02, IM-045): the whole sheet at about 2048
    /// pixels, drawn under everything for as long as the page is shown. It stands in while a
    /// new sheet's tiles render, and it is what any spot of the sheet falls back to mid-gesture,
    /// so no frame of a pinch is ever blank paper — the thumbnail this replaces was thrown away
    /// the moment the first tiles landed.
    private func showBaseRaster(
        page: ZPDFUIPresentation.PageDescriptor,
        rasterSource: PageRasterSource
    ) {
        let index = rasterKey(of: page)
        let pdfIndex = page.index
        thumbnailTask?.cancel()
        // The resident base raster is the whole sheet upright; a turned or cropped view has no
        // matching picture, so its tiles stand alone (NL-DOCS-07/16).
        guard page.viewRotation == 0, page.viewCrop == nil else {
            pageView.baseRaster = nil
            return
        }
        if let base = baseRasters[index] {
            pageView.baseRaster = base
            return
        }
        pageView.baseRaster = nil
        // The native thumbnail honours only the file's default layer configuration. Under a
        // layer filter the base goes through the same content-stream renderer as the tiles, so
        // a hidden layer stays hidden under every gesture, pan and page return; before, the
        // native base drew it in colour wherever the filtered tiles did not reach (U-002,
        // iteration 4). `setLayerFiltering` drops the cached base whenever the filter changes.
        let produce: @MainActor () async -> CGImage?
        if let filtering = layerFiltering, filtering.applies(toPageIndex: index) {
            guard let plan = Self.baseRasterPlan(for: page) else { return }
            let render = rasterRenderer(page: page, rasterSource: rasterSource)
            produce = { await render(plan) }
        } else {
            produce = {
                try? await rasterSource.thumbnail(pageIndex: pdfIndex, maximumPixelSize: Self.baseRasterPixelSize)
            }
        }
        thumbnailTask = Task { @MainActor [weak self] in
            guard let image = await produce() else { return }
            guard !Task.isCancelled, let self, self.currentRasterKey == index else { return }
            let width = self.pageView.transform?.displaySize.width ?? CGFloat(image.width)
            let base = await CanvasSurfaceImage.surfaced(PageRaster(
                image: image,
                coverage: .wholePage,
                scale: width > 0 ? CGFloat(image.width) / width : 1
            ))
            guard !Task.isCancelled, self.currentRasterKey == index else { return }
            self.recordLanding {
                self.baseRasters[index] = base
                self.baseRasterOrder.removeAll { $0 == index }
                self.baseRasterOrder.append(index)
                while self.baseRasterOrder.count > 3 {
                    self.baseRasters.removeValue(forKey: self.baseRasterOrder.removeFirst())
                }
                self.pageView.baseRaster = base
            }
            // Something of the sheet is on screen: the waiting notice has done its job.
            if self.pageView.renderNotice == .rendering { self.pageView.renderNotice = nil }
        }
    }

    /// The whole upright sheet at the base raster's size — its long side
    /// ``baseRasterPixelSize`` pixels — as a plan the layer-filtered renderer draws (U-002).
    /// Backing scale 1 with the zoom carrying the whole factor, so the plan's device pixels are
    /// the bitmap's pixels.
    static func baseRasterPlan(for page: ZPDFUIPresentation.PageDescriptor) -> ViewportRasterPlan? {
        let unit = PageDisplayTransform(pageBox: page.viewBox, rotation: page.displayRotation, zoom: 1, origin: .zero)
        let longSide = max(unit.displaySize.width, unit.displaySize.height)
        guard longSide > 0 else { return nil }
        let transform = PageDisplayTransform(
            pageBox: page.viewBox,
            rotation: page.displayRotation,
            zoom: CGFloat(baseRasterPixelSize) / longSide,
            origin: .zero
        )
        return try? ViewportRasterPlanner.plan(
            transform: transform,
            visibleViewRect: transform.pageFrame,
            backingScale: 1,
            overscanViewPoints: 0
        )
    }

    /// After 250 ms with nothing drawn for a newly shown page, the sheet says it is rendering
    /// rather than showing blank paper (IM-164).
    private func scheduleRenderingNotice(pageIndex: Int) {
        renderNoticeTask?.cancel()
        if pageView.renderNotice == .rendering { pageView.renderNotice = nil }
        renderNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.renderingNoticeDelay)
            guard !Task.isCancelled, let self, self.renderedPageIndex == pageIndex else { return }
            guard self.pageView.pageRaster == nil, self.pageView.baseRaster == nil,
                  self.pageView.tileRasters.isEmpty,
                  self.pageView.renderNotice == nil else { return }
            self.pageView.renderNotice = .rendering
        }
    }

    /// How long a new page may show nothing before the sheet says it is rendering.
    static var renderingNoticeDelay: UInt64 = 250_000_000
    private var renderNoticeTask: Task<Void, Never>?

    /// Nanoseconds to wait before rendering, while zoom steps are still arriving (IM-170).
    private func zoomGestureDebounce() -> UInt64 {
        guard zoomStepIsBurst, let last = lastZoomStepAt else { return 0 }
        return Date().timeIntervalSince(last) < 0.12 ? 60_000_000 : 0
    }

    /// Compiles the page's extracted linework into the vector underlay.
    ///
    /// Called once per page, from the same pass that builds the snap index, because it uses the
    /// same extraction. The compile costs about 171 ms on the reference machine and happens on
    /// the underlay's own actor — never on a zoom, which is the condition gate Z10 attaches to
    /// having an underlay at all.
    func prepareVectorUnderlay(page: ZPDFContracts.PageDescriptor, extraction: VectorPageExtraction) {
        let underlay = vectorUnderlay ?? VectorUnderlay()
        vectorUnderlay = underlay
        underlayPage = page
        underlayExtraction = extraction
        let hidden = underlayHiddenLayerIDs(forPageIndex: page.index)
        underlayGeneration &+= 1
        let generation = underlayGeneration
        Task { @MainActor in
            await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: hidden, generation: generation)
            let availability = await underlay.availability
            CanvasLog.logger.info("vector underlay: \(availability.explanation, privacy: .public)")
        }
    }

    /// The layers hidden on `pageIndex` for the skeleton: the filter's set only when the filter
    /// belongs to that page, so another page's hidden layers never thin this page's linework
    /// (the raster path is scoped the same way).
    func underlayHiddenLayerIDs(forPageIndex pageIndex: Int) -> Set<String> {
        guard let layerFiltering, layerFiltering.pageIndex == pageIndex else { return [] }
        return layerFiltering.hiddenLayerIDs
    }

    /// Orders underlay prepares, so an older one arriving late is ignored (BH-889).
    private var underlayGeneration = 0

    // MARK: Automation (nl-automation)

    /// Document-side facts auto-trace needs: layer visibility, the measure lock, other pages'
    /// extractions. Injected by the window controller.
    var automationContext: CanvasAutomationContext?
    /// Prepared pages and the off-main walk (NL-AUTO-01).
    let autoTraceService = AutoTraceService()
    private var autoTraceTask: Task<Void, Never>?
    private var autoTraceGeneration = 0
    /// The opening proposal on screen, while the person decides (NL-AUTO-07).
    private(set) var pendingOpeningProposal: OpeningProposal?

    /// Renders the skeleton for the plan the raster is being made for, so it is on screen for
    /// the few milliseconds the raster takes.
    private func requestUnderlay(plan: ViewportRasterPlan) {
        guard let vectorUnderlay, let page = underlayPage, rasterKey(ofPage: page) == renderedPageIndex else {
            return
        }
        // The skeleton is drawn for the upright sheet; a turned or cropped view goes without.
        if let shown = core.document.currentPage, shown.viewRotation != 0 || shown.viewCrop != nil { return }
        underlayTask?.cancel()
        let hidden = underlayHiddenLayerIDs(forPageIndex: page.index)
        underlayTask = Task { @MainActor [weak self] in
            let signpost = CanvasLog.signposter.beginInterval("UnderlayRender")
            let image = await vectorUnderlay.render(page: page, plan: plan, hiddenLayerIDs: hidden)
            CanvasLog.signposter.endInterval("UnderlayRender", signpost)
            guard !Task.isCancelled, let self, let image else { return }
            // A raster that has already landed for this plan makes the skeleton redundant.
            guard self.deliveredPlan != plan else { return }
            let underlay = await CanvasSurfaceImage.surfaced(
                PageRaster(image: image, coverage: .region(plan.pageRegion), scale: plan.scale)
            )
            guard !Task.isCancelled, self.deliveredPlan != plan else { return }
            self.recordLanding {
                self.pageView.underlayRaster = underlay
            }
        }
    }

    /// The verb the pointer is wearing over the canvas right now.
    ///
    /// Read off the view rather than recomputed, so what a test asks and what the pointer shows
    /// cannot be two different answers — which is exactly how a wrong pointer once survived
    /// a change that had already drawn both cursors.
    public var armedCursorKind: CanvasCursorKind { pageView.cursorKind }

    // MARK: - Input

    func handleClick(at point: PDFPointValue, additive: Bool, optionHeld: Bool = false) {
        // Clicking away from an open text box commits it.
        // The click is spent on the commit rather than also starting the next markup, so
        // "click away to finish" cannot accidentally place a second box.
        if activeTextEntry != nil {
            commitTextEntry()
            return
        }
        // Tool-set modes. Before every drawing branch, because Apply and
        // Place *replace* what a click means rather than adding to it: in those two modes both
        // drawing families are deliberately disarmed by `AppCoreEnvironment.onArm`, and a click
        // that fell through to them would draw a markup the estimator did not ask for.
        // Calibration outranks an armed Apply/Place preset: Calibrate Scale… is an explicit
        // request, and the preset used to eat both reference clicks (BH-343).
        if !isCalibrating, let preset = core.toolLibrary.activePreset {
            switch core.toolLibrary.armedSetMode {
            case .apply:
                handlePresetApplyClick(preset, at: point)
                return
            case .place:
                handlePresetPlaceClick(preset, at: point)
                return
            case .draw:
                break
            }
        }
        if let kind = core.markup.activeKind {
            handleMarkupClick(at: point, kind: kind)
            return
        }
        if isCalibrating {
            routeCalibrationClick(at: point)
            return
        }

        if let kind = core.measurement.activeKind {
            // LT3-05: a sheet with no scale refuses the first point up front and opens the
            // scale sheet, instead of letting a whole shape be drawn that can never commit.
            // L-102: a circle tool is refused by the scale where the click lands — a uniform
            // Scale Region on an X/Y sheet measures circles — so the click goes with the question.
            if core.measurement.placedPoints.isEmpty, core.measurement.refusesForMissingScale(at: point) { return }
            // `⌥`-click with the Area tool armed and nothing drawn yet is **auto-trace**: the
            // boundary around the click is walked on the page's own vector geometry and
            // committed as the area. It is not a drawing transition — no vertex is placed — so
            // it stays outside the input machine, which is re-synchronised
            // from the presenter on the next event.
            // NL-MEASURE-11: Perimeter and Wall Area trace too (CanvasTraceFences.swift).
            if optionHeld, Self.traceableKinds.contains(kind), core.measurement.placedPoints.isEmpty,
               underlayExtraction != nil || automationContext != nil {
                // ⇧⌥ adds the room to the one selected area (NL-MEASURE-11). Decided here, from
                // the click's own ⇧ and the selection at the click — the trace lands later, and
                // by then ⇧ may be up or the selection changed (V-009).
                let selected = core.canvas.selectedMarkupIDs
                autoTraceArea(at: point, unionInto: additive && selected.count == 1 ? selected.first : nil)
                return
            }
            routeMeasurementClick(at: point, optionHeld: optionHeld, kind: kind)
            return
        }

        // ⌥-click on an edge of the selected markup inserts a vertex (NL-MEASURE-06).
        if optionHeld, armedMode == .select, insertVertexOnSelectedEdge(at: point) { return }
        // A plain click on a handle of a selected markup focuses that vertex, and Delete then
        // removes it (NL-MEASURE-06). The markup the handle belongs to becomes the selection on
        // its own, so the focus and the selection agree. Every other Select click lets go of the
        // focus: a vertex focused by an earlier drag must not turn a later Delete of the markup
        // into a vertex edit (T-001). ⇧ and ⌘ keep their meaning on a handle too. Only a handle
        // whose vertex Delete can remove is focused; any other handle, such as a Length's
        // endpoint, a lone count mark or a stamp's centre, is a click on the markup (T-001,
        // iteration 3).
        if armedMode == .select, !additive, !isCommandClick, let handle = vertexHandle(at: point),
           vertexTakesFocus(markupID: handle.markupID, index: handle.index) {
            if core.canvas.selectedMarkupIDs != [handle.markupID] {
                core.canvas.select(markupIDs: [handle.markupID], additive: false)
            }
            focusedVertex = handle
            return
        }
        focusedVertex = nil
        let hit = hitTest(point)
        // r2-markup: ⌘-click follows a hyperlink markup (NL-MARKUP-17).
        if let hit, isCommandClick, followMarkupLink(hit) { return }
        if let hit {
            // `⇧` adds *or removes*: clicking a selected
            // markup with `⇧` takes it out of the selection. A union-only modifier makes a
            // mis-shift-click impossible to correct without starting the selection over.
            if additive, core.canvas.selectedMarkupIDs.contains(hit) {
                core.canvas.select(
                    markupIDs: core.canvas.selectedMarkupIDs.subtracting([hit]),
                    additive: false
                )
            } else {
                // A click on one member selects its group; ⌘-click picks the member alone
                // (NL-MARKUP-11).
                core.canvas.select(markupIDs: isCommandClick ? [hit] : core.expandingGroups([hit]), additive: additive)
            }
        } else if !additive {
            core.canvas.clearSelection()
            // A click on empty drawing may be a click on the drawing's own link (NL-DOCS-09).
            followDrawingLink(at: point)
        }
    }

    /// Follows the drawing's link under `point`, when there is one, through ``onFollowLink``.
    /// Links are read once per page and kept.
    func followDrawingLink(at point: PDFPointValue) {
        guard let onFollowLink, let page = core.document.currentPage,
              let rasterSource = rasterSource(for: page) else { return }
        let index = rasterKey(of: page)
        let pdfIndex = page.index
        Task { @MainActor [weak self] in
            guard let self else { return }
            let links: [DrawingLink]
            if let cached = self.drawingLinksByPage[index] {
                links = cached
            } else {
                links = (try? await rasterSource.links(pageIndex: pdfIndex)) ?? []
                self.drawingLinksByPage[index] = links
            }
            guard self.currentRasterKey == index,
                  let hit = DrawingLink.hit(CGPoint(x: point.x, y: point.y), in: links) else { return }
            if let onFollowDrawingLink = self.onFollowDrawingLink {
                onFollowDrawingLink(hit)
            } else {
                onFollowLink(hit.target)
            }
        }
    }

    // MARK: - Tool-set modes

    /// Apply mode: one click writes the armed preset's properties onto a markup.
    ///
    /// The multi-selection rule is the one thing worth stating. Clicking a markup that is
    /// **already in the selection** applies to the whole selection, in one action — that is the
    /// "these forty areas are all Foundation" case the mode exists for. Clicking a
    /// markup outside the selection applies to that markup alone and makes it the selection,
    /// because a click somewhere else plainly means *that one*, and silently including forty
    /// others would be a bulk mutation nobody asked for.
    ///
    /// A click that hits nothing does nothing and says so. Clearing the selection here would be
    /// worse than useless: the estimator would lose the forty rows they had just gathered.
    func handlePresetApplyClick(_ preset: ToolPresetSummary, at point: PDFPointValue) {
        guard let hit = hitTest(point) else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Nothing there to apply to. Click a markup, or select several and click one of them.",
                comment: "Apply-mode note when the click missed every markup"
            ))
            return
        }
        let selection = core.canvas.selectedMarkupIDs
        let targets = selection.contains(hit) ? selection : [hit]
        if !selection.contains(hit) { core.canvas.select(markupIDs: [hit], additive: false) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let receipt = await self.core.applyPreset(preset, to: targets)
            self.core.status.setActiveToolNote(receipt.summaryMessage)
            self.reportSkips(receipt.skipReport, preset: preset)
            self.refresh()
        }
    }

    /// Puts a per-markup skip report where it can be read.
    ///
    /// The status bar takes one sentence, so a mixed selection whose markups gave *different*
    /// answers is exactly the case a single line cannot carry — and it is the case the old
    /// property-keyed union silently merged. One answer, however many markups gave it, stays in
    /// the status bar and nowhere else: "12 markups skipped Depth" is a complete report. Two or
    /// more distinct answers go to the warnings tray as one line each, which is the only surface
    /// in the window with room for a list.
    private func reportSkips(_ report: MarkupSkipReport, preset: ToolPresetSummary) {
        guard report.groups.count > 1 else { return }
        core.document.post(
            AppWarning(
                id: UUID(),
                severity: .info,
                title: String(
                    format: NSLocalizedString(
                        "“%@” did not apply to every markup.",
                        comment: "Apply-mode skip report title. %@ is the preset name"
                    ),
                    preset.name
                ),
                message: report.lines.joined(separator: "\n"),
                source: NSLocalizedString("Tool Library", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// Place mode: one click drops a complete copy of the preset's markup.
    ///
    /// No snap resolve. A stamp goes where the estimator clicked; snapping a revision tag onto a
    /// wall corner would be a surprise rather than a service, which is the same rule
    /// `AppMarkupToolPresenter` already keeps for the markup family — a snap earns its
    /// interference only when a *number* depends on it.
    func handlePresetPlaceClick(_ preset: ToolPresetSummary, at point: PDFPointValue) {
        let pageID = core.canvas.viewport.pageID
        // nl-markup: a stamp goes through the stamp door, which asks the template's questions
        // (`StampPlacementAsk`); the generic door froze every prompted field blank.
        if preset.stamp != nil {
            StampPlacementAsk.place(preset, at: point, pageID: pageID, core: core, window: view.window) { [weak self] receipt in
                guard let self, let receipt else { return }
                if let failure = receipt.failureMessage {
                    self.core.status.setActiveToolNote(failure)
                } else {
                    self.core.status.setActiveToolNote(self.core.toolLibrary.armedSetMode.shortHelp)
                }
                self.refresh()
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let receipt = await self.core.placePreset(preset, at: point, pageID: pageID)
            if let failure = receipt.failureMessage {
                self.core.status.setActiveToolNote(failure)
            } else {
                self.core.status.setActiveToolNote(self.core.toolLibrary.armedSetMode.shortHelp)
            }
            self.refresh()
        }
    }

    // MARK: - Routing through the input machine (IM-019)

    /// The machine's tunables for this canvas: the zoom-aware tolerances the canvas has always
    /// used — close on the first vertex within 12 screen points, a Shift ray accepting a snap
    /// within 8, a count mark removed within ``countRemovalToleranceScreenPoints`` — the 45°
    /// rose, the canvas's gesture table, and Reuse left to the shell's Finish.
    private var measurementInputConfiguration: MeasurementInputConfiguration {
        let viewport = core.canvas.viewport
        return MeasurementInputConfiguration(
            angleIncrementDegrees: Self.shiftAngleIncrementDegrees,
            // The shell decides whether the tool stays armed after a commit (Reuse Tool); the
            // machine re-synchronises from the presenter on the next event either way.
            reusesToolAfterCommit: true,
            firstVertexCloseTolerance: viewport.pageDistance(forViewPoints: 12),
            constrainedRayTolerance: viewport.pageDistance(forViewPoints: 8),
            countPointHitTolerance: viewport.pageDistance(forViewPoints: Self.countRemovalToleranceScreenPoints),
            appliesCanvasGestures: true
        )
    }

    /// The anchor corner of the measurement drag in progress, as the machine holds it.
    private var measurementDragAnchor: PDFPointValue? {
        let state = measurementInput.state
        guard state.dragPressPoint != nil else { return nil }
        return state.vertices.first
    }

    /// Brings the machine in step with the canvas before a routed event.
    ///
    /// The presenter is the truth for the placed points, but it lags a click by one snap
    /// resolve; while a click of this canvas is still resolving, the machine — which already
    /// holds it — keeps its own list. A different tool always re-synchronises.
    private func prepareMeasurementInput(rawPoint: PDFPointValue?) {
        let measurement = core.measurement
        measurementInput.configuration = measurementInputConfiguration
        if measurement.activeKind != measurementInput.state.kind || !measurementDriver.hasWorkInFlight {
            measurementInput.synchronize(
                kind: measurement.activeKind,
                vertices: measurement.placedPoints,
                cutoutParentID: measurement.cutoutParentID?.rawValue,
                // The arc in progress (NL-MEASURE-05) is the presenter's too.
                arcNextSegment: measurement.isArcNextSegment,
                arcThroughPoint: measurement.arcThroughPoint
            )
        }
        measurementInput.send(.setCutoutParents(cutoutCandidates))
        // Shift and `⌘` (V-070); `⌥` is a gesture here, never a snap bypass.
        measurementInput.send(.setModifiers(measurementInputModifiers))
        measurementInput.send(.setSnapCandidates(hoverSnapCandidate(reaching: rawPoint).map { [$0] } ?? []))
        if let rawPoint { measurementInput.send(.pointerMoved(rawPoint)) }
    }

    /// The hover's snap candidate, unless it cannot answer a pointer at `rawPoint` (W-002).
    ///
    /// A candidate lies within the snap radius of the pointer it was resolved for — a held one
    /// within the radius plus the hysteresis band — and the radius never exceeds the frozen
    /// maximum, so one farther than `(maximum + hysteresis) / zoom` from the click answered
    /// another pointer position: a scroll's re-aim still resolving, or a click no pointer move
    /// preceded. The machine places a click at `snap ?? rawCursor`, so handing it that candidate
    /// put the vertex somewhere the person did not point. No point (Return at the keyboard
    /// cursor, Tab, the A key) keeps the candidate.
    private func hoverSnapCandidate(reaching rawPoint: PDFPointValue?) -> SnapFeedbackSnapshot? {
        guard let feedback = core.canvas.snapFeedback else { return nil }
        guard let rawPoint else { return feedback }
        let zoom = core.canvas.layout.zoom
        guard zoom.isFinite, zoom > 0 else { return feedback }
        let reach = (SnapSettings.specMaximumPixels + SnapSettings.specHysteresisPixels) / zoom
        let distance = hypot(feedback.pagePoint.x - rawPoint.x, feedback.pagePoint.y - rawPoint.y)
        return distance <= reach ? feedback : nil
    }

    /// Sends one decisive event with its gesture and returns what the machine decided.
    @discardableResult
    private func routeMeasurement(
        _ event: MeasurementInputEvent,
        as gesture: CanvasMeasurementDriver.Gesture
    ) -> [MeasurementInputEffect] {
        cutoutParentBeforeEvent = measurementInput.cutoutParent
        measurementDriver.begin(gesture)
        measurementInput.send(event)
        measurementDriver.end()
        let effects = measurementInput.lastEffects
        reportCutoutOutcome(effects)
        return effects
    }

    /// The parent the cutout in progress had before the decisive event, for the status note.
    private var cutoutParentBeforeEvent: CutoutParentCandidate?

    /// Brings the machine in step before the A key decides (NL-MEASURE-05).
    func prepareMeasurementInputForArc() { prepareMeasurementInput(rawPoint: nil) }

    /// The A key's arc toggle, through the machine (NL-MEASURE-05).
    func routeArcToggle() { routeMeasurement(.toggleArcSegment, as: .none) }

    /// Tab / ⇧Tab: the next or the previous snap candidate under the pointer.
    ///
    /// The one implementation: the canvas key and the window's forwarded command both land
    /// here. The machine records the step; the ranked list is the snap engine's, stepped on the
    /// session, and the glyph re-resolves after it. ⇧Tab used to step forward as well, because
    /// neither the key nor the window's command carried a direction (V-071).
    @discardableResult
    func cycleSnapCandidate(forward: Bool) -> Bool {
        guard core.measurement.activeKind != nil else { return false }
        // One candidate, or none, under the pointer: there is nothing to step to, and the step
        // used to change nothing and say nothing (L-71).
        if core.canvas.snapFeedback == nil || core.canvas.snapAlternativeCount == 0 {
            core.status.setActiveToolNote(Self.noOtherSnapCandidateNote)
        }
        prepareMeasurementInput(rawPoint: nil)
        routeMeasurement(.cycleSnapCandidate(forward: forward), as: .none)
        let session = core.session
        let step: SnapModifierInput = forward ? .cycleForward : .cycleBackward
        Task { @MainActor [weak self] in
            _ = await session.applySnapModifier(step)
            guard let self else { return }
            self.resolveHoverSnap(at: self.core.canvas.viewport.cursorPagePoint)
        }
        return true
    }

    /// What Cycle Snap Candidate says when the pointer has no other candidate to step to (L-71).
    static var noOtherSnapCandidateNote: String {
        NSLocalizedString(
            "No other snap candidate under the pointer.",
            comment: "Status note: Cycle Snap Candidate (Tab) was used where only one snap candidate, or none, is in reach"
        )
    }

    /// A measurement click, as the machine decides it: count removal on `⌥`, the three-point
    /// rectangle on `⌥` with an edge placed, and otherwise a point at the snapped,
    /// Shift-constrained cursor — which closes a polygon on its first vertex, completes a
    /// fixed-count tool, and is refused outside a cutout's parent.
    private func routeMeasurementClick(at point: PDFPointValue, optionHeld: Bool, kind: MeasurementKind) {
        dropTypedEntryForPointerPoint()
        prepareMeasurementInput(rawPoint: point)
        let gesture = ZenitToolMode.measure(kind).gesture
        let state = measurementInput.state
        if optionHeld, gesture.isPointPlacement {
            // `⌥` on a count un-places the mark under the cursor rather than adding one.
            // A click that hits nothing is spent.
            let tolerance = measurementInput.configuration.countPointHitTolerance
            let effects = routeMeasurement(
                .removePoint(near: point),
                as: .optionRemoval(point: point, tolerance: tolerance)
            )
            if effects.contains(where: { if case .removePoint = $0 { return true } else { return false } }) {
                refresh()
            }
            return
        }
        if optionHeld, gesture.optionDerivesRectangle {
            let completesRectangle = state.phase == .drawing && state.vertices.count == 2
            routeMeasurement(
                .placeRectangleDepthAtCursor,
                as: completesRectangle ? .optionRectangle : .click(constrained: state.isAngleConstrained)
            )
            return
        }
        routeMeasurement(.placePointAtCursor, as: .click(constrained: state.isAngleConstrained))
    }

    // MARK: - The keyboard cursor (R-137)

    /// Arrow keys while a measurement tool is armed: the keyboard cursor moves one page point in
    /// the arrow's screen direction (Shift: ten), through the display transform so a turned sheet
    /// moves the way the arrow points (spec §21.9, and the keyboard access `ACCESSIBILITY_PLAN.md`
    /// requires). It gets the feedback a pointer move gets — the snap engine, the rubber band, the
    /// close ring — plus a crosshair and a status-bar line, and Return then places a point at it.
    /// `false` when no measurement tool is armed, so the arrows keep nudging the selection or
    /// panning the sheet (IM-166).
    ///
    /// Before this the arrows did nothing while a tool was armed, and a vertex could only be
    /// placed with the pointer.
    func moveKeyboardCursor(dx: Int, dy: Int, large: Bool) -> Bool {
        guard core.measurement.activeKind != nil, core.markup.activeKind == nil,
              activeTextEntry == nil, !isCalibrating else { return false }
        commitLiveZoomIfNeeded()
        guard let transform = pageView.transform else { return false }
        prepareMeasurementInput(rawPoint: nil)
        if !measurementInput.state.isKeyboardCursorActive {
            measurementInput.send(.pointerMoved(keyboardCursorStart))
        }
        let step = Self.nudgePageDelta(dx: dx, dy: dy, points: large ? 10 : 1, transform: transform)
        measurementInput.send(.moveKeyboardCursor(dx: step.x, dy: step.y))
        let cursor = measurementInput.cursor
        resolveHoverSnap(at: cursor)
        core.measurement.updateLiveCursor(constrainedCursor(from: cursor))
        keepKeyboardCursorVisible(cursor, transform: transform)
        refreshLiveFeedback()
        return true
    }

    /// Return while the keyboard cursor leads: a point at the cursor, decided and applied exactly
    /// as a click there — snapped, Shift-constrained, closing on the first vertex, completing a
    /// fixed-count tool through the shell's Finish.
    private func placePointAtKeyboardCursor() {
        guard core.measurement.activeKind != nil else { return }
        prepareMeasurementInput(rawPoint: nil)
        // The machine's own predicate — it holds Shift from `prepareMeasurementInput` — says
        // whether it will hold this point to the Shift ray, so it is stored raw.
        routeMeasurement(.placePointAtCursor, as: .click(constrained: measurementInput.state.isAngleConstrained))
        refresh()
    }

    /// Where the keyboard cursor starts: at the pointer when it is over the sheet, else at the
    /// last placed point, else in the middle of what is on screen.
    private var keyboardCursorStart: PDFPointValue {
        if let pointer = lastRawPointerPoint { return pointer }
        if let last = core.measurement.placedPoints.last { return last }
        let visible = core.canvas.viewport.visiblePageRect
        return PDFPointValue(
            x: visible.origin.x + visible.size.width / 2,
            y: visible.origin.y + visible.size.height / 2
        )
    }

    /// Scrolls just enough to keep the keyboard cursor 24 view points inside what is visible.
    private func keepKeyboardCursorVisible(_ cursor: PDFPointValue, transform: PageDisplayTransform) {
        let point = transform.viewPoint(from: cursor)
        let visible = pageView.visibleRect.insetBy(dx: 24, dy: 24)
        guard visible.width > 0, visible.height > 0, !visible.contains(point) else { return }
        pageView.scrollToVisible(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
    }

    /// The keyboard cursor the overlay draws: the machine's cursor while it leads a measurement.
    private var drawnKeyboardCursor: PDFPointValue? {
        guard core.markup.activeKind == nil, core.measurement.activeKind != nil,
              measurementInput.state.returnPlacesPoint else { return nil }
        return measurementInput.cursor
    }

    /// Places a typed segment's end point exactly where it was computed (NL-MEASURE-18): no snap
    /// and no Shift ray, stored raw like a constrained click.
    func placeTypedMeasurementPoint(_ point: PDFPointValue) {
        prepareMeasurementInput(rawPoint: point)
        measurementInput.send(.setSnapCandidates([]))
        measurementInput.send(.setModifiers([]))
        measurementInput.send(.pointerMoved(point))
        routeMeasurement(.placePointAtCursor, as: .click(constrained: true))
        refresh()
    }

    /// The last placed vertex and the leading raw point, for a typed segment's anchor and
    /// direction.
    var typedSegmentAnchor: (anchor: PDFPointValue, pointer: PDFPointValue?)? {
        guard let anchor = core.measurement.placedPoints.last else { return nil }
        return (anchor, leadingRawPoint)
    }

    /// The raw point that leads the drawing: the keyboard cursor while it leads a measurement
    /// (R-137), the pointer otherwise. Shift's rubber band, a typed length's direction, the
    /// Shift angle in the pill and the snap-glyph filter all follow it, so the preview matches
    /// what Return places (S-002). They read the mouse's last position — or nothing once the
    /// pointer had left the canvas — so Shift+arrow pulled the rubber band to the mouse and a
    /// typed length drawn from the keyboard alone was refused for want of a direction.
    var leadingRawPoint: PDFPointValue? {
        if core.markup.activeKind == nil, core.measurement.activeKind != nil,
           measurementInput.state.isKeyboardCursorActive {
            return measurementInput.cursor
        }
        return lastRawPointerPoint
    }

    /// Speaks a cutout's parent or refusal in the status bar and hands the parent to the
    /// presenter, whose commit sends the hole to `DocumentCommand.addCutout`.
    private func reportCutoutOutcome(_ effects: [MeasurementInputEffect]) {
        guard measurementInput.state.kind?.requiresParentArea == true else { return }
        let refused = effects.contains { if case .rejectFinish = $0 { return true } else { return false } }
        if refused, let reason = measurementInput.cutoutRefusal {
            core.status.setActiveToolNote(reason.message)
            return
        }
        guard cutoutParentBeforeEvent == nil, let parent = measurementInput.cutoutParent else { return }
        core.measurement.cutoutParentID = MarkupID(parent.markupID)
        core.status.setActiveToolNote(
            String(
                format: NSLocalizedString(
                    "Cutting out of %@.",
                    comment: "Status bar note naming the area a cutout will subtract from"
                ),
                parent.displayName
            )
        )
    }

    /// A calibration click: the machine counts the two reference points; the driver snaps and
    /// constrains each one exactly as ``placeCalibrationPoint(at:)`` always has.
    private func routeCalibrationClick(at point: PDFPointValue) {
        if calibrationPlacementsInFlight == 0 {
            calibrationInput.synchronize(kind: .length, vertices: calibrationPoints, cutoutParentID: nil)
        }
        // An explicit point: the snap is resolved on the session and Shift applied after it,
        // so the machine must not snap or constrain it first.
        calibrationInput.send(.placePoint(point))
    }

    // MARK: - Markup tools (Text, Callout, Shapes)

    /// One click of a markup tool.
    ///
    /// The whole grammar comes from ``ZenitToolGesture``, so Text, Callout and the seven
    /// shapes share this one function rather than having nine special cases: a fixed
    /// completing count finishes on its last click, a closing polygon finishes on its first
    /// vertex, and everything else keeps collecting until the user says stop.
    func handleMarkupClick(at point: PDFPointValue, kind: ZPDFUIPresentation.MarkupKind) {
        let gesture = markupGesture(for: kind)
        guard gesture.collectsPoints else { return }
        if gesture.closesOnFirstVertex, firstVertexCloseTarget(probe: point) != nil {
            finishMarkup()
            return
        }
        var placed = point
        if isShiftHeld, core.markup.placedPoints.last != nil {
            placed = markupConstrainedCursor(from: point)
        }
        core.markup.placePoint(placed)
        if let completing = gesture.completingPointCount,
           core.markup.placedPoints.count >= completing {
            finishMarkup()
            return
        }
        refresh()
    }

    /// A markup drag begins: the press is the anchor corner.
    func handleMarkupDragBegan(at point: PDFPointValue, kind: ZPDFUIPresentation.MarkupKind) {
        let gesture = markupGesture(for: kind)
        guard gesture.usesDragGesture else { return }
        if kind == .callout {
            // Phase two of a callout: the target is already placed and the drag sizes the
            // box. Dragging straight from the target places it and sizes the box in one
            // gesture, which is the same shape of interaction, one click shorter.
            if core.markup.placedPoints.isEmpty { core.markup.placePoint(point) }
            core.markup.setPoints([core.markup.placedPoints[0], point])
        } else {
            core.markup.setPoints([point])
        }
        dragAnchorPoint = point
        refresh()
    }

    /// A markup drag ends: the release is the opposite corner, and the shape finishes.
    func handleMarkupDragEnded(at point: PDFPointValue, kind: ZPDFUIPresentation.MarkupKind) {
        guard let anchor = dragAnchorPoint else { return }
        dragAnchorPoint = nil
        let release = isShiftHeld ? markupConstrainedCursor(from: point) : point
        if kind == .freehand {
            // Pen and Highlighter: the samples are the stroke; the release is its last point.
            core.markup.appendFreehandPoint(point)
            finishMarkup()
            return
        }
        if kind == .callout {
            let target = core.markup.placedPoints.first ?? anchor
            core.markup.setPoints([target, anchor, release])
        } else {
            core.markup.setPoints([anchor, release])
        }
        finishMarkup()
    }

    /// Finishes the markup in progress: text tools open their editor, everything else
    /// commits on the spot (enough input means no confirmation step).
    func finishMarkup() {
        guard let kind = core.markup.activeKind else { return }
        guard markupGesture(for: kind).needsTextEntry else {
            commitMarkup()
            return
        }
        beginTextEntry(kind: kind)
    }

    /// Commits the markup in progress through the document command bus, and returns to
    /// Select unless Reuse Tool is on — or unless `keepingTool`, when the commit is the side
    /// effect of the person choosing another tool (L-10), whose choice stands.
    func commitMarkup(keepingTool: Bool = false) {
        let record = core.markup.commit()
        let committed = record != nil
        endTextEditor()
        let scale = activeTextEntry?.editing == nil ? (activeTextEntry?.textScale ?? 1) : 1
        activeTextEntry = nil
        restoreMarkupStyleAfterTextEntry(scale: scale)
        // Reuse Tool is read here, live, from the Tool Library presenter the status-bar
        // switch writes to — not from a copy taken when the tool was armed. The decision
        // itself belongs to `markupCommitted()`, which the measurement family asks too, so
        // the switch cannot be honoured by one family and ignored by the other.
        if committed, !core.toolLibrary.markupCommitted(), !keepingTool {
            toolbar.selectTool(.select)
        }
        if let record, record.kind == .hyperlink { askForLinkDestination(of: record.id.rawValue) }
        refresh()
    }

    /// A link box just drawn is selected and asked where it leads (L-101). It used to be drawn
    /// with no destination and nothing asking for one, and Edit ▸ Edit Link… needs the box
    /// selected — which a click inside its frame could not do — so a link could never get a
    /// target. Runs once the box is in the document, so Edit Link finds it.
    func askForLinkDestination(of id: UUID) {
        let core = self.core
        Task { @MainActor [weak self] in
            // The commit travels the command bus on its own task; the box is asked about once
            // the snapshot holds it, and not at all when the commit was refused.
            for _ in 0..<80 where !core.snapshot.markups.contains(where: { $0.id == id }) {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let self, core.snapshot.markups.contains(where: { $0.id == id }) else { return }
            core.canvas.select(markupIDs: [id], additive: false)
            MarkupRound2Actions.editLink(core, window: self.view.window)
        }
    }

    /// Throws away the markup in progress and returns to Select unless Reuse Tool is on.
    func cancelMarkup() {
        core.markup.cancel()
        endTextEditor()
        let scale = activeTextEntry?.editing == nil ? (activeTextEntry?.textScale ?? 1) : 1
        activeTextEntry = nil
        restoreMarkupStyleAfterTextEntry(scale: scale)
        refresh()
    }

    // MARK: - In-canvas text entry

    /// Opens a text box with the caret already in it.
    ///
    /// An editable text box appears **with the caret already in it**; typing shows; Escape or
    /// clicking away commits; empty text discards the markup rather than leaving an invisible
    /// one.
    ///
    /// The box is normalised into the stored schema here, so the record's geometry and the
    /// editor's frame are the same rectangle by construction.
    /// One-click auto-trace: walk the boundary around the click and commit it as an area.
    ///
    /// The walk is `RegionTracer` on the same extraction the snap index and
    /// the vector underlay are built from — one scan, three uses. Every refusal is spoken in the
    /// status bar rather than swallowed, because auto-trace must never bridge a gap silently:
    /// a region that is not closed is *named*, with where it gave up, and nothing is committed.
    ///
    /// The traced ring goes through `appendRawPoints` + the ordinary commit, so the resulting
    /// markup is an area like any other: same command, same audit entry, same undo, same ledger
    /// row. Nothing downstream knows it was traced.
    ///
    /// `unionInto` is the area a ⇧⌥-click adds the traced room to, captured at the click (V-009).
    func autoTraceArea(at point: PDFPointValue, unionInto unionTarget: UUID? = nil) {
        guard let page = core.document.currentPage else { return }
        let pageID = page.id
        let pageIndex = page.index
        autoTraceGeneration &+= 1
        let generation = autoTraceGeneration
        clearAutomationProposal()
        // The walk runs off the main actor on a prepared page (NL-AUTO-01): the click used to
        // flatten every primitive on the sheet again, synchronously, before the walk started.
        autoTraceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let extracted = await self.autoTraceExtraction(pageID: pageID, pageIndex: pageIndex)
            // r2-platform (NL-AUTO-14): a scanned sheet has no vector linework; the trace reads
            // the pixels instead, and the area records that it came from the scan.
            if extracted?.primitives.isEmpty ?? true,
               await self.autoTraceOnScan(at: point, pageID: pageID, pageIndex: pageIndex,
                                          isCurrent: { [weak self] in self?.autoTraceGeneration == generation }) {
                return
            }
            guard let extraction = extracted else {
                guard self.autoTraceGeneration == generation else { return }
                self.core.status.setActiveToolNote(NSLocalizedString(
                    "Not traced: this page's vector geometry is not available yet.",
                    comment: "Auto-trace refusal: no extraction for the current page"
                ))
                return
            }
            // What the person can see and measure on: hidden layers, and under a measure lock
            // every other layer, are structurally absent from the walk — the rule the snap
            // index follows (S23). A line the person switched off can no longer split the room.
            var filter = self.automationContext?.traceChoices() ?? .none
            filter.hiddenLayerIDs = self.automationContext?.traceHiddenLayerIDs(pageID, pageIndex)
                ?? self.layerFiltering?.hiddenLayerIDs ?? []
            let prepared = await self.autoTraceService.prepared(pageID: pageID, extraction: extraction, filter: filter)
            let metresPerPoint = await self.metresPerPoint(pageID: pageID)
            let cap = AutoTraceService.maximumClosureWidth(metresPerPoint: metresPerPoint)
            // NL-MEASURE-11: the fence lines the person drew on this page close openings too.
            let fenced = await Self.traceWithFences(
                prepared, click: PDFPoint(x: point.x, y: point.y),
                fences: self.traceFences[pageID] ?? [], maximumClosureWidth: cap
            )
            // A later click, a page turn or a disarmed tool supersedes this answer.
            guard self.autoTraceGeneration == generation,
                  self.core.document.currentPage?.id == pageID,
                  self.core.measurement.activeKind.map(Self.traceableKinds.contains) == true,
                  self.core.measurement.placedPoints.isEmpty
            else { return }
            self.applyAutoTrace(fenced.outcome, filter: filter, metresPerPoint: metresPerPoint, fencesUsed: fenced.fencesUsed, unionInto: unionTarget)
        }
    }

    /// The extraction auto-trace walks: the canvas's own when it is this page's and stands in for
    /// a layer-aware one, otherwise the document's layer-aware store.
    private func autoTraceExtraction(pageID: UUID, pageIndex: Int) async -> VectorPageExtraction? {
        if let underlayExtraction, let underlayPage, underlayPage.id.rawValue == pageID,
           automationContext?.underlayIsLayerComplete() ?? true {
            return underlayExtraction
        }
        return await automationContext?.extraction(pageID, pageIndex)
    }

    /// Metres of real world per page point on a calibrated page, or `nil`.
    private func metresPerPoint(pageID: UUID) async -> Double? {
        guard let scale = await core.session.scale(onPage: PageID(pageID)) else { return nil }
        let origin = scale.matrix.map(PDFPoint(x: 0, y: 0))
        let unit = scale.matrix.map(PDFPoint(x: 1, y: 0))
        let value = origin.distance(to: unit)
        return value.isFinite && value > 0 ? value : nil
    }

    private func applyAutoTrace(
        _ outcome: OpeningAwareTraceResult, filter: TraceFilter, metresPerPoint: Double?,
        fencesUsed: [ProposedClosure] = [], unionInto unionTarget: UUID? = nil
    ) {
        let filterNote = AutoTraceWording.filterNote(filter)
        switch outcome {
        case .traced(let region):
            // NL-MEASURE-11: ⇧⌥-click with one area selected adds the face to it.
            if let unionTarget {
                unionTracedFace(region.ring, into: unionTarget)
                return
            }
            core.measurement.appendRawPoints(region.ring.map { PDFPointValue(x: $0.x, y: $0.y) })
            // r2-platform, ADR-0031: the area records that it was traced — and, NL-MEASURE-11,
            // every fence line a person drew that it closed across.
            core.measurement.markPlacedPointsCaptured(as: .autoTraced(closureWidthsPoints: fencesUsed.map(\.width)))
            core.measurement.commitActiveMeasurement()
            core.status.setActiveToolNote(Self.fenceNote(fencesUsed, appendedTo: AutoTraceWording.tracedNote(region, filterNote: filterNote)))
            // Islands inside the room are offered as cutouts, never deducted unasked (NL-AUTO-10).
            // Islands inside the room are offered as cutouts and the room's printed name as its
            // subject — offers only, never applied unasked (NL-AUTO-10, NL-AUTO-21).
            if let pageID = core.document.currentPage?.id {
                automationContext?.offerIslands(PageID(pageID), region.ring, region.islands, metresPerPoint)
            }
        case .closesOpenings(let proposal):
            // Proposed, not committed: the ring is placed as the area in progress, the closing
            // lines are drawn dashed, and Return commits it through the ordinary Finish — same
            // command, same undo. Escape cancels it. Nothing was closed that the person did not
            // see and accept.
            core.measurement.appendRawPoints(proposal.region.ring.map { PDFPointValue(x: $0.x, y: $0.y) })
            // r2-platform, ADR-0031: accepted as proposed, the area records each closing line.
            core.measurement.markPlacedPointsCaptured(as: .autoTraced(closureWidthsPoints: proposal.closures.map(\.width)))
            pageView.automationOverlay = CanvasAutomationOverlay(proposal: proposal)
            pendingOpeningProposal = proposal
            core.status.setActiveToolNote(AutoTraceWording.proposalNote(
                proposal, metresPerPoint: metresPerPoint, filterNote: filterNote
            ))
        case .refused(let result):
            switch result {
            case .traced(let region):
                core.measurement.appendRawPoints(region.ring.map { PDFPointValue(x: $0.x, y: $0.y) })
                core.measurement.markPlacedPointsCaptured(as: .autoTraced(closureWidthsPoints: []))
                core.measurement.commitActiveMeasurement()
                core.status.setActiveToolNote(AutoTraceWording.tracedNote(region, filterNote: filterNote))
            case .notClosed(let gap):
                // Show where it gave up, when it knows: the gap point becomes the snap glyph for
                // a moment, which is the cheapest "look here" the canvas has.
                if let gap {
                    pageView.snapPoint = PDFPointValue(x: gap.x, y: gap.y)
                }
                core.status.setActiveToolNote(AutoTraceWording.notClosedNote(filterNote: filterNote))
            case .tooComplex:
                core.status.setActiveToolNote(AutoTraceWording.tooComplexNote())
            }
        }
        refresh()
    }

    /// Shows or clears automation's highlights on the sheet (the symbol review's hits and near
    /// misses). An opening proposal owns the overlay while it is pending.
    func setAutomationOverlay(_ overlay: CanvasAutomationOverlay?) {
        guard pendingOpeningProposal == nil else { return }
        pageView.automationOverlay = overlay
    }

    /// The overlay on the sheet right now. Test seam.
    var automationOverlayForTesting: CanvasAutomationOverlay? { pageView.automationOverlay }

    /// Clears a proposal the person has accepted, cancelled or walked away from.
    func clearAutomationProposal() {
        pendingOpeningProposal = nil
        pageView.automationOverlay = nil
    }

    /// Waits for the in-flight auto-trace, so a test asserts on the answer rather than a sleep.
    func settleAutoTrace() async {
        while let task = autoTraceTask {
            let generation = autoTraceGeneration
            await task.value
            guard autoTraceGeneration == generation else { continue }
            autoTraceTask = nil
        }
    }

    /// Places one calibration reference point — **snapped**, like every other placed point.
    ///
    /// Calibration once did not snap at all, and it was not a near miss: this branch took
    /// `point` straight from the click and appended it.
    /// Every other placement in the product goes through `TakeoffSession.resolveSnap`; calibration
    /// was the one that did not.
    ///
    /// It matters more here than anywhere else. Calibration is the step every later number is
    /// derived from, and it is measured between two points the estimator picks off a dimension
    /// line — exactly the endpoints vector snap exists to find. A calibration two pixels off
    /// scales the whole sheet by that error, silently, so both calibration picks snap to the
    /// dimension line's endpoints.
    ///
    /// Asynchronous for the same reason `AppMeasurementToolPresenter.placePoint` is: the resolve
    /// is. The task chain keeps two fast clicks in order, so the second reference point cannot
    /// land before the first.
    private func placeCalibrationPoint(at point: PDFPointValue) {
        guard let pageID = core.document.currentPage?.id else { return }
        let anchor = calibrationPoints.last.map { PDFPoint(shown: $0) }
        let layout = core.measurement.layout
        let session = core.session
        let cursor = PDFPoint(shown: point)
        // `⌘` held at the click suspends the snap for this pick too (V-070).
        let modifiers: SnapModifiers = isCommandHeld ? .command : .none
        // Ink the ledger filter's Hide took off the sheet is no target for this pick (V-003).
        let excluded = core.canvas.snapExcludedMarkupIDs
        let previous = calibrationPlacementTask
        onCalibrationClick?(calibrationPoints.count + calibrationPlacementsInFlight)
        calibrationPlacementGeneration &+= 1
        calibrationPlacementsInFlight += 1

        calibrationPlacementTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.calibrationPlacementsInFlight -= 1 }
            guard self.isCalibrating else { return }
            let resolution = try? await session.resolveSnap(
                pageID: PageID(pageID),
                pagePoint: cursor,
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchor,
                excludingMarkupIDs: excluded
            )
            let snapped = resolution.map { PDFPointValue(domain: $0.resolvedPagePoint) } ?? point
            self.appendCalibrationPoint(snapped)
        }
    }

    /// Appends a resolved calibration point, applying the Shift constraint to it.
    ///
    /// Shift is applied *after* the snap rather than instead of it: holding Shift says "keep this
    /// straight", not "ignore the geometry". Constraining the snapped point honours both, and
    /// when nothing was in snap range the snapped point is the raw one, so the old behaviour is
    /// the limiting case rather than a separate path.
    private func appendCalibrationPoint(_ point: PDFPointValue) {
        // The hover's perpendicular and tangent candidates are measured from the last collected
        // point (`hoverSnapAnchor`, read at every resolve — W-001).
        var collectedPoint = point
        // Shift holds the second reference point straight too — calibration is a
        // segment-drawing context like any other.
        if isShiftHeld, let anchor = calibrationPoints.last {
            collectedPoint = MeasurementInputStateMachine.constrain(
                point,
                to: anchor,
                incrementDegrees: Self.shiftAngleIncrementDegrees
            )
        }
        calibrationPoints.append(collectedPoint)
        pageView.calibrationPoints = calibrationPoints
        if calibrationPoints.count == 2 {
            let collected = calibrationPoints
            endCalibration(collected: true)
            onCalibrationPointsCollected?(collected)
        } else {
            // The first pick runs no refresh, and it is the anchor of the second (W-001).
            reresolveHoverIfAnchorMoved()
        }
    }

    /// Waits for every in-flight calibration placement, so a test does not have to guess at
    /// run-loop turns. Mirrors `AppMeasurementToolPresenter.settlePlacements()`.
    public func settleCalibrationPlacements() async {
        // A generation counter rather than an identity check: `Task` is a value type, so the
        // "is this still the task I awaited" question has to be asked about a number.
        while let task = calibrationPlacementTask {
            let generation = calibrationPlacementGeneration
            await task.value
            guard calibrationPlacementGeneration == generation else { continue }
            calibrationPlacementTask = nil
        }
    }

    func beginTextEntry(kind: ZPDFUIPresentation.MarkupKind) {
        let points = core.markup.placedPoints
        // L-49: zoomed out, the words are stored large enough to read at this zoom. The scale is
        // taken against the toolbar's own size, so a box typed right after a scaled one is not
        // scaled twice.
        let textScale = kind == .note ? 1 : Self.textCreationScale(zoom: Double(pageView.transform?.zoom ?? 1))
        if textScale != 1 {
            let selection = toolbar.activeSelection
            var style = core.markup.style
            if case .markup(let armed) = selection.mode, armed == kind { style = selection.style }
            style.fontSize *= textScale
            core.markup.activate(kind: kind, style: style, variant: core.markup.variant)
        }
        let fontSize = core.markup.style.fontSize
        let box: PDFRectValue
        var target: PDFPointValue?
        switch kind {
        case .text:
            guard let first = points.first else { return }
            box = points.count >= 2
                ? ZenitMarkupGeometry.boundingRect(first, points[1])
                : ZenitMarkupGeometry.defaultTextBox(at: first, fontSize: fontSize)
            core.markup.setPoints([
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            ])
        case .callout:
            guard points.count >= 2 else { return }
            box = points.count >= 3
                ? ZenitMarkupGeometry.boundingRect(points[1], points[2])
                : ZenitMarkupGeometry.defaultTextBox(at: points[1], fontSize: fontSize)
            target = points[0]
            core.markup.setPoints([
                points[0],
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            ])
        case .cloud:
            // A clouded callout (ADR-0029 §2.4): the drag drew the cloud; the box and the
            // leader's target are placed beside it and the caret goes in the box.
            guard points.count >= 2 else { return }
            let placement = AppMarkupToolPresenter.cloudedCalloutPlacement(
                ring: points[0], points[1], fontSize: fontSize
            )
            box = placement.box
            target = placement.target
            core.markup.setPoints([
                points[0], points[1], placement.target,
                PDFPointValue(x: box.minX, y: box.minY),
                PDFPointValue(x: box.maxX, y: box.maxY)
            ])
        case .note:
            // A note (NL-MARKUP-17): a 20 pt icon at the click; its words are typed in place.
            guard let first = points.first else { return }
            let side = AppMarkupToolPresenter.noteSide
            core.markup.setPoints([first, PDFPointValue(x: first.x + side, y: first.y - side)])
            box = PDFRectValue(x: first.x, y: first.y - side * 4, width: side * 8, height: side * 3)
        default:
            return
        }
        // A zero-area drag would leave a caret nobody can see.
        let usable = box.size.width < 8 || box.size.height < 8
            ? ZenitMarkupGeometry.defaultTextBox(
                at: PDFPointValue(x: box.minX, y: box.minY),
                fontSize: fontSize
            )
            : box
        if usable != box {
            let corners = [
                PDFPointValue(x: usable.minX, y: usable.minY),
                PDFPointValue(x: usable.maxX, y: usable.maxY)
            ]
            core.markup.setPoints(kind == .callout ? [points[0]] + corners : corners)
        }
        core.markup.setDraftText("")
        activeTextEntry = TextEntry(kind: kind, box: usable, target: target, textScale: textScale)
        installTextEditor()
        refresh()
    }

    /// Test helper that types into the open text box and updates the draft.
    public func typeIntoTextEntry(_ text: String) {
        guard activeTextEntry != nil else { return }
        core.markup.setDraftText(text)
        if let textEditor, textEditor.string != text { textEditor.string = text }
    }

    /// Commits the open text box. Empty text discards the markup instead.
    ///
    /// `keepingTool` is the tool switch's commit (L-10): the words are kept and the tool the
    /// person chose stays armed, rather than Reuse Tool's return to Select overriding it.
    public func commitTextEntry(keepingTool: Bool = false) {
        guard activeTextEntry != nil else { return }
        if activeTextEntry?.editing != nil {
            finishInPlaceTextEdit(commit: true)
            return
        }
        if core.markup.canCommit {
            commitMarkup(keepingTool: keepingTool)
        } else {
            cancelMarkup()
        }
    }

    func installTextEditor() {
        endTextEditor()
        guard let entry = activeTextEntry, let transform = pageView.transform else { return }
        // The committed markup lives in page space, but the EDITOR is for the person's
        // eyes and fingers: at 11% zoom the page-space box came out 2–3 view pixels tall,
        // so typing into a Callout was a one-pixel dash and nobody could tell whether the
        // text landed (LT-39, 2026-08-29). The box is floored to a readable size on
        // screen; the stored markup keeps the page-space box untouched.
        let frame = Self.readableEditorFrame(transform.viewRect(from: entry.box))
        let editor = CanvasTextEditor(frame: frame)
        editor.font = NSFont.systemFont(ofSize: editorPointSize(entry: entry, transform: transform))
        editor.onTextChange = { [weak self] text in self?.core.markup.setDraftText(text) }
        editor.onCommit = { [weak self] in self?.commitTextEntry() }
        pageView.addSubview(editor)
        textEditor = editor
        // The caret, already in it.
        view.window?.makeFirstResponder(editor)
    }

    /// Test seam: the installed text editor, so a test can ask whether it is first responder and
    /// whether a keystroke reaches it — the two questions the controller-level seams cannot.
    var textEditorForTesting: CanvasTextEditor? { textEditor }

    /// Test seam: how many areas the cutout tool currently believes it could cut out of.
    ///
    /// Zero while an area is plainly on the page means the scene has not been rebuilt
    /// since that area was committed, and every cutout started inside it will be refused
    /// as "outside every area".
    var cutoutCandidateCountForTesting: Int { cutoutCandidates.count }

    /// Test seam: the snap ring's page point, or `nil` while no snap is shown.
    var snapGlyphForTesting: PDFPointValue? { pageView.snapPoint }

    /// Test seam: the live calibration cursor, or `nil` outside calibration.
    var calibrationCursorForTesting: PDFPointValue? { pageView.calibrationCursor }

    /// Test seam: how many committed records the scene currently holds.
    var sceneRecordCountForTesting: Int { sceneRecords.count }

    /// The coverage overlay the page view is drawing, for the toggle's window-level test.
    var coverageOverlayForTesting: CanvasPageView.CoverageOverlay? { pageView.coverageOverlay }

    /// Test seam: whether the vector extraction has reached the canvas, which auto-trace needs.
    var hasUnderlayExtractionForTesting: Bool { underlayExtraction != nil }

    /// The extraction the canvas holds for a page, when it holds that page's (nl-automation):
    /// automation reuses it rather than asking the extraction service again.
    func heldExtraction(forPageID pageID: UUID) -> VectorPageExtraction? {
        guard let underlayPage, underlayPage.id.rawValue == pageID else { return nil }
        return underlayExtraction
    }

    /// Test seam: how many times `refresh()` has run.
    var refreshCountForTesting = 0

    private func layoutTextEditor() {
        guard let editor = textEditor, let entry = activeTextEntry,
              let transform = pageView.transform else { return }
        editor.frame = Self.readableEditorFrame(transform.viewRect(from: entry.box))
        // A zoom re-sizes the text too, not only the box (IM-243).
        let size = editorPointSize(entry: entry, transform: transform)
        if editor.font?.pointSize != size { editor.font = NSFont.systemFont(ofSize: size) }
    }

    /// The editor previews the size the text will be drawn at once committed — the style's
    /// size at this zoom, clamped to the box — floored at 11 pt so a far zoom is still typable.
    private func editorPointSize(entry: TextEntry, transform: PageDisplayTransform) -> CGFloat {
        let committed = CanvasPageView.markupTextPointSize(
            requested: core.markup.style.fontSize * Double(transform.zoom),
            boxHeight: transform.viewRect(from: entry.box).height
        )
        return max(11, committed)
    }

    /// The editor's frame on screen, never smaller than a person can type into.
    ///
    /// The committed markup lives in page space, but the EDITOR is for eyes and fingers: at
    /// 11–43 % zoom the page-space box comes out a few view points tall and the typed line
    /// wraps one letter per row (LT-39, and still wrong on retest as RT-6 because
    /// `layoutTextEditor` re-applied the raw rect on every refresh — the floor has to live
    /// in one place both callers use). The stored markup keeps the page-space box untouched.
    static func readableEditorFrame(_ rect: NSRect) -> NSRect {
        let minimum = NSSize(width: 180, height: 26)
        var frame = rect
        if frame.width < minimum.width {
            frame.origin.x -= (minimum.width - frame.width) / 2
            frame.size.width = minimum.width
        }
        if frame.height < minimum.height {
            frame.origin.y -= (minimum.height - frame.height) / 2
            frame.size.height = minimum.height
        }
        return frame
    }

    func endTextEditor() {
        guard let editor = textEditor else { return }
        // Cleared first: the editor commits when it resigns first responder, and tearing it
        // down must not re-enter the commit that is tearing it down.
        editor.onCommit = nil
        editor.onTextChange = nil
        if editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(pageView)
        }
        editor.removeFromSuperview()
        textEditor = nil
    }

    /// A secondary click — two-finger trackpad tap or right mouse button — finishes the
    /// measurement in progress. Returns whether it was consumed.
    ///
    /// A polygon with three or more vertices closes and commits; a polylength with two or
    /// more finishes as placed. With fewer points the tap does nothing — it never cancels
    /// work and never commits degenerate geometry. While a measurement tool is armed the
    /// click is always consumed, so a context menu never appears mid-measurement.
    func handleSecondaryClick() -> Bool {
        // A calibration pick — and Verify Scale, Curve an Edge and a fence line, which borrow
        // it — and a snippet region are measurements in progress too: the tap is swallowed, so
        // no menu opens and the selection does not change between the reference clicks (V-014).
        if isCalibrating || isCapturingSnippetRegion { return true }
        if let markupKind = core.markup.activeKind {
            let gesture = ZenitToolMode.markup(markupKind).gesture
            // Only variable-vertex markups finish this way, and only with enough vertices;
            // the tap never cancels work and never commits a degenerate shape.
            if gesture.completingPointCount == nil,
               core.markup.placedPoints.count >= gesture.minimumPointCount {
                finishMarkup()
            }
            return true
        }
        guard core.measurement.activeKind != nil else { return false }
        prepareMeasurementInput(rawPoint: nil)
        routeMeasurement(.secondaryClick, as: .secondaryClick)
        return true
    }

    /// Double-click closes a variable-vertex geometry (polygon area, polylength).
    ///
    /// The first click of the pair already placed a vertex; if it duplicated the previous
    /// one the machine drops it before the commit, so the polygon does not carry a zero-length
    /// edge (CR-176). A double-click means nothing to Count (CR-177).
    /// Internal rather than private so a test can double-click the shipping controller (IM-019).
    func handleDoubleClick(at point: PDFPointValue) {
        // r2-markup (NL-MARKUP-08): double-click a text box, callout, clouded callout or note
        // with the pointer tool to edit its words in place.
        if armedMode == .select, core.markup.activeKind == nil, core.measurement.activeKind == nil,
           beginInPlaceTextEdit(at: point) { return }
        if let markupKind = core.markup.activeKind {
            let gesture = ZenitToolMode.markup(markupKind).gesture
            guard gesture.completingPointCount == nil,
                  core.markup.placedPoints.count >= gesture.minimumPointCount else { return }
            finishMarkup()
            return
        }
        guard let kind = core.measurement.activeKind else { return }
        // A double-click over an armed tool with nothing drawn means nothing (L-105). It is the
        // second press of the pair whose first press just closed a shape — Reuse Tool re-armed
        // the tool in between — and it used to reach Finish, which said "Polygon Cutout needs 3
        // more points" over an empty, freshly armed tool.
        guard !core.measurement.placedPoints.isEmpty || core.measurement.hasPlacementsInFlight else { return }
        prepareMeasurementInput(rawPoint: point)
        let tolerance = measurementInput.configuration.firstVertexCloseTolerance
        routeMeasurement(.doubleClick, as: .doubleClick(duplicateTolerance: tolerance))
        // A double-click the machine refused — too few points — still reaches the shell, which
        // speaks the refusal exactly as it always has and stays the last gate on the commit.
        if !measurementDriver.committedThisEvent, kind.completingPointCount == nil,
           !kind.usesDragGesture, !kind.isPointPlacement {
            measurementDriver.forwardDoubleClickFinish(duplicateTolerance: tolerance)
        }
    }

    // MARK: - One-gesture drag tools (rectangle area: press, drag, release)

    func handleDragBegan(at point: PDFPointValue) {
        if let markupKind = core.markup.activeKind {
            handleMarkupDragBegan(at: point, kind: markupKind)
            return
        }
        if armedMode == .select, !isCalibrating {
            // NL-MEASURE-09: a press on a selected measurement's caption drags the caption.
            if beginCaptionDrag(at: point) { return }
            beginSelectDrag(at: point)
            return
        }
        guard core.measurement.activeKind != nil else { return }
        // LT3-05, the press-drag tools' half; L-102, the scale where the press lands.
        if core.measurement.placedPoints.isEmpty, core.measurement.refusesForMissingScale(at: point) { return }
        dropTypedEntryForPointerPoint()
        prepareMeasurementInput(rawPoint: point)
        // The machine decides: a fresh press places the snapped anchor (resolving a cutout's
        // parent first); a press on a shape already being placed click by click continues it.
        let effects = routeMeasurement(.dragBegan(point), as: .dragPress)
        if effects.contains(where: { if case .placePoint = $0 { return true } else { return false } }) {
            refresh()
        }
    }

    func handleDragMoved(to point: PDFPointValue) {
        lastRawPointerPoint = point
        // A press-drag measurement (a rectangle area, a drag-placed corner) arrives here, not
        // through `handlePointerMove`, and the lens froze at the press (V-006).
        if loupeApplies { updateLoupe(at: point) }
        resolveHoverSnap(at: point)
        if moveCaptionDrag(to: point) { return }   // NL-MEASURE-09
        if selectDrag != nil {
            updateSelectDrag(to: point)
            return
        }
        if core.markup.activeKind != nil {
            // Pen and Highlighter sample the drag (NL-MARKUP-06). The stroke in progress is the
            // live overlay's (observed `placedPoints`); the page view's committed ink does not
            // change, and repainting it per sample was a full ink pass at pointer rate (V-005).
            if core.markup.activeKind == .freehand, dragAnchorPoint != nil {
                core.markup.appendFreehandPoint(point)
            }
            core.markup.updateLiveCursor(markupConstrainedCursor(from: point))
            return
        }
        guard core.measurement.activeKind != nil else { return }
        measurementInput.send(.dragMoved(point))
        guard measurementDragAnchor != nil else {
            core.measurement.updateLiveCursor(constrainedCursor(from: point))
            return
        }
        core.measurement.updateLiveCursor(point)
        pageView.liveCursorPoint = point
    }

    func handleDragEnded(at point: PDFPointValue) {
        if let markupKind = core.markup.activeKind {
            handleMarkupDragEnded(at: point, kind: markupKind)
            return
        }
        if endCaptionDrag(at: point) { return }   // NL-MEASURE-09
        if selectDrag != nil {
            endSelectDrag(at: point)
            return
        }
        guard let kind = core.measurement.activeKind else {
            dragAnchorPoint = nil
            return
        }
        prepareMeasurementInput(rawPoint: point)
        guard measurementInput.state.dragPressPoint != nil else {
            // No drag of the machine's is in progress. On a click-placing tool with a shape
            // under way that press continued the shape, and its release is the next point:
            // it goes through the click path, where the polygon, the close-on-first-vertex
            // rule and the derived fourth corner all live.
            let gesture = ZenitToolMode.measure(kind).gesture
            if gesture.usesDragGesture, gesture.dragAlsoPlacesClicks,
               !measurementInput.state.vertices.isEmpty {
                handleClick(at: point, additive: isShiftHeld, optionHeld: isOptionHeld)
            }
            return
        }
        let effects = routeMeasurement(.dragEnded(point), as: .dragRelease)
        // A cutout whose far corner leaves the parent is refused with the same words the click
        // path uses, and the drag is abandoned rather than left hanging on its anchor.
        let refused = effects.contains { if case .rejectFinish = $0 { return true } else { return false } }
        if refused, measurementInput.state.phase == .drawing {
            routeMeasurement(.cancel, as: .abandonDrag)
            refresh()
        }
    }

    /// Topmost markup whose outline, fill, count mark or text box contains the point.
    ///
    /// The rule lives in ``CanvasHitTesting`` so it can be asserted without a window. It
    /// used to be `shape.bounds` padded by six screen points, which meant a click in the
    /// notch of an L-shaped area — inside its box, outside its polygon — selected it.
    func hitTest(_ point: PDFPointValue) -> UUID? {
        let tolerance = core.canvas.viewport.pageDistance(forViewPoints: 6)
        let zoom = core.canvas.viewport.zoom
        // ADR-0032: a markup on a locked layer is drawn and never hit; the click reaches what
        // lies under it.
        let unselectable = core.canvas.unselectableMarkupIDs
        let shapes = pageView.shapes
        // One rectangle comparison per shape; the exact test only for the few whose ink is
        // near the pointer (S-005).
        let inks = pageView.shapeInkBounds
        exactHitTestsInLastPass = 0
        // A measurement's pill is drawn over the ink, so a click on it is a click on its markup
        // (L-68). An area's pill sits inside its fill and a length's beside its line, so those
        // were reached by the ink anyway; a count's pill hangs on a leader away from its marks,
        // and a click on "Count A: 3" selected nothing.
        if let id = pillHit(at: point, among: shapes, excluding: unselectable) { return id }
        for index in shapes.indices.reversed() {
            let shape = shapes[index]
            guard !unselectable.contains(shape.id),
                  CanvasHitTesting.mayContain(shape, inkBounds: inks[index], point: point, tolerance: tolerance, zoom: zoom)
            else { continue }
            exactHitTestsInLastPass += 1
            if CanvasHitTesting.shape(shape, contains: point, tolerance: tolerance, zoom: zoom) { return shape.id }
        }
        return nil
    }

    /// How many shapes the last ``hitTest(_:)`` ran the exact test on. S-005's test seam.
    private(set) var exactHitTestsInLastPass = 0

    /// The markup whose drawn pill is under `point`, topmost first (L-68). The pills are the
    /// frames last drawn, in view points; one pill under the point is the common case.
    private func pillHit(at point: PDFPointValue, among shapes: [CanvasMarkupShape], excluding unselectable: Set<UUID>) -> UUID? {
        guard !pageView.captionFrames.isEmpty, let transform = pageView.transform else { return nil }
        let view = transform.viewPoint(from: point)
        let hits = Set(pageView.captionFrames.compactMap { id, frame in
            !unselectable.contains(id) && frame.insetBy(dx: -2, dy: -2).contains(view) ? id : nil
        })
        guard !hits.isEmpty else { return nil }
        // Only a committed markup on this page: a Temporary Measure is never selectable ink.
        return shapes.last { hits.contains($0.id) && !$0.isTemporary }?.id
    }

    // MARK: - Select

    /// How close a click must land on a vertex handle, in screen points, to grab it.
    static let vertexHandleToleranceScreenPoints: Double = 7

    /// The vertex handle under `point`, as (markup, index in `MarkupVertexEditing`'s order).
    ///
    /// Only a **selected** markup offers handles, which is what keeps a dense drawing from
    /// grabbing a vertex the user was trying to click past.
    func vertexHandle(at point: PDFPointValue) -> (markupID: UUID, index: Int)? {
        // View points, not device pixels: the same grab radius on a 1x and a 2x display
        // (BH-885).
        let tolerance = core.canvas.viewport.pageDistance(
            forViewPoints: Self.vertexHandleToleranceScreenPoints
        )
        let selected = core.canvas.selectedMarkupIDs
        for shape in pageView.shapes.reversed() where selected.contains(shape.id) {
            var best: (index: Int, distance: Double)?
            for (index, vertex) in shape.vertices.enumerated() {
                let distance = vertex.distance(to: point)
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
            if let best { return (shape.id, best.index) }
        }
        return nil
    }

    /// How close a click must land on a stamp's rotation knob, in screen points, to grab it.
    ///
    /// Larger than the knob is drawn (`CanvasPageView.stampRotationHandleRadiusViewPoints`),
    /// because a 4.5-point circle is a 9-point target and the HIG's floor for a pointer target
    /// is not 9 points. The knob is drawn small and grabbed generously, which is the same trade
    /// the vertex handles make.
    static let stampRotationHandleToleranceScreenPoints: Double = 10

    /// The angle increment a rotation drag snaps to with Shift held.
    ///
    /// Fifteen degrees: a seal is squared to the sheet, or turned to a detail, far more often
    /// than it is set to 37°. Not the 45° the *line* tools use — a stamp at 45° is a diagonal
    /// stamp, and the useful stops for a seal are finer than that.
    static let stampRotationSnapDegrees: Double = 15

    /// The selected stamp whose rotation knob is under `point`, or `nil`.
    ///
    /// Only a **selected** stamp offers a knob, for the reason the vertex handles do: an
    /// affordance every stamp on a busy sheet carries is an affordance that steals clicks from
    /// the drawing underneath.
    func stampRotationHandle(at point: PDFPointValue) -> UUID? {
        let tolerance = core.canvas.viewport.pageDistance(
            forViewPoints: Self.stampRotationHandleToleranceScreenPoints
        )
        // Every view-point distance through the one conversion (IM-021).
        let gapPagePoints = core.canvas.viewport.pageDistance(
            forViewPoints: Double(CanvasPageView.stampRotationHandleGapViewPoints)
        )
        let selected = core.canvas.selectedMarkupIDs
        for shape in pageView.shapes.reversed() where selected.contains(shape.id) {
            // An image markup draws through a stamp placement but turns by its style
            // (NL-MARKUP-18): its knob is `markupRotationHandle`'s.
            guard let stamp = shape.stamp, shape.kind != .image else { continue }
            let knob = stamp.rotationHandlePoint(gapPoints: gapPagePoints)
            if knob.distance(to: point) <= tolerance { return shape.id }
        }
        return nil
    }

    /// Writes a turned stamp through `DocumentCommand.rotateStamp`, which files its own undo
    /// inverse — so a rotation survives ⌘Z, save and reopen exactly as a move does.
    private func commitStampRotation(markupID: UUID, to point: PDFPointValue) {
        guard let record = sceneRecords.first(where: { $0.id.rawValue == markupID }),
              let stamp = record.stamp,
              let rotation = rotation(ofStamp: record, draggedTo: point),
              abs(CanvasStampPlacement.normalised(stamp.rotationDegrees) - rotation) > 1e-9
        else {
            refresh()
            return
        }
        Task { @MainActor [core] in
            do {
                _ = try await core.commands.perform(
                    .rotateStamp(id: record.id, degrees: rotation)
                )
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
            self.refresh()
        }
    }

    /// A press with the pointer tool armed. Decides what the drag, if there is one, means.
    func beginSelectDrag(at point: PDFPointValue) {
        pageView.hoverTarget = nil
        // The rotation knob is tested **before** the vertex handles and before the hit test.
        // It sits outside the stamp's box, so nothing else claims that pixel — but a stamp
        // anchor vertex is close by at a small box, and the knob is the smaller target.
        if let stamp = stampRotationHandle(at: point) {
            selectDrag = SelectDrag(mode: .rotateStamp(markupID: stamp), origin: point, current: point)
            refresh()
            return
        }
        // r2-markup: a selected text box or shape has a rotation knob of its own.
        if let turned = markupRotationHandle(at: point) {
            selectDrag = SelectDrag(mode: .rotateMarkup(markupID: turned), origin: point, current: point)
            refresh()
            return
        }
        if let handle = vertexHandle(at: point) {
            // Every handle drags, but only one whose vertex Delete can remove keeps the focus
            // (T-001, iteration 3): a dragged Length endpoint must leave Delete to the markup.
            focusedVertex = vertexTakesFocus(markupID: handle.markupID, index: handle.index) ? handle : nil
            let vertices = pageView.shapes.first(where: { $0.id == handle.markupID })?.vertices ?? []
            // Handles drag with snap (INTERACTION_MATRIX, V-001).
            vertexDragSnap = nil
            selectDrag = SelectDrag(
                mode: .vertex(markupID: handle.markupID, index: handle.index),
                origin: point,
                current: point,
                vertexOrigin: vertices.indices.contains(handle.index) ? vertices[handle.index] : nil,
                vertexAnchor: Self.neighbouringVertex(of: handle.index, in: vertices)
            )
        } else if let hit = hitTest(point) {
            // Dragging an unselected markup selects it first, so the thing that moves is
            // the thing under the pointer rather than a selection made three clicks ago.
            var ids = core.canvas.selectedMarkupIDs
            if !ids.contains(hit) {
                // A group moves as one (NL-MARKUP-11).
                ids = core.expandingGroups([hit])
                core.canvas.select(markupIDs: ids, additive: false)
            }
            selectDrag = SelectDrag(mode: .move(ids: Array(ids)), origin: point, current: point)
        } else {
            selectDrag = SelectDrag(mode: .marquee, origin: point, current: point)
        }
        refresh()
    }

    /// The pointer moved during a select drag.
    func updateSelectDrag(to point: PDFPointValue) {
        guard let drag = selectDrag else { return }
        if case .vertex = drag.mode {
            // The vertex goes where the ring points (V-001): the last snap while the pointer is
            // still inside its radius, otherwise the pointer, until this sample's resolve lands.
            if let held = vertexDragSnap, held.point.distance(to: point) <= held.tolerance {
                selectDrag?.current = held.point
            } else {
                vertexDragSnap = nil
                selectDrag?.current = point
            }
            resolveVertexDragSnap(at: point)
        } else {
            selectDrag?.current = point
        }
        if case .marquee = selectDrag?.mode {
            // A marquee selects as it grows, so the count in the ledger is honest before
            // the button comes up. Only when the caught set changes: re-selecting the same
            // set every pointer event woke the selection observers at pointer rate (IM-172).
            let caught = markupIDs(in: selectDrag?.rect ?? .zero)
            if caught != core.canvas.selectedMarkupIDs {
                core.canvas.select(markupIDs: caught, additive: false)
            }
            refreshLiveFeedback()
        } else {
            scheduleLiveMeasurementPreview()
            // A drag frame moves one preview: the live lane and the cached scene, never a
            // layout or an actor hop for every record (IM-040, IM-042).
            refreshLiveFeedback()
            applyScene()
        }
    }

    /// The select drag was abandoned with no release point (BH-061): disarm it so the
    /// ghost stops drawing an uncommitted move, and issue nothing.
    func cancelSelectDrag() {
        guard selectDrag != nil else { return }
        selectDrag = nil
        endVertexDragSnap()
        livePreviewTask?.cancel()
        liveCaptionOverride = [:]
        refresh()
    }

    /// Whether a select drag is armed. Test seam for BH-061.
    var isSelectDragArmed: Bool { selectDrag != nil }

    /// What a Select click at `point` would pick, shown before the click (IM-043). Only with
    /// the pointer tool armed and nothing in progress: a measurement tool never highlights.
    func updateHover(at point: PDFPointValue?) {
        guard let point, armedMode == .select, !isCalibrating, selectDrag == nil,
              core.toolLibrary.activePreset == nil else {
            pageView.hoverTarget = nil
            return
        }
        if let knob = stampRotationHandle(at: point) ?? markupRotationHandle(at: point) {
            pageView.hoverTarget = .rotationKnob(knob)
        } else if let handle = vertexHandle(at: point) {
            pageView.hoverTarget = .vertex(handle.markupID)
        } else if let hit = hitTest(point) {
            pageView.hoverTarget = .markup(hit)
        } else {
            pageView.hoverTarget = nil
        }
    }

    /// The page view, for tests that drive it with synthetic events.
    var pageViewForTesting: CanvasPageView { pageView }

    /// The scroll view, for tests that drive page turns.
    var scrollViewForTesting: ZenitCanvasScrollView { scrollView }
    /// The document view: raster layers under the page view (NL-PERF-05).
    var documentViewForTesting: CanvasDocumentView { documentView }
    /// The debounce the last raster request waited, in nanoseconds.
    private(set) var lastRasterDebounceForTesting: UInt64 = 0

    /// How many live quantity previews a Select drag started. V-004's counter.
    private(set) var livePreviewStartCountForTesting = 0
    /// A vertex drag's own snap (V-001): the last landing, its resolve and its sample number.
    private(set) var vertexDragSnap: VertexDragSnap?
    private var vertexDragSnapTask: Task<Void, Never>?
    private var vertexDragSnapSequence = 0

    /// The select drag was released: this is where the one command per gesture is issued.
    func endSelectDrag(at point: PDFPointValue) {
        guard var drag = selectDrag else { return }
        drag.current = point
        selectDrag = nil
        livePreviewTask?.cancel()
        liveCaptionOverride = [:]
        switch drag.mode {
        case .marquee:
            core.canvas.select(markupIDs: markupIDs(in: drag.rect), additive: false)
            refresh()
        case let .move(ids):
            commitMove(ids: ids, dx: drag.dx, dy: drag.dy)
        case let .vertex(markupID, index):
            endVertexDragSnap()
            commitVertexDrag(markupID: markupID, index: index, release: point, origin: drag.vertexOrigin, anchor: drag.vertexAnchor)
        case let .rotateStamp(markupID):
            commitStampRotation(markupID: markupID, to: point)
        case let .rotateMarkup(markupID):
            commitMarkupRotation(markupID: markupID, to: point)
        }
    }

    /// Markups a marquee catches, by bounds intersection.
    private func markupIDs(in rect: PDFRectValue) -> Set<UUID> {
        // ADR-0032: a marquee does not catch a locked layer's markups.
        Set(pageView.shapes.filter { CanvasHitTesting.shape($0, intersects: rect) }.map(\.id))
            .subtracting(core.canvas.unselectableMarkupIDs)
    }

    /// Translates the dragged markups through the command bus.
    ///
    /// One batch: moving three selected markups is **one** gesture, so it is one `⌘Z` and one
    /// refresh, and a refusal applies nothing, as Delete does. A cutout whose parent moves too
    /// is left out, because the parent carries it (X-001): sent on its own as well, the hole
    /// landed twice the offset away and the ghost no longer matched what was stored.
    private func commitMove(ids: [UUID], dx: Double, dy: Double) {
        guard abs(dx) > 1e-9 || abs(dy) > 1e-9 else {
            refresh()
            return
        }
        let parents = CarriedCutouts.parents(in: core.snapshot.markups)
        let moves = CarriedCutouts.roots(of: ids) { parents[$0] }
            .map { DocumentCommand.moveMarkup(id: MarkupID($0), dx: dx, dy: dy) }
        Task { @MainActor [core] in
            do {
                if moves.count == 1 {
                    _ = try await core.commands.perform(moves[0])
                } else {
                    _ = try await core.commands.performBatch(moves, actionName: moves.first?.undoActionName ?? "")
                }
            } catch {
                // A refused move snapped back with no word (CR-156).
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
            self.refresh()
        }
    }

    /// Keeps the status bar's tool note on the armed tool's modifiers and finish gestures
    /// (IM-168), without ever overwriting a note something else posted.
    private func updateGestureHint(mode: ZenitToolMode, gesture: ZenitToolGesture) {
        let placed = mode.markupKind != nil ? core.markup.placedPoints.count : core.measurement.placedPoints.count
        let hint = Self.gestureHint(
            gesture: gesture, placedCount: placed,
            keyboardCursor: mode.markupKind == nil && measurementInput.state.returnPlacesPoint
        )
        guard hint != lastGestureHint else { return }
        let current = core.status.snapshot.activeToolNote
        guard current == nil || current == lastGestureHint else { return }
        lastGestureHint = hint
        core.status.setActiveToolNote(hint)
    }

    /// The hint this canvas last put in the status bar, so it only ever replaces its own.
    private(set) var lastGestureHint: String?

    /// The hint line for an armed tool: "⇧ straight · ⌥ rectangle · Return or double-click to
    /// finish". `nil` when no tool collects points.
    nonisolated static func gestureHint(
        gesture: ZenitToolGesture, placedCount: Int, keyboardCursor: Bool = false
    ) -> String? {
        guard gesture.collectsPoints, !gesture.needsTextEntry else { return nil }
        var parts: [String] = []
        // While the keyboard cursor leads, Return means "place" — the status bar says which
        // meaning Return has (R-137).
        if keyboardCursor {
            parts.append(NSLocalizedString("Arrows move the cursor, ⇧ by 10", comment: "Tool hint: arrow keys move the keyboard cursor; Shift moves it ten times as far"))
            parts.append(NSLocalizedString("Return places a point", comment: "Tool hint: Return places a point at the keyboard cursor"))
            if gesture.isPointPlacement {
                parts.append(NSLocalizedString("Escape to finish", comment: "Tool hint: Escape finishes a count group"))
            } else if gesture.completingPointCount == nil {
                parts.append(NSLocalizedString("⌘Return to finish", comment: "Tool hint: Command-Return finishes the shape placed with the keyboard cursor"))
            }
            if placedCount > 0 {
                parts.append(NSLocalizedString("Delete removes the last point", comment: "Tool hint: Delete removes the last vertex"))
            }
            return parts.joined(separator: " · ")
        }
        if gesture.isPointPlacement {
            parts.append(NSLocalizedString("⌥-click removes a mark", comment: "Tool hint: option-click un-places a count mark"))
            parts.append(NSLocalizedString("Escape to finish", comment: "Tool hint: Escape finishes a count group"))
            return parts.joined(separator: " · ")
        }
        if gesture.usesDragGesture, !gesture.dragAlsoPlacesClicks, gesture.completingPointCount == nil {
            // L-99: a freehand stroke (Pen, Highlighter) is one drag, finished by letting go. It
            // used to read "⇧ square · Return, double-click or secondary click to finish" — the
            // box tools' modifier and the polyline's finishes, none of which a stroke has.
            return NSLocalizedString(
                "Drag to draw · release to finish",
                comment: "Tool hint: a freehand stroke is drawn with one drag and finished by releasing"
            )
        }
        if gesture.usesDragGesture, !gesture.dragAlsoPlacesClicks {
            parts.append(NSLocalizedString("⇧ square", comment: "Tool hint: shift constrains a dragged box to a square"))
        } else {
            parts.append(NSLocalizedString("⇧ straight", comment: "Tool hint: shift constrains the segment to 45 degrees"))
        }
        if gesture.optionDerivesRectangle {
            if placedCount == 2 {
                parts.append(NSLocalizedString("⌥-click rectangle", comment: "Tool hint: option-click with two points makes a three-point rectangle"))
            } else if placedCount == 0 {
                parts.append(NSLocalizedString("⌥-click traces the area", comment: "Tool hint: option-click auto-traces an enclosed area"))
            }
        }
        if gesture.completingPointCount == nil {
            parts.append(NSLocalizedString(
                "Return, double-click or secondary click to finish",
                comment: "Tool hint: the ways to finish a variable-vertex tool"
            ))
        }
        if placedCount > 0 {
            parts.append(NSLocalizedString("Delete removes the last point", comment: "Tool hint: Delete removes the last vertex"))
        }
        return parts.joined(separator: " · ")
    }

    /// Arrow keys (IM-166). With a selection and no tool drawing, the selection moves 1 pt
    /// (Shift: 10 pt) in the screen direction, whatever the page's rotation; a held arrow's
    /// repeats gather into one move, so one press — or one hold — is one ⌘Z. With nothing
    /// selected the sheet scrolls 40 view points.
    func nudge(dx: Int, dy: Int, large: Bool, isRepeat: Bool) -> Bool {
        guard core.measurement.activeKind == nil, core.markup.activeKind == nil,
              activeTextEntry == nil else { return false }
        let ids = Array(core.canvas.selectedMarkupIDs)
        guard !ids.isEmpty else {
            scroll(by: CGSize(width: CGFloat(dx) * 40, height: CGFloat(dy) * 40))
            return true
        }
        guard let transform = pageView.transform else { return false }
        let step = Self.nudgePageDelta(dx: dx, dy: dy, points: large ? 10 : 1, transform: transform)
        if !isRepeat { flushNudge() }
        if pendingNudge?.ids == Set(ids) {
            pendingNudge?.dx += step.x
            pendingNudge?.dy += step.y
        } else {
            flushNudge()
            pendingNudge = (Set(ids), step.x, step.y)
        }
        nudgeFlushTask?.cancel()
        if isRepeat {
            // Gathered until the repeats pause.
            nudgeFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                self?.flushNudge()
            }
        } else {
            flushNudge()
        }
        return true
    }

    /// Commits the gathered nudge as one move.
    func flushNudge() {
        nudgeFlushTask?.cancel()
        nudgeFlushTask = nil
        guard let pending = pendingNudge else { return }
        pendingNudge = nil
        nudgeCommitCountForTesting += 1
        commitMove(ids: Array(pending.ids), dx: pending.dx, dy: pending.dy)
    }

    private var pendingNudge: (ids: Set<UUID>, dx: Double, dy: Double)?
    private var nudgeFlushTask: Task<Void, Never>?
    /// How many moves the arrow keys committed. IM-166's counter.
    private(set) var nudgeCommitCountForTesting = 0

    /// The page-space translation of `points` page points in a screen direction, through the
    /// display transform so a rotated sheet moves the way the arrow points.
    nonisolated static func nudgePageDelta(
        dx: Int, dy: Int, points: Double, transform: PageDisplayTransform
    ) -> (x: Double, y: Double) {
        let origin = CGPoint(x: 0, y: 0)
        let length = CGFloat(points) * transform.zoom
        let a = transform.pagePoint(from: origin)
        let b = transform.pagePoint(from: CGPoint(x: CGFloat(dx) * length, y: CGFloat(dy) * length))
        return (b.x - a.x, b.y - a.y)
    }

    /// The vertex next to `index` in a vertex list — the one before it, or the one after the
    /// first — which a dragged vertex's snap measures perpendiculars and angles from (V-001).
    nonisolated static func neighbouringVertex(of index: Int, in vertices: [PDFPointValue]) -> PDFPointValue? {
        guard vertices.count >= 2, vertices.indices.contains(index) else { return nil }
        return vertices[index > 0 ? index - 1 : 1]
    }

    /// The snap a vertex drag's pointer sample takes, resolved on the session with the drag's
    /// anchor, by the canvas rather than the canvas presenter: the presenter keeps only the
    /// winner, and the winner beside a dragged vertex is usually that vertex's own old position
    /// (V-001). The latest sample wins; a stale answer is dropped.
    private func resolveVertexDragSnap(at raw: PDFPointValue) {
        guard let drag = selectDrag, case .vertex = drag.mode, let pageID = core.document.currentPage?.id else { return }
        vertexDragSnapSequence &+= 1
        let sequence = vertexDragSnapSequence
        let resolve = vertexSnapResolver(pageID: pageID, anchor: drag.vertexAnchor)
        let origin = drag.vertexOrigin
        vertexDragSnapTask = Task { @MainActor [weak self] in
            let resolution = await resolve(raw)
            guard let self, !Task.isCancelled, sequence == self.vertexDragSnapSequence,
                  let current = self.selectDrag, case .vertex = current.mode else { return }
            let snapped = Self.vertexDragSnapPoint(in: resolution, excluding: origin)
            self.vertexDragSnap = snapped.map {
                VertexDragSnap(point: $0, sample: raw, tolerance: resolution?.tolerancePagePoints ?? 0)
            }
            let target = snapped ?? raw
            let changed = target != current.current
            self.selectDrag?.current = target
            self.refreshLiveFeedback()
            if changed {
                self.scheduleLiveMeasurementPreview()
                self.applyScene()
            }
        }
    }

    /// One resolve of a vertex drag's snap, on the session, with the snap keys the canvas holds
    /// and without the markups the ledger filter's Hide took off the sheet (V-003).
    private func vertexSnapResolver(pageID: UUID, anchor: PDFPointValue?) -> @MainActor (PDFPointValue) async -> SnapResolution? {
        let session = core.session
        let layout = core.canvas.layout
        let modifiers = core.canvas.snapModifiers
        let excluded = core.canvas.snapExcludedMarkupIDs
        return { raw in
            try? await session.resolveSnap(
                pageID: PageID(pageID),
                pagePoint: PDFPoint(shown: raw),
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchor.map { PDFPoint(shown: $0) },
                excludingMarkupIDs: excluded
            )
        }
    }

    /// Forgets a vertex drag's snap and stops its resolve.
    private func endVertexDragSnap() {
        vertexDragSnapTask?.cancel()
        vertexDragSnapTask = nil
        vertexDragSnap = nil
    }

    /// Ends a vertex drag: the release point is snapped once more on the session, as a
    /// measurement's click and a calibration pick are, so the stored vertex is the snap for the
    /// release itself rather than the ring's last landing, and the quantity the command
    /// recomputes is measured from it (V-001). The vertex's own old corner is never the target.
    private func commitVertexDrag(
        markupID: UUID, index: Int, release raw: PDFPointValue, origin: PDFPointValue?, anchor: PDFPointValue?
    ) {
        guard let pageID = core.document.currentPage?.id else {
            commitVertexEdit(markupID: markupID, index: index, to: raw)
            return
        }
        let resolve = vertexSnapResolver(pageID: pageID, anchor: anchor)
        Task { @MainActor [weak self] in
            let resolution = await resolve(raw)
            guard let self else { return }
            self.commitVertexEdit(
                markupID: markupID, index: index,
                to: Self.vertexDragSnapPoint(in: resolution, excluding: origin) ?? raw
            )
        }
    }

    /// Writes a dragged vertex through `DocumentCommand.editVertices`, which recomputes the
    /// measurement and files its own undo inverse.
    private func commitVertexEdit(markupID: UUID, index: Int, to point: PDFPointValue) {
        guard let record = sceneRecords.first(where: { $0.id.rawValue == markupID }),
              let geometry = record.geometry,
              let edited = MarkupVertexEditing.replacing(
                  vertexAt: index,
                  with: PDFPoint(shown: point),
                  in: geometry
              ),
              edited != geometry
        else {
            refresh()
            return
        }
        Task { @MainActor [core] in
            do {
                _ = try await core.commands.perform(.editVertices(id: record.id, geometry: edited))
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
            self.refresh()
        }
    }

    /// Recomputes the dragged vertex's markup quantity on the engine and shows it live.
    private func scheduleLiveMeasurementPreview() {
        guard let drag = selectDrag else { return }
        let ids: [UUID]
        switch drag.mode {
        case .marquee: return
        case .move:
            // A move translates the geometry, and the engine measures with the record's own
            // scale, so the value cannot change: every move frame used to queue one recompute per
            // dragged markup on the session actor — ahead of the snap resolves and the release's
            // moves — and swapped the pill for a bare "label: value", dropping its repetition
            // badge and chosen caption fields while the markup moved (V-004).
            return
        case let .vertex(markupID, _): ids = [markupID]
        case .rotateStamp, .rotateMarkup:
            // A stamp carries no measurement, so there is no quantity to recompute while it
            // turns. Redrawing the preview is `applyScene`'s job and it has already happened.
            return
        }
        livePreviewStartCountForTesting &+= 1
        let previewed = sceneRecords
            .filter { ids.contains($0.id.rawValue) }
            .map(previewing(_:))
        let session = core.session
        let formatter = core.snapshot.ledger.formatter
        // The summaries the committed pills are built from, so the live pill is built the same
        // way (X-005).
        let committed = Dictionary(
            core.canvas.visibleMarkups.filter { ids.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        livePreviewTask?.cancel()
        livePreviewTask = Task { @MainActor [weak self] in
            var captions: [UUID: String] = [:]
            for record in previewed {
                // A superseded frame stops here rather than recomputing the rest (V-004).
                guard !Task.isCancelled else { return }
                guard let tool = record.tool, let geometry = record.geometry,
                      let summary = committed[record.id.rawValue] else { continue }
                guard let result = await session.preview(
                    tool: tool,
                    geometry: geometry,
                    parameters: record.parameters ?? .default,
                    scaleID: record.scaleID
                ) else { continue }
                let fields = MarkupBridge.fields(of: result, tool: tool, formatter: formatter)
                guard let caption = Self.liveCaption(
                    previewFields: fields, committed: summary, choice: record.style.measurementCaption
                ) else { continue }
                captions[record.id.rawValue] = caption
            }
            guard !Task.isCancelled, let self else { return }
            self.liveCaptionOverride = captions
            self.applyScene()
        }
    }

    /// The pill a vertex drag shows: the committed pill's own grammar — headline field, label,
    /// caption choice and ×N badge — over the fields the engine just previewed (X-005). It took
    /// the first field the engine wrote, which for an Area is Perimeter, so dragging a room's
    /// corner swapped "Room 1: 37.50 m²" for a length and dropped the badge for the whole drag.
    static func liveCaption(
        previewFields: [MeasurementFieldSummary],
        committed summary: MarkupSummary,
        choice: MeasurementCaption?
    ) -> String? {
        var live = summary
        live.measurementFields = previewFields
        return CanvasSceneBuilder.caption(for: live, choice: choice)
    }

    /// The canvas's own key handling. Internal rather than private so a test can press
    /// Escape or Return against the shipping controller without synthesising an `NSEvent`.
    func handle(key: CanvasKey) -> Bool {
        // NL-MEASURE-18: a typed segment owns Return, Delete and Escape while it has text.
        if handleTypedEntry(key) { return true }
        switch key {
        case .typed(let character):
            // A slot digit the window left here because the canvas owns the keyboard (a pick, a
            // markup shape) and no typed length took it: no preset is armed under it (K-02).
            guard ToolSlotShortcut.slot(forCharactersIgnoringModifiers: String(character), modifiers: []) != nil else {
                return false
            }
            return holdToolKey()
        case .toolKey:
            return holdToolKey()
        case let .nudge(dx, dy, large, isRepeat):
            if moveKeyboardCursor(dx: dx, dy: dy, large: large) { return true }
            return nudge(dx: dx, dy: dy, large: large, isRepeat: isRepeat)
        case .escape:
            // Escape lets go of a focused vertex (T-001), then falls through to whatever else it
            // ends: the focus is not a mode of its own, so it never swallows the key.
            focusedVertex = nil
            // An opening proposal is withdrawn by Escape along with the area in progress.
            if pendingOpeningProposal != nil { clearAutomationProposal() }
            // A search highlight is the cheapest thing Escape can clear, and clearing it costs
            // nothing else: it is not a selection and cancels no work in progress. So it goes
            // first, and Escape still falls through to whatever else was active.
            if !pageView.searchHighlights.isEmpty {
                clearSearchHighlights()
            }
            if activeTextEntry != nil {
                // Escape commits a text box that has text and discards one that does not —
                // never leaves an invisible markup.
                commitTextEntry()
                return true
            }
            if isCapturingSnippetRegion {
                // A stray click no longer ends region capture (LT-14), so Escape must —
                // a mode with no exit is a dead end.
                endSnippetRegion()
                onSnippetRegionCancelled?()
                return true
            }
            if isCalibrating {
                // The calibration machine cancels its point or disarms; either way the flow
                // ends, and it ends exactly once.
                calibrationInput.send(.cancel)
                if isCalibrating { endCalibration() }
                return true
            }
            if core.markup.activeKind != nil {
                // A shape in progress is cancelled and, with Reuse Tool on, the tool stays;
                // an armed tool with nothing drawn is put down by the
                // shell's Cancel Tool, Reuse or not (L-71).
                let hadShape = !core.markup.placedPoints.isEmpty
                cancelMarkup()
                if !hadShape || !core.toolLibrary.reuseToolEnabled {
                    onShellCommand?(.cancelTool)
                }
                return true
            }
            guard core.measurement.activeKind != nil else { return false }
            // The machine decides: a count group is *finished* by Escape, not thrown away;
            // every other tool cancels its geometry, and an armed tool with nothing drawn backs
            // out. The commit goes to the shell's Finish and the rest to its Cancel, which knows
            // the outer levels.
            prepareMeasurementInput(rawPoint: nil)
            routeMeasurement(.cancel, as: .escape)
            if measurementDriver.shellCommandsThisEvent.isEmpty {
                onShellCommand?(.cancelTool)
            }
            return true
        case .finish:
            // While the keyboard cursor leads a measurement, Return places a point at it and
            // ⌘Return (below) finishes (R-137). An opening proposal waiting
            // for Return is still accepted by it.
            if pendingOpeningProposal == nil, core.markup.activeKind == nil,
               core.measurement.activeKind != nil, measurementInput.state.returnPlacesPoint {
                placePointAtKeyboardCursor()
                return true
            }
            // Return accepts an opening proposal: the placed ring commits through Finish below.
            if pendingOpeningProposal != nil { clearAutomationProposal() }
            if core.markup.activeKind != nil {
                let gesture = armedGesture
                guard core.markup.placedPoints.count >= gesture.minimumPointCount else { return false }
                finishMarkup()
                return true
            }
            guard core.measurement.activeKind != nil else { return false }
            prepareMeasurementInput(rawPoint: nil)
            routeMeasurement(.finish, as: .finishKey)
            // A Return the machine refused still reaches the shell: after its fence settles
            // the in-flight snaps, the presenter's `canCommit` is the last gate and the shell
            // speaks the refusal, exactly as before.
            measurementDriver.issueFinishIfNeeded()
            return true
        case .commandFinish:
            // ⌘Return: finish, even while the keyboard cursor leads (R-137). Everywhere else it
            // is Return.
            guard core.markup.activeKind == nil, core.measurement.activeKind != nil,
                  measurementInput.state.returnPlacesPoint else { return handle(key: .finish) }
            if pendingOpeningProposal != nil { clearAutomationProposal() }
            prepareMeasurementInput(rawPoint: nil)
            routeMeasurement(.finish, as: .finishKey)
            measurementDriver.issueFinishIfNeeded()
            return true
        case .removeLastVertex:
            if core.markup.activeKind != nil, !core.markup.placedPoints.isEmpty {
                core.markup.removeLastPoint()
                refresh()
                return true
            }
            if core.measurement.activeKind != nil {
                prepareMeasurementInput(rawPoint: nil)
                let effects = routeMeasurement(.removeLastVertex, as: .removeKey)
                // An arc's through point is taken back before any vertex (NL-MEASURE-05).
                if effects.contains(.removeLastPoint) || effects.contains(.removeArcThroughPoint) {
                    refresh()
                    return true
                }
            }
            guard !core.canvas.selectedMarkupIDs.isEmpty else { return false }
            onShellCommand?(.deleteSelection)
            return true
        case .cycleSnap(let backward):
            return cycleSnapCandidate(forward: !backward)
        case .area:
            return handleAreaKey()
        }
    }

    // MARK: - Calibration

    /// Puts the canvas into two-point calibration.
    public func beginCalibration() {
        calibrationPoints = []
        isCalibrating = true
        calibrationInput.synchronize(kind: .length, vertices: [], cutoutParentID: nil)
        refresh()
        view.window?.makeFirstResponder(pageView)
    }

    // MARK: - Snippet region (ADR-0006 §1, the `.rect` region)

    /// Puts the canvas into "drag the rectangle you want a picture of".
    ///
    /// The mode ends on the release, on Escape, or if the drag was too small to be a region —
    /// never silently, because a pointer stuck in an invisible mode is the same affordance
    /// failure calibration once had.
    public func beginSnippetRegion() {
        isCapturingSnippetRegion = true
        pageView.isRegionCaptureTool = true
        pageView.cursorKind = .select
        refresh()
        view.window?.makeFirstResponder(pageView)
    }

    /// Leaves snippet-region capture, with a rectangle or without one.
    public func endSnippetRegion() {
        guard isCapturingSnippetRegion else { return }
        isCapturingSnippetRegion = false
        pageView.isRegionCaptureTool = false
        refresh()
    }

    /// Leaves calibration — with points collected or by Escape — and disarms the
    /// toolbar's Calibrate state, so the ring never outlives the flow.
    public func endCalibration(collected: Bool = false) {
        pageView.calibrationCursor = nil
        calibrationPoints = []
        isCalibrating = false
        calibrationInput.synchronize(kind: nil, vertices: [], cutoutParentID: nil)
        toolbar.selectTool(.select)
        refresh()
        onCalibrationEnd?(collected)
    }
}

private extension MeasurementKind {
    /// Whether the tool's live geometry is drawn as a closed outline.
    var closesOutline: Bool {
        switch self {
        case .area, .volume, .polygonCutout: return true
        default: return false
        }
    }
}


// MARK: - The zoom gesture on the GPU (NL-PERF-04, NL-PERF-05, NL-PERF-06)

extension PDFCanvasViewController {

    /// One zoom input from the trackpad or the wheel.
    ///
    /// The old path laid the whole page out and redrew it on the main thread per event — 120
    /// times a second, each one a relayout, a status refresh, a CPU resample of the stale
    /// raster and every markup again. Now an input only composes its factor into one
    /// similarity transform; the display link applies that transform once per frame as the
    /// document view's `sublayerTransform`, and the render server scales rasters, markups and
    /// overlay together. The page is laid out exactly once, when the gesture ends, with the
    /// transform removed in the same Core Animation transaction, so the hand-over is invisible.
    func gestureZoom(by factor: Double, aboutWindowPoint windowPoint: NSPoint, phase: ZenitCanvasScrollView.ZoomGesturePhase) {
        guard pageView.transform != nil, view.window != nil else {
            // Nothing laid out to transform: the immediate path is the honest one.
            if phase != .ended, abs(factor - 1) > 1e-12 { zoom(by: factor, aboutWindowPoint: windowPoint) }
            return
        }
        if abs(factor - 1) > 1e-12 {
            if liveZoom == nil { beginLiveZoom(anchor: windowPoint) }
            composeLiveZoom(factor: CGFloat(factor), aboutWindowPoint: windowPoint)
        }
        switch phase {
        case .ended:
            commitLiveZoom()
        case .lifted:
            armLiveZoomIdle(seconds: 0.05)
        case .began, .changed:
            armLiveZoomIdle(seconds: 0.12)
        }
        // The display link applies the frame; when it has not fired for two frame periods —
        // the first event of a gesture, a link that is not running — the input applies it.
        if let last = lastLiveApply, ContinuousClock.now - last < .milliseconds(17), frameClock.isRunning {
            return
        }
        applyLiveZoomFrame()
    }

    /// Lays out a gesture still on the GPU, if there is one. Every door that changes the zoom
    /// or reads view coordinates calls this first.
    func commitLiveZoomIfNeeded() {
        guard liveZoom != nil, !isCommittingLiveZoom else { return }
        commitLiveZoom()
    }

    private func beginLiveZoom(anchor: NSPoint) {
        zoomAnimationTask?.cancel()
        isAnimatingZoom = false
        liveZoomGeneration &+= 1
        liveZoom = LiveZoom(anchorWindowPoint: anchor, generation: liveZoomGeneration)
        lastLevelSignature = nil
        // The kept link resumes; only a canvas's first gesture on screen makes one (K-14).
        frameClock.start(for: view)
    }

    /// Composes one factor about a window point into the live similarity, clamped to the
    /// zoom range, and centres an axis on which the scaled sheet fits the view (LT3-10, so the
    /// commit does not jump).
    private func composeLiveZoom(factor: CGFloat, aboutWindowPoint windowPoint: NSPoint) {
        guard var live = liveZoom, let transform = pageView.transform, lastLayoutZoom > 0 else { return }
        let base = CGFloat(lastLayoutZoom)
        let wanted = base * live.scale * factor
        let clamped = min(CGFloat(ViewportSnapshot.maximumZoom), max(CGFloat(ViewportSnapshot.minimumZoom), wanted))
        let effective = clamped / (base * live.scale)
        let point = documentView.convert(windowPoint, from: nil)
        live.scale *= effective
        live.offset = CGPoint(
            x: effective * live.offset.x + (1 - effective) * point.x,
            y: effective * live.offset.y + (1 - effective) * point.y
        )
        let visible = scrollView.documentVisibleRect
        let sheet = transform.pageFrame.applying(live.transform)
        if sheet.width <= visible.width + 0.5 { live.offset.x += visible.midX - sheet.midX }
        if sheet.height <= visible.height + 0.5 { live.offset.y += visible.midY - sheet.midY }
        live.anchorWindowPoint = windowPoint
        live.needsApply = true
        liveZoom = live
    }

    /// One display frame of a gesture: one transform, then the pyramid scheduling.
    func applyLiveZoomFrame() {
        guard var live = liveZoom else { return }
        guard live.needsApply else {
            // K-14: level tiles held back by the per-frame layer budget come in on the frames
            // where the fingers rest.
            pageView.flushDeferredRasterLayers()
            return
        }
        let signpost = CanvasLog.signposter.beginInterval("ZoomGestureFrame")
        defer { CanvasLog.signposter.endInterval("ZoomGestureFrame", signpost) }
        live.needsApply = false
        liveZoom = live
        lastLiveApply = .now
        liveZoomFrameCountForTesting &+= 1
        let transform = live.transform
        // One Core Animation transaction per frame (K-14): the document view's transform and the
        // layer pass each committed their own, and the first of a frame is a top-level commit
        // that flushes the tree to the render server — two flushes on every level-changing frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        documentView.liveTransform = transform
        // Entering the gesture and showing its first level tiles re-stack the layers once, not
        // once each (R-006).
        pageView.performRasterBatch {
            pageView.liveDisplayTransform = transform
            scheduleLevelTiles()
            // K-14: and the next budget's worth of any level tiles an earlier frame held back.
            pageView.flushDeferredRasterLayers()
        }
    }

    private func armLiveZoomIdle(seconds: Double) {
        liveZoomIdleTask?.cancel()
        let generation = liveZoomGeneration
        liveZoomIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.liveZoom?.generation == generation else { return }
            self.commitLiveZoom()
        }
    }

    /// Ends the gesture: one layout at the gesture's zoom, the page point under the fingers
    /// kept where it is, and the GPU transform removed in the same transaction.
    func commitLiveZoom() {
        guard let live = liveZoom else { return }
        endLiveZoomMachinery()
        applyPendingFrameIfNeeded(live)
        let target = Double(CGFloat(lastLayoutZoom) * live.scale)
        var anchor: (window: NSPoint, page: PDFPointValue)?
        if let transform = pageView.transform {
            let display = documentView.convert(live.anchorWindowPoint, from: nil)
            let laidOut = display.applying(live.transform.inverted())
            anchor = (live.anchorWindowPoint, transform.pagePoint(from: laidOut))
        }
        liveZoomCommitCountForTesting &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentView.liveTransform = .identity
        // Leaving the gesture, the new page transform and the tiles the layout requests are
        // one layer pass; they were three (R-006).
        pageView.performRasterBatch {
            pageView.liveDisplayTransform = nil
            if abs(target - lastLayoutZoom) > 1e-9 {
                pendingZoomAnchor = anchor
                // The gesture is over: the exact pass renders now, not after a debounce.
                lastZoomStepAt = nil
                zoomStepIsBurst = false
                isCommittingLiveZoom = true
                core.canvas.setZoom(target)
                layoutPage()
                isCommittingLiveZoom = false
            } else if live.offset != .zero {
                // A pinch that came back to the zoom it started at can still have moved the sheet.
                scroll(by: CGSize(width: -live.offset.x, height: -live.offset.y))
            }
        }
        CATransaction.commit()
    }

    /// Drops a gesture without laying it out: something else set the zoom and that wins.
    private func abandonLiveZoom() {
        guard liveZoom != nil else { return }
        endLiveZoomMachinery()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentView.liveTransform = .identity
        pageView.liveDisplayTransform = nil
        CATransaction.commit()
    }

    private func endLiveZoomMachinery() {
        liveZoom = nil
        liveZoomIdleTask?.cancel()
        liveZoomIdleTask = nil
        lastLiveApply = nil
        lastLevelSignature = nil
        // Paused, not destroyed: making a link cost the next gesture's first frame up to 2 ms (K-14).
        frameClock.pause()
        // Queued level tiles are for a gesture that is over; the exact pass needs the renderer.
        levelQueue.cancelQueued()
    }

    /// A frame composed but not yet shown is shown before the commit replaces it, so the
    /// coverage and the anchor are computed against what the person last saw.
    private func applyPendingFrameIfNeeded(_ live: LiveZoom) {
        guard live.needsApply else { return }
        documentView.liveTransform = live.transform
    }

    // MARK: The pyramid, mid-gesture

    /// Shows the resident tiles of the level that suits the live scale (and the next coarser
    /// one beneath them), and queues the missing ones nearest the fingers first.
    private func scheduleLevelTiles() {
        guard let live = liveZoom, let transform = pageView.transform,
              let page = core.document.currentPage, rasterSource(for: page) != nil else { return }
        let backing = pageView.effectiveBackingScale
        let exponent = CanvasLevelGrid.exponent(forDeviceScale: CGFloat(lastLayoutZoom) * live.scale * backing)
        let inverse = live.transform.inverted()
        let visible = scrollView.documentVisibleRect.applying(inverse).intersection(transform.pageFrame)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let pageRect = transform.pageRect(covering: visible)
        let level = CanvasLevelGrid(
            pageIndex: rasterKey(of: page),
            exponent: exponent,
            pageBox: transform.pageBox,
            rotation: transform.rotation,
            generation: tileGeneration
        )
        let cells = level.cells(covering: pageRect)
        let signature = LevelSignature(
            exponent: exponent,
            cells: cells.flatMap { [$0.column, $0.row] },
            generation: tileGeneration
        )
        guard signature != lastLevelSignature else { return }
        lastLevelSignature = signature

        var shown: [PageRaster] = []
        if exponent > CanvasLevelGrid.exponents.lowerBound {
            let coarser = CanvasLevelGrid(
                pageIndex: rasterKey(of: page),
                exponent: exponent - 1,
                pageBox: transform.pageBox,
                rotation: transform.rotation,
                generation: tileGeneration
            )
            for cell in coarser.cells(covering: pageRect) {
                if let tile = tileCache.tile(for: coarser.key(column: cell.column, row: cell.row)) { shown.append(tile) }
            }
        }
        var jobs: [CanvasTileRenderQueue.Job] = []
        let anchorLaidOut = documentView.convert(live.anchorWindowPoint, from: nil).applying(inverse)
        let anchorInLevel = level.transform.viewPoint(from: transform.pagePoint(from: anchorLaidOut))
        for cell in cells {
            let key = level.key(column: cell.column, row: cell.row)
            if let tile = tileCache.tile(for: key) {
                shown.append(tile)
                continue
            }
            guard let plan = try? level.plan(column: cell.column, row: cell.row) else { continue }
            let centre = CGPoint(x: plan.deviceRect.midX, y: plan.deviceRect.midY)
            jobs.append(CanvasTileRenderQueue.Job(
                key: key,
                plan: plan,
                scale: level.scale,
                priority: Double(hypot(centre.x - anchorInLevel.x, centre.y - anchorInLevel.y))
            ))
        }
        pageView.levelTileRasters = shown
        levelQueue.replace(with: jobs)
    }

    /// A level tile landed: into the cache, and onto the screen if its level is still shown.
    func deliverLevelTile(_ job: CanvasTileRenderQueue.Job, _ raster: PageRaster) {
        recordLanding {
            tileCache.insert(raster, for: job.key)
            guard liveZoom != nil, job.key.pageIndex == currentRasterKey,
                  let signature = lastLevelSignature,
                  job.key.generation == signature.generation else { return }
            let exponent = CanvasLevelGrid.exponent(forDeviceScale: job.scale)
            guard exponent == signature.exponent || exponent == signature.exponent - 1 else { return }
            pageView.levelTileRasters.append(raster)
        }
    }

    // MARK: Memory pressure (NL-PERF-10)

    @objc func memoryPressureDidChange(_ note: Notification) {
        let critical = (note.userInfo?[CanvasMemoryPressure.levelKey] as? Bool) ?? false
        handleMemoryPressure(critical: critical)
    }

    /// Gives memory back under pressure: the queued level renders, every tile not on screen,
    /// yesterday's tiles, the level tiles and the other pages' base rasters. What is on screen
    /// stays — the visible tiles and this page's base — so the sheet does not go blank to save
    /// memory. `critical` also drops the vector underlay.
    func handleMemoryPressure(critical: Bool) {
        levelQueue.cancelQueued()
        tileCache.removeAll(except: Set(currentTileKeys))
        pageView.staleTileRasters = []
        if liveZoom == nil { pageView.levelTileRasters = [] }
        let current = currentRasterKey
        for index in Array(baseRasters.keys) where index != current {
            baseRasters.removeValue(forKey: index)
        }
        baseRasterOrder.removeAll { $0 != current }
        if critical { pageView.underlayRaster = nil }
    }
}

/// One process-wide memory-pressure source, fanned out to every canvas by notification.
@MainActor
enum CanvasMemoryPressure {
    static let notification = Notification.Name("ZenitCanvasMemoryPressure")
    /// `true` for `.critical`, `false` for `.warning`.
    static let levelKey = "critical"
    private static var source: DispatchSourceMemoryPressure?

    static func install() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                guard let event = self.source?.data else { return }
                guard event.contains(.warning) || event.contains(.critical) else { return }
                NotificationCenter.default.post(
                    name: notification,
                    object: nil,
                    userInfo: [levelKey: event.contains(.critical)]
                )
            }
        }
        source.resume()
        self.source = source
    }
}
