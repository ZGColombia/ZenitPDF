import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

/// The document view of the canvas scroll view: one page, its markups, and the measurement in
/// progress.
///
/// Flipped, because a scroll view's document view that is not flipped scrolls from the bottom, and
/// a drawing set reads from the top. Every page-space coordinate goes through
/// ``PageDisplayTransform``, which is where the flip and `/Rotate` are reconciled once.
@MainActor
final class CanvasPageView: NSView {

    /// The page-space to view-space mapping. `nil` when no page is showing.
    var transform: PageDisplayTransform? {
        didSet {
            guard transform != oldValue else { return }
            areaPillPlacements.removeAll(keepingCapacity: true)
            // A caption frame is in view points at the transform it was drawn under; a caption
            // not redrawn since must not be grabbable where it used to be (R-011).
            captionFrames.removeAll(keepingCapacity: true)
            invalidateShapeBounds()
            invalidatePage()
            liveOverlay.needsDisplay = true
            // Inside a raster batch (a gesture's commit lays out under one) the layers are
            // re-stacked once, at the batch's end, with every other change (R-006).
            syncRasterLayersOrDefer()
        }
    }

    // MARK: - Raster layers (NL-PERF-05)

    /// The layer view that shows this page's rasters, when the canvas composites them as
    /// layers. `nil` for a standalone page view — print, export, the drawing tests — which
    /// draws its rasters itself in ``draw(_:)`` exactly as before.
    weak var rasterLayerView: CanvasRasterLayerView? {
        didSet { syncRasterLayers() }
    }

    /// Whether this view composites its rasters as layers instead of drawing them.
    var compositesRasters: Bool { rasterLayerView != nil }

    /// The resident low-resolution raster of the whole page (NL-PERF-02): drawn under
    /// everything for the page's whole life, so no frame of any gesture is blank paper.
    var baseRaster: PageRaster? { didSet { if baseRaster != oldValue { rasterModelChanged() } } }
    /// Power-of-two pyramid tiles for a zoom in progress (NL-PERF-06), ordered with the stale
    /// tiles by their own sharpness.
    var levelTileRasters: [PageRaster] = [] { didSet { if levelTileRasters != oldValue { rasterModelChanged() } } }

    /// The gesture transform the document view is applying on the GPU right now, display =
    /// this × view point; `nil` outside a gesture. Setting it draws nothing — that is the
    /// point — but event conversion and the coverage seam read it, so a pointer that moves
    /// during a pinch still lands on the page point under it.
    var liveDisplayTransform: CGAffineTransform? {
        didSet {
            // Entering or leaving a gesture changes how the layers stack and filter; the
            // transform itself changing within a gesture does not.
            if (liveDisplayTransform == nil) != (oldValue == nil) { syncRasterLayersOrDefer() }
        }
    }

    /// Raised before a press or a key is handled, so a zoom gesture still in flight is laid
    /// out first and the event is converted against the page the person is looking at.
    var onWillBeginInteraction: (@MainActor () -> Void)?

    private func rasterModelChanged() {
        if compositesRasters {
            guard rasterBatchDepth == 0 else {
                rasterBatchIsDirty = true
                return
            }
            syncRasterLayers()
        } else {
            invalidatePage()
        }
    }

    private var rasterBatchDepth = 0
    private var rasterBatchIsDirty = false

    /// Re-stacks the layers now, or at the end of the open raster batch. `transform` and
    /// `liveDisplayTransform` called `syncRasterLayers()` directly, so a gesture's first frame
    /// and its commit walked every tile layer two or three times (R-006). Not
    /// ``rasterModelChanged()``: for a view that draws its own rasters that invalidates the
    /// page, which a live gesture transform must never do.
    private func syncRasterLayersOrDefer() {
        guard rasterBatchDepth == 0 else {
            rasterBatchIsDirty = true
            return
        }
        syncRasterLayers()
    }

    /// Asks for one more layer pass when the last one held level tiles back for want of budget
    /// (K-14, ``CanvasRasterLayerView/levelLayerBudgetPerUpdate``). Deferred inside a batch.
    func flushDeferredRasterLayers() {
        guard let rasterLayerView, rasterLayerView.deferredLayerCount > 0 else { return }
        syncRasterLayersOrDefer()
    }

    /// Applies several raster-model changes as one layer update: a landing that sets the
    /// tiles, clears yesterday's and drops the underlay costs one pass over the layers and one
    /// Core Animation commit, not one per property.
    func performRasterBatch(_ body: () -> Void) {
        rasterBatchDepth += 1
        body()
        rasterBatchDepth -= 1
        if rasterBatchDepth == 0, rasterBatchIsDirty {
            rasterBatchIsDirty = false
            syncRasterLayers()
        }
    }

    /// Hands the raster model to the layer view: the current zoom's tiles above everything,
    /// the underlay when it is exact for this zoom, then level and stale tiles by sharpness,
    /// and the base under all of it.
    private func syncRasterLayers() {
        guard let rasterLayerView else { return }
        let scale = effectiveBackingScale
        var rasters: [(role: CanvasRasterLayerView.Role, raster: PageRaster)] = []
        // Mid-gesture the laid-out zoom's tiles are just one more picture of the page, and a
        // level tile rendered for the live scale is sharper than they are: they stack by
        // sharpness with the others instead of on top of everything.
        let live = liveDisplayTransform != nil
        rasters += tileRasters.map { (live ? .stale : .current, $0) }
        if let pageRaster, let transform {
            let exact = pageRaster.placement(in: transform, backingScale: scale).isPixelExact
            rasters.append((exact ? .current : .stale, pageRaster))
        }
        if let underlayRaster, let transform,
           underlayRaster.placement(in: transform, backingScale: scale).isPixelExact {
            rasters.append((.underlay, underlayRaster))
        }
        rasters += levelTileRasters.map { (.level, $0) }
        rasters += staleTileRasters.map { (.stale, $0) }
        rasterLayerView.update(
            transform: transform,
            backingScale: scale,
            base: baseRaster,
            rasters: rasters,
            filtersForMotion: live
        )
    }

    /// The view point an event lands on, through a live gesture transform if one is applied.
    private func localPoint(for event: NSEvent) -> CGPoint {
        localPoint(atWindowLocation: event.locationInWindow)
    }

    /// The view point under a window location, through a live gesture transform if one is applied.
    private func localPoint(atWindowLocation location: CGPoint) -> CGPoint {
        let local = convert(location, from: nil)
        guard let live = liveDisplayTransform else { return local }
        return local.applying(live.inverted())
    }

    /// Page-space rectangles to mark out as search hits.
    ///
    /// A search result should not move the zoom, it should show *where* the word is. This is
    /// that highlight. It is drawn over the page and under nothing, persists until the
    /// next reveal or an Escape, and is deliberately not a selection: a found word is not a
    /// markup and must not join the selection, or Delete would appear to act on it.
    var searchHighlights: [PDFRectValue] = [] { didSet { if searchHighlights != oldValue { invalidatePage() } } }
    /// The rasterised page, or the rasterised piece of it, in display space.
    var pageRaster: PageRaster? { didSet { if pageRaster != oldValue { rasterModelChanged() } } }
    /// The vector underlay: the page's own extracted linework, drawn under the raster while
    /// the raster for this zoom is still in flight. `nil` when there is none, when the
    /// machine has no Metal device, or when the raster has landed and made it redundant.
    var underlayRaster: PageRaster? { didSet { if underlayRaster != oldValue { rasterModelChanged() } } }
    /// The tiled raster for the current zoom (IM-044): each tile a pixel-exact 1:1 copy of
    /// its piece of the page. Drawn over whatever stands in for missing tiles.
    var tileRasters: [PageRaster] = [] { didSet { if tileRasters != oldValue { rasterModelChanged() } } }
    /// Tiles from the previous zoom, resampled under the current ones while those render.
    var staleTileRasters: [PageRaster] = [] { didSet { if staleTileRasters != oldValue { rasterModelChanged() } } }
    /// How many tiles the last draw pass blitted. A test seam for IM-044.
    private(set) var tilesDrawnInLastPass = 0
    /// Device pixels per view point, for tests that have no window. Production reads the
    /// window; a `cacheDisplay` render in a test has neither window nor screen.
    var backingScaleOverride: CGFloat?

    /// The whole-page raster, as a plain image. Print, export and the drawing tests.
    var pageImage: CGImage? {
        get { pageRaster?.image }
        set {
            guard let newValue else { pageRaster = nil; return }
            let displayWidth = transform?.displaySize.width ?? CGFloat(newValue.width)
            pageRaster = PageRaster(
                image: newValue,
                coverage: .wholePage,
                scale: displayWidth > 0 ? CGFloat(newValue.width) / displayWidth : 1
            )
        }
    }

    /// Device pixels per view point this view is drawing at.
    var effectiveBackingScale: CGFloat {
        backingScaleOverride ?? window?.backingScaleFactor ?? 2
    }
    /// What the sheet says about its own rendering (IM-164): nothing, "Rendering page…" while
    /// a newly shown page has nothing drawn yet, or that an area could not be rendered.
    enum RenderNotice: Equatable {
        case rendering
        case refused

        var text: String {
            switch self {
            case .rendering:
                return NSLocalizedString("Rendering page…", comment: "Shown on the sheet while a page renders")
            case .refused:
                return NSLocalizedString(
                    "This area could not be rendered at this zoom",
                    comment: "Shown on the sheet when the renderer refused the viewport"
                )
            }
        }
    }

    var renderNotice: RenderNotice? {
        didSet {
            guard renderNotice != oldValue else { return }
            liveOverlay.needsDisplay = true
            if renderNotice == .refused { announce(RenderNotice.refused.text) }
        }
    }

    /// Caption layouts by text, and area-pill placements by shape and caption. The placements
    /// are view-space, so a transform or shape change drops them (IM-165).
    struct AreaPillKey: Hashable {
        var shapeID: UUID?
        var text: String
    }
    /// A pill's text and the ink it is set in: light or dark on a markup-coloured fill, or
    /// chrome text on the neutral pill of the render notice and the hover caption.
    struct PillLayoutKey: Hashable {
        var text: String
        var tone: PillInk
    }
    enum PillInk: Hashable {
        case light
        case dark
        case chrome
    }
    private var pillLayouts: [PillLayoutKey: (NSAttributedString, CGSize)] = [:]
    private var areaPillPlacements: [AreaPillKey: AreaPillLayout.Placement?] = [:]
    /// How many caption layouts and area placements were computed. IM-165's counters.
    private(set) var pillLayoutComputeCount = 0
    private(set) var areaPillPlacementComputeCount = 0

    /// The page number VoiceOver names the canvas by (IM-162).
    var accessibilityPageNumber = 1
    /// The sheet label VoiceOver reads for the canvas (for example "A-101"), when the page has one.
    var accessibilitySheetLabel: String?
    /// The most recent VoiceOver announcements, newest last. A test seam for IM-162.
    fileprivate(set) var accessibilityAnnouncements: [String] = []
    /// r2-platform (NL-PLAT-20): what VoiceOver reads for a markup — "Slab, A, 21.40 m², sheet
    /// A-101" — supplied by the controller from the takeoff; `nil` falls back to the shape's kind.
    var markupAccessibilityTexts: (() -> [UUID: String])?
    /// r2-platform (NL-PLAT-20): VoiceOver's press on a markup selects it.
    var onMarkupAccessibilityPress: ((UUID) -> Void)?
    /// The decoded pixels of inserted images, by artwork digest (ADR-0043, L-81). Supplied by the
    /// controller; an image whose pixels are not here draws its mosaic, as before.
    var insertedImagePixels: [String: CGImage] = [:] {
        didSet { if Set(insertedImagePixels.keys) != Set(oldValue.keys) { invalidatePage() } }
    }
    /// How many inserted images the last pass drew from their pixels. A test seam for L-81.
    private(set) var insertedImagesDrawnInLastPass = 0

    /// Committed markups on this page.
    var shapes: [CanvasMarkupShape] = [] {
        didSet {
            guard shapes != oldValue else { return }
            areaPillPlacements.removeAll(keepingCapacity: true)
            // A hidden shape, or one whose caption was turned off, is not redrawn: its old frame
            // must not start a caption drag (R-011).
            captionFrames.removeAll(keepingCapacity: true)
            invalidateShapeBounds()
            cachedShapeInkBounds = nil
            invalidatePage()
            announceAddedShapes(since: oldValue)
        }
    }

    /// The coverage map's page overlay: measured regions to tint, plus the badge text that
    /// names the fraction — the state is text and tint together, never colour alone.
    struct CoverageOverlay: Equatable {
        /// Outer rings and hole rings together, page space, filled even-odd.
        var rings: [[PDFPointValue]]
        /// "Coverage 82 % of page" — drawn as a badge on the sheet.
        var label: String
    }
    /// Set by the controller while the View-menu toggle is on; `nil` draws nothing.
    var coverageOverlay: CoverageOverlay? {
        didSet { if coverageOverlay != oldValue { invalidatePage() } }
    }
    /// The double-count guard's overlaps on this page, page-space rings (NL-MEASURE-13). Drawn
    /// hatched with a text label by `drawDoubleCountHatch(transform:)` in
    /// `CanvasDoubleCountHatch.swift`; empty draws nothing.
    var doubleCountHatch: [[PDFPointValue]] = [] {
        didSet { if doubleCountHatch != oldValue { invalidatePage() } }
    }
    /// NL-MEASURE-09: while one measurement's caption draws, how far it is moved from its
    /// automatic position (view points) and whose it is; recorded frames serve the caption drag
    /// (`CanvasCaptionPlacement.swift`).
    var captionViewOffset: CGSize = .zero
    var captionShapeID: UUID?
    var captionFrames: [UUID: CGRect] = [:]
    /// Fence lines drawn for auto-trace on this page (NL-MEASURE-11), drawn dashed and labelled.
    var traceFenceLines: [CanvasFenceLine] = [] {
        didSet { if traceFenceLines != oldValue { invalidatePage() } }
    }
    /// The saved Project Zone and Scale Region outlines and calibration picks on this page
    /// (U-086), drawn by `drawBoundaryMarks(transform:)` in `CanvasBoundaryMarks.swift`. The
    /// snap boundary layer is fed from the same marks, so every boundary target is drawn here.
    var boundaryMarks: [PageBoundaryMark] = [] {
        didSet { if boundaryMarks != oldValue { invalidatePage() } }
    }
    /// The identities of the boundary marks the last ink pass drew, in drawing order — what a
    /// test compares with the snap boundary layer.
    private(set) var boundaryMarkIDsDrawnInLastPass: [String] = []
    /// The caption being dragged and how far, in view points, before the drop commits it.
    ///
    /// A drag frame repaints the pill's old box, its new box and the leader back to its
    /// automatic place, never the whole sheet's ink (V-012); an unchanged frame repaints
    /// nothing. The dragged shape's padded bounds follow the pill (``viewBounds(for:transform:)``),
    /// so the narrowed rectangle never culls the pill it is repainting (V-011).
    var captionDragPreview: (id: UUID, delta: CGSize)? {
        didSet {
            guard captionDragPreview?.id != oldValue?.id || captionDragPreview?.delta != oldValue?.delta else { return }
            invalidateCaptionDrag(from: oldValue, to: captionDragPreview)
        }
    }
    /// The rectangle the last caption-drag frame repainted; `nil` when it fell back to the
    /// whole page (no drawn frame to start from). V-012's seam.
    private(set) var lastCaptionDragDirtyRect: CGRect?

    private func invalidateCaptionDrag(from old: (id: UUID, delta: CGSize)?, to new: (id: UUID, delta: CGSize)?) {
        guard let id = new?.id ?? old?.id, let frame = captionFrames[id], let transform,
              let shape = shapes.first(where: { $0.id == id }) else {
            lastCaptionDragDirtyRect = nil
            invalidatePage()
            return
        }
        // The frame on record was drawn at the old delta; the automatic box is under the stored
        // offset and that delta, and the new box is the automatic one moved by the new delta.
        let stored = Self.captionViewOffset(of: shape, transform: transform)
        let oldDelta = old?.id == id ? old!.delta : .zero
        let newDelta = new?.id == id ? new!.delta : .zero
        let automatic = frame.offsetBy(dx: -(stored.width + oldDelta.width), dy: -(stored.height + oldDelta.height))
        let moved = automatic.offsetBy(dx: stored.width + newDelta.width, dy: stored.height + newDelta.height)
        // Padded for the pill's keyline and the leader's width.
        let dirty = frame.union(moved).union(automatic).insetBy(dx: -4, dy: -4)
        lastCaptionDragDirtyRect = dirty
        setNeedsDisplay(dirty)
    }

