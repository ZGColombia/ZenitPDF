import CoreGraphics
import Foundation
import Observation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation

/// `CanvasPresenting` fed by markup state, the measurement in progress and the snap engine.
///
/// The presenter holds what the renderer draws — viewport, visible markups, selection, snap
/// feedback — and nothing else. Cursor moves are the hottest path in the product, so the
/// rule here is strict: `updateCursor(pagePoint:)` never awaits and never calls an engine
/// synchronously. It records the point and hands a snap query to the session; the answer
/// arrives as a `Sendable` snapshot one hop later, and a stale answer is dropped by
/// sequence number rather than being drawn a frame late.
@MainActor
@Observable
public final class AppCanvasPresenter: CanvasPresenting {

    // MARK: Published state

    public private(set) var viewport: ViewportSnapshot
    public private(set) var visibleMarkups: [MarkupSummary] = []
    public private(set) var selectedMarkupIDs: Set<UUID> = []
    public private(set) var snapFeedback: SnapFeedbackSnapshot?
    /// How many ranked alternatives the last applied hover resolve had beside its winner — what
    /// Cycle Snap Candidate can step to (L-71: with none it says so rather than doing nothing).
    @ObservationIgnored public private(set) var snapAlternativeCount = 0
    public private(set) var activeScale: ScaleSummary?
    /// The last snapshot adopted, so turning a page can re-resolve the scale immediately.
    ///
    /// Without it the canvas would keep showing the scale of the page it just left until the
    /// next refresh arrived — which is exactly the window in which a person reads the status
    /// bar and starts measuring.
    private var latestSnapshot: DocumentSnapshot?
    public private(set) var activeScaleRegion: ScaleRegionSummary?
    public private(set) var isVectorSnapAvailable: Bool = false
    public private(set) var splitCanvasMode: SplitCanvasMode = .off
    public private(set) var filterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    /// The coverage-map toggle (View menu). Observed by the canvas host, which draws the
    /// overlay; user-driven, never assigned during layout, so no conditional-assign guard.
    public var showsCoverageMap: Bool = false
    /// NL-COLLAB-06: draw every markup in its author's colour. Display only — the stored style
    /// is never touched — and never printed or exported.
    public var tintsByAuthor: Bool = false

    /// Markups that are drawn but failed the ledger filter, under ``filterBehavior``
    /// `.dimNonMatching`.
    ///
    /// Empty under `.hideNonMatching` (those markups are not in ``visibleMarkups`` at all),
    /// under `.leaveUnchanged`, and whenever no filter is on. Published rather than kept
    /// private because dimming happens where the stroke is drawn, and the drawing layer
    /// must not have to know what a ledger filter is to honour one.
    public private(set) var dimmedMarkupIDs: Set<UUID> = []

    /// Markups the ledger filter takes off the sheet under ``filterBehavior``
    /// `.hideNonMatching`: not hidden, yet failing the filter, on every page (V-003).
    ///
    /// The one rule for "filtered out of sight": the canvas leaves these out of the drawing,
    /// the hit test and the marquee, and every snap resolve made for this window excludes them
    /// (``snapExcludedMarkupIDs``), so a snap can never land on ink the sheet no longer shows.
    /// Empty under `.dimNonMatching` and `.leaveUnchanged` (a dimmed markup is drawn, so it
    /// stays a target) and whenever no filter is on.
    public private(set) var filterHiddenMarkupIDs: Set<UUID> = []

    /// ``filterHiddenMarkupIDs`` as the session's snap exclusion, built once per change so
    /// every pointer move hands the session the same stored set (its cache compares by
    /// identity first). Read at the moment of each resolve: this presenter's hover, the
    /// measurement presenter's clicks, a calibration pick and a Select vertex drag.
    @ObservationIgnored public private(set) var snapExcludedMarkupIDs: Set<MarkupID> = []

    /// The saved Project Zone and Scale Region outlines and calibration picks on the page on
    /// screen, which the canvas draws (U-086) — the marks the snap boundary layer is fed from,
    /// so every boundary snap target is drawn. Assigned only on a real change, so the canvas's
    /// observation wakes for an outline edit and not for every refresh.
    public private(set) var boundaryMarks: [PageBoundaryMark] = []

