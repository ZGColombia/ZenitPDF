// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation
import Observation

/// In-memory presenters backed by ``ZenitSampleProject``.
///
/// Every UI package builds against the presenter protocols; previews and package tests bind
/// to these mocks instead of the core engines. They are deliberately real enough to exercise the UI:
/// selection round-trips, filters actually filter, totals actually re-sum, and the
/// measurement presenter computes live values from the sample scale. Nothing here touches
/// the file system, the network or a database.
@MainActor
public enum MockPresenters {

    /// Builds a fully wired set of presenters over the shared sample project.
    public static func makeEnvironment(
        project: ZenitSampleProject = .shared
    ) -> MockPresenterEnvironment {
        MockPresenterEnvironment(project: project)
    }
}

/// A wired set of mock presenters sharing one sample project.
///
/// The environment owns the cross-presenter links a real app would get from the document
/// controller: selecting a ledger row selects the markup on the canvas, and committing a
/// measurement adds a markup the canvas can draw.
@MainActor
public final class MockPresenterEnvironment {

    /// The sample data every presenter reads from.
    public let project: ZenitSampleProject
    /// Documents, pages, zones and scale regions.
    public let document: MockDocumentPresenter
    /// Canvas viewport, visible markups, selection and snap feedback.
    public let canvas: MockCanvasPresenter
    /// Quantity Ledger.
    public let ledger: MockLedgerPresenter
    /// Tool Library.
    public let toolLibrary: MockToolLibraryPresenter
    /// Search.
    public let search: MockSearchPresenter
    /// Revision Compare and Revision Overlay.
    public let compare: MockComparePresenter
    /// Measurement palette and the live measurement.
    public let measurement: MockMeasurementToolPresenter
    /// Status bar and warning tray.
    public let status: MockStatusPresenter

    /// Builds and wires the environment.
    public init(project: ZenitSampleProject = .shared) {
        self.project = project
        let document = MockDocumentPresenter(project: project)
        let canvas = MockCanvasPresenter(project: project)
        let ledger = MockLedgerPresenter(project: project)
        let toolLibrary = MockToolLibraryPresenter(project: project)
        let search = MockSearchPresenter(project: project)
        let compare = MockComparePresenter(project: project)
        let measurement = MockMeasurementToolPresenter(project: project)
        let status = MockStatusPresenter(project: project)

        self.document = document
        self.canvas = canvas
        self.ledger = ledger
        self.toolLibrary = toolLibrary
        self.search = search
        self.compare = compare
        self.measurement = measurement
        self.status = status

        // Ledger selection drives the canvas selection.
        ledger.onSelectionChange = { [weak canvas] rowIDs in
            canvas?.select(markupIDs: rowIDs, additive: false)
        }
        // Canvas selection drives the ledger selection.
        canvas.onSelectionChange = { [weak ledger] markupIDs in
            ledger?.applyExternalSelection(markupIDs)
        }
        // A committed measurement becomes a markup the canvas can draw.
        measurement.onCommit = { [weak canvas] markup in
            canvas?.appendMarkup(markup)
        }
        // The measurement lands on the canvas's page, at the scale in force there
        // (BH-277, BH-773).
        measurement.currentPageProvider = { [weak canvas] in canvas?.viewport.pageID }
        measurement.scaleProvider = { [weak canvas] in canvas?.activeScale }
        // The Tool Library's reuse switch and the status bar's stay in step.
        toolLibrary.onReuseToolChange = { [weak status] enabled in
            status?.setReuseToolEnabled(enabled)
        }
        // Revealing a search hit navigates the document.
        search.onReveal = { [weak document] hit in
            document?.goToPage(id: hit.pageID)
        }
        // Turning the page moves the canvas and the status bar with it.
        //
        // `MockCanvasPresenter.showPage` and `MockStatusPresenter.showPage` both existed and
        // neither had a caller, so every page command in a preview or a shell test left the
        // canvas on sheet one with the old sheet's markups and the status bar reading the old
        // page number — the one cross-presenter link a real document controller cannot fail to
        // make, missing from the harness the shell is tested against (CR-108).
        document.onPageChange = { [weak canvas, weak status, weak document] page in
            canvas?.showPage(id: page.id)
            status?.showPage(page, pageCount: document?.pages.count ?? 0)
        }
    }
}

// MARK: - Documents

/// Mock implementation of ``DocumentPresenting``.
@MainActor
@Observable
public final class MockDocumentPresenter: DocumentPresenting {

    public private(set) var tabs: [DocumentTabSummary]
    public private(set) var activeTabID: DocumentTabSummary.ID?
    public private(set) var pages: [PageDescriptor]
    public private(set) var currentPageID: PageDescriptor.ID?
    public private(set) var zones: [ProjectZoneSummary]
    public private(set) var scaleRegions: [ScaleRegionSummary]
    public private(set) var defaultScale: ScaleSummary?
    public private(set) var warnings: [AppWarning]