    /// A measurement caption's stored offset (page points on the style) in view points.
    static func captionViewOffset(of shape: CanvasMarkupShape, transform: PageDisplayTransform) -> CGSize {
        guard let stored = shape.captionOffset else { return .zero }
        let origin = transform.viewPoint(from: PDFPointValue(x: 0, y: 0))
        let moved = transform.viewPoint(from: stored)
        return CGSize(width: moved.x - origin.x, height: moved.y - origin.y)
    }
    /// Automation's proposals awaiting a person's decision (nl-automation). Drawn by
    /// `drawAutomationOverlay(transform:)` in `Automation/CanvasAutomationOverlay.swift`.
    var automationOverlay: CanvasAutomationOverlay? {
        didSet { if automationOverlay != oldValue { invalidatePage() } }
    }
    /// Selected markup identities.
    var selection: Set<UUID> = [] {
        didSet {
            guard selection != oldValue else { return }
            invalidatePage()
            // The hover outline and its label live on the overlay and are drawn only for an
            // unselected markup. A click that selects the hovered markup changes no hover, so the
            // overlay kept the label and the page drew the markup's own pill under it: two
            // identical labels stacked (L-13). The overlay repaints when the hovered markup
            // joins or leaves the selection.
            if let hovered = hoverTarget?.markupID, selection.contains(hovered) != oldValue.contains(hovered) {
                liveChanged()
            }
        }
    }
    /// A vertex handle of a selected markup, by markup and index in its ``CanvasMarkupShape/vertices``.
    struct FocusedVertex: Equatable {
        var markupID: UUID
        var index: Int
    }
    /// The vertex Delete removes (NL-MEASURE-06), drawn as a filled handle so the person sees
    /// what Delete will act on (T-001). Drawn with the other handles, from the same shape list,
    /// so it moves with its vertex.
    var focusedVertex: FocusedVertex? { didSet { if focusedVertex != oldValue { invalidatePage() } } }
    // MARK: - Live state (IM-163)

    /// Everything the live overlay draws, as one value in three groups: the drawing in
    /// progress, pointer feedback and calibration. Each group is compared once; a change
    /// repaints the union of the group's old and new ink on the overlay only, never the page.
    /// Build it in one place and assign it once; the forwarders below keep single-property
    /// assignments working, each one still guarded by the group's equality.
    var live = CanvasLiveState() {
        didSet { liveStateDidChange(from: oldValue) }
    }

    /// The overlay rectangle the last live-state change invalidated; `nil` when it was the
    /// whole overlay. A test seam for IM-163.
    private(set) var lastLiveDirtyRect: CGRect?

    private func liveStateDidChange(from old: CanvasLiveState) {
        guard live != old else { return }
        // A snap target acquired during placement is said, not only drawn (IM-162).
        if old.pointer.snapPoint == nil, live.pointer.snapPoint != nil,
           !live.drawing.points.isEmpty || live.drawing.isPointPlacement {
            announce(NSLocalizedString("Snapped", comment: "VoiceOver announcement when a snap target is acquired"))
        }
        let dirty = CanvasLiveState.dirtyRect(from: old, to: live, transform: transform) { [unowned self] text in
            pillLayout(text, tone: .light).1
        }
        liveChanged(dirty: dirty)
    }

    /// Vertices placed so far by the armed measurement tool.
    var livePoints: [PDFPointValue] {
        get { live.drawing.points }
        set { live.drawing.points = newValue }
    }
    /// Whether the armed tool closes its outline.
    var liveClosesOutline: Bool {
        get { live.drawing.closesOutline }
        set { live.drawing.closesOutline = newValue }
    }
    /// The live readout drawn beside the measurement in progress.
    var liveCaption: String? {
        get { live.drawing.caption }
        set { live.drawing.caption = newValue }
    }
    /// Where the snap engine says the pointer will land.
    var snapPoint: PDFPointValue? {
        get { live.pointer.snapPoint }
        set { live.pointer.snapPoint = newValue }
    }
    /// Where the pointer is while calibrating, so a live segment can follow it.
    ///
    /// Between the two reference clicks calibration used to draw nothing at all — no segment,
    /// no live feedback — while every measuring tool draws one. A tool that shows nothing
    /// between clicks reads as a tool whose snap is broken.
    var calibrationCursor: PDFPointValue? {
        get { live.calibration.cursor }
        set { live.calibration.cursor = newValue }
    }
    /// The two points of a calibration in progress.
    var calibrationPoints: [PDFPointValue] {
        get { live.calibration.points }
        set { live.calibration.points = newValue }
    }
    /// The pointer, in page space, while a measurement is in progress — the rubber band is
    /// drawn from the last placed vertex to this point.
    var liveCursorPoint: PDFPointValue? {
        get { live.drawing.cursorPoint }
        set { live.drawing.cursorPoint = newValue }
    }
    /// The first vertex, when the next click would close the polygon on it. Drawn as a ring
    /// so the close affordance is visible before the click.
    var firstVertexCloseTarget: PDFPointValue? {
        get { live.drawing.firstVertexCloseTarget }
        set { live.drawing.firstVertexCloseTarget = newValue }
    }
    /// The anchor corner of a one-gesture drag tool in progress.
    var liveDragAnchor: PDFPointValue? {
        get { live.drawing.dragAnchor }
        set { live.drawing.dragAnchor = newValue }
    }
    /// The inferred quadrilateral of a three-point rectangle following the cursor, drawn
    /// closed with a fill so the running area visibly belongs to a shape.
    var liveInferredQuad: [PDFPointValue]? {
        get { live.drawing.inferredQuad }
        set { live.drawing.inferredQuad = newValue }
    }
    /// The Select tool's rubber band, in page space, or `nil` when no marquee is open.
    var selectionMarquee: PDFRectValue? {
        get { live.pointer.selectionMarquee }
        set { live.pointer.selectionMarquee = newValue }
    }

    /// What the pointer would pick with the Select tool (IM-043): the markup under it, drawn
    /// with a thin outline and a label naming it — never colour alone.
    enum HoverTarget: Equatable {
        case markup(UUID)
        case vertex(UUID)
        case rotationKnob(UUID)

        var markupID: UUID {
            switch self {
            case let .markup(id), let .vertex(id), let .rotationKnob(id): id
            }
        }
    }
    var hoverTarget: HoverTarget? {
        didSet {
            guard hoverTarget != oldValue else { return }
            liveChanged()
            hoverCursor()?.set()
            if hoverTarget == nil { cursorKind.nsCursor.set() }
        }
    }

    /// NL-UX-09 (r2-layers): the markup whose Quantity Ledger row the pointer is over, outlined on
    /// the sheet (`UX/CanvasPageView+LedgerHover.swift`). Never touches the cursor: the pointer is
    /// over the ledger, not here.
    var ledgerHoverMarkupID: UUID? {
        didSet {
            guard ledgerHoverMarkupID != oldValue else { return }
            liveChanged()
        }
    }

    /// The cursor the page rests on once a pan ends: an open hand while Space or the pan tool
    /// still pans, otherwise the hover's cursor or the armed verb's (BH-881).
    func restingCursor() -> NSCursor {
        if isSpaceHeld || isPanTool { return .openHand }
        return hoverCursor() ?? cursorKind.nsCursor
    }

    /// Sets the resting cursor and refreshes the cursor rect, so the pointer is right at once
    /// rather than on the next exit and re-entry (IM-167).
    func restCursor() {
        restingCursor().set()
        window?.invalidateCursorRects(for: self)
    }

    /// The cursor the hover asks for: a move hand over a markup's body, a crosshair over a
    /// vertex handle or the rotation knob.
    func hoverCursor() -> NSCursor? {
        switch hoverTarget {
        case .markup: return .openHand
        case .vertex, .rotationKnob: return .crosshair
        case nil: return nil
        }
    }