    /// Markups on a hidden or a locked markup layer (ADR-0032): the canvas never selects them —
    /// a hidden layer cannot be seen and a locked one cannot be picked. The ledger's own row
    /// selection (``applyExternalSelection(_:)``) is not narrowed; editing is refused by the
    /// session either way.
    public private(set) var unselectableMarkupIDs: Set<UUID> = []

    /// Called when the selection changed on the canvas, so the ledger can follow.
    public var onSelectionChange: (@MainActor (Set<UUID>) -> Void)?
    /// Called when the canvas asks to be scrolled to a rectangle in page space.
    public var onScrollTo: (@MainActor (PDFRectValue, _ flash: Bool) -> Void)?

    /// Called when revealing a markup needs a different page shown first.
    ///
    /// Clicking a measurement in the summary list must bring up its page when it is on another
    /// sheet (reported 2026-08-26). ``zoomTo(markupID:)`` moved this
    /// presenter's own `viewport.pageID` and stopped there — but the canvas renders
    /// `AppDocumentPresenter.currentPage`, so the viewport pointed at sheet 7 while sheet 3 was
    /// still on screen. Clicking a row on another sheet appeared to do nothing.
    ///
    /// The page change belongs to the document presenter, which this one deliberately does not
    /// hold. `AppCoreEnvironment` wires the two together, so every caller — the ledger, the
    /// history feed, the Inspector — is fixed at once rather than each remembering to change the
    /// page before asking for the reveal. The search path already did it by hand; it no longer
    /// has to.
    public var onRequestPage: (@MainActor (ZPDFUIPresentation.PageDescriptor.ID) -> Void)?

    // MARK: Private state

    private let session: TakeoffSession
    private var allMarkups: [MarkupSummary] = []

    /// Test seam: seeds the markup list without a whole `DocumentSnapshot`, so the reveal path
    /// can be asserted against two markups on two pages rather than a fixture document.
    func adoptMarkupsForTesting(_ markups: [MarkupSummary]) { allMarkups = markups }

    /// Test seam: everything the canvas knows about, so a test can assert what the Inspector
    /// would read rather than what the record holds.
    var allMarkupsForTesting: [MarkupSummary] { allMarkups }
    private var matchingMarkupIDs: Set<UUID>?
    /// Page-space anchor of the in-progress measurement, which perpendicular and tangent
    /// candidates are computed relative to.
    private var snapAnchor: PDFPointValue?
    /// The snap keys the canvas holds down (`⌘` suspends snapping, spec 13.8), passed
    /// with every hover resolve so the glyph agrees with the click. Set by the canvas on each
    /// modifier change; not observed, because the canvas re-resolves itself when it changes.
    @ObservationIgnored public var snapModifiers: SnapModifiers = .none
    /// Monotonic pointer-sample number. A resolution whose sequence is behind the latest
    /// sample is discarded: showing it would move the snap glyph backwards.
    private var pointerSequence: Int = 0
    private var latestAppliedSequence: Int = -1
    private var snapTask: Task<Void, Never>?

    /// The view geometry the snap engine needs to turn a page point back into pixels.
    /// Supplied by the hosting view on every layout, because zoom can change between two
    /// mouse moves.
    public var layout: PageViewLayout = PageViewLayout()

    /// The size of the scroll view's content area, in view points.
    ///
    /// Supplied by the hosting view. Without it "fit the page" has nothing to fit to, so
    /// the two fit commands would be a pair of controls that do nothing — which is worse
    /// than not offering them.
    public var viewSize: CGSize = .zero

    /// The full size of the active page in page points, after `/Rotate`.
    private var pageSize: PDFSizeValue = .zero

    /// Creates a presenter over a session.
    public init(session: TakeoffSession, pageID: UUID, pageIndex: Int = 0) {
        self.session = session
        self.viewport = ViewportSnapshot(
            pageID: pageID,
            pageIndex: pageIndex,
            zoom: 1,
            viewerRotation: .degrees0,
            visiblePageRect: .zero,
            cursorPagePoint: nil,
            backingScaleFactor: 1,
            displayMode: .single
        )
    }

    // MARK: Snapshot intake