    /// Raised whenever the current page actually changes, with the page now showing.
    ///
    /// ``MockPresenterEnvironment`` wires it to the canvas and the status bar, which is the
    /// job a real document controller does.
    @ObservationIgnored
    public var onPageChange: (@MainActor (PageDescriptor) -> Void)?

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.tabs = project.tabs
        self.activeTabID = project.tabs.first(where: \.isActive)?.id ?? project.tabs.first?.id
        self.pages = project.pages
        self.currentPageID = project.pages.first?.id
        self.zones = project.zones
        self.scaleRegions = project.scaleRegions
        self.defaultScale = project.defaultScale
        self.warnings = project.warnings
    }

    public func selectTab(_ id: DocumentTabSummary.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        tabs = tabs.map { tab in
            var updated = tab
            updated.isActive = tab.id == id
            return updated
        }
    }

    public func closeTab(_ id: DocumentTabSummary.ID) {
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = tabs.first?.id }
        // BH-777: the flag the tab bar highlights follows the active tab.
        for index in tabs.indices { tabs[index].isActive = tabs[index].id == activeTabID }
    }

    public func goToPage(id: PageDescriptor.ID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        show(page)
    }

    public func goToPage(index: Int) {
        guard pages.indices.contains(index) else { return }
        show(pages[index])
    }

    /// The one place `currentPageID` moves, so every navigation path announces the change.
    private func show(_ page: PageDescriptor) {
        guard currentPageID != page.id else { return }
        currentPageID = page.id
        onPageChange?(page)
    }

    public func dismissWarning(id: AppWarning.ID) {
        warnings.removeAll { $0.id == id && $0.isDismissible }
    }
}

// MARK: - Canvas

/// Mock implementation of ``CanvasPresenting``.
@MainActor
@Observable
public final class MockCanvasPresenter: CanvasPresenting {

    public private(set) var viewport: ViewportSnapshot
    public private(set) var visibleMarkups: [MarkupSummary]
    public private(set) var selectedMarkupIDs: Set<UUID> = []
    public private(set) var snapFeedback: SnapFeedbackSnapshot?
    public private(set) var activeScale: ScaleSummary?
    public private(set) var activeScaleRegion: ScaleRegionSummary?
    public private(set) var isVectorSnapAvailable: Bool
    public private(set) var splitCanvasMode: SplitCanvasMode = .off
    public private(set) var filterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    /// Stored, not the inert protocol default: a shell test that toggles the coverage map must
    /// be able to read the flip back, or the test would pass against a presenter that ignores it.
    public var showsCoverageMap: Bool = false

    /// Called after the selection changes from inside the canvas, so the ledger can follow.
    public var onSelectionChange: (@MainActor (Set<UUID>) -> Void)?

    private let project: ZenitSampleProject
    /// Every markup the canvas knows, on every page — the sample's own plus every committed
    /// one. ``visibleMarkups`` is derived from it per page, so turning the page no longer
    /// throws committed markups away (BH-278).
    public private(set) var allMarkups: [MarkupSummary]