    /// Raised on a click inside the page.
    ///
    /// `optionHeld` is separate from `additive` because the two modifiers mean opposite
    /// things: `⇧` adds to a selection or constrains an angle, `⌥` *un-places* a count
    /// point. Folding them into one flag is how a tool ends
    /// up doing the other one's job.
    var onClick: (@MainActor (PDFPointValue, _ additive: Bool, _ optionHeld: Bool) -> Void)?
    /// Raised on a double-click inside the page: closes a variable-vertex geometry.
    var onDoubleClick: (@MainActor (PDFPointValue) -> Void)?
    /// Raised on every pointer move, with `nil` when the pointer leaves the page.
    var onPointerMove: (@MainActor (PDFPointValue?) -> Void)?
    /// Raised on a key the canvas owns. Returns `true` when the key was consumed.
    var onKey: (@MainActor (CanvasKey) -> Bool)?
    /// Raised when the pointer is dragged with Space held, the pan tool or the middle button.
    var onPanBy: (@MainActor (CGSize) -> Void)?
    /// One press-drag-release gesture for the rectangle and ellipse area tools.
    var onDragBegan: (@MainActor (PDFPointValue) -> Void)?
    var onDragMoved: (@MainActor (PDFPointValue) -> Void)?
    var onDragEnded: (@MainActor (PDFPointValue) -> Void)?
    /// Raised when the held modifier keys change — `Shift` for the live 45° straight-line
    /// constraint, `⌥` for the Area tool's three-point rectangle
    /// preview, which is what makes that gesture visible before it is used, `⌘` for suspending
    /// snapping while it is held (V-070).
    var onModifiersChanged: (@MainActor (_ shiftHeld: Bool, _ optionHeld: Bool, _ commandHeld: Bool) -> Void)?
    /// Raised on a secondary click — a two-finger trackpad tap or the right mouse button.
    /// Returns `true` when the click was consumed (a measurement in progress finished or
    /// swallowed it); `false` falls back to select-and-context-menu.
    var onSecondaryClick: (@MainActor (PDFPointValue?) -> Bool)?
    /// Whether a click selects rather than places a point.
    ///
    /// Guarded like ``isPanTool`` and ``cursorKind``: the live lane assigns it on every pointer
    /// move and snap landing, and an unguarded assignment rebuilt the window's cursor rects each
    /// time, which also put the tool cursor back over a hover's open hand or crosshair (V-010).
    var isSelectionTool = true {
        didSet {
            guard isSelectionTool != oldValue else { return }
            cursorRectInvalidationCount &+= 1
            window?.invalidateCursorRects(for: self)
        }
    }
    /// How many times ``isSelectionTool`` asked for a cursor-rect rebuild. V-010's test seam.
    private(set) var cursorRectInvalidationCount = 0
    /// Whether the armed tool draws with one press-drag-release gesture.
    var usesDragGesture = false
    /// Whether the armed drag tool also places corners click by click — the three-point
    /// rectangle. A press-and-release without movement is then a
    /// click routed through `onClick`, not a failed drag.
    var dragToolPlacesClicks = false
    /// Whether the Zoom tool is armed: a drag draws the marquee, a click steps the zoom
    /// (marquee zoom).
    var isZoomTool = false { didSet { if !isZoomTool { zoomMarqueeViewRect = nil } } }
    /// Whether a snippet region is being drawn: a drag frames the rectangle ADR-0006 exports,
    /// and the release hands it back in **page space**.
    ///
    /// It rides the zoom tool's marquee gesture rather than a second one of its own. The two are
    /// the same interaction — press, drag a frame, release over a page region — and the zoom
    /// marquee's press/drag/release path is the one already proven; a parallel implementation
    /// would be a second place for the "release outside the page" and "release without moving"
    /// cases to be got wrong.
    var isRegionCaptureTool = false {
        didSet {
            guard !isRegionCaptureTool else { return }
            zoomMarqueeViewRect = nil
            zoomDragStartView = nil
        }
    }
    /// Whether the Pan tool is armed: a drag anywhere moves the page and the cursor is an
    /// open hand. The button used to arm a state nobody read, so Pan was indistinguishable
    /// from Select.
    var isPanTool = false {
        didSet {
            guard isPanTool != oldValue else { return }
            liveChanged()
            window?.invalidateCursorRects(for: self)
        }
    }
    /// What the pointer must look like, named by the **verb** the next click performs.
    ///
    /// The three booleans above say which *tool* is armed. They cannot say what Apply and Place
    /// mean, because both of those deliberately disarm the drawing families — so from here they
    /// are indistinguishable from Select, and the pointer used to say "this click selects" while
    /// the next click was about to rewrite forty markups. ``PDFCanvasViewController/refresh()``
    /// resolves the verb from the armed tool *and* the armed set's mode through
    /// ``ZPDFUIPresentation/CanvasCursorKind/resolve(tool:setMode:hasArmedPreset:)`` and assigns
    /// it here; this view no longer infers a cursor from anything.
    var cursorKind: CanvasCursorKind = .select {
        didSet {
            guard cursorKind != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Whether the armed tool's placed points are *points*, never a path.
    ///
    /// Count places dots. Stroking a polyline through them draws a polygon that was never measured.
    var isPointPlacement: Bool {
        get { live.drawing.isPointPlacement }
        set { live.drawing.isPointPlacement = newValue }
    }
    /// The markup kind being drawn, so the live preview is the shape that will be
    /// committed — a rectangle previews as a rectangle, an ellipse as an ellipse.
    var liveMarkupKind: ZPDFUIPresentation.MarkupKind? {
        get { live.drawing.markupKind }
        set { live.drawing.markupKind = newValue }
    }

    /// Raised when a zoom marquee is released over a page region.
    var onZoomMarquee: (@MainActor (PDFRectValue) -> Void)?
    /// Raised when the zoom tool is clicked without a drag: step in, or out with `⌥`.
    var onZoomClick: (@MainActor (_ locationInWindow: NSPoint, _ zoomOut: Bool) -> Void)?
    /// Raised when a snippet region marquee is released over a page region.
    ///
    /// The rectangle is in **page space** — `PageDisplayTransform.pageRect(covering:)` has
    /// already undone the zoom, the scroll offset and the page rotation, which is why the
    /// snippet built from it is the same picture whatever the window was doing.
    var onRegionCaptured: (@MainActor (PDFRectValue) -> Void)?

    private var trackingArea: NSTrackingArea?
    /// Space is held: drags pan, clicks do nothing, the cursor is a grab hand.
    private var isSpaceHeld = false
    /// A pan drag (Space or middle button) is in progress.
    private var isPanDragging = false
    /// A measurement drag gesture is in progress.
    private var isMeasureDragging = false
    /// The press point of a drag tool that also places clicks, held until the first real
    /// drag movement decides between "drag" and "click".
    private var pendingMeasureDragStart: PDFPointValue?
    /// The press point of a Select gesture, held until the pointer decides between a click
    /// and a drag.
    private var pendingSelectStart: PDFPointValue?
    /// A Select drag — marquee, move or vertex — is in progress.
    private var isSelectDragging = false
    /// The press only ended an open text box (W-004): it and its release do nothing else.
    private var pressEndedTextEntry = false
    /// The last press this view received, in window coordinates, with its event time (L-36).
    private var lastPress: (timestamp: TimeInterval, windowLocation: CGPoint)?
    /// Where the pointer rests over this view, in window coordinates: set by every hover and
    /// release, cleared when it leaves the view or presses (a gesture owns the pointer then).
    /// A scroll or a zoom moves the page under a still pointer without a `mouseMoved`, so the
    /// controller re-runs the pointer path from here (W-002).
    private(set) var hoverWindowLocation: CGPoint?
    /// The zoom marquee in view space while the zoom tool drags, drawn dashed.
    private var zoomMarqueeViewRect: CGRect? { didSet { if zoomMarqueeViewRect != oldValue { liveChanged() } } }
    /// Where the zoom marquee started, in view space.
    private var zoomDragStartView: CGPoint?

    // MARK: - The live overlay (IM-039)

    /// Rubber band, snap ring, close target, live caption, calibration segment and marquees
    /// draw here, in a transparent layer above the sheet, so a pointer move repaints a few
    /// hundred pixels of overlay instead of the raster and every committed markup.
    let liveOverlay = CanvasLiveOverlayView()

    /// How many times the live state changed. A test seam for IM-039.
    private(set) var liveChangeCount = 0

    /// How many times a committed-state change invalidated the page view. A test seam for
    /// IM-038/IM-039: identical assignments and live changes must leave it alone.
    private(set) var pageInvalidationCount = 0

    private func invalidatePage() {
        pageInvalidationCount &+= 1
        needsDisplay = true
    }

    private func liveChanged() {
        liveChanged(dirty: nil)
    }

    /// Repaints the live overlay: only `dirty` when a change knows its ink bounds, the whole
    /// overlay otherwise. Never the page view.
    private func liveChanged(dirty: CGRect?) {
        liveChangeCount &+= 1
        lastLiveDirtyRect = dirty
        if let dirty {
            let clipped = dirty.intersection(liveOverlay.bounds)
            if !clipped.isNull, !clipped.isEmpty { liveOverlay.setNeedsDisplay(clipped) }
        } else {
            liveOverlay.needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installLiveOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installLiveOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        liveOverlay.frame = bounds
    }

    /// Whether draw passes skip shapes outside the dirty rectangle. Always on in the product;
    /// a test turns it off to compare a culled render with an unculled one pixel for pixel.
    var cullsToDirtyRect = true

    private func installLiveOverlay() {
        liveOverlay.host = self
        liveOverlay.frame = bounds
        liveOverlay.autoresizingMask = [.width, .height]
        addSubview(liveOverlay)
    }

    // MARK: - Culling (IM-038)

    /// How many committed shapes the last draw pass stroked. A test seam for IM-038.
    private(set) var shapesDrawnInLastPass = 0

    /// How strongly a markup the ledger filter dims is drawn (V-003).
    static let dimmedMarkupAlpha: CGFloat = 0.25

    /// Each shape's padded on-screen bounds, for the current transform and shape list.
    private var shapeViewBounds: [CGRect]?

    private func invalidateShapeBounds() { shapeViewBounds = nil }

    /// Each shape's ink rectangle in page space (``CanvasHitTesting/inkBounds(of:)``), parallel
    /// to ``shapes``: computed once per shape list, so a pointer move rejects a shape far from
    /// the pointer with one rectangle comparison instead of an exact test (S-005).
    var shapeInkBounds: [PDFRectValue?] {
        if let cached = cachedShapeInkBounds, cached.count == shapes.count { return cached }
        let computed = shapes.map(CanvasHitTesting.inkBounds(of:))
        cachedShapeInkBounds = computed
        return computed
    }
    private var cachedShapeInkBounds: [PDFRectValue?]?

    /// The rectangle a shape can put ink in, generously padded for pills, arrowheads, ticks,
    /// count symbols and selection handles. A stamp can rotate about its anchor and is never
    /// culled.
    static func paddedViewBounds(of shape: CanvasMarkupShape, transform: PageDisplayTransform) -> CGRect {
        if shape.stamp != nil { return .infinite }
        var points: [PDFPointValue] = []
        for stroke in shape.strokes { points.append(contentsOf: stroke.points) }
        points.append(contentsOf: shape.counts)
        if let leader = shape.leaderTarget { points.append(leader) }
        // The box as drawn — turned with the words when the markup is turned (T-002).
        let box = shape.drawnBox
        points.append(PDFPointValue(x: box.minX, y: box.minY))
        points.append(PDFPointValue(x: box.maxX, y: box.maxY))
        var rect = CGRect.null
        for point in points {
            let view = transform.viewPoint(from: point)
            rect = rect.union(CGRect(origin: view, size: .zero))
        }
        guard !rect.isNull else { return .infinite }
        let stroke = CGFloat(max(0.25, shape.lineWidth * Double(transform.zoom)))
        let caption = CGFloat((shape.caption?.count ?? 0) * 8 + 32)
        // A count mark reaches half its drawn size plus its keyline from its point (L-15).
        let mark = shape.counts.isEmpty ? 0
            : CanvasCountSymbolPainter.drawnSizeInView(for: shape.symbol, zoom: CGFloat(transform.zoom)) / 2
                + CanvasCountSymbolPainter.keylineWidth + 2
        let pad = max(48, stroke * 2 + 24, caption, countNumberReach(of: shape, zoom: CGFloat(transform.zoom)), mark)
        let padded = rect.insetBy(dx: -pad, dy: -pad)
        // A caption dragged away from its markup (NL-MEASURE-09) draws beyond the pad: the padded
        // rectangle moved by the stored offset holds the pill, and the union holds the leader
        // back to its automatic place. Without it the pill was culled with the markup and could
        // be neither seen nor grabbed once the markup left the redraw rectangle (V-011).
        return Self.movedByCaption(padded, offset: captionViewOffset(of: shape, transform: transform))
    }

    /// `padded` together with itself moved by a caption offset in view points.
    static func movedByCaption(_ padded: CGRect, offset: CGSize) -> CGRect {
        guard offset != .zero else { return padded }
        return padded.union(padded.offsetBy(dx: offset.width, dy: offset.height))
    }

    /// How far a numbered count mark's number reaches from the mark, in view points: its offset
    /// plus its text, both of which grow with zoom (`CanvasCountNumbers.drawNumber`). The fixed
    /// pad stopped covering it from about 400 %, so a partial redraw culled the shape and the
    /// number came out cut off (R-012). 0 for a shape without numbers.
    static func countNumberReach(of shape: CanvasMarkupShape, zoom: CGFloat) -> CGFloat {
        guard let largest = shape.countNumbers.max() else { return 0 }
        let digits = CGFloat(String(largest).count)
        let size = max(8, 7 * zoom), offset = max(5, 5 * zoom)
        // A monospaced digit is about 0.6 of the font size wide and a line about 1.2 tall;
        // 1.3 per digit covers either, plus the backing's inset.
        return offset + 1.3 * size * max(digits, 1) + 4
    }

    private func viewBounds(for index: Int, transform: PageDisplayTransform) -> CGRect {
        if shapeViewBounds?.count != shapes.count {
            shapeViewBounds = shapes.map { Self.paddedViewBounds(of: $0, transform: transform) }
        }
        let bounds = shapeViewBounds?[index] ?? .infinite
        // The caption in flight moves with the pointer, so its reach is added per pass rather
        // than cached (V-011).
        if let drag = captionDragPreview, shapes.indices.contains(index), shapes[index].id == drag.id {
            return Self.movedByCaption(bounds, offset: drag.delta)
        }
        return bounds
    }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The armed verb's cursor. The first shared tool rule is that the cursor changes.
    /// Before this only the space-held pan ever touched `NSCursor`, so every
    /// armed tool looked identical to Select under the pointer; then the tool booleans
    /// arrived and Apply and Place still looked identical to Select, because neither is a
    /// tool. One assignment decides it now, and ``ZenitCanvasCursor`` owns the artwork.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursorKind.nsCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let signpost = CanvasLog.signposter.beginInterval("CanvasDraw")
        defer { CanvasLog.signposter.endInterval("CanvasDraw", signpost) }
        if compositesRasters {
            // The backdrop is the scroll view's, the paper and every raster are layers under
            // this view: nothing of the page's pixels is drawn — or resampled — on the main
            // thread (NL-PERF-05). What remains is ink.
            tilesDrawnInLastPass = 0
            guard let transform else { return }
            drawInk(transform: transform, context: context, dirtyRect: dirtyRect)
            return
        }
        ZPDFColor.nsColor(.canvasBackdrop).setFill()
        dirtyRect.fill()

        guard let transform else { return }
        let frame = transform.pageFrame

        // The sheet. Drawn even before the raster arrives, so the page has its real proportions
        // from the first frame rather than appearing at the wrong size and then jumping.
        CanvasMarkupStyle.paper.setFill()
        frame.fill()
        // Which picture of the page this frame shows, in priority order. The benchmark
        // inverted the originally planned layer order and this is what the inversion means in code
        // (gate Z10):
        //
        // 1. the raster for *this* zoom, if it has landed — a 1:1 copy onto whole device
        //    pixels, and the only layer that is the page;
        // 2. otherwise the vector underlay, if it is available and current — the drawing's own
        //    linework, sharp at any zoom, 0.61-0.92 ms, and correct at the zoom the user just
        //    arrived at. A skeleton: geometry only, no text, no colour, no shading, no images;
        // 3. otherwise the raster from the previous zoom, resampled. That is what the canvas
        //    used to show *always*, and it is what an estimator called laggy.
        //
        // The underlay is not drawn under an opaque raster, because an opaque raster hides it;
        // it is drawn in place of a raster that has gone stale, which is the moment it helps.
        let rasterPlacement = pageRaster?.placement(in: transform, backingScale: effectiveBackingScale)
        let underlayPlacement = underlayRaster?.placement(in: transform, backingScale: effectiveBackingScale)
        let tilePlacements = tileRasters.map { ($0, $0.placement(in: transform, backingScale: effectiveBackingScale)) }
        let tilesCover = Self.tiles(tilePlacements.map(\.1.destination), cover: dirtyRect.intersection(frame))
        if !tilesCover {
            // Whatever stands in for tiles still rendering, in the same priority order as a
            // single raster: an exact raster, then the underlay, then yesterday's pixels.
            if let pageRaster, let rasterPlacement, rasterPlacement.isPixelExact {
                blit(pageRaster, placement: rasterPlacement, context: context)
            } else if let underlayRaster, let underlayPlacement, underlayPlacement.isPixelExact {
                blit(underlayRaster, placement: underlayPlacement, context: context)
            } else {
                for stale in staleTileRasters {
                    let placement = stale.placement(in: transform, backingScale: effectiveBackingScale)
                    guard placement.destination.intersects(dirtyRect) else { continue }
                    blit(stale, placement: placement, context: context)
                }
                if let pageRaster, let rasterPlacement {
                    blit(pageRaster, placement: rasterPlacement, context: context)
                }
            }
        }
        var tilesDrawn = 0
        for (tile, placement) in tilePlacements where placement.destination.intersects(dirtyRect) {
            blit(tile, placement: placement, context: context)
            tilesDrawn += 1
        }
        tilesDrawnInLastPass = tilesDrawn
        drawInk(transform: transform, context: context, dirtyRect: dirtyRect)
    }

    /// Everything on the sheet that is not the sheet's own pixels: its edge, the coverage tint,
    /// the committed markups and the search highlights.
    private func drawInk(transform: PageDisplayTransform, context: CGContext, dirtyRect: NSRect) {
        let frame = transform.pageFrame
        ZPDFColor.nsColor(.border).setStroke()
        NSBezierPath(rect: frame).stroke()

        // The coverage tint sits under the ink: it says where measurements *are*, and the
        // measurements themselves stay fully legible on top of it.
        if let coverage = coverageOverlay {
            drawCoverage(coverage, transform: transform)
        }
        // Zone and region outlines and calibration picks sit under the markups: they are
        // reference geometry, and the measurements stay legible on top (U-086).
        boundaryMarkIDsDrawnInLastPass = drawBoundaryMarks(transform: transform)

        var drawn = 0
        insertedImagesDrawnInLastPass = 0
        for (index, shape) in shapes.enumerated() {
            // Only the shapes whose ink can reach the dirty rectangle: zoomed into a dense
            // sheet, a scroll or a small invalidation strokes a handful, not thousands.
            if cullsToDirtyRect {
                guard viewBounds(for: index, transform: transform).intersects(dirtyRect) else { continue }
            }
            // A markup the ledger filter dims draws faintly — ink, fill, pill and all — unless it
            // is selected, when its handles must read (V-003).
            if shape.isDimmed, !selection.contains(shape.id) {
                context.saveGState()
                context.setAlpha(Self.dimmedMarkupAlpha)
                draw(shape, transform: transform, context: context)
                context.restoreGState()
            } else {
                draw(shape, transform: transform, context: context)
            }
            drawn += 1
        }
        shapesDrawnInLastPass = drawn
        drawDoubleCountHatch(transform: transform)
        drawTraceFences(transform: transform)   // NL-MEASURE-11
        drawSearchHighlights(transform: transform)
        drawAutomationOverlay(transform: transform)
    }

    /// The live layer, drawn by ``CanvasLiveOverlayView`` into the same flipped coordinates.
    func drawLiveLayer(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let transform else { return }
        if liveDragAnchor != nil {
            drawDragPreview(transform: transform)
        } else if let quad = liveInferredQuad, quad.count >= 3 {
            drawInferredQuad(quad, transform: transform)
        } else {
            drawLiveMeasurement(transform: transform, context: context)
        }
        drawCalibration(transform: transform, context: context)
        if let cursor = live.drawing.keyboardCursor { drawKeyboardCursor(cursor, transform: transform) }
        drawSnap(transform: transform)
        drawHover(transform: transform)
        drawLedgerHover(transform: transform)   // NL-UX-09
        drawRenderNotice()
        if let selectionMarquee {
            // The Select tool's rubber band: dashed, in the selection tint, filled faintly
            // so the region it is claiming is visible over a busy drawing.
            let rect = transform.viewRect(from: selectionMarquee)
            let path = NSBezierPath(rect: rect)
            CanvasMarkupStyle.selectionInk.withAlphaComponent(0.10).setFill()
            path.fill()
            path.lineWidth = ZPDFStroke.regular
            path.setLineDash([4, 3], count: 2, phase: 0)
            CanvasMarkupStyle.selectionInk.setStroke()
            path.stroke()
        }
        if let marquee = zoomMarqueeViewRect {
            // The marquee: dashed accent, no fill — it frames what the release zooms into.
            let path = NSBezierPath(rect: marquee)
            path.lineWidth = ZPDFStroke.emphasis
            path.setLineDash([5, 3], count: 2, phase: 0)
            CanvasMarkupStyle.liveInk.setStroke()
            path.stroke()
        }
    }

    /// The keyboard cursor (R-137): a crosshair with a ring in the live ink, so a person placing
    /// points with the arrow keys sees where Return puts the next one. Inside ``CanvasLiveState/inkPadding``.
    private func drawKeyboardCursor(_ point: PDFPointValue, transform: PageDisplayTransform) {
        let centre = transform.viewPoint(from: point)
        let arm: CGFloat = 9
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - arm, y: centre.y))
        path.line(to: NSPoint(x: centre.x + arm, y: centre.y))
        path.move(to: NSPoint(x: centre.x, y: centre.y - arm))
        path.line(to: NSPoint(x: centre.x, y: centre.y + arm))
        path.appendOval(in: NSRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8))
        path.lineWidth = ZPDFStroke.emphasis
        CanvasMarkupStyle.liveInk.setStroke()
        path.stroke()
    }

    /// Whether tile destinations cover a rectangle. Coarse but exact for a tile grid: each
    /// tile is clipped to the target and the clipped areas summed; tiles never overlap.
    static func tiles(_ destinations: [CGRect], cover target: CGRect) -> Bool {
        guard !target.isNull, target.width > 0, target.height > 0 else { return true }
        guard !destinations.isEmpty else { return false }
        var covered: CGFloat = 0
        for rect in destinations {
            let clipped = rect.intersection(target)
            if !clipped.isNull { covered += clipped.width * clipped.height }
        }
        return covered >= target.width * target.height - 1
    }

    /// The fraction of `target` (view space) that the rasters this view would draw right now
    /// actually cover — the same choice ``draw(_:)`` makes, as geometry. Gate Z12's seam: a
    /// frame whose visible sheet is not covered is a frame of blank paper.
    ///
    /// `target` is in display coordinates: while a gesture transform is live, the sheet and
    /// every raster are mapped through it first, because that is where the compositor puts them.
    func drawnRasterCoverage(of target: CGRect) -> Double {
        guard let transform else { return 0 }
        if let rasterLayerView {
            let live = liveDisplayTransform ?? .identity
            let visibleSheet = target.intersection(transform.pageFrame.applying(live))
            guard !visibleSheet.isNull, visibleSheet.width > 0, visibleSheet.height > 0 else { return 1 }
            let rects = rasterLayerView.displayed.map { $0.frame.applying(live) }
            return Self.coveredFraction(of: visibleSheet, by: rects)
        }
        let visibleSheet = target.intersection(transform.pageFrame)
        guard !visibleSheet.isNull, visibleSheet.width > 0, visibleSheet.height > 0 else { return 1 }
        let scale = effectiveBackingScale
        let tileRects = tileRasters.map { $0.placement(in: transform, backingScale: scale).destination }
        var rects = tileRects
        if !Self.tiles(tileRects, cover: visibleSheet) {
            let raster = pageRaster?.placement(in: transform, backingScale: scale)
            let underlay = underlayRaster?.placement(in: transform, backingScale: scale)
            if let raster, raster.isPixelExact {
                rects.append(raster.destination)
            } else if let underlay, underlay.isPixelExact {
                rects.append(underlay.destination)
            } else {
                rects += staleTileRasters.map { $0.placement(in: transform, backingScale: scale).destination }
                if let raster { rects.append(raster.destination) }
            }
        }
        return Self.coveredFraction(of: visibleSheet, by: rects)
    }

    /// The fraction of `target` inside the union of `rects`, sampled on a 200 × 125 grid of
    /// cell centres (a resolution of 0.004 %, well under Z12's 0.1 % threshold). Overlapping
    /// rectangles are counted once, which a sum of intersections would not do.
    static func coveredFraction(of target: CGRect, by rects: [CGRect]) -> Double {
        guard !target.isNull, target.width > 0, target.height > 0 else { return 1 }
        let candidates = rects.filter { !$0.isNull && $0.intersects(target) }
        guard !candidates.isEmpty else { return 0 }
        let columns = 200
        let rows = 125
        var covered = 0
        for row in 0..<rows {
            let y = target.minY + (CGFloat(row) + 0.5) * target.height / CGFloat(rows)
            for column in 0..<columns {
                let x = target.minX + (CGFloat(column) + 0.5) * target.width / CGFloat(columns)
                let point = CGPoint(x: x, y: y)
                if candidates.contains(where: { $0.contains(point) }) { covered += 1 }
            }
        }
        return Double(covered) / Double(columns * rows)
    }

    /// The Select tool's hover: a thin dashed outline round what a click would pick, and its
    /// name and value beside it so the cue is not colour-only (IM-043).
    /// The markup the overlay's hover outline and label are drawn for: the hovered markup while
    /// it is not selected (a selected markup carries its own pill and handles). L-13's seam.
    var hoverOutlineMarkupID: UUID? {
        guard let hoverTarget, !selection.contains(hoverTarget.markupID) else { return nil }
        return hoverTarget.markupID
    }

    private func drawHover(transform: PageDisplayTransform) {
        guard let id = hoverOutlineMarkupID,
              let shape = shapes.first(where: { $0.id == id }) else { return }
        let box = shape.drawnBox   // framed as drawn, turned or not (T-002)
        let rect = transform.viewRect(from: box).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: rect, xRadius: ZPDFRadius.small, yRadius: ZPDFRadius.small)
        path.lineWidth = ZPDFStroke.regular
        path.setLineDash([3, 2], count: 2, phase: 0)
        CanvasMarkupStyle.selectionInk.withAlphaComponent(0.8).setStroke()
        path.stroke()
        if let caption = shape.caption, !caption.isEmpty {
            drawPill(caption, centeredAt: CGPoint(x: rect.midX, y: rect.minY - 12), fill: nil)
        }
    }

    /// Search hits, drawn with the committed ink on the sheet.
    private func drawSearchHighlights(transform: PageDisplayTransform) {
        guard !searchHighlights.isEmpty else { return }
        for highlight in searchHighlights {
            // Inset outwards: a text run's bounds hug the glyphs, and a highlight flush to
            // the ink is hard to see against a busy drawing.
            let rect = transform.viewRect(from: highlight).insetBy(dx: -2, dy: -2)
            let path = NSBezierPath(roundedRect: rect, xRadius: ZPDFRadius.hairline, yRadius: ZPDFRadius.hairline)
            CanvasMarkupStyle.searchInk.withAlphaComponent(0.28).setFill()
            path.fill()
            path.lineWidth = ZPDFStroke.emphasis
            CanvasMarkupStyle.searchInk.setStroke()
            path.stroke()
        }
    }

    /// Draws one raster into the page.
    ///
    /// The view is flipped, so the context's y axis points down. `CGContext.draw` places an
    /// image's first row at the *bottom* of the destination rectangle in the current space,
    /// which in a flipped context means the page would come out upside down. Undo the flip
    /// for the duration of the draw rather than pre-flipping the raster, which would cost a
    /// full-page copy on every frame.
    ///
    /// Interpolation is chosen from the placement rather than fixed. At 1:1 onto whole device
    /// pixels there is nothing to interpolate and asking for `.high` anyway is what used to
    /// cost 15.5 ms of a 16.6 ms frame; while a raster is stale the resample is real and
    /// `.high` is what the page should look like for those few milliseconds.
    private func blit(_ raster: PageRaster, placement: PageRasterPlacement, context: CGContext) {
        guard placement.destination.width > 0, placement.destination.height > 0 else { return }
        context.saveGState()
        context.interpolationQuality = placement.isPixelExact ? .none : .high
        context.translateBy(x: placement.destination.minX, y: placement.destination.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(raster.image, in: CGRect(origin: .zero, size: placement.destination.size))
        context.restoreGState()
    }

    private func draw(_ shape: CanvasMarkupShape, transform: PageDisplayTransform, context: CGContext) {
        let color = NSColor(
            srgbRed: shape.color.red,
            green: shape.color.green,
            blue: shape.color.blue,
            alpha: shape.color.alpha
        )
        let isSelected = selection.contains(shape.id)

        // The stored fill wins; a markup stored before styles carried a fill derives one from
        // its stroke at the shared area tint (20 %), the same value the
        // Inspector's Fill Colour row shows for it.
        let fill = shape.fill.map {
            NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
        } ?? color.withAlphaComponent(shape.color.alpha * MarkupFillDefaults.derivedAreaFillAlpha)

        // The stroke the markup was *given*, not a constant.
        //
        // Until 2026-08-27 every markup was stroked at `ZPDFStroke.measurement` and nothing read
        // `shape.lineWidth`, which the scene had been carrying all along. Opacity and line style
        // were not carried at all. So the Inspector could set 9 pt dotted at 40 % and the arrow
        // stayed thin, solid and opaque. Colour worked, and only colour, because colour is the one field this function read.
        // The tape: dashed, uncaptioned, and done. It returns before pills, dimension
        // decorations and selection handles because none of those may suggest a committed
        // measurement.
        if shape.isTemporary {
            let tape = CanvasMarkupStyle.snapInk
            for stroke in shape.strokes where stroke.points.count >= 2 {
                let path = bezierPath(stroke.points, closed: stroke.closed, transform: transform)
                path.lineWidth = ZPDFStroke.emphasis
                path.setLineDash([5, 4], count: 2, phase: 0)
                tape.setStroke()
                path.stroke()
            }
            // The value, small and unboxed — a reading, not a row.
            if let caption = shape.caption, let anchor = shape.strokes.first?.points.last {
                let view = transform.viewPoint(from: anchor)
                let text = NSAttributedString(string: caption, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: tape
                ])
                text.draw(at: CGPoint(x: view.x + 8, y: view.y - 14))
            }
            return
        }

        let inkOpacity = min(1, max(0, shape.opacity))
        let ink = color.withAlphaComponent(color.alphaComponent * inkOpacity)
        let inkFill = fill.withAlphaComponent(fill.alphaComponent * inkOpacity)
        // Page points to view points: a 9 pt line is 9 pt *on the sheet*, so it thickens as the
        // reader zooms in, exactly as the drawing under it does.
        let storedWidth = max(0.25, shape.lineWidth * Double(transform.zoom))
        // A callout's frame and leader are floored so the note never reads as a faint box.
        let strokeWidth = shape.kind == .callout ? max(storedWidth, CanvasMarkupStyle.calloutMinimumBorder) : storedWidth

        // The selection halo sits *under* the ink: a soft band in the selection colour along
        // the markup's own strokes, so a selected area reads as the design's heavier outline and
        // a red callout still says "selected" in a colour that is not its own.
        if isSelected {
            drawSelectionHalo(shape, strokeWidth: strokeWidth, transform: transform)
        }

        // A cutout is a hole in the fill: the outer ring and its holes fill as one even-odd
        // path. Filling each ring as its own path covered the courtyard with the outer fill,
        // and the deducted region read as *more* measured than the rest (BH-340).
        let holes = CanvasHitTesting.holes(of: shape)
        // ADR-0029: a highlighter's ink multiplies with the drawing, so linework under it stays
        // readable. Restored before the handles and the pill, which are never blended.
        if shape.multiplyBlend {
            context.saveGState()
            context.setBlendMode(.multiply)
        }
        for stroke in shape.strokes {
            guard stroke.points.count >= 2 else { continue }
            // A callout's border is a rounded note, not a sharp polygon, and it always has a
            // backing: the stored fill when there is one, otherwise paper faintly tinted by its
            // ink, so the note reads over dense linework. A turned callout draws its turned
            // polygon instead (ADR-0029).
            if shape.kind == .callout || stroke.calloutBox, stroke.closed, shape.rotationDegrees == 0,
               let box = shape.textBox {
                drawCalloutBox(
                    transform.viewRect(from: box).standardized,
                    ink: ink,
                    fill: stroke.filled ? inkFill : CanvasMarkupStyle.calloutBacking(forInk: ink),
                    strokeWidth: strokeWidth,
                    lineStyle: shape.lineStyle
                )
                continue
            }
            let path = stroke.smooth
                ? Self.smoothPath(stroke.points.map { transform.viewPoint(from: $0) })
                : bezierPath(stroke.points, closed: stroke.closed, transform: transform)
            if stroke.filled, stroke.closed {
                let fillPath = bezierPath(stroke.points, closed: true, transform: transform)
                for hole in holes {
                    fillPath.append(bezierPath(hole, closed: true, transform: transform))
                }
                fillPath.windingRule = .evenOdd
                inkFill.setFill()
                fillPath.fill()
            }
            guard stroke.stroked else { continue }
            if stroke.calloutBox, stroke.closed, !stroke.filled, shape.kind == .cloud {
                // A clouded callout's box has the callout's backing, so its words read.
                CanvasMarkupStyle.calloutBacking(forInk: ink).setFill()
                path.fill()
            }
            ink.setStroke()
            path.lineWidth = strokeWidth
            if stroke.smooth {
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
            }
            // A revision cloud's scallops meet in cusps; a round join keeps each cusp clean
            // instead of spiking a miter out of it at thick widths.
            if shape.kind == .cloud || shape.lineStyle == .cloud { path.lineJoinStyle = .round }
            Self.applyDash(shape.lineStyle, to: path, strokeWidth: strokeWidth)
            path.stroke()

            // The decorations belong to the markup, so they fade with it. An arrowhead at full
            // opacity on a 40 % line is a markup that half faded.
            if stroke.dimensioned {
                drawDimensionDecoration(stroke, color: ink, transform: transform)
            }
            // nl-markup: the stored start and end decorations, not an arrowhead chosen by kind.
            if !stroke.closed, stroke.drawnEndCap != .none || stroke.startCap != .none {
                CanvasLineEnds.drawEnds(
                    of: stroke,
                    viewPoints: stroke.points.map { transform.viewPoint(from: $0) },
                    color: ink,
                    strokeWidth: strokeWidth
                )
            }
        }

        if shape.multiplyBlend { context.restoreGState() }

        if shape.kind == .note, let box = shape.strokes.first?.points {
            CanvasNoteGlyph.draw(corners: box.map { transform.viewPoint(from: $0) }, ink: ink)
        }

        if let text = shape.text, let box = shape.textBox {
            // ADR-0029: a separate text colour, faded with the markup like its ink.
            let textInk = shape.textStyle?.textColor.map {
                NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha * inkOpacity)
            } ?? ink
            let draw = {
                self.drawMarkupText(
                    text,
                    in: transform.viewRect(from: box),
                    color: textInk,
                    pointSize: shape.fontSize * Double(transform.zoom),
                    callout: shape.kind == .callout || shape.kind == .cloud,
                    fontName: shape.fontName,
                    alignment: shape.textAlignment,
                    bold: shape.textStyle?.bold ?? false,
                    italic: shape.textStyle?.italic ?? false,
                    explicitColour: shape.textStyle?.textColor != nil
                )
            }
            if shape.rotationDegrees != 0, let centre = shape.rotationCentre {
                // The box is stored unturned; the text turns about the same centre the strokes
                // turned about, measured after the page transform so a flipped view or a page
                // /Rotate turns it the right way.
                let c = transform.viewPoint(from: centre)
                let along = transform.viewPoint(from: CanvasSceneBuilder.turn(
                    PDFPointValue(x: centre.x + 1, y: centre.y), about: centre, degrees: shape.rotationDegrees
                ))
                let rest = transform.viewPoint(from: PDFPointValue(x: centre.x + 1, y: centre.y))
                let angle = atan2(along.y - c.y, along.x - c.x) - atan2(rest.y - c.y, rest.x - c.x)
                context.saveGState()
                context.translateBy(x: c.x, y: c.y)
                context.rotate(by: angle)
                context.translateBy(x: -c.x, y: -c.y)
                draw()
                context.restoreGState()
            } else {
                draw()
            }
        }

        // A placed stamp draws its **artwork**, not a box with text in it.
        if let stamp = shape.stamp {
            drawStamp(stamp, color: ink, transform: transform, context: context)
        }

        // The mark's **own** symbol, from `MarkupRecord.symbol` (ADR-0011
        // §2.1). This used to be an 8 × 8 oval with the glyph nailed shut, so a Door Count and
        // a Column Count were the same dot however the presets were configured.
        for (index, count) in shape.counts.enumerated() {
            let point = transform.viewPoint(from: count)
            CanvasCountSymbolPainter.draw(
                symbol: shape.symbol,
                artwork: shape.artwork,
                at: point,
                zoom: transform.zoom,
                backingScale: effectiveBackingScale,
                // The markup's stroke opacity, like its lines and text (BH-879).
                color: ink,
                in: context
            )
            // NL-MEASURE-12: the running number beside the mark (`CanvasCountNumbers.swift`).
            if shape.countNumbers.indices.contains(index) {
                CanvasCountNumbers.drawNumber(shape.countNumbers[index], beside: point, zoom: transform.zoom, color: ink)
            }
        }

        if isSelected {
            // A markup with no path to halo — a text box, a count group, a stamp — keeps a
            // dashed ring round its bounds, so selection never relies on the ink colour.
            if !shape.strokes.contains(where: { $0.points.count >= 2 }) || shape.stamp != nil {
                let rect = transform.viewRect(from: shape.bounds).insetBy(dx: -3, dy: -3)
                let ring = NSBezierPath(roundedRect: rect, xRadius: ZPDFRadius.hairline, yRadius: ZPDFRadius.hairline)
                ring.lineWidth = ZPDFStroke.emphasis
                ring.setLineDash([4, 3], count: 2, phase: 0)
                CanvasMarkupStyle.selectionInk.setStroke()
                ring.stroke()
            }
            // Handles sit on the markup's own vertices, because that is what dragging one
            // edits (`DocumentCommand.editVertices`). A shape with no vertex list — a
            // circle, an arc — keeps the eight box handles, which say "selected" without
            // promising an edit the geometry cannot take. Every handle is a circle. No
            // edge-midpoint dots: nothing on the canvas inserts a vertex at a midpoint, and a
            // dot that looks draggable but is not would be a dead affordance.
            let handles = shape.vertices.isEmpty
                ? handleCenters(of: transform.viewRect(from: shape.bounds))
                : shape.vertices.map { transform.viewPoint(from: $0) }
            let focusedIndex = shape.vertices.isEmpty || focusedVertex?.markupID != shape.id ? nil : focusedVertex?.index
            for (index, handle) in handles.enumerated() {
                drawHandle(at: handle, ring: CanvasMarkupStyle.selectionInk, focused: index == focusedIndex)
            }
            // A selected stamp gets one handle the other families do not: the rotation knob.
            if let stamp = shape.stamp, shape.kind != .image {
                drawStampRotationHandle(stamp, transform: transform)
            } else if let box = shape.rotationBox, selection.count == 1 {
                // r2-markup (NL-MARKUP-18): a text box, a shape or an image turns by the same
                // knob a stamp does, about its box centre. An image draws through a stamp
                // placement but turns by its style, so its knob comes from the one rotation box
                // the controller grabs by (`CanvasSceneBuilder.rotationBox(of:)`), not from the
                // placement — which drew it in a multiple selection too, where no press takes it
                // (U-006, iteration 4).
                drawStampRotationHandle(CanvasStampPlacement(
                    anchor: PDFPointValue(x: box.minX + box.size.width / 2, y: box.minY + box.size.height / 2),
                    widthPoints: box.size.width,
                    heightPoints: box.size.height,
                    rotationDegrees: shape.rotationDegrees
                ), transform: transform)
            }
        }

        // NL-MEASURE-09: a length beside every segment, when the caption asks for them.
        drawSegmentLabels(shape, transform: transform)

        if let caption = shape.caption {
            // NL-MEASURE-09: a dragged caption keeps its offset (CanvasCaptionPlacement.swift).
            beginCaptionPlacement(for: shape, transform: transform)
            defer { endCaptionPlacement() }
            // The label pill is filled with the markup's own colour, opaque, with light or dark
            // text by contrast: "Area: 620 SF" in white on blue.
            let pillFill = CanvasMarkupStyle.pillFill(forInk: color)
            if let area = shape.strokes.first(where: { $0.closed && $0.filled }) {
                // An area's pill anchors INSIDE the fill, with
                // the leader fallback for a concave outline the centroid escapes.
                // Never inside a cutout (BH-880).
                drawAreaPill(caption, polygon: area.points, holes: holes, color: color, transform: transform, shapeID: shape.id)
            } else if let length = shape.strokes.first(where: { $0.dimensioned && $0.points.count >= 2 }),
                      let center = Self.lengthPillCenter(
                          viewPoints: length.points.map { transform.viewPoint(from: $0) },
                          pillSize: CanvasMarkupStyle.pillBoxSize(forText: pillLayout(caption, tone: pillInk(onFill: pillFill)).1),
                          strokeWidth: strokeWidth
                      ) {
                // A length's value sits centred under the middle of its run, clear of the
                // shaft, as "24' - 0"" does in the design.
                drawPill(caption, centeredAt: center, fill: pillFill)
            } else if let anchor = shape.strokes.first?.points.first {
                // Committed ink keeps one side whatever the scroll (V-015): only the live pill
                // flips by the visible area, since a scroll never redraws the page.
                drawPill(caption, at: transform.viewPoint(from: anchor), fill: pillFill, within: bounds)
            } else if let first = Self.countCaptionAnchor(shape.counts) {
                // A count has no strokes, and its caption was dropped: forty glyphs, no number
                // (BH-341). It hangs on a short leader from the group's top-left mark.
                let mark = transform.viewPoint(from: first)
                let end = CGPoint(x: mark.x + 14, y: mark.y - 14)
                let leader = NSBezierPath()
                leader.move(to: mark)
                leader.line(to: end)
                leader.lineWidth = ZPDFStroke.measurement
                ink.setStroke()
                leader.stroke()
                drawPill(caption, at: end, fill: pillFill, within: bounds)
            }
        }
    }

    /// The soft band under a selected markup's strokes.
    private func drawSelectionHalo(_ shape: CanvasMarkupShape, strokeWidth: CGFloat, transform: PageDisplayTransform) {
        let halo = CanvasMarkupStyle.selectionInk.withAlphaComponent(CanvasMarkupStyle.selectionHaloAlpha)
        halo.setStroke()
        for stroke in shape.strokes where stroke.points.count >= 2 {
            let path: NSBezierPath
            if shape.kind == .callout || stroke.calloutBox, stroke.closed, shape.rotationDegrees == 0,
               let box = shape.textBox {
                let rect = transform.viewRect(from: box).standardized
                let radius = CanvasMarkupStyle.calloutCornerRadius(for: rect)
                path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            } else {
                path = bezierPath(stroke.points, closed: stroke.closed, transform: transform)
            }
            path.lineWidth = strokeWidth + CanvasMarkupStyle.selectionHaloExtraWidth
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            // L-16: a dashed or dotted markup's halo breaks where its ink does. A continuous
            // 6-pt band under a 0.6-pt dashed line read as one solid line, so a selected
            // Length drawn dashed looked solid beside an Inspector that said "Dashed".
            if var dash = Self.selectionHaloDash(shape.lineStyle, strokeWidth: strokeWidth) {
                path.lineCapStyle = .butt
                path.setLineDash(&dash, count: dash.count, phase: 0)
            }
            path.stroke()
        }
    }

    /// The selection halo's dash, in step with ``applyDash(_:to:strokeWidth:)``'s ink pattern, or
    /// `nil` for a solid line or a cloud, whose halo stays one continuous band (L-16).
    static func selectionHaloDash(_ style: MarkupLineStyle, strokeWidth: Double) -> [CGFloat]? {
        let unit = CGFloat(max(1, strokeWidth))
        switch style {
        case .solid, .cloud: return nil
        case .dashed: return [unit * 4, unit * 3]
        case .dotted: return [unit, unit * 2.2]
        case .dashDot: return [unit * 4, unit * 2, unit, unit * 2]
        }
    }

    /// A callout's note: a rounded box with its backing, stroked in the markup's ink and style.
    private func drawCalloutBox(
        _ rect: CGRect,
        ink: NSColor,
        fill: NSColor,
        strokeWidth: CGFloat,
        lineStyle: MarkupLineStyle
    ) {
        let radius = CanvasMarkupStyle.calloutCornerRadius(for: rect)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        ink.setStroke()
        path.lineWidth = strokeWidth
        Self.applyDash(lineStyle, to: path, strokeWidth: strokeWidth)
        path.stroke()
    }

    /// One vertex handle: a paper-filled circle ringed in `ring`, so it reads on the white
    /// sheet, on a tinted fill and on the ink itself.
    ///
    /// The focused handle (T-001) is larger and filled with the ring's own ink.
    private func drawHandle(at center: CGPoint, ring: NSColor, focused: Bool = false) {
        let side = focused ? CanvasMarkupStyle.focusedHandleDiameter : CanvasMarkupStyle.handleDiameter
        let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let path = NSBezierPath(ovalIn: box)
        (focused ? ring : CanvasMarkupStyle.paper).setFill()
        path.fill()
        path.lineWidth = CanvasMarkupStyle.handleBorderWidth
        ring.setStroke()
        path.stroke()
    }

    /// Where a length's pill is centred: under the midpoint of the run, measured along the
    /// path, pushed off the shaft by the pill's own extent plus a gap. "Under" is the side of
    /// the segment facing down the screen; on a vertical segment it is the right-hand side.
    nonisolated static func lengthPillCenter(
        viewPoints: [CGPoint],
        pillSize: CGSize,
        strokeWidth: CGFloat = 0
    ) -> CGPoint? {
        guard viewPoints.count >= 2 else { return nil }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in 1..<viewPoints.count {
            let a = viewPoints[index - 1], b = viewPoints[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            lengths.append(length)
            total += length
        }
        guard total > 0.5 else { return nil }
        var remaining = total / 2
        var segment = 0
        while segment < lengths.count - 1, remaining > lengths[segment] {
            remaining -= lengths[segment]
            segment += 1
        }
        let a = viewPoints[segment], b = viewPoints[segment + 1]
        let length = max(lengths[segment], 0.0001)
        let t = min(1, max(0, remaining / length))
        let mid = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        // The flipped view's y grows downward, so the normal with positive y faces down.
        var nx = -uy, ny = ux
        if ny < 0 || (abs(ny) < 1e-6 && nx < 0) { nx = -nx; ny = -ny }
        let reach = abs(nx) * pillSize.width / 2 + abs(ny) * pillSize.height / 2
        let offset = reach + CanvasMarkupStyle.lengthPillGap + strokeWidth / 2
        return CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)
    }

    // MARK: - Stamps

    /// How far above a selected stamp's top edge the rotation knob sits, in **view** points.
    ///
    /// View points rather than page points, so the knob is the same distance from the hand at
    /// 25 % and at 400 %. A page-space gap would put the knob inside a title block at one zoom
    /// and off the sheet at another.
    static let stampRotationHandleGapViewPoints: CGFloat = 22
    /// The knob's radius, in view points.
    static let stampRotationHandleRadiusViewPoints: CGFloat = 4.5

    /// Draws a placed stamp: its artwork if it has any, and its frozen text.
    ///
    /// The border is not drawn here — it is a `CanvasStroke` of the box's rotated corners and
    /// the ordinary stroke loop has already drawn it. Everything below is placed by mapping
    /// stamp-local or artwork-unit coordinates into **page space** through
    /// `CanvasStampPlacement`, and then through the same `PageDisplayTransform` the border
    /// went through. Nothing rotates a `CGContext` to position geometry, which is what keeps
    /// the seal, the frame and the hit test in agreement under a page `/Rotate`.
    /// The coverage map: every measured region under one translucent tint, and a badge that
    /// says the fraction in words. Even-odd fill so a region's cutout holes read as uncovered.
    private func drawCoverage(_ coverage: CoverageOverlay, transform: PageDisplayTransform) {
        if !coverage.rings.isEmpty {
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for ring in coverage.rings where ring.count >= 3 {
                path.move(to: transform.viewPoint(from: ring[0]))
                for point in ring.dropFirst() {
                    path.line(to: transform.viewPoint(from: point))
                }
                path.close()
            }
            CanvasMarkupStyle.onPaper(.success).withAlphaComponent(0.16).setFill()
            path.fill()
            CanvasMarkupStyle.onPaper(.success).withAlphaComponent(0.5).setStroke()
            path.lineWidth = ZPDFStroke.regular
            path.stroke()
        }

        // The badge, pinned to the sheet's top-left corner (the view is flipped).
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: ZPDFColor.nsColor(.textPrimary)
        ]
        let text = coverage.label as NSString
        let textSize = text.size(withAttributes: attributes)
        let frame = transform.pageFrame
        let badge = CGRect(
            x: frame.minX + 8,
            y: frame.minY + 8,
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        let pill = NSBezierPath(roundedRect: badge, xRadius: CanvasMarkupStyle.pillCornerRadius, yRadius: CanvasMarkupStyle.pillCornerRadius)
        ZPDFColor.nsColor(.elevated).withAlphaComponent(0.94).setFill()
        pill.fill()
        ZPDFColor.nsColor(.success).withAlphaComponent(0.6).setStroke()
        pill.stroke()
        text.draw(
            at: CGPoint(x: badge.minX + 6, y: badge.minY + 3),
            withAttributes: attributes
        )
    }

    private func drawStamp(
        _ stamp: CanvasStampPlacement,
        color: NSColor,
        transform: PageDisplayTransform,
        context: CGContext
    ) {
        if let digest = stamp.rasterImageDigest, let image = insertedImagePixels[digest] {
            // ADR-0043 (L-81): an inserted picture from its own pixels, not its 96-cell mosaic.
            drawInsertedImage(image, stamp: stamp, color: color, transform: transform, context: context)
        } else if let artwork = stamp.artwork, !artwork.isEmpty {
            drawStampArtwork(artwork, stamp: stamp, color: color, transform: transform, context: context)
        }
        guard !stamp.lines.isEmpty else { return }
        drawStampText(stamp, color: color, transform: transform, context: context)
    }

    /// An inserted image drawn from its pixels into its letterboxed, turned box (ADR-0043).
    ///
    /// The artwork's unit square is mapped to the view through the same `pagePoint(unit:)` the
    /// mosaic, the border and the rotation knob use, so the picture sits exactly where its
    /// geometry did and turns with its box; Core Graphics resamples it at the zoom on screen.
    private func drawInsertedImage(
        _ image: CGImage,
        stamp: CanvasStampPlacement,
        color: NSColor,
        transform: PageDisplayTransform,
        context: CGContext
    ) {
        let origin = transform.viewPoint(from: stamp.pagePoint(unit: PDFPoint(x: 0, y: 0)))
        let right = transform.viewPoint(from: stamp.pagePoint(unit: PDFPoint(x: 1, y: 0)))
        let up = transform.viewPoint(from: stamp.pagePoint(unit: PDFPoint(x: 0, y: 1)))
        let unitToView = CGAffineTransform(
            a: right.x - origin.x, b: right.y - origin.y,
            c: up.x - origin.x, d: up.y - origin.y,
            tx: origin.x, ty: origin.y
        )
        guard [unitToView.a, unitToView.b, unitToView.c, unitToView.d, unitToView.tx, unitToView.ty].allSatisfy(\.isFinite)
        else { return }
        context.saveGState()
        context.concatenate(unitToView)
        context.interpolationQuality = .high
        context.setAlpha(color.alphaComponent)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.restoreGState()
        insertedImagesDrawnInLastPass &+= 1
    }

    /// Compiled artwork, drawn as geometry.
    ///
    /// **There is no image in this path.** A vector source compiled to contours, and a raster
    /// source compiled to its bounded mosaic, are both filled polygons and stroked polylines
    /// here — so magnifying the canvas multiplies coordinates and never resamples, which is the
    /// structural half of the "sharp at 400 %" requirement. A raster stamp's cells grow with
    /// the zoom, visibly and predictably, which is the honest degradation ADR-0011 §2.4 chose.
    ///
    /// Vector artwork carries no ink of its own — `VectorPrimitive` records paint role and
    /// stroke width, not colour (ADR-0011 §2.4) — so it takes the stamp's style colour. A
    /// mosaic cell keeps the colour it was sampled with, because a mosaic without colour is not
    /// a picture.
    private func drawStampArtwork(
        _ artwork: ArtworkGeometry,
        stamp: CanvasStampPlacement,
        color: NSColor,
        transform: PageDisplayTransform,
        context: CGContext
    ) {
        func viewPoint(_ unit: PDFPoint) -> CGPoint {
            transform.viewPoint(from: stamp.pagePoint(unit: unit))
        }

        context.saveGState()
        for region in artwork.regions where region.outer.count >= 3 {
            let path = CGMutablePath()
            path.addLines(between: region.outer.map(viewPoint))
            path.closeSubpath()
            for hole in region.holes where hole.count >= 3 {
                path.addLines(between: hole.map(viewPoint))
                path.closeSubpath()
            }
            context.addPath(path)
            if let own = region.color {
                context.setFillColor(CGColor(
                    srgbRed: CGFloat(own.red),
                    green: CGFloat(own.green),
                    blue: CGFloat(own.blue),
                    alpha: CGFloat(own.alpha)
                ))
            } else {
                context.setFillColor(color.cgColor)
            }
            // Even-odd, as everywhere else in Zenit, which is what makes a hole a hole.
            context.fillPath(using: .evenOdd)
        }

        // Stroke widths are a fraction of the artwork box's smaller edge (`ArtworkContour`), so
        // a seal scaled from 96 points to 400 keeps its line weights in proportion — and so the
        // weight has to be resolved in *view* points, against the fitted size at this zoom.
        let fitted = stamp.fittedArtworkSize
        let minimumEdge = CGFloat(Swift.min(fitted.width, fitted.height)) * transform.zoom
        context.setStrokeColor(color.cgColor)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        for stroke in artwork.strokes where stroke.points.count >= 2 {
            let width = stroke.widthFraction > 0
                ? CGFloat(stroke.widthFraction) * minimumEdge
                : Swift.max(0.5, minimumEdge * 0.02)
            context.setLineWidth(Swift.max(0.4, width))
            let path = CGMutablePath()
            path.addLines(between: stroke.points.map(viewPoint))
            if stroke.isClosed { path.closeSubpath() }
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The stamp's frozen field text, turned with the box.
    ///
    /// The text is the one part that cannot be placed vertex by vertex, so the context *is*
    /// rotated for it — by the angle the stamp's own x axis comes out at **after** the page
    /// transform, measured rather than assumed. Reading the angle off the transformed axis is
    /// what makes the text turn the right way in a flipped view and under a page `/Rotate`,
    /// where the sign of the rotation is not the sign stored on the record.
    private func drawStampText(
        _ stamp: CanvasStampPlacement,
        color: NSColor,
        transform: PageDisplayTransform,
        context: CGContext
    ) {
        let centre = transform.viewPoint(from: stamp.anchor)
        let alongX = transform.viewPoint(from: stamp.pagePoint(localX: stamp.widthPoints / 2, localY: 0))
        let angle = atan2(alongX.y - centre.y, alongX.x - centre.x)
        let width = CGFloat(stamp.widthPoints) * transform.zoom
        let height = CGFloat(stamp.heightPoints) * transform.zoom
        guard width > 2, height > 2 else { return }

        context.saveGState()
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: angle)
        // The view is flipped and the text is not, so the box is flipped back for the draw.
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let box = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let text = stamp.lines.joined(separator: "\n")
        let pointSize = Swift.max(
            5,
            Swift.min(height / CGFloat(Swift.max(1, stamp.lines.count)) * 0.62, 200)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: pointSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(in: box.insetBy(dx: 2, dy: 1))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// The rotation knob of a selected stamp, and the stem that says what it turns about.
    ///
    /// `StampInstance.rotationDegrees` has been stored, persisted, honoured by the renderer and
    /// settable from a template since stamps first shipped, and no pointer affordance turned
    /// one. This is the affordance.
    func drawStampRotationHandle(
        _ stamp: CanvasStampPlacement,
        transform: PageDisplayTransform
    ) {
        let gapPagePoints = Double(Self.stampRotationHandleGapViewPoints / max(transform.zoom, 0.0001))
        let knob = transform.viewPoint(from: stamp.rotationHandlePoint(gapPoints: gapPagePoints))
        let top = transform.viewPoint(from: stamp.pagePoint(localX: 0, localY: stamp.heightPoints / 2))
        let stem = NSBezierPath()
        stem.move(to: top)
        stem.line(to: knob)
        stem.lineWidth = ZPDFStroke.measurement
        CanvasMarkupStyle.selectionInk.setStroke()
        stem.stroke()
        let radius = Self.stampRotationHandleRadiusViewPoints
        let circle = NSBezierPath(ovalIn: CGRect(
            x: knob.x - radius,
            y: knob.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        CanvasMarkupStyle.paper.setFill()
        circle.fill()
        circle.lineWidth = ZPDFStroke.emphasis
        CanvasMarkupStyle.selectionInk.setStroke()
        circle.stroke()
    }

    /// The area pill of the design grammar: centred on the polygon's centroid inside the
    /// fill, or — when the centroid leaves a concave outline or the pill will not fit —
    /// hung below the polygon's bottom vertex on a short leader (the Count-caption
    /// pattern). The placement maths is `AreaPillLayout`, the view-space mirror of the
    /// renderer's `AreaPillPlacement`.
    /// Where a count group's caption hangs: its top-left mark in page space.
    static func countCaptionAnchor(_ counts: [PDFPointValue]) -> PDFPointValue? {
        counts.max { a, b in a.y != b.y ? a.y < b.y : a.x > b.x }
    }

    private func drawAreaPill(
        _ text: String,
        polygon: [PDFPointValue],
        holes: [[PDFPointValue]] = [],
        color: NSColor,
        transform: PageDisplayTransform,
        shapeID: UUID? = nil
    ) {
        let fill = CanvasMarkupStyle.pillFill(forInk: color)
        let box = CanvasMarkupStyle.pillBoxSize(forText: pillLayout(text, tone: pillInk(onFill: fill)).1)
        let key = AreaPillKey(shapeID: shapeID, text: text)
        let placement: AreaPillLayout.Placement?
        // L-70: the first area pill drawn after the shapes or the zoom changed lays out every area
        // pill on the page together, so a pill that steps out on a leader never covers another.
        if key.shapeID != nil, areaPillPlacements.isEmpty { layOutAreaPills(transform: transform) }
        if key.shapeID != nil, let cached = areaPillPlacements[key] {
            placement = cached
        } else {
            let viewPolygon = polygon.map { transform.viewPoint(from: $0) }
            let viewHoles = holes.map { ring in ring.map { transform.viewPoint(from: $0) } }
            placement = AreaPillLayout.placement(
                polygon: viewPolygon,
                holes: viewHoles,
                pillHalfWidth: box.width / 2,
                pillHalfHeight: box.height / 2
            )
            areaPillPlacementComputeCount += 1
            if key.shapeID != nil { areaPillPlacements[key] = placement }
        }
        guard let placement else { return }
        if let start = placement.leaderStart, let end = placement.leaderEnd {
            let leader = NSBezierPath()
            leader.move(to: start)
            leader.line(to: end)
            leader.lineWidth = ZPDFStroke.measurement
            color.setStroke()
            leader.stroke()
        }
        drawPill(text, centeredAt: placement.center, fill: fill)
    }

    /// Every area pill on the page at `transform`, laid out together into the cache (L-70).
    ///
    /// Placed one shape at a time, the two halves of a split area both hung their pill under their
    /// own bottom-left corner and one printed over the other. The same inputs the draw uses — the
    /// caption, its ink, the filled ring and its holes — go through `AreaPillLayout.placement` per
    /// shape and then `AreaPillLayout.separating`, in drawing order, so every redraw of the page at
    /// this zoom draws the same layout whatever part of it is dirty.
    private func layOutAreaPills(transform: PageDisplayTransform) {
        var pills: [AreaPillLayout.PagePill] = []
        var keys: [UUID: AreaPillKey] = [:]
        for shape in shapes where !shape.isTemporary {
            guard let caption = shape.caption,
                  let area = shape.strokes.first(where: { $0.closed && $0.filled }) else { continue }
            let ink = NSColor(srgbRed: shape.color.red, green: shape.color.green, blue: shape.color.blue, alpha: shape.color.alpha)
            let fill = CanvasMarkupStyle.pillFill(forInk: ink)
            let box = CanvasMarkupStyle.pillBoxSize(forText: pillLayout(caption, tone: pillInk(onFill: fill)).1)
            let key = AreaPillKey(shapeID: shape.id, text: caption)
            let placement = AreaPillLayout.placement(
                polygon: area.points.map { transform.viewPoint(from: $0) },
                holes: CanvasHitTesting.holes(of: shape).map { ring in ring.map { transform.viewPoint(from: $0) } },
                pillHalfWidth: box.width / 2,
                pillHalfHeight: box.height / 2
            )
            areaPillPlacementComputeCount += 1
            areaPillPlacements[key] = placement
            guard let placement else { continue }
            keys[shape.id] = key
            pills.append(AreaPillLayout.PagePill(id: shape.id, placement: placement, halfWidth: box.width / 2, halfHeight: box.height / 2))
        }
        for (id, placement) in AreaPillLayout.separating(pills) {
            if let key = keys[id] { areaPillPlacements[key] = placement }
        }
    }

    /// The committed-length dimension grammar: arrowheads whose
    /// tips are the measured endpoints and a perpendicular extension tick through every measured
    /// point. Sizes are view points, so the decoration reads at every zoom (see
    /// `DimensionGrammar`); the measured vertices themselves are untouched.
    private func drawDimensionDecoration(
        _ stroke: CanvasStroke,
        color: NSColor,
        transform: PageDisplayTransform
    ) {
        let viewPoints = stroke.points.map { transform.viewPoint(from: $0) }
        let decoration = DimensionGrammar.decoration(forViewPoints: viewPoints)
        // The design ends a length in round dots rather than arrowheads: the dot
        // is centred on the measured endpoint, so the tip is still exactly the point measured.
        // The tick through every measured point stays, as the extension line.
        color.setFill()
        if !decoration.arrowheads.isEmpty, let first = viewPoints.first, let last = viewPoints.last {
            let r = CanvasMarkupStyle.endpointDotRadius
            for end in [first, last] {
                NSBezierPath(ovalIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
        color.setStroke()
        for tick in decoration.ticks {
            guard tick.count == 2 else { continue }
            let path = NSBezierPath()
            path.move(to: tick[0])
            path.line(to: tick[1])
            path.lineWidth = ZPDFStroke.measurement
            path.stroke()
        }
    }

    /// A filled arrowhead whose tip is the segment's last point — the Arrow shape and the
    /// callout leader. Sized in view points so it reads at every zoom, like the dimension
    /// grammar's own arrowheads.
    /// Applies a line style's dash pattern to a path.
    ///
    /// The pattern scales with the stroke, so a dotted 1 pt line and a dotted 9 pt line both read
    /// as dotted rather than the second one looking solid. `cloud` is drawn as a scallop by the
    /// shape builder rather than as a dash, so it strokes solid here.
    static func applyDash(_ style: MarkupLineStyle, to path: NSBezierPath, strokeWidth: Double) {
        let unit = max(1, strokeWidth)
        switch style {
        case .solid, .cloud:
            path.setLineDash([], count: 0, phase: 0)
        case .dashed:
            var pattern: [CGFloat] = [unit * 4, unit * 3]
            path.setLineDash(&pattern, count: 2, phase: 0)
        case .dotted:
            // Round caps turn a zero-length segment into a dot; without them a "dot" is a stub.
            path.lineCapStyle = .round
            var pattern: [CGFloat] = [0.01, unit * 2.2]
            path.setLineDash(&pattern, count: 2, phase: 0)
        case .dashDot:
            var pattern: [CGFloat] = [unit * 4, unit * 2, 0.01, unit * 2]
            path.lineCapStyle = .round
            path.setLineDash(&pattern, count: 4, phase: 0)
        }
    }

    /// The head scales with the stroke, or a thick line swallows its own tip (found
    /// live, 2026-08-29): a 9 pt-wide arrow whose fixed 9 pt head sat *inside* the
    /// line. Head length ≈ 4.5× and half-width ≈ 1.75× the stroke keeps the classic
    /// proportion at every width; the floors keep hairline arrows legible.
    ///
    /// The head also never outgrows the arrow it sits on: uncapped, a 24 pt stroke put a
    /// 108 pt wedge on a shorter shaft and the "arrow" became one giant triangle (LT-8,
    /// same live session). At most 60% of the shaft stays a recognisable arrow; the
    /// half-width shrinks in proportion when the cap bites.
    static func arrowheadDimensions(
        strokeWidth: CGFloat,
        shaftLength: CGFloat = .greatestFiniteMagnitude
    ) -> (length: CGFloat, halfWidth: CGFloat) {
        let length = max(9, strokeWidth * 4.5)
        let capped = min(length, shaftLength * 0.6)
        guard capped < length else { return (length, max(3.5, strokeWidth * 1.75)) }
        let scale = capped / length
        return (capped, max(3.5, strokeWidth * 1.75) * scale)
    }

    private func drawArrowhead(
        from previous: CGPoint,
        to tip: CGPoint,
        color: NSColor,
        strokeWidth: CGFloat = ZPDFStroke.measurement
    ) {
        let dx = tip.x - previous.x
        let dy = tip.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return }
        let ux = dx / length
        let uy = dy / length
        let (size, half) = Self.arrowheadDimensions(strokeWidth: strokeWidth, shaftLength: length)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        path.line(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        path.close()
        color.setFill()
        path.fill()
    }

    /// A committed Text or Callout string, drawn inside its box.
    ///
    /// The box is page space, so the type scales with the drawing: a note sized to a room
    /// at 1:50 must stay sized to that room at 400 %. The size is derived from the box
    /// height rather than from the stored font size for the same reason.
    /// The on-screen point size of a markup's text: the stored size at this zoom, clamped to
    /// the box, or box-derived for a markup stored before styles carried a size. One formula
    /// for the committed text and the editor that previews it (IM-243).
    nonisolated static func markupTextPointSize(requested: Double?, boxHeight: CGFloat) -> CGFloat {
        let derived = max(6, min(boxHeight * 0.72, 200))
        return requested.map { max(4, min(CGFloat($0), max(6, boxHeight))) } ?? derived
    }

    /// Draws a markup's text at the size the style asks for.
    ///
    /// `pointSize` is the stored point size already scaled to the view, so text on the sheet
    /// grows with the zoom like everything else on it. It is clamped to the box: a 200 pt size in
    /// a 20 pt box would draw one letter and hide the rest, and the stored number is not worth
    /// making the text unreadable for. `nil` keeps the old box-derived behaviour, which is what a
    /// markup stored before styles carried a font size gets.
    private func drawMarkupText(
        _ text: String,
        in box: CGRect,
        color: NSColor,
        pointSize requested: Double? = nil,
        callout: Bool = false,
        fontName: String? = nil,
        alignment: ZPDFContracts.TextAlignment = .leading,
        bold: Bool = false,
        italic: Bool = false,
        explicitColour: Bool = false
    ) {
        // A callout is a note in a frame: its text is padded off the border, set semibold in
        // a deeper shade of the ink, and sized to the padded box so it cannot touch the frame.
        // A plain Text markup keeps the tight inset its editor previews.
        let inset = callout
            ? CanvasMarkupStyle.calloutTextInset(for: box.standardized)
            : 0
        let textBox = callout
            ? box.standardized.insetBy(dx: inset, dy: inset * 0.75)
            : box.insetBy(dx: 2, dy: 1)
        let pointSize = Self.markupTextPointSize(
            requested: requested,
            boxHeight: callout ? textBox.height : box.height
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // nl-markup: the stored family and alignment, which the canvas used to ignore.
        paragraph.alignment = CanvasMarkupFont.alignment(alignment)
        let string = NSAttributedString(string: text, attributes: [
            .font: CanvasMarkupFont.font(
                named: fontName, size: pointSize, weight: callout ? .semibold : .regular,
                bold: bold, italic: italic
            ),
            // A colour chosen for the text is drawn as chosen; the callout's deeper shade is
            // only the default for text that follows the ink (ADR-0029).
            .foregroundColor: callout && !explicitColour ? CanvasMarkupStyle.calloutTextInk(forInk: color) : color,
            .paragraphStyle: paragraph
        ])
        string.draw(in: textBox)
    }

    private func drawLiveMeasurement(transform: PageDisplayTransform, context: CGContext) {
        guard !livePoints.isEmpty else { return }
        let accent = CanvasMarkupStyle.liveInk
        // Count's dots are not a path. Without this guard the overlay strokes a polyline
        // through every placed point — "Count draws a polygon": the geometry was always
        // right, the drawing was not.
        if isPointPlacement {
            for point in livePoints {
                let view = transform.viewPoint(from: point)
                accent.setFill()
                NSBezierPath(ovalIn: CGRect(x: view.x - 4, y: view.y - 4, width: 8, height: 8)).fill()
            }
            // The running total joined to the readout; the same string the dirty rect measures.
            if let caption = live.drawing.displayedCaption, let anchor = live.drawing.captionAnchor {
                drawPill(caption, at: transform.viewPoint(from: anchor), fill: CanvasMarkupStyle.livePillFill)
            }
            return
        }
        if let kind = liveMarkupKind {
            drawLiveMarkup(kind: kind, transform: transform)
            return
        }
        if livePoints.count >= 2 {
            // Arc segments placed so far (NL-MEASURE-05) are drawn as the arcs they are.
            let path = bezierPath(live.drawing.drawnPath, closed: liveClosesOutline && livePoints.count > 2, transform: transform)
            if liveClosesOutline, livePoints.count > 2 {
                accent.withAlphaComponent(0.18).setFill()
                path.fill()
            }
            accent.setStroke()
            path.lineWidth = ZPDFStroke.measurement
            path.stroke()
        }
        for point in livePoints {
            drawHandle(at: transform.viewPoint(from: point), ring: accent)
        }
        // The rubber band: last placed vertex to the pointer, dashed, so the value the
        // caption shows visibly belongs to the segment being drawn — the arc through the
        // through point while an arc segment is being drawn.
        if let bandPoints = live.drawing.rubberBand, bandPoints.count >= 2 {
            let band = NSBezierPath()
            band.move(to: transform.viewPoint(from: bandPoints[0]))
            for point in bandPoints.dropFirst() { band.line(to: transform.viewPoint(from: point)) }
            band.lineWidth = ZPDFStroke.measurement
            band.setLineDash([5, 3], count: 2, phase: 0)
            accent.withAlphaComponent(0.8).setStroke()
            band.stroke()
        }
        // The arc's through point: a small diamond, so it reads as a guide and not a vertex.
        if let through = live.drawing.arcThroughPoint {
            let view = transform.viewPoint(from: through)
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: view.x, y: view.y - 5))
            diamond.line(to: CGPoint(x: view.x + 5, y: view.y))
            diamond.line(to: CGPoint(x: view.x, y: view.y + 5))
            diamond.line(to: CGPoint(x: view.x - 5, y: view.y))
            diamond.close()
            diamond.lineWidth = ZPDFStroke.measurement
            accent.setStroke()
            diamond.stroke()
        }
        // The close affordance: a ring on the first vertex when the next click closes there.
        if let closeTarget = firstVertexCloseTarget {
            let view = transform.viewPoint(from: closeTarget)
            let ring = NSBezierPath(ovalIn: CGRect(x: view.x - 7, y: view.y - 7, width: 14, height: 14))
            ring.lineWidth = ZPDFStroke.emphasis
            accent.setStroke()
            ring.stroke()
        }
        if let caption = liveCaption, let anchor = live.drawing.captionAnchor {
            drawPill(caption, at: transform.viewPoint(from: anchor), fill: CanvasMarkupStyle.livePillFill)
        }
    }

    /// The three-point rectangle's live preview: the inferred quadrilateral following the
    /// cursor, closed and filled, with its running area beside the pointer.
    private func drawInferredQuad(_ quad: [PDFPointValue], transform: PageDisplayTransform) {
        let accent = CanvasMarkupStyle.liveInk
        let path = bezierPath(quad, closed: true, transform: transform)
        accent.withAlphaComponent(0.18).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = ZPDFStroke.measurement
        path.stroke()
        for point in quad.prefix(2) {
            drawHandle(at: transform.viewPoint(from: point), ring: accent)
        }
        if let caption = liveCaption, let anchor = liveCursorPoint ?? quad.last {
            drawPill(caption, at: transform.viewPoint(from: anchor), fill: CanvasMarkupStyle.livePillFill)
        }
    }

    /// The markup in progress: the shape that will be committed, previewed as itself.
    private func drawLiveMarkup(kind: ZPDFUIPresentation.MarkupKind, transform: PageDisplayTransform) {
        let accent = CanvasMarkupStyle.liveInk
        var preview = livePoints
        if let cursor = liveCursorPoint { preview.append(cursor) }
        let outline = Self.previewOutline(kind: kind, points: preview)
        if outline.count >= 2 {
            let path = bezierPath(outline.points, closed: outline.closed, transform: transform)
            if outline.closed {
                accent.withAlphaComponent(0.18).setFill()
                path.fill()
            }
            accent.setStroke()
            path.lineWidth = ZPDFStroke.measurement
            path.stroke()
            if outline.arrow, outline.points.count >= 2 {
                drawArrowhead(
                    from: transform.viewPoint(from: outline.points[outline.points.count - 2]),
                    to: transform.viewPoint(from: outline.points[outline.points.count - 1]),
                    color: accent
                )
            }
        }
        // A freehand stroke is hundreds of samples, not vertices a person placed.
        for point in livePoints where kind != .freehand {
            drawHandle(at: transform.viewPoint(from: point), ring: accent)
        }
        if let closeTarget = firstVertexCloseTarget {
            let view = transform.viewPoint(from: closeTarget)
            let ring = NSBezierPath(ovalIn: CGRect(x: view.x - 7, y: view.y - 7, width: 14, height: 14))
            ring.lineWidth = ZPDFStroke.emphasis
            accent.setStroke()
            ring.stroke()
        }
    }

    /// The live outline of a markup being drawn. Pure, so the preview and the commit can be
    /// asserted against each other in a test rather than compared by eye.
    static func previewOutline(
        kind: ZPDFUIPresentation.MarkupKind,
        points: [PDFPointValue]
    ) -> (points: [PDFPointValue], closed: Bool, arrow: Bool, count: Int) {
        switch kind {
        case .rectangle, .text:
            guard points.count >= 2 else { return (points, false, false, points.count) }
            let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[points.count - 1])
            return (corners, true, false, corners.count)
        case .ellipse:
            guard points.count >= 2 else { return (points, false, false, points.count) }
            let outline = ZenitMarkupGeometry.ellipseOutline(
                in: ZenitMarkupGeometry.boundingRect(points[0], points[points.count - 1])
            )
            return (outline, true, false, outline.count)
        case .line:
            return (Array(points.prefix(2)), false, false, Swift.min(points.count, 2))
        case .arrow:
            return (Array(points.prefix(2)), false, true, Swift.min(points.count, 2))
        case .callout:
            guard points.count >= 2 else { return (points, false, false, points.count) }
            let box = ZenitMarkupGeometry.boundingRect(points[1], points[points.count - 1])
            let attachment = ZenitMarkupGeometry.leaderAttachment(target: points[0], box: box)
            return ([points[0], attachment], false, false, 2)
        case .polygon, .cloud:
            return (points, points.count > 2, false, points.count)
        default:
            return (points, false, false, points.count)
        }
    }

    /// The one-gesture drag preview: the rectangle between the anchor and the pointer.
    private func drawDragPreview(transform: PageDisplayTransform) {
        if let kind = liveMarkupKind {
            drawLiveMarkup(kind: kind, transform: transform)
            return
        }
        guard let anchor = liveDragAnchor, let cursor = liveCursorPoint else { return }
        let a = transform.viewPoint(from: anchor)
        let b = transform.viewPoint(from: cursor)
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        let accent = CanvasMarkupStyle.liveInk
        let path = NSBezierPath(rect: rect)
        accent.withAlphaComponent(0.18).setFill()
        path.fill()
        accent.setStroke()
        path.lineWidth = ZPDFStroke.measurement
        path.stroke()
        if let caption = liveCaption {
            drawPill(caption, at: b, fill: CanvasMarkupStyle.livePillFill)
        }
    }

    private func drawCalibration(transform: PageDisplayTransform, context: CGContext) {
        guard !calibrationPoints.isEmpty else { return }
        let color = CanvasMarkupStyle.calibrationInk
        color.setStroke()
        if calibrationPoints.count >= 2 {
            let path = bezierPath(calibrationPoints, closed: false, transform: transform)
            path.lineWidth = ZPDFStroke.emphasis
            path.stroke()
        }
        // The live segment: last placed reference point to the pointer, dashed so it cannot be
        // mistaken for the committed dimension line it will become.
        if let cursor = calibrationCursor, let anchor = calibrationPoints.last {
            let live = NSBezierPath()
            live.move(to: transform.viewPoint(from: anchor))
            live.line(to: transform.viewPoint(from: cursor))
            live.lineWidth = ZPDFStroke.emphasis
            live.setLineDash([4, 3], count: 2, phase: 0)
            color.setStroke()
            live.stroke()
        }
        for point in calibrationPoints {
            let view = transform.viewPoint(from: point)
            let box = CGRect(x: view.x - 4, y: view.y - 4, width: 8, height: 8)
            color.setFill()
            NSBezierPath(ovalIn: box).fill()
        }
    }

    private func drawSnap(transform: PageDisplayTransform) {
        guard let snapPoint else { return }
        let view = transform.viewPoint(from: snapPoint)
        let ring = NSBezierPath(ovalIn: CGRect(x: view.x - 6, y: view.y - 6, width: 12, height: 12))
        ring.lineWidth = ZPDFStroke.emphasis
        CanvasMarkupStyle.snapInk.setStroke()
        ring.stroke()
        // A centre dot, so the exact landing point is visible inside the ring.
        CanvasMarkupStyle.snapInk.setFill()
        NSBezierPath(ovalIn: CGRect(x: view.x - 1.5, y: view.y - 1.5, width: 3, height: 3)).fill()
    }

    /// A pill hung beside its anchor. `fill` is the markup-coloured fill; `nil` draws the
    /// neutral chrome pill.
    ///
    /// `within` is the area the pill flips to stay inside. The live overlay's pills leave it
    /// `nil` and follow what the scroll view shows (IM-240). Committed ink passes the page frame:
    /// a scroll never redraws the page, so a side chosen by the visible area was the side of the
    /// last redraw, and an unrelated redraw made the label and its drag frame jump (V-015).
    private func drawPill(_ text: String, at point: CGPoint, fill: NSColor?, within area: CGRect? = nil) {
        let (string, size) = pillLayout(text, tone: pillInk(onFill: fill))
        let visible = area ?? pillVisibleArea
        drawPillBox(string, size: size, in: Self.anchoredPillBox(size: size, anchor: point, visible: visible), fill: fill)
    }

    /// The area a pill must stay inside: what the scroll view shows, clipped to the page view.
    /// Off screen (a snapshot, an export render) there is no clip view and AppKit reports an
    /// infinite visible rectangle, which would let a pill run off the picture.
    private var pillVisibleArea: CGRect {
        let visible = visibleRect.intersection(bounds)
        return visible.isNull || visible.isEmpty ? bounds : visible
    }

    private func pillInk(onFill fill: NSColor?) -> PillInk {
        guard let fill else { return .chrome }
        switch CanvasMarkupStyle.pillTone(onFill: fill) {
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// A caption's attributed string and size, built once per text and ink rather than every
    /// frame for every caption (IM-165).
    private func pillLayout(_ text: String, tone: PillInk) -> (NSAttributedString, CGSize) {
        let key = PillLayoutKey(text: text, tone: tone)
        if let cached = pillLayouts[key] { return cached }
        let foreground: NSColor
        switch tone {
        case .light: foreground = CanvasMarkupStyle.pillTextColor(.light)
        case .dark: foreground = CanvasMarkupStyle.pillTextColor(.dark)
        case .chrome: foreground = ZPDFColor.nsColor(.textPrimary)
        }
        let string = NSAttributedString(string: text, attributes: [
            .font: CanvasMarkupStyle.pillFont,
            .foregroundColor: foreground
        ])
        let layout = (string, string.size())
        pillLayoutComputeCount += 1
        if pillLayouts.count > 2048 { pillLayouts.removeAll(keepingCapacity: true) }
        pillLayouts[key] = layout
        return layout
    }

    /// A pill beside its anchor: right of and above it, flipped left or below when that would
    /// leave the visible area — the live value used to vanish exactly while measuring along the
    /// window's right or top edge (IM-240).
    nonisolated static func anchoredPillBox(size: CGSize, anchor: CGPoint, visible: CGRect) -> CGRect {
        let box = CanvasMarkupStyle.pillBoxSize(forText: size)
        let gap = CanvasMarkupStyle.pillAnchorGap
        var x = anchor.x + gap
        var y = anchor.y - box.height
        if x + box.width > visible.maxX, anchor.x - gap - box.width >= visible.minX { x = anchor.x - gap - box.width }
        if y < visible.minY { y = anchor.y + 6 }
        return CGRect(x: x, y: y, width: box.width, height: box.height)
    }

    /// The render notice, centred on what is visible: static text, never animated, so Reduce
    /// Motion has nothing to stop.
    private func drawRenderNotice() {
        guard let renderNotice else { return }
        let visible = pillVisibleArea
        drawPill(renderNotice.text, centeredAt: CGPoint(x: visible.midX, y: visible.midY), fill: nil)
    }

    /// A pill centred on a point rather than offset from an anchor.
    private func drawPill(_ text: String, centeredAt center: CGPoint, fill: NSColor?) {
        let (string, size) = pillLayout(text, tone: pillInk(onFill: fill))
        let box = CanvasMarkupStyle.pillBoxSize(forText: size)
        drawPillBox(string, size: size, in: CGRect(
            x: center.x - box.width / 2,
            y: center.y - box.height / 2,
            width: box.width,
            height: box.height
        ), fill: fill)
    }

    /// The pill itself. A markup pill is filled with its ink and edged with a one-point paper
    /// keyline, so it separates cleanly from the linework it sits on; the chrome pill is the
    /// raised surface with a hairline.
    private func drawPillBox(_ string: NSAttributedString, size: CGSize, in automaticBox: CGRect, fill: NSColor?) {
        // NL-MEASURE-09: a measurement caption moved by the person, with a leader back to where
        // it would sit; its frame is kept for the drag.
        let box = placedCaptionBox(automaticBox, ink: fill)
        let radius = CanvasMarkupStyle.pillCornerRadius
        let pill = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            pill.fill()
            let keyline = NSBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5)
            keyline.lineWidth = ZPDFStroke.regular
            CanvasMarkupStyle.paper.withAlphaComponent(0.9).setStroke()
            keyline.stroke()
        } else {
            ZPDFColor.nsColor(.elevated).withAlphaComponent(0.94).setFill()
            pill.fill()
            pill.lineWidth = ZPDFStroke.hairline
            ZPDFColor.nsColor(.border).setStroke()
            pill.stroke()
        }
        // Centred in the box, as ``ZPDFPillGeometry/draw(_:centeredAt:fill:foreground:scale:)``
        // sets it; the string and its size come from the layout cache (IM-165).
        string.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }

    /// A freehand stroke drawn as a Catmull-Rom curve through its view points (ADR-0029 §2.5):
    /// each span a cubic whose control points come from the neighbouring samples, so the curve
    /// passes through every stored point and nothing is written back.
    nonisolated static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.line(to: points[1]) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    private func bezierPath(
        _ points: [PDFPointValue],
        closed: Bool,
        transform: PageDisplayTransform
    ) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let view = transform.viewPoint(from: point)
            if index == 0 { path.move(to: view) } else { path.line(to: view) }
        }
        if closed { path.close() }
        return path
    }

    private func handleCenters(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    // MARK: - Pointer

    private func pagePoint(for event: NSEvent) -> PDFPointValue? {
        pagePoint(atWindowLocation: event.locationInWindow)
    }

    /// The page point under a window location — on the sheet or within 2 pt of it — or `nil`.
    /// The one rule an event's point and a re-aimed resting pointer (W-002) both follow.
    func pagePoint(atWindowLocation location: CGPoint) -> PDFPointValue? {
        guard let transform else { return nil }
        let local = localPoint(atWindowLocation: location)
        guard transform.pageFrame.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return transform.pagePoint(from: local)
    }

    /// ``pagePoint(for:)``, for the tests that prove a pointer mid-gesture lands on the page
    /// point under it.
    func pagePointForTesting(_ event: NSEvent) -> PDFPointValue? { pagePoint(for: event) }

    /// The event's page point with the pointer clamped onto the sheet.
    ///
    /// A select drag (a move, a vertex edit, a marquee) must keep tracking and must *end*
    /// when the pointer leaves the page: `pagePoint(for:)` answers nil there, and a release
    /// off the sheet used to drop the gesture entirely — the controller's drag stayed armed,
    /// the moved ghost stayed on screen and no command was ever issued (BH-061).
    func clampedPagePoint(for event: NSEvent) -> PDFPointValue? {
        guard let transform else { return nil }
        let local = localPoint(for: event)
        return clampedPagePoint(atLocal: local, transform: transform)
    }

    /// Pure form of ``clampedPagePoint(for:)`` for tests.
    static func clamp(_ local: CGPoint, into frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(local.x, frame.minX), frame.maxX),
            y: min(max(local.y, frame.minY), frame.maxY)
        )
    }

    private func clampedPagePoint(atLocal local: CGPoint, transform: PageDisplayTransform) -> PDFPointValue {
        transform.pagePoint(from: Self.clamp(local, into: transform.pageFrame))
    }

    /// Fired when a select drag is abandoned without a release the view can place (the
    /// view lost first responder mid-drag). The controller disarms its drag and redraws.
    var onDragCancelled: (@MainActor () -> Void)?

    override func mouseMoved(with event: NSEvent) {
        reconcileModifiers(from: event)
        hoverWindowLocation = event.locationInWindow
        onPointerMove?(pagePoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        hoverWindowLocation = nil
        onPointerMove?(nil)
    }

    /// How far apart, in window points, the two presses of a double-click may land (L-36) — the
    /// project window's own rule (``ZPDFClickCounter/slop``, L-108), so the two agree.
    static let doubleClickSlop: CGFloat = ZPDFClickCounter.slop

    /// Whether a press is the second press of a double-click on this view (L-36, L-36b, L-105).
    ///
    /// The event's `clickCount` alone is not that: the system counts any two presses inside the
    /// double-click interval, wherever they land and whichever view took the first. A pick's
    /// second point clicked within half a second of the first, or the first point clicked right
    /// after the toolbar button that armed the tool, arrived as `clickCount == 2`, went to the
    /// double-click path — which means nothing to a calibration pick or to a tool with no point
    /// yet — and the click was dropped. A double-click is two presses on this view, inside the
    /// interval, within ``doubleClickSlop`` of each other. The project window re-counts presses
    /// by the same rule before AppKit dispatches them (L-108); this check stays for a canvas
    /// hosted anywhere else.
    static func isDoubleClick(
        clickCount: Int,
        timestamp: TimeInterval,
        windowLocation: CGPoint,
        previous: (timestamp: TimeInterval, windowLocation: CGPoint)?,
        interval: TimeInterval = NSEvent.doubleClickInterval
    ) -> Bool {
        guard clickCount == 2, let previous else { return false }
        let elapsed = timestamp - previous.timestamp
        guard elapsed >= 0, elapsed <= interval else { return false }
        let distance = hypot(windowLocation.x - previous.windowLocation.x, windowLocation.y - previous.windowLocation.y)
        return distance <= doubleClickSlop
    }

    override func mouseDown(with event: NSEvent) {
        reconcileModifiers(from: event)
        hoverWindowLocation = nil
        let isDoubleClick = Self.isDoubleClick(
            clickCount: event.clickCount,
            timestamp: event.timestamp,
            windowLocation: event.locationInWindow,
            previous: lastPress
        )
        lastPress = (event.timestamp, event.locationInWindow)
        onWillBeginInteraction?()
        // A press outside an open text box finishes the box and nothing else (W-004). Taking
        // first responder commits it (the editor's resign); the press used to carry on as a
        // Text-tool press, so with Reuse Tool on its release opened a new empty box — and an
        // empty box could never be clicked away — and with Reuse off it fell through to Select.
        let endsTextEntry = window?.firstResponder is CanvasTextEditor
        window?.makeFirstResponder(self)
        if endsTextEntry {
            pressEndedTextEntry = true
            return
        }
        if isSpaceHeld || isPanTool {
            isPanDragging = true
            NSCursor.closedHand.set()
            return
        }
        if isZoomTool || isRegionCaptureTool {
            // The zoom tool owns the whole gesture: press starts a possible marquee, the
            // release decides between marquee zoom and a click step. A snippet region capture
            // is the same gesture with a different destination.
            zoomDragStartView = localPoint(for: event)
            return
        }
        guard let point = pagePoint(for: event) else { return }
        if isDoubleClick {
            onDoubleClick?(point)
            return
        }
        if !isSelectionTool, usesDragGesture {
            if dragToolPlacesClicks {
                // A drag tool that also places clicks — the three-point rectangle, the Area
                // polygon, the two-point shapes: whether this press is a drag anchor or a
                // click is decided by the first real movement, so the press only records
                // the point.
                pendingMeasureDragStart = point
                return
            }
            isMeasureDragging = true
            onDragBegan?(point)
            return
        }
        if isSelectionTool, !isZoomTool, !isRegionCaptureTool, !isPanTool {
            // The pointer tool drags too — a marquee, a move, or a vertex handle
            // — so the press waits to see whether the
            // pointer moves. A press that never moves is the click it always was, and it
            // fires on release.
            pendingSelectStart = point
            return
        }
        onClick?(point, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) {
        reconcileModifiers(from: event)
        if pressEndedTextEntry { return }
        if isPanDragging || isSpaceHeld {
            onPanBy?(CGSize(width: -event.deltaX, height: -event.deltaY))
            return
        }
        if let start = zoomDragStartView {
            let current = localPoint(for: event)
            zoomMarqueeViewRect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            return
        }
        if let start = pendingMeasureDragStart {
            // First real movement: the press was a drag anchor after all.
            pendingMeasureDragStart = nil
            isMeasureDragging = true
            onDragBegan?(start)
            if let point = pagePoint(for: event) { onDragMoved?(point) }
            return
        }
        if let start = pendingSelectStart {
            pendingSelectStart = nil
            isSelectDragging = true
            onDragBegan?(start)
            if let point = pagePoint(for: event) { onDragMoved?(point) }
            return
        }
        if isSelectDragging {
            if let point = clampedPagePoint(for: event) { onDragMoved?(point) }
            return
        }
        if isMeasureDragging {
            if let point = pagePoint(for: event) { onDragMoved?(point) }
            return
        }
        onPointerMove?(pagePoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        reconcileModifiers(from: event)
        hoverWindowLocation = event.locationInWindow
        if pressEndedTextEntry {
            pressEndedTextEntry = false
            return
        }
        if isPanDragging {
            isPanDragging = false
            restCursor()
            return
        }
        if zoomDragStartView != nil {
            let marquee = zoomMarqueeViewRect
            zoomDragStartView = nil
            zoomMarqueeViewRect = nil
            if isRegionCaptureTool {
                // A region must be *drawn*. A click is not a small region, it is a miss —
                // and a miss KEEPS the capture armed. Ending the mode on the first stray
                // click meant the activation click silently disarmed it, and the drag that
                // followed became a marquee zoom instead of the region (LT-14,
                // 2026-08-29). Escape is the way out now.
                if let marquee, marquee.width > 4, marquee.height > 4, let transform {
                    onRegionCaptured?(transform.pageRect(covering: marquee))
                }
                return
            }
            if let marquee, marquee.width > 4 || marquee.height > 4, let transform {
                onZoomMarquee?(transform.pageRect(covering: marquee))
            } else {
                onZoomClick?(event.locationInWindow, event.modifierFlags.contains(.option))
            }
            return
        }
        if let start = pendingMeasureDragStart {
            // Press and release without movement on a click-placing drag tool: a click,
            // which places a rectangle corner.
            pendingMeasureDragStart = nil
            onClick?(pagePoint(for: event) ?? start, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option))
            return
        }
        if let start = pendingSelectStart {
            pendingSelectStart = nil
            onClick?(pagePoint(for: event) ?? start, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option))
            return
        }
        if isSelectDragging {
            isSelectDragging = false
            // Released off the page: end the gesture at the sheet edge under the pointer
            // rather than stranding a drag that never came up (BH-061).
            if let point = clampedPagePoint(for: event) {
                onDragEnded?(point)
            } else {
                onDragCancelled?()
            }
            return
        }
        if isMeasureDragging {
            isMeasureDragging = false
            if let point = pagePoint(for: event) {
                onDragEnded?(point)
            } else if let anchor = liveDragAnchor {
                // Released off the page: end where the gesture last was rather than losing it.
                onDragEnded?(liveCursorPoint ?? anchor)
            } else if let point = clampedPagePoint(for: event) {
                // A markup drag has no measurement anchor: released off the page it ends on the
                // sheet edge under the pointer, as a Select drag does (W-007). It used to send
                // nothing — a Pen stroke was thrown away by the next press, and a rectangle,
                // line, arrow, text box or link was finished from the stale anchor by the next
                // click.
                onDragEnded?(point)
            }
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: - Middle-button pan

    override func otherMouseDown(with event: NSEvent) {
        onWillBeginInteraction?()
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        isPanDragging = true
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isPanDragging else { return super.otherMouseDragged(with: event) }
        onPanBy?(CGSize(width: -event.deltaX, height: -event.deltaY))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard isPanDragging else { return super.otherMouseUp(with: event) }
        isPanDragging = false
        restCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        // A two-finger trackpad tap arrives here too — macOS delivers both as the same
        // secondary-click event. During a measurement it finishes the geometry (or is
        // swallowed); a context menu is never shown mid-measurement.
        onWillBeginInteraction?()
        if onSecondaryClick?(pagePoint(for: event)) == true { return }
        // Otherwise: a selection followed by the context menu. `super` asks `menu(for:)`,
        // which asks the controller (nl-markup, NL-MARKUP-02): the menu is built from the
        // command table there. A right-click inside the current selection keeps it.
        if let point = pagePoint(for: event) {
            if let onSecondarySelect { onSecondarySelect(point) } else { onClick?(point, false, false) }
        }
        super.rightMouseDown(with: event)
    }

    /// nl-markup: the canvas's context menu, from the controller (NL-MARKUP-02, NL-UX-02).
    /// `nil` point means the press missed the page.
    var onContextMenu: (@MainActor (PDFPointValue?) -> NSMenu?)?
    /// nl-markup: selects for a right-click, keeping a selection the press lands inside.
    var onSecondarySelect: (@MainActor (PDFPointValue) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(pagePoint(for: event)) ?? super.menu(for: event)
    }

    // MARK: - Modifiers

    override func flagsChanged(with event: NSEvent) {
        onModifiersChanged?(
            event.modifierFlags.contains(.shift),
            event.modifierFlags.contains(.option),
            event.modifierFlags.contains(.command)
        )
        super.flagsChanged(with: event)
    }

    /// Reconciles the held keys from a pointer event's own flags (V-002).
    ///
    /// `flagsChanged` reaches only the first responder, so ⇧ pressed on the canvas and released
    /// in an Inspector field left Shift held here, and every move and click after it was forced
    /// onto the 45° rose; one pressed elsewhere never arrived. Every pointer event carries the
    /// keys actually down, so each one corrects the stored state before its point is used; an
    /// unchanged state is one comparison in the controller.
    private func reconcileModifiers(from event: NSEvent) {
        let flags = event.modifierFlags
        onModifiersChanged?(flags.contains(.shift), flags.contains(.option), flags.contains(.command))
    }

    /// Forgets every held key: the view stopped hearing the keyboard (V-002).
    private func releaseModifiers() {
        onModifiersChanged?(false, false, false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            // Selector-based, so the registration dies with the view.
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
    }

    /// Another window took the keyboard: a key released there never comes back here (V-002).
    @objc private func windowDidResignKey(_ note: Notification) {
        releaseModifiers()
    }

    // MARK: - Keyboard

    /// Which way a page-turn key points.
    enum PageTurn: Sendable, Hashable {
        case next, previous, first, last
    }

    /// Page Up / Page Down / Home / End. Wired by the canvas controller.
    ///
    /// A page turn here does exactly what clicking a Navigator thumbnail already does,
    /// including mid-draft: the keyboard is a second door onto one behaviour, never a second
    /// behaviour. That keeps one rule to remember and one path to fix.
    var onPageTurn: (@MainActor (PageTurn) -> Void)?

    override func keyDown(with event: NSEvent) {
        onWillBeginInteraction?()
        // Space held is the temporary pan: the cursor becomes a grab hand and drags
        // pan; releasing Space returns to the previous tool with nothing else changed.
        if event.keyCode == 49 {
            // A space inside a typed length ("4 1/2", 12'6 1/2") is part of the entry, not a pan
            // (S-001): it went to the pan unconditionally, so "4 1/2" reached the parser as
            // "41/2" and placed 20.5. The controller claims it only while an entry has text, so
            // Space still pans whenever nothing is being typed.
            if !event.isARepeat, !isSpaceHeld,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               onKey?(.typed(" ")) == true {
                return
            }
            if !event.isARepeat, !isSpaceHeld {
                isSpaceHeld = true
                NSCursor.openHand.set()
            }
            return
        }
        // Page navigation. Before the CanvasKey table because none of these four is a drawing
        // key, and after the Space check because Space is the temporary pan.
        switch event.keyCode {
        case 116: onPageTurn?(.previous); return   // Page Up
        case 121: onPageTurn?(.next); return       // Page Down
        case 115: onPageTurn?(.first); return      // Home
        case 119: onPageTurn?(.last); return       // End
        default: break
        }

        let key: CanvasKey?
        switch event.keyCode {
        case 53: key = .escape
        // ⌘Return always finishes; plain Return places a point at the keyboard cursor while it
        // leads a measurement, and finishes otherwise — the controller decides (R-137).
        case 36, 76: key = event.modifierFlags.contains(.command) ? .commandFinish : .finish
        case 51, 117: key = .removeLastVertex
        // Tab steps forward through the snap candidates, ⇧Tab back (V-071).
        case 48: key = .cycleSnap(backward: event.modifierFlags.contains(.shift))
        // Arrows move the keyboard cursor while a measurement tool is armed (R-137); otherwise
        // they nudge the selection, or pan the sheet when nothing is selected (IM-166).
        case 123: key = .nudge(dx: -1, dy: 0, large: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat)
        case 124: key = .nudge(dx: 1, dy: 0, large: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat)
        case 125: key = .nudge(dx: 0, dy: 1, large: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat)
        case 126: key = .nudge(dx: 0, dy: -1, large: event.modifierFlags.contains(.shift), isRepeat: event.isARepeat)
        default:
            // ⌘A is Select All, served by the menu bar.
            // It used to arm Area here — but only when the menu's Select All was disabled, i.e.
            // on a page without markups, so one key did two things by page content.
            // NL-MEASURE-18: a typed length character, unmodified, is offered to the controller,
            // which claims it only mid-drawing.
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let characters = event.characters, characters.count == 1, let character = characters.first,
               CanvasKey.typedCharacters.contains(character) {
                key = .typed(character)
            } else if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      event.charactersIgnoringModifiers == "a" {
                // A, unmodified: the Area tool's single key — or, mid-shape, "next segment is an
                // arc" (NL-MEASURE-05). The controller decides which; it never switches tools
                // under a shape in progress.
                key = .area
            } else if CanvasToolShortcut.command(
                forCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: ZPDFModifierFlags(event.modifierFlags),
                in: .effective
            ) != nil {
                // Any other tool letter reaches the canvas only when the window's router left
                // it here — the canvas owns the keyboard (a pick, a shape, a typed length) — and
                // the controller says why no tool was chosen (K-02).
                key = .toolKey
            } else {
                key = nil
            }
        }
        if let key, onKey?(key) == true { return }
        // Escape the canvas has nothing to cancel belongs to the window: drive the
        // `cancelOperation` chain explicitly so the mode registry always hears it
        // (Escape never does nothing).
        if event.keyCode == 53 {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: self)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceHeld = false
            // The armed verb's cursor, not an arrow: the next click places with that tool (BH-881).
            if !isPanDragging { restCursor() }
            return
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        isSpaceHeld = false
        isPanDragging = false
        // A key released while something else has the keyboard never reaches this view (V-002).
        releaseModifiers()
        pendingMeasureDragStart = nil
        pendingSelectStart = nil
        pressEndedTextEntry = false
        if isSelectDragging {
            isSelectDragging = false
            // The release will never reach this view: disarm the controller's drag too,
            // or its ghost keeps drawing a move that was never committed (BH-061).
            onDragCancelled?()
        }
        zoomDragStartView = nil
        zoomMarqueeViewRect = nil
        return super.resignFirstResponder()
    }
}

/// Keys the canvas claims before the menu bar sees them.
enum CanvasKey: Sendable, Equatable {
    case escape
    /// Return: finish — or, while the keyboard cursor leads a measurement, place a point at it
    /// (R-137).
    case finish
    /// ⌘Return: finish, whatever the keyboard cursor is doing (R-137).
    case commandFinish
    case removeLastVertex
    /// Tab, or ⇧Tab with `backward` set: the next or the previous snap candidate.
    case cycleSnap(backward: Bool)
    case area
    /// A single-letter tool shortcut other than A. The window's router serves these; one reaches
    /// the canvas only while the canvas owns the keyboard, and never switches tools there (K-02).
    case toolKey
    /// An arrow key: the screen direction (view space, y down), whether Shift was held, and
    /// whether it is a key-repeat of a held arrow. It moves the keyboard cursor while a
    /// measurement tool is armed (R-137), and nudges the selection or pans otherwise.
    case nudge(dx: Int, dy: Int, large: Bool, isRepeat: Bool)
    /// A character of a typed length or angle while drawing (NL-MEASURE-18): a digit, a decimal
    /// separator, `<`, a feet or inch mark, a space or `/`. Claimed only while a segment tool
    /// has a placed point; otherwise it falls through to the menus.
    case typed(Character)

    /// The characters a typed segment is made of.
    static let typedCharacters: Set<Character> = Set("0123456789.,<'\" /-")
}

/// The transparent layer the live feedback draws in (IM-039). It takes no events — the page
/// view under it owns every gesture — and draws nothing of its own: it asks its host to paint
/// the live layer into the shared flipped coordinates.
@MainActor
final class CanvasLiveOverlayView: NSView {
    weak var host: CanvasPageView?

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        host?.drawLiveLayer(dirtyRect)
    }
}

// MARK: - Accessibility (IM-162)

extension CanvasPageView {

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }

    override func accessibilityRoleDescription() -> String? {
        NSLocalizedString("drawing", comment: "VoiceOver role description of the canvas")
    }

    override func accessibilityLabel() -> String? {
        Self.canvasAccessibilityLabel(sheetLabel: accessibilitySheetLabel, pageNumber: accessibilityPageNumber)
    }

    /// "Drawing, sheet A-101" when the page has a sheet label, "Drawing, page 3" otherwise. The
    /// canvas used to read the page index even on a labelled sheet.
    nonisolated static func canvasAccessibilityLabel(sheetLabel: String?, pageNumber: Int) -> String {
        let label = sheetLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty, label != String(pageNumber) {
            return String(
                format: NSLocalizedString("Drawing, sheet %@", comment: "VoiceOver label of the canvas; the sheet label"),
                label
            )
        }
        return String(
            format: NSLocalizedString("Drawing, page %ld", comment: "VoiceOver label of the canvas; the page number"),
            pageNumber
        )
    }

    override func accessibilityChildren() -> [Any]? { markupAccessibilityElements() }

    /// One element per markup on this page — **every** markup, scrolled out of view or not
    /// (`ACCESSIBILITY_PLAN.md`): its caption (or text, or kind) as the label, its
    /// frame from the display transform, in reading order. Until 2026-09-23 the list was cut to
    /// the visible rectangle, so VoiceOver could not reach a markup without scrolling to it first.
    func markupAccessibilityElements() -> [NSAccessibilityElement] {
        guard let transform else { return [] }
        let ordered = Self.accessibilityReadingOrder(shapes.filter { !$0.hidden })
        let texts = markupAccessibilityTexts?() ?? [:]
        return ordered.map { shape in
            let frame = transform.viewRect(from: shape.bounds).standardized
            let element = CanvasMarkupAccessibilityElement(markupID: shape.id, onPress: onMarkupAccessibilityPress)
            element.setAccessibilityRole(.layoutItem)
            element.setAccessibilityLabel(texts[shape.id] ?? Self.accessibilityLabel(for: shape))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            element.setAccessibilitySelected(selection.contains(shape.id))
            return element
        }
    }

    /// The deterministic order VoiceOver walks the markups in: top of the sheet first, then left
    /// to right (page space has y up), with the id as the last tie-break so two runs never differ.
    nonisolated static func accessibilityReadingOrder(_ shapes: [CanvasMarkupShape]) -> [CanvasMarkupShape] {
        shapes.sorted { a, b in
            let ay = a.bounds.maxY.rounded(), by = b.bounds.maxY.rounded()
            if ay != by { return ay > by }
            let ax = a.bounds.minX.rounded(), bx = b.bounds.minX.rounded()
            if ax != bx { return ax < bx }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// What VoiceOver reads for one markup.
    nonisolated static func accessibilityLabel(for shape: CanvasMarkupShape) -> String {
        let kind = shape.kind.displayName
        if let caption = shape.caption, !caption.isEmpty { return "\(kind), \(caption)" }
        if let text = shape.text, !text.isEmpty { return "\(kind), \(text)" }
        return kind
    }

    /// Posts an announcement for VoiceOver, and keeps the last few for tests.
    func announce(_ text: String) {
        accessibilityAnnouncements.append(text)
        if accessibilityAnnouncements.count > 20 { accessibilityAnnouncements.removeFirst() }
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// A markup that appears on the page it was drawn on is announced: "Added Length, 4.20 m".
    /// A page turn replaces every shape and says nothing.
    fileprivate func announceAddedShapes(since previous: [CanvasMarkupShape]) {
        guard let page = shapes.first?.pageID, previous.first?.pageID == page || previous.isEmpty else { return }
        guard !previous.isEmpty else { return }
        let before = Set(previous.map(\.id))
        let added = shapes.filter { !before.contains($0.id) }
        guard added.count == 1, let shape = added.first else { return }
        announce(String(
            format: NSLocalizedString("Added %@", comment: "VoiceOver announcement when a markup is committed; the markup"),
            Self.accessibilityLabel(for: shape)
        ))
    }
}