    /// Adopts a document snapshot: markups, scale, and the page list the viewport indexes
    /// into.
    public func adopt(_ snapshot: DocumentSnapshot) {
        // Every write below is guarded by a comparison. The canvas both writes the viewport
        // and observes it, and `@Observable` fires on assignment rather than on change: an
        // unconditional `viewport.pageIndex = …` and `selectedMarkupIDs = …` on every refresh
        // re-ran the observers' layout and selection passes for values that had not moved
        // (CR-18) — and a refresh follows every command, undo and unit change.
        if allMarkups != snapshot.markups { allMarkups = snapshot.markups }
        let unselectable = Set(snapshot.markups.lazy.filter { $0.layerLocked == true || $0.layerHidden == true }.map(\.id))
        if unselectable != unselectableMarkupIDs { unselectableMarkupIDs = unselectable }
        latestSnapshot = snapshot
        if let page = snapshot.pages.first(where: { $0.id == viewport.pageID }) {
            if viewport.pageIndex != page.index { viewport.pageIndex = page.index }
            if pageSize != page.viewSize { pageSize = page.viewSize }
        } else if let first = snapshot.pages.first {
            viewport.pageID = first.id
            viewport.pageIndex = first.index
            viewport.visiblePageRect = first.visibleBox
            pageSize = first.viewSize
        }
        // After the page has been resolved above, so the scale is the scale of the page the
        // canvas actually settled on rather than of the one it was asked for.
        let scale = snapshot.scale(onPage: viewport.pageID)
        if activeScale != scale { activeScale = scale }
        let known = Set(allMarkups.map(\.id))
        // A layer hidden or locked since the last snapshot takes its markups out of the selection.
        let retained = selectedMarkupIDs.filter { known.contains($0) && !unselectable.contains($0) }
        if retained != selectedMarkupIDs { selectedMarkupIDs = retained }
        recomputeVisible()
    }

    /// Reports whether the active page has vector geometry, which is what decides whether
    /// Vector Snap is offered at all (spec 13.11).
    public func setVectorSnapAvailable(_ available: Bool) {
        isVectorSnapAvailable = available
    }

    /// Narrows the canvas to the markups that pass the ledger filter, or clears the
    /// narrowing when `ids` is `nil`.
    public func setFilterMatches(_ ids: Set<UUID>?) {
        matchingMarkupIDs = ids
        recomputeVisible()
    }

    /// Sets the anchor the in-progress measurement is drawing from.
    public func setSnapAnchor(_ point: PDFPointValue?) { snapAnchor = point }

    private func recomputeVisible() {
        let page = viewport.pageID
        let marks = latestSnapshot?.boundaryMarks(onPage: page) ?? []
        if marks != boundaryMarks { boundaryMarks = marks }   // U-086
        visibleMarkups = allMarkups.filter { summary in
            guard summary.pageID == page, !summary.hidden else { return false }
            guard let matchingMarkupIDs else { return true }
            switch filterBehavior {
            case .hideNonMatching: return matchingMarkupIDs.contains(summary.id)
            case .dimNonMatching, .leaveUnchanged: return true
            }
        }
        // Which of the drawn markups the filter left out. Only `.dimNonMatching` produces
        // any: `.hideNonMatching` removed them above, and `.leaveUnchanged` means the
        // filter is a ledger fact the drawing does not react to.
        if let matchingMarkupIDs, filterBehavior == .dimNonMatching {
            dimmedMarkupIDs = Set(visibleMarkups.map(\.id)).subtracting(matchingMarkupIDs)
        } else {
            dimmedMarkupIDs = []
        }
        // What Hide takes off the sheet, on every page — the complement of the rule above for
        // everything that is not hidden in its own right (V-003).
        var filterHidden: Set<UUID> = []
        if let matchingMarkupIDs, filterBehavior == .hideNonMatching {
            for summary in allMarkups where !summary.hidden && !matchingMarkupIDs.contains(summary.id) {
                filterHidden.insert(summary.id)
            }
        }
        guard filterHidden != filterHiddenMarkupIDs else { return }
        filterHiddenMarkupIDs = filterHidden
        snapExcludedMarkupIDs = Set(filterHidden.map { MarkupID($0) })
        // A ring resting on a markup the filter just hid, or missing one it just showed, is
        // re-resolved now rather than at the next pointer move.
        if let cursor = viewport.cursorPagePoint { updateCursor(pagePoint: cursor) }
    }