    /// The selection resolved from every page, not only the visible one (BH-279).
    public var resolvedSelectedMarkups: [MarkupSummary] {
        allMarkups.filter { selectedMarkupIDs.contains($0.id) }
    }

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.project = project
        self.allMarkups = project.markups
        let page = project.pages[0]
        self.viewport = ViewportSnapshot(
            pageID: page.id,
            pageIndex: page.index,
            zoom: 1.0,
            visiblePageRect: page.cropBox,
            backingScaleFactor: 2.0,
            displayMode: .continuous
        )
        self.visibleMarkups = project.markups.filter { $0.pageID == page.id }
        self.activeScale = project.defaultScale
        self.isVectorSnapAvailable = true
        self.snapFeedback = SnapFeedbackSnapshot(
            kind: .endpoint,
            pagePoint: PDFPointValue(x: 812.5, y: 640.0),
            sourceLabel: NSLocalizedString("Wall centreline", comment: "Sample snap source description"),
            guideHint: SnapGuideHint(
                text: NSLocalizedString("Aligned with the grid line above", comment: "Sample snap guide hint"),
                start: PDFPointValue(x: 812.5, y: 320.0),
                end: PDFPointValue(x: 812.5, y: 640.0)
            ),
            pageID: page.id,
            confidence: 0.92
        )
    }

    public func setZoom(_ zoom: Double) {
        viewport.zoom = min(ViewportSnapshot.maximumZoom, max(ViewportSnapshot.minimumZoom, zoom))
    }

    public func zoomToFit() {
        guard let page = project.pages.first(where: { $0.id == viewport.pageID }) else { return }
        viewport.visiblePageRect = page.cropBox
        viewport.zoom = 1.0
    }

    public func zoomToFitWidth() {
        guard let page = project.pages.first(where: { $0.id == viewport.pageID }) else { return }
        viewport.visiblePageRect = page.cropBox
        viewport.zoom = 1.25
    }

    public func zoomTo(markupID: UUID) {
        guard let markup = allMarkups.first(where: { $0.id == markupID }) else { return }
        showPage(id: markup.pageID)
        viewport.visiblePageRect = markup.boundsInPageSpace
        viewport.zoom = 2.0
        setSelection([markupID])
    }

    public func select(markupIDs: Set<UUID>, additive: Bool) {
        setSelection(additive ? selectedMarkupIDs.union(markupIDs) : markupIDs)
        if let first = markupIDs.first,
           let markup = allMarkups.first(where: { $0.id == first }),
           markup.pageID != viewport.pageID {
            showPage(id: markup.pageID)
        }
    }

    /// The one place the selection is stored, so every path that changes it also announces it.
    ///
    /// `select` and `zoomTo` used to assign `selectedMarkupIDs` directly and raise nothing,
    /// which meant canvas→ledger mirroring was dead in every preview and in every shell test —
    /// the seam was wired in ``MockPresenterEnvironment`` and never fired, so no test could
    /// catch a regression in it (CR-107). `clearSelection` was the only honest path.
    private func setSelection(_ ids: Set<UUID>) {
        guard ids != selectedMarkupIDs else { return }
        selectedMarkupIDs = ids
        onSelectionChange?(ids)
    }

    public func clearSelection() {
        setSelection([])
    }

    public func updateCursor(pagePoint: PDFPointValue?) {
        viewport.cursorPagePoint = pagePoint
        guard let pagePoint else {
            snapFeedback = nil
            activeScaleRegion = nil
            return
        }
        let region = project.scaleRegions
            .filter { $0.pageID == viewport.pageID }
            .sorted { $0.priority > $1.priority }
            .first { $0.boundsInPageSpace?.contains(pagePoint) == true }
        activeScaleRegion = region
        activeScale = region?.scale ?? project.defaultScale
    }

    public func setSplitCanvasMode(_ mode: SplitCanvasMode) { splitCanvasMode = mode }

    public func setFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { filterBehavior = behavior }

    /// Adds a markup produced by a committed measurement.
    ///
    /// Kept on every page, not only the visible one: a markup committed on sheet 1 is still
    /// there after the estimator visits sheet 2 and comes back (BH-278).
    public func appendMarkup(_ markup: MarkupSummary) {
        allMarkups.removeAll { $0.id == markup.id }
        allMarkups.append(markup)
        guard markup.pageID == viewport.pageID else { return }
        visibleMarkups.removeAll { $0.id == markup.id }
        visibleMarkups.append(markup)
    }

    /// Switches the visible page and refreshes the markup list.
    public func showPage(id: PageDescriptor.ID) {
        guard let page = project.pages.first(where: { $0.id == id }) else { return }
        viewport.pageID = page.id
        viewport.pageIndex = page.index
        viewport.visiblePageRect = page.cropBox
        visibleMarkups = allMarkups.filter { $0.pageID == page.id }
        // The sample's structural sheet is a scan, so it has no vector geometry.
        isVectorSnapAvailable = page.index != 2
        if !isVectorSnapAvailable { snapFeedback = nil }
    }
}

// MARK: - Status

/// Mock implementation of ``StatusPresenting``.
@MainActor
@Observable
public final class MockStatusPresenter: StatusPresenting {

    public private(set) var snapshot: StatusBarSnapshot
    public private(set) var warnings: [AppWarning]

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.snapshot = project.statusBar
        self.warnings = project.warnings.sorted { $0.severity > $1.severity }
    }

    public func setGridSnapEnabled(_ enabled: Bool) { snapshot.gridSnapEnabled = enabled }

    public func setVectorSnapEnabled(_ enabled: Bool) {
        guard snapshot.geometryIndexStatus.allowsVectorSnap else { return }
        snapshot.vectorSnapEnabled = enabled
    }

    public func setMarkupSnapEnabled(_ enabled: Bool) { snapshot.markupSnapEnabled = enabled }

    public func setReuseToolEnabled(_ enabled: Bool) { snapshot.reuseToolEnabled = enabled }

    public func setActiveTool(name: String, note: String?) {
        snapshot.activeToolName = name
        snapshot.activeToolNote = note
    }

    public func dismissWarning(id: AppWarning.ID) {
        warnings.removeAll { $0.id == id && $0.isDismissible }
    }

    public func dismissAllWarnings() {
        warnings.removeAll(where: \.isDismissible)
    }

    /// Updates the page fields of the status bar, used when the canvas changes page.
    public func showPage(_ page: PageDescriptor, pageCount: Int) {
        snapshot.pageLabel = page.label
        snapshot.pageIndex = page.index
        snapshot.pageCount = pageCount
        // BH-778: the geometry index follows the page, as the canvas does — the sample's
        // structural sheet (index 2) is a scan with no vector content, so Vector Snap cannot
        // be on there.
        snapshot.geometryIndexStatus = page.index == 2 ? .unavailable : .ready
        if !snapshot.geometryIndexStatus.allowsVectorSnap { snapshot.vectorSnapEnabled = false }
    }
}
#endif