    // MARK: CanvasPresenting

    public func setZoom(_ zoom: Double) {
        // Conditional for the reason `setVisiblePageRect` is: `@Observable` publishes on every
        // assignment, and the canvas both writes the viewport and observes it. That loop once
        // cost ≈17 000 refreshes a second; this is the same shape, one property along.
        let clamped = min(PageViewLayout.maximumZoom, max(PageViewLayout.minimumZoom, zoom))
        guard viewport.zoom != clamped else { return }
        viewport.zoom = clamped
        layout = layout.withZoom(viewport.zoom)
    }

    /// The zoom that fits the whole page on screen, whichever dimension is the binding one:
    /// the page as displayed (view crop, `/Rotate` plus view rotation) in the scroll view's
    /// content area. `nil` until both sizes are known. The one fit rule — the Fit Page command
    /// and the canvas's smart magnify both read it (app-canvas S-003).
    public var fitZoom: Double? {
        guard pageSize.width > 0, pageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        return min(viewSize.width / pageSize.width, viewSize.height / pageSize.height)
    }

    /// Fits the whole page, whichever dimension is the binding one.
    public func zoomToFit() {
        guard let fitZoom else { return }
        setZoom(fitZoom)
    }

    /// Fits the page width, which is what a user reading a title block wants.
    public func zoomToFitWidth() {
        guard pageSize.width > 0, viewSize.width > 0 else { return }
        setZoom(viewSize.width / pageSize.width)
    }

    /// Scrolls to a markup and flashes it — or, under Reduce Motion, selects it and asks
    /// for a static reveal, because a flash is an animation.
    public func zoomTo(markupID: UUID) {
        guard let summary = allMarkups.first(where: { $0.id == markupID }) else { return }
        if summary.pageID != viewport.pageID {
            // A markup whose page is not in the document — left behind by a shorter revision —
            // has no sheet to go to. Its summary carries a stand-in index of 0, and copying that
            // into the viewport claimed page 1 while requesting a page that does not exist
            // (BH-419). The index is taken from the document's own pages, or nothing moves.
            var pageIndex = summary.pageIndex
            if let snapshot = latestSnapshot {
                guard let page = snapshot.pages.first(where: { $0.id == summary.pageID }) else { return }
                pageIndex = page.index
            }
            viewport.pageID = summary.pageID
            viewport.pageIndex = pageIndex
            activeScale = latestSnapshot?.scale(onPage: viewport.pageID)
            recomputeVisible()
            // …and the document has to follow, or the canvas keeps drawing the old sheet.
            onRequestPage?(summary.pageID)
        }
        selectedMarkupIDs = [markupID]
        // The revealed markup is marked out by a static highlight, which is not motion: the
        // Reduce Motion and Increase Contrast flags that used to gate it were never set in
        // production (R-063), and the zoom's own animation checks Reduce Motion in the canvas.
        onScrollTo?(summary.boundsInPageSpace, true)
    }

    /// The whole selection, resolved from every markup in the document — other sheets, hidden
    /// and filtered-out ones included — in document order. The protocol's default resolves
    /// from the visible set only, which let the Inspector drop selected markups the canvas was
    /// not drawing (BH-279).
    public var resolvedSelectedMarkups: [MarkupSummary] {
        allMarkups.filter { selectedMarkupIDs.contains($0.id) }
    }

    public func select(markupIDs: Set<UUID>, additive: Bool) {
        let selectable = unselectableMarkupIDs.isEmpty ? markupIDs : markupIDs.subtracting(unselectableMarkupIDs)
        selectedMarkupIDs = additive ? selectedMarkupIDs.union(selectable) : selectable
        onSelectionChange?(selectedMarkupIDs)
    }

    public func clearSelection() {
        guard !selectedMarkupIDs.isEmpty else { return }
        selectedMarkupIDs = []
        onSelectionChange?(selectedMarkupIDs)
    }

    /// Applies a selection that came from the ledger, without echoing it back.
    public func applyExternalSelection(_ markupIDs: Set<UUID>) {
        selectedMarkupIDs = markupIDs
    }

    /// Records a cursor position and starts a snap resolve for it.
    ///
    /// Returns immediately. The resolve runs on the session actor and its answer is applied
    /// only if no newer sample has been taken in the meantime, so the glyph the user sees
    /// always corresponds to where the pointer is now.
    public func updateCursor(pagePoint: PDFPointValue?) {
        // Same rule. A pointer that has not moved between two samples must not wake every
        // observer of the viewport — and a stationary pointer sends plenty of samples.
        if viewport.cursorPagePoint != pagePoint {
            viewport.cursorPagePoint = pagePoint
        }
        guard let pagePoint else {
            snapTask?.cancel()
            snapFeedback = nil
            snapAlternativeCount = 0
            return
        }

        pointerSequence &+= 1
        let sequence = pointerSequence
        let pageID = PageID(viewport.pageID)
        let layout = self.layout
        let anchor = snapAnchor.map { PDFPoint(shown: $0) }
        let cursor = PDFPoint(shown: pagePoint)
        let modifiers = snapModifiers
        let excluded = snapExcludedMarkupIDs

        snapTask?.cancel()
        snapTask = Task { [weak self] in
            guard let self else { return }
            let resolution = try? await self.session.resolveSnap(
                pageID: pageID,
                pagePoint: cursor,
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchor,
                sequence: sequence,
                excludingMarkupIDs: excluded
            )
            guard !Task.isCancelled else { return }
            self.applySnap(resolution, sequence: sequence, pageID: pageID)
        }
    }

    /// Applies a snap resolution if it is not already stale.
    public func applySnap(_ resolution: SnapResolution?, sequence: Int, pageID: PageID) {
        guard sequence >= latestAppliedSequence else { return }
        latestAppliedSequence = sequence
        snapAlternativeCount = resolution?.feedback == nil ? 0 : (resolution?.alternatives.count ?? 0)
        guard let resolution, let feedback = resolution.feedback else {
            snapFeedback = nil
            return
        }
        snapFeedback = SnapFeedbackSnapshot(
            domain: feedback,
            pageID: pageID,
            confidence: resolution.winner.map { Double($0.confidence) } ?? 1
        )
    }

    public func setSplitCanvasMode(_ mode: SplitCanvasMode) { splitCanvasMode = mode }

    public func setFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) {
        filterBehavior = behavior
        recomputeVisible()
    }

    /// Moves the viewport to a page.
    public func showPage(_ page: ZPDFUIPresentation.PageDescriptor) {
        viewport.pageID = page.id
        viewport.pageIndex = page.index
        viewport.visiblePageRect = page.visibleBox
        pageSize = page.viewSize
        snapFeedback = nil
        // The scale belongs to the page, so it changes with the page and not one refresh later.
        activeScale = latestSnapshot?.scale(onPage: page.id)
        recomputeVisible()
    }

    /// Installs the visible rectangle after a scroll, so the status bar and the renderer
    /// agree about what is on screen.
    public func setVisiblePageRect(_ rect: PDFRectValue, backingScaleFactor: Double) {
        // **Assign only on a real change.** `@Observable` publishes on every *assignment*, not on
        // every change of value, and the canvas both writes this and observes `viewport`. Writing
        // an identical rectangle therefore woke the canvas, which laid out, which reported its
        // visible rectangle again — a loop with nothing in it that ever settles.
        //
        // Measured on 2026-08-27, in a window, with one area on the page:
        // `PDFCanvasViewController.refresh()` ran **≈17 000 times per second**. Each pass
        // cancelled the scene-building task before `await session.orderedMarkups` returned, so
        // `sceneRecords` stayed empty for as long as the loop ran, and with it the cutout parent
        // list — which is why the Cutout tool appeared not to work. The tool was refusing
        // every click as "outside every area" while the pointer sat inside one.
        //
        // The loop also spends the main thread, which is what `Scripts/verify-app-launches.sh`
        // measures; it had been failing at 36–42 % idle against a floor of 50 %.
        if viewport.visiblePageRect != rect {
            viewport.visiblePageRect = rect
        }
        if viewport.backingScaleFactor != backingScaleFactor {
            viewport.backingScaleFactor = backingScaleFactor
        }
    }
}
