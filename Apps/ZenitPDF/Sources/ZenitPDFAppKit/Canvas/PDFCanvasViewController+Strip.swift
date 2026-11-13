import AppKit
import QuartzCore
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// Continuous scrolling's state, kept in one object so the controller's single-page path reads
/// as it always has. Every field is inert while ``isActive`` is off.
@MainActor
final class CanvasStripState {

    /// Reads the app-wide preference. Injectable, so a test decides the mode.
    var preference: @MainActor () -> ZenitCanvasPreferences.PageLayout = { ZenitCanvasPreferences.current.pageLayout }
    /// The preference as last read. The layout key reads this at pointer rate, never the defaults.
    var prefersContinuous = true
    /// Whether PDF layer overrides are in force for the document. Wired by the window.
    var layerOverridesActive: @MainActor () -> Bool = { false }
    /// ``layerOverridesActive`` as last read, when the layer state changed.
    var overridesActive = false
    /// Work outside the canvas that belongs to the current page: a Scale Region's calibration
    /// destination, a borrowed two-click pick, a region draft. Wired by the window.
    var externalPageLock: @MainActor () -> Bool = { false }

    /// Whether the last layout laid the strip out.
    var isActive = false
    /// The strip as last laid out.
    var layout: PageStripLayout?
    /// The current page's index in the strip, as last laid out.
    var currentIndex: Int?
    /// The page list the display sizes were read from, and the sizes.
    var sizesSource: [ZPDFUIPresentation.PageDescriptor] = []
    var sizes: [CGSize] = []
    /// The page a windowed strip is laid out around (``PageStripLayout/window``).
    var windowAnchor = 0
    /// The navigation count the last layout saw; a change is a navigation, which rests the page.
    var lastNavigationSerial: Int?
    /// Set when the strip was left, so the single-page layout that follows keeps the place.
    var leftStrip = false

    /// The neighbouring sheets on screen, by page.
    var hosts: [UUID: CanvasPassivePage] = [:]
    /// Re-entry guard: a hand-off lays the page out and reports the view, which must not hand
    /// off again from inside.
    var isAdopting = false
    /// When the current page last followed the view (the rate limit).
    var lastFollow: ContinuousClock.Instant?
    /// A follow the rate limit held back, run when the interval has passed.
    var followRetry: Task<Void, Never>?

    /// Every page's records from the last scene fetch, and the same by page.
    var recordsFetched = false
    var recordsByPage: [UUID: [MarkupRecord]] = [:]
    /// Every page's summaries by page, and the list they were grouped from.
    var summariesSource: [MarkupSummary] = []
    var summariesByPage: [UUID: [MarkupSummary]] = [:]

    /// The search hit marked out, with the page it was found on.
    var searchHighlight: (pageID: UUID, rect: PDFRectValue)?
    /// Whether the status bar has said that layer overrides suspend continuous scrolling.
    var saidSuspended = false

    // Test seams.
    /// Hand-offs of the current page: scrolling, presses and drops.
    var adoptionCount = 0
    /// Neighbouring sheets materialised.
    var materialiseCount = 0
    /// Renders started for neighbouring sheets.
    var passiveRenderStartCount = 0
    /// Window re-bases of a very tall strip.
    var rebaseCount = 0
    /// Presses on another sheet refused because work in progress holds the current one.
    var refusedPressCount = 0

    /// Whether the strip was just left, once.
    func consumeLeftStrip() -> Bool {
        defer { leftStrip = false }
        return leftStrip
    }
}

/// Continuous scrolling (ADR-0045): every page of the document in one vertical strip, one of
/// them *live* — the page the tools, the hit test and the raster pipeline act on, laid out
/// exactly as in single-page mode but in its slot — and its neighbours as passive pictures.
///
/// The live page follows the view: after a scroll the page with the largest visible area
/// becomes current (``PageStripLayout/pageToFollow(visible:current:)``), at most ten times a
/// second, through ``AppDocumentPresenter/followView(toPage:settle:)`` and one synchronous
/// layout in the same run-loop turn, so the hand-off moves nothing on screen. It never happens
/// while work in progress holds the page (``isPageLocked``), during a pinch, or while a zoom
/// animates. A press on a neighbouring sheet makes that sheet current before the press is
/// interpreted, so a click with a tool armed acts on the sheet it lands on.
extension PDFCanvasViewController {

    /// The fewest milliseconds between two hand-offs while scrolling.
    static let stripFollowInterval: Duration = .milliseconds(100)
    /// The most neighbouring sheets materialised at once.
    static let passiveHostLimit = 12
    /// The bytes the neighbours' stand-in rasters may hold together (Z7's passive clause).
    static let passiveBaseByteBudget = 96 * 1024 * 1024
    /// The stand-in raster's long side for a sheet shown no larger than this many device pixels.
    static let passiveSmallBasePixelSize = 512

    // MARK: - Mode

    /// Reads the page-layout preference. Setting it re-reads the preference and lays out again.
    var pageLayoutPreference: @MainActor () -> ZenitCanvasPreferences.PageLayout {
        get { strip.preference }
        set {
            strip.preference = newValue
            canvasPreferencesChanged()
        }
    }

    /// Whether PDF layer overrides are in force. Wired by the window.
    var layerOverridesActive: @MainActor () -> Bool {
        get { strip.layerOverridesActive }
        set {
            strip.layerOverridesActive = newValue
            strip.overridesActive = newValue()
        }
    }

    /// Work outside the canvas that holds the current page. Wired by the window.
    var externalPageLock: @MainActor () -> Bool {
        get { strip.externalPageLock }
        set { strip.externalPageLock = newValue }
    }

    /// Whether the strip should be laid out now: the preference, more than one page, and no
    /// layer overrides. Cheap: the layout key reads it at pointer rate.
    var wantsContinuousStrip: Bool {
        strip.prefersContinuous && !strip.overridesActive && core.document.pages.count > 1
    }

    /// Whether the canvas is in continuous scrolling now.
    var isContinuousScrollActive: Bool { strip.isActive }

    /// Listens for the preference changing in the View menu or in Settings.
    func installStripObservers() {
        strip.prefersContinuous = strip.preference() == .continuous
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(canvasPreferencesDidChange(_:)),
            name: ZenitCanvasPreferences.didChangeNotification,
            object: nil
        )
    }

    @objc func canvasPreferencesDidChange(_ note: Notification) {
        canvasPreferencesChanged()
    }

    private func canvasPreferencesChanged() {
        let continuous = strip.preference() == .continuous
        guard continuous != strip.prefersContinuous else { return }
        strip.prefersContinuous = continuous
        guard isViewLoaded, pageView.transform != nil else { return }
        refresh()
    }

    /// Re-reads whether layer overrides are in force; a layer change calls this before laying out.
    func refreshLayerOverrideState() {
        strip.overridesActive = strip.layerOverridesActive()
        if !strip.overridesActive { strip.saidSuspended = false }
    }

    private func enterStrip() {
        strip.isActive = true
        strip.lastNavigationSerial = nil
        // The overscroll page turn belongs to single-page mode; here the next page is just below.
        scrollView.onTurnPage = nil
        rebuildScene()
    }

    private func leaveStrip() {
        strip.isActive = false
        strip.layout = nil
        strip.currentIndex = nil
        strip.lastNavigationSerial = nil
        strip.leftStrip = true
        strip.followRetry?.cancel()
        strip.followRetry = nil
        strip.recordsFetched = false
        strip.recordsByPage = [:]
        releasePassiveHosts()
        scrollView.onTurnPage = { [weak self] forward in
            self?.turnPage(forward: forward) ?? false
        }
        // A highlight found on another sheet does not follow the reader into single-page mode.
        if let highlight = strip.searchHighlight, highlight.pageID != core.document.currentPageID {
            strip.searchHighlight = nil
            pageView.searchHighlights = []
        }
    }

    /// Says once why a multi-page document shows one page while layers are overridden.
    private func noteStripSuspension() {
        guard strip.prefersContinuous, strip.overridesActive, core.document.pages.count > 1,
              !strip.saidSuspended else { return }
        strip.saidSuspended = true
        core.status.setActiveToolNote(NSLocalizedString(
            "Continuous scrolling is paused while PDF layers are hidden: pages show one at a time.",
            comment: "Status note: a multi-page document shows one page at a time while PDF layer overrides are active"
        ))
    }

    // MARK: - Layout

    /// The display sizes of the pages, read again only when the page list is replaced.
    private func stripPageSizes(_ pages: [ZPDFUIPresentation.PageDescriptor]) -> [CGSize] {
        if strip.sizesSource != pages {
            strip.sizesSource = pages
            strip.sizes = pages.map { PageStripLayout.displaySize(of: $0.viewBox, rotation: $0.displayRotation) }
        }
        return strip.sizes
    }

    /// Lays the current page out in its slot of the strip, or returns `false` for the
    /// single-page path. The scroll rules, in order:
    ///
    /// 1. the first layout, or 2. a navigation: rest the page (top edge, or centred if it fits);
    /// 3. a hand-off by scrolling or a press: nothing moves;
    /// 4. a zoom: the page point under the anchor stays under it;
    /// 5. the viewport, the strip or the mode changed: the view's centre stays;
    /// 6. an axis on which the whole strip fits is centred;
    /// 7. Fit Page from the menu: the page is centred.
    func layoutStripIfWanted(
        page: ZPDFUIPresentation.PageDescriptor,
        zoom: CGFloat,
        previousPageID: UUID?,
        previousViewSize: CGSize?,
        anchor: (window: NSPoint, page: PDFPointValue)?,
        zoomChanged: Bool,
        externalZoom: Bool
    ) -> Bool {
        guard wantsContinuousStrip else {
            if strip.isActive { leaveStrip() }
            noteStripSuspension()
            return false
        }
        let pages = core.document.pages
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { return false }
        let entering = !strip.isActive
        if entering { enterStrip() }
        let serial = core.document.navigationSerial
        let navigated = strip.lastNavigationSerial.map { $0 != serial } ?? false
        strip.lastNavigationSerial = serial

        let viewSize = scrollView.contentSize
        let panMargin = CGSize(
            width: max(Self.margin, viewSize.width * Self.panMarginFraction),
            height: max(Self.margin, viewSize.height * Self.panMarginFraction)
        )
        if navigated || entering || needsInitialCentring { strip.windowAnchor = index }
        let sizes = stripPageSizes(pages)
        var layout = PageStripLayout(pageSizes: sizes, zoom: zoom, panMargin: panMargin, windowAnchor: strip.windowAnchor)
        if !layout.window.contains(index) {
            strip.windowAnchor = index
            layout = PageStripLayout(pageSizes: sizes, zoom: zoom, panMargin: panMargin, windowAnchor: index)
        }
        strip.layout = layout
        strip.currentIndex = index
        documentView.frame = CGRect(origin: .zero, size: layout.documentSize)
        let transform = PageDisplayTransform(
            pageBox: page.viewBox,
            rotation: page.displayRotation,
            zoom: zoom,
            origin: layout.slotOrigin(of: index)
        )
        let oldOrigin = previousPageID == page.id ? pageView.transform?.origin : nil
        let stripMoved = oldOrigin.map { $0 != transform.origin } ?? false
        pageView.transform = transform
        pageView.accessibilityPageNumber = core.canvas.viewport.pageIndex + 1
        pageView.accessibilitySheetLabel = page.label

        let clip = scrollView.contentView
        let viewportChanged = previousViewSize != nil && previousViewSize != viewSize
        if needsInitialCentring || navigated {
            needsInitialCentring = false
            restStripPage(index, layout: layout)
        } else if zoomChanged, let anchor {
            let viewAfter = transform.viewPoint(from: anchor.page)
            pageView.scroll(ZoomMath.scrollOrigin(
                anchorInDocumentAfterZoom: viewAfter,
                anchorInClipBounds: clip.convert(anchor.window, from: nil),
                clipBoundsOrigin: clip.bounds.origin
            ))
            scrollView.reflectScrolledClipView(clip)
        } else if previousPageID == page.id, !zoomChanged, entering || viewportChanged || stripMoved,
                  let centre = lastVisibleCentrePagePoint {
            let point = transform.viewPoint(from: centre)
            pageView.scroll(NSPoint(x: point.x - clip.bounds.width / 2, y: point.y - clip.bounds.height / 2))
            scrollView.reflectScrolledClipView(clip)
        }
        if zoomChanged, externalZoom, let fit = core.canvas.fitZoom, abs(fit - Double(zoom)) < 1e-9 {
            centreStripPage(index, layout: layout)
        }
        if zoomChanged || viewportChanged || entering || stripMoved {
            centreAxesWhereTheContentFits(layout.stripFrame)
        }

        let backingScale = view.window?.backingScaleFactor ?? 2
        let pageLayout = PageViewLayout(
            anchor: transform.origin,
            zoom: Double(zoom),
            backingScale: Double(backingScale),
            isViewFlipped: true
        )
        core.canvas.layout = pageLayout
        core.measurement.layout = pageLayout
        core.canvas.viewSize = viewSize
        applyPendingDestination(on: page.id, transform: transform)
        reportVisibleRect()
        // A hand-off inside the report laid the new page out already.
        guard core.document.currentPageID == page.id, pageView.transform == transform else { return true }
        requestRaster(page: page, transform: transform, backingScale: backingScale)
        updatePassiveHosts()
        return true
    }

    /// Scrolls so page `index` rests in the viewport.
    private func restStripPage(_ index: Int, layout: PageStripLayout) {
        let clip = scrollView.contentView
        pageView.scroll(layout.restingOrigin(for: index, viewport: clip.bounds.size, currentX: clip.bounds.origin.x))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Centres page `index` on every axis on which it fits the viewport: where Fit Page lands.
    private func centreStripPage(_ index: Int, layout: PageStripLayout) {
        let clip = scrollView.contentView
        let frame = layout.slotFrame(of: index)
        var origin = clip.bounds.origin
        if frame.width <= clip.bounds.width + 0.5 { origin.x = frame.midX - clip.bounds.width / 2 }
        if frame.height <= clip.bounds.height + 0.5 { origin.y = frame.midY - clip.bounds.height / 2 }
        guard origin != clip.bounds.origin else { return }
        pageView.scroll(origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Following the view

    /// Whether work in progress holds the current page, so scrolling never cancels it: placed
    /// points, an arc's through point, an armed boundary capture, an open text box, a
    /// calibration point, a drag, a typed length or the keyboard cursor, an opening proposal,
    /// or work outside the canvas (``externalPageLock``). Pan drags do not lock.
    var isPageLocked: Bool {
        let measurement = core.measurement
        if !measurement.placedPoints.isEmpty || measurement.arcThroughPoint != nil || measurement.isCapturingBoundary {
            return true
        }
        if measurementDriver.hasWorkInFlight || measurementDragAnchor != nil { return true }
        if !core.markup.placedPoints.isEmpty || activeTextEntry != nil { return true }
        if isCalibrating, !calibrationPoints.isEmpty || calibrationPlacementsInFlight > 0 { return true }
        if selectDrag != nil || captionDrag != nil || dragAnchorPoint != nil || pageView.isTrackingPress { return true }
        if !typedEntry.isEmpty || measurementInput.state.isKeyboardCursorActive { return true }
        if pendingOpeningProposal != nil { return true }
        return strip.externalPageLock()
    }

    /// Runs the follow rule for the view as it is: re-bases a windowed strip near its edge, or
    /// hands the current page over to the one the view shows most of. Returns whether it laid
    /// the page out (and so reported the view already).
    @discardableResult
    func followViewIfNeeded() -> Bool {
        guard strip.isActive, let layout = strip.layout, let current = strip.currentIndex,
              !strip.isAdopting, liveZoom == nil, !isAnimatingZoom, !isCommittingLiveZoom else { return false }
        let visible = scrollView.documentVisibleRect
        if layout.needsRebase(visible: visible), let centre = layout.nearestPage(toY: visible.midY) {
            let candidate = PageStripLayout(
                pageSizes: layout.pageSizes, zoom: layout.zoom, panMargin: layout.panMargin, windowAnchor: centre
            )
            if candidate.window != layout.window, candidate.window.contains(current) {
                strip.windowAnchor = centre
                strip.rebaseCount &+= 1
                pageView.performRasterBatch { layoutPage() }
                return true
            }
        }
        guard !isPageLocked else { return false }
        let target = layout.pageToFollow(visible: visible, current: current)
        guard target != current else { return false }
        let now = ContinuousClock.now
        if let last = strip.lastFollow, now - last < Self.stripFollowInterval {
            scheduleFollowRetry(after: Self.stripFollowInterval - (now - last))
            return false
        }
        return adoptStripPage(target, settle: false)
    }

    private func scheduleFollowRetry(after delay: Duration) {
        guard strip.followRetry == nil else { return }
        strip.followRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.strip.followRetry = nil
            self.followViewIfNeeded()
        }
    }

    /// A press is about to be interpreted: the sheet under it becomes current first, unless work
    /// in progress holds the current one — then the press is ignored there, as a press off the
    /// sheet always was, and a boundary capture says why.
    func adoptStripPage(atWindowPoint windowPoint: CGPoint) {
        guard strip.isActive, let layout = strip.layout, !strip.isAdopting, view.window != nil else { return }
        let point = documentView.convert(windowPoint, from: nil)
        guard let index = layout.page(at: point), index != strip.currentIndex else { return }
        guard !isPageLocked else {
            strip.refusedPressCount &+= 1
            if core.measurement.isCapturingBoundary || strip.externalPageLock() {
                core.status.setActiveToolNote(NSLocalizedString(
                    "Finish or cancel the work on this page before using another page.",
                    comment: "Status note: a press on another page in continuous scrolling while a boundary or pick on the current page is in progress"
                ))
            }
            return
        }
        adoptStripPage(index, settle: true)
    }

    /// A drop lands on the sheet under it.
    func adoptStripPageUnderDrop() {
        guard let location = scrollView.lastDropLocationInWindow else { return }
        adoptStripPage(atWindowPoint: location)
    }

    /// Makes page `index` the current page without moving anything on screen: the presenter
    /// follows, the page is laid out in its slot (its tiles and stand-in come from the cache),
    /// its scene is re-filtered from the records already fetched, and the page it replaces
    /// becomes a neighbouring sheet — all in one Core Animation transaction.
    @discardableResult
    func adoptStripPage(_ index: Int, settle: Bool) -> Bool {
        let pages = core.document.pages
        guard strip.isActive, !strip.isAdopting, pages.indices.contains(index) else { return false }
        let target = pages[index]
        guard target.id != core.document.currentPageID else { return false }
        strip.isAdopting = true
        defer { strip.isAdopting = false }
        strip.lastFollow = .now
        strip.adoptionCount &+= 1
        strip.followRetry?.cancel()
        strip.followRetry = nil
        // The sheet's stand-in becomes the current page's resident base: nothing is fetched again.
        if let host = strip.hosts[target.id], let base = host.base, host.basePixelSize == Self.baseRasterPixelSize {
            baseRasters[host.rasterKey] = base
            baseRasterOrder.removeAll { $0 == host.rasterKey }
            baseRasterOrder.append(host.rasterKey)
            while baseRasterOrder.count > 3 { baseRasters.removeValue(forKey: baseRasterOrder.removeFirst()) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        core.document.followView(toPage: target.id, settle: settle)
        if strip.recordsFetched { sceneRecords = strip.recordsByPage[target.id] ?? [] }
        pageView.performRasterBatch { layoutPage() }
        if strip.recordsFetched {
            applyScene()
            markSceneCurrent()
        }
        refreshLiveFeedback()
        applyStripSearchHighlight()
        return true
    }

    // MARK: - Neighbouring sheets

    /// Materialises the sheets whose slots meet the viewport grown by one viewport height —
    /// nearest first, at most ``passiveHostLimit`` — places them, and drops the rest. O(log n)
    /// in the page count.
    func updatePassiveHosts() {
        guard strip.isActive, let layout = strip.layout, let current = strip.currentIndex else {
            if !strip.hosts.isEmpty { releasePassiveHosts() }
            return
        }
        let pages = core.document.pages
        let visible = scrollView.documentVisibleRect
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        let range = layout.visibleRange(band)
        var wanted: [Int] = []
        if !range.isEmpty {
            let middle = min(max(layout.nearestPage(toY: visible.midY) ?? range.lowerBound, range.lowerBound), range.upperBound - 1)
            var up = middle, down = middle + 1
            while wanted.count < Self.passiveHostLimit, up >= range.lowerBound || down < range.upperBound {
                if up >= range.lowerBound {
                    if up != current { wanted.append(up) }
                    up -= 1
                }
                if wanted.count < Self.passiveHostLimit, down < range.upperBound {
                    if down != current { wanted.append(down) }
                    down += 1
                }
            }
        }
        let wantedIDs = Set(wanted.map { pages[$0].id })
        for (id, host) in strip.hosts where !wantedIDs.contains(id) {
            host.remove()
            strip.hosts.removeValue(forKey: id)
        }
        for index in wanted {
            let page = pages[index]
            let transform = PageDisplayTransform(
                pageBox: page.viewBox,
                rotation: page.displayRotation,
                zoom: layout.zoom,
                origin: layout.slotOrigin(of: index)
            )
            var host = strip.hosts[page.id]
            if let existing = host, existing.page != page || existing.rasterKey != rasterKey(of: page) {
                existing.remove()
                strip.hosts.removeValue(forKey: page.id)
                host = nil
            }
            let materialised = host == nil
            let sheet = host ?? materialise(page)
            if let previous = sheet.documentTransform, previous.zoom != transform.zoom || previous.pageBox != transform.pageBox {
                // Another zoom: what is on screen stands in, resampled, until the new tiles land.
                if !sheet.pageView.tileRasters.isEmpty { sheet.pageView.staleTileRasters = sheet.pageView.tileRasters }
                sheet.resetRaster()
            }
            sheet.place(transform)
            if materialised { applyPassiveScene(sheet) }
            ensurePassiveBase(sheet)
        }
        enforcePassiveBaseBudget(order: wanted.map { pages[$0].id })
        requestPassiveRasters()
    }

    private func materialise(_ page: ZPDFUIPresentation.PageDescriptor) -> CanvasPassivePage {
        let host = CanvasPassivePage(pageID: page.id, rasterKey: rasterKey(of: page))
        host.page = page
        host.install(in: documentView.passiveHost)
        strip.hosts[page.id] = host
        strip.materialiseCount &+= 1
        // A page the current page has just left keeps its resident base.
        if let base = baseRasters[host.rasterKey] {
            host.base = base
            host.basePixelSize = Self.baseRasterPixelSize
            host.pageView.baseRaster = base
        }
        return host
    }

    /// Gives a sheet its whole-page stand-in: the thumbnail the Navigator and the current
    /// page's base raster use, 2048 pixels — or 512 for a sheet shown no larger than that.
    /// A turned or cropped view has none, as on the current page.
    private func ensurePassiveBase(_ host: CanvasPassivePage) {
        guard let page = host.page, let transform = host.documentTransform else { return }
        guard page.viewRotation == 0, page.viewCrop == nil, let source = rasterSource(for: page) else { return }
        let device = max(transform.pageFrame.width, transform.pageFrame.height) * (view.window?.backingScaleFactor ?? 2)
        let size = device <= CGFloat(Self.passiveSmallBasePixelSize) ? Self.passiveSmallBasePixelSize : Self.baseRasterPixelSize
        guard host.basePixelSize < size, host.baseTask == nil else { return }
        let pdfIndex = page.index
        let displayWidth = transform.displaySize.width
        host.baseTask = Task { @MainActor [weak self, weak host] in
            guard let image = try? await source.thumbnail(pageIndex: pdfIndex, maximumPixelSize: size) else {
                host?.baseTask = nil
                return
            }
            let base = await CanvasSurfaceImage.surfaced(PageRaster(
                image: image,
                coverage: .wholePage,
                scale: displayWidth > 0 ? CGFloat(image.width) / displayWidth : 1
            ))
            guard let self, let host, !Task.isCancelled, self.strip.hosts[host.pageID] === host else { return }
            self.recordLanding {
                host.baseTask = nil
                host.base = base
                host.basePixelSize = size
                host.pageView.baseRaster = base
            }
            self.enforcePassiveBaseBudget(order: nil)
        }
    }

    /// Keeps the neighbours' stand-ins within ``passiveBaseByteBudget``, dropping the farthest.
    private func enforcePassiveBaseBudget(order: [UUID]?) {
        var total = strip.hosts.values.reduce(0) { $0 + $1.baseBytes }
        guard total > Self.passiveBaseByteBudget else { return }
        let visible = scrollView.documentVisibleRect
        let farthestFirst = (order.map { $0.reversed().compactMap { strip.hosts[$0] } } ?? strip.hosts.values.sorted {
            abs(($0.documentTransform?.pageFrame.midY ?? 0) - visible.midY) > abs(($1.documentTransform?.pageFrame.midY ?? 0) - visible.midY)
        })
        for host in farthestFirst where total > Self.passiveBaseByteBudget {
            total -= host.baseBytes
            host.dropBase()
        }
    }

    /// Bytes the neighbours' stand-ins hold. A test seam for the memory bound.
    var passiveBaseBytesForTesting: Int { strip.hosts.values.reduce(0) { $0 + $1.baseBytes } }

    /// Asks for exact tiles for every neighbouring sheet in view — only while the current page
    /// has no render in flight, so its render is always issued first (the renderer is serial
    /// per drawing), and never mid-gesture.
    func requestPassiveRasters() {
        guard strip.isActive, pendingPlan == nil, liveZoom == nil, !isAnimatingZoom else { return }
        let visible = scrollView.documentVisibleRect
        let hosts = strip.hosts.values.sorted {
            abs(($0.documentTransform?.pageFrame.midY ?? 0) - visible.midY)
                < abs(($1.documentTransform?.pageFrame.midY ?? 0) - visible.midY)
        }
        for host in hosts { requestPassiveRaster(host, visible: visible) }
    }

    /// One sheet's exact tiles: planned in document coordinates exactly as the current page
    /// plans, cached cells shown at once, the missing ones rendered in one call into the shared
    /// cache. One render in flight per sheet; a newer plan waits for it rather than cancelling.
    private func requestPassiveRaster(_ host: CanvasPassivePage, visible: CGRect) {
        guard let page = host.page, let transform = host.documentTransform,
              let source = rasterSource(for: page) else { return }
        guard visible.intersects(transform.pageFrame) else {
            if host.pendingPlan == nil, !host.pageView.tileRasters.isEmpty {
                host.pageView.tileRasters = []
                host.pageView.staleTileRasters = []
                host.deliveredPlan = nil
            }
            return
        }
        let backingScale = view.window?.backingScaleFactor ?? 2
        noteRenderedView(of: page)
        guard let plan = try? ViewportRasterPlanner.plan(
            transform: transform, visibleViewRect: visible, backingScale: backingScale
        ) else { return }
        if let delivered = host.deliveredPlan, ViewportRasterPlanner.satisfies(delivered, plan) { return }
        if let pending = host.pendingPlan {
            if pending != plan { host.needsReplan = true }
            return
        }
        let grid = CanvasTileCache.Grid(
            pageIndex: host.rasterKey,
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
        let keys = cells.map { grid.key(column: $0.column, row: $0.row) }
        let cached = keys.compactMap { tileCache.tile(for: $0) }
        let missing = cells.filter { !tileCache.contains(grid.key(column: $0.column, row: $0.row)) }
        host.pageView.tileRasters = cached
        guard !missing.isEmpty else {
            host.deliveredPlan = plan
            host.tileKeys = keys
            host.pageView.staleTileRasters = []
            return
        }
        let union = missing
            .map { grid.deviceRect(column: $0.column, row: $0.row) }
            .reduce(CGRect.null) { $0.union($1) }
        guard let renderPlan = try? ViewportRasterPlanner.plan(
            transform: transform,
            visibleViewRect: CGRect(
                x: union.minX / backingScale, y: union.minY / backingScale,
                width: union.width / backingScale, height: union.height / backingScale
            ),
            backingScale: backingScale,
            overscanViewPoints: 0
        ) else { return }
        host.pendingPlan = plan
        host.renderGeneration &+= 1
        let generation = host.renderGeneration
        let render = rasterRenderer(page: page, rasterSource: source)
        strip.passiveRenderStartCount &+= 1
        host.renderTask = Task { @MainActor [weak self, weak host] in
            let image = await render(renderPlan)
            guard let self, let host, !Task.isCancelled, host.renderGeneration == generation else { return }
            guard let image else {
                host.pendingPlan = nil
                return
            }
            let sliced = await Task.detached(priority: .utility) {
                CanvasTileCache.slice(
                    image,
                    renderedDeviceRect: renderPlan.deviceRect,
                    cells: missing,
                    grid: grid,
                    transform: transform,
                    backingScale: backingScale
                )
            }.value
            guard !Task.isCancelled, host.renderGeneration == generation else { return }
            // Recorded with the current page's landings: gate Z14 measures every millisecond
            // the main thread spends putting a render on screen.
            self.recordLanding {
                self.tileCache.insert(contentsOf: sliced)
                host.pendingPlan = nil
                guard host.documentTransform == transform else { return }
                host.pageView.performRasterBatch {
                    let tiles = keys.compactMap { self.tileCache.tile(for: $0) }
                    host.pageView.tileRasters = tiles
                    if tiles.count == keys.count {
                        host.deliveredPlan = plan
                        host.tileKeys = keys
                        host.pageView.staleTileRasters = []
                    }
                }
            }
            if host.needsReplan || host.documentTransform != transform {
                host.needsReplan = false
                self.requestPassiveRaster(host, visible: self.scrollView.documentVisibleRect)
            }
        }
    }

    /// Waits for every neighbouring sheet's render and stand-in in flight.
    func settlePassiveRastersForTesting() async {
        for host in Array(strip.hosts.values) {
            await host.baseTask?.value
            await host.renderTask?.value
        }
    }

    /// The cache keys of the tiles the neighbours show, which a memory warning keeps.
    func passiveTileKeys() -> Set<CanvasTileCache.Key> {
        var keys: Set<CanvasTileCache.Key> = []
        for host in strip.hosts.values { keys.formUnion(host.tileKeys) }
        return keys
    }

    /// Gives memory back under pressure: the neighbours' resampled stand-ins always, their
    /// whole-page stand-ins too when it is critical. What is on screen stays.
    func relievePassiveHosts(critical: Bool) {
        for host in strip.hosts.values {
            host.pageView.staleTileRasters = []
            if critical { host.dropBase() }
        }
    }

    /// Drops every neighbouring sheet (the canvas left the screen, or the strip was left).
    func releasePassiveHosts() {
        for host in strip.hosts.values { host.remove() }
        strip.hosts.removeAll()
    }

    /// The neighbouring sheets materialised now. A test seam.
    var passivePagesForTesting: [CanvasPassivePage] {
        strip.hosts.values.sorted { ($0.documentTransform?.origin.y ?? 0) < ($1.documentTransform?.origin.y ?? 0) }
    }

    // MARK: - The neighbours' ink

    /// Keeps the scene fetch's records for the neighbouring sheets, by page.
    func adoptStripRecords(_ records: [MarkupRecord]) {
        guard strip.isActive else { return }
        strip.recordsByPage = Dictionary(grouping: records, by: { $0.pageID.rawValue })
        strip.recordsFetched = true
    }

    /// Draws every neighbouring sheet's markups again (a fetch landed).
    func applyPassiveScenes() {
        guard strip.isActive else { return }
        for host in strip.hosts.values { applyPassiveScene(host) }
    }

    /// One neighbouring sheet's ink, from the same builder the current page uses: its markups,
    /// the selection, the double-count hatch, its boundary marks, the dim set, the coverage map
    /// and its search highlight.
    private func applyPassiveScene(_ host: CanvasPassivePage) {
        let pageID = host.pageID
        let records = strip.recordsByPage[pageID] ?? []
        let hidden = sceneHiddenMarkupIDs
        let shown = hidden.isEmpty ? records : records.filter { !hidden.contains($0.id.rawValue) }
        let summaries = core.snapshot.markups
        if strip.summariesSource != summaries {
            strip.summariesSource = summaries
            strip.summariesByPage = Dictionary(grouping: summaries, by: \.pageID)
        }
        host.pageView.shapes = sceneShapes(
            records: shown,
            summaries: strip.summariesByPage[pageID] ?? [],
            pageID: pageID,
            captionOverrides: [:],
            cache: host.shapeCache,
            authorsByID: { AuthorTint.authorsByID(records) },
            dimmed: core.canvas.dimmedMarkupIDs(onPage: pageID)
        )
        host.pageView.selection = core.canvas.selectedMarkupIDs
        host.pageView.boundaryMarks = core.snapshot.boundaryMarks(onPage: pageID)
        host.pageView.doubleCountHatch = Self.doubleCountHatch(core.doubleCountRegions[PageID(pageID)] ?? [])
        host.pageView.insertedImagePixels = resolvedInsertedImages
        host.pageView.coverageOverlay = passiveCoverage(host, records: records)
        host.pageView.searchHighlights = strip.searchHighlight.flatMap { $0.pageID == pageID ? [$0.rect] : nil } ?? []
    }

    private func passiveCoverage(_ host: CanvasPassivePage, records: [MarkupRecord]) -> CanvasPageView.CoverageOverlay? {
        guard core.canvas.showsCoverageMap, let page = host.page else {
            host.coverageCache = nil
            return nil
        }
        let measured = Self.coverageRecords(records, onPage: host.pageID)
        let newest = measured.map(\.modifiedAt).max()
        if let cache = host.coverageCache, cache.count == measured.count, cache.newest == newest { return cache.overlay }
        let overlay = Self.coverageOverlay(measured: measured, page: page)
        host.coverageCache = (measured.count, newest, overlay)
        return overlay
    }

    /// The live lane's share for the neighbours: the selection, which a click elsewhere or the
    /// ledger moves. One comparison per sheet when nothing changed.
    func refreshPassiveSelection() {
        guard strip.isActive else { return }
        let selection = core.canvas.selectedMarkupIDs
        for host in strip.hosts.values { host.pageView.selection = selection }
    }

    // MARK: - Search highlights

    /// Records the search highlight with the page it was found on (`nil` clears it).
    func noteStripSearchHighlight(_ rect: PDFRectValue?) {
        strip.searchHighlight = rect.flatMap { rect in core.document.currentPageID.map { (pageID: $0, rect: rect) } }
        applyStripSearchHighlight()
    }

    /// Draws the highlight on the sheet it belongs to, live or passive, and nowhere else.
    func applyStripSearchHighlight() {
        guard strip.isActive else { return }
        let highlight = strip.searchHighlight
        pageView.searchHighlights = highlight.flatMap { $0.pageID == core.document.currentPageID ? [$0.rect] : nil } ?? []
        for host in strip.hosts.values {
            host.pageView.searchHighlights = highlight.flatMap { $0.pageID == host.pageID ? [$0.rect] : nil } ?? []
        }
    }

    // MARK: - Test seams

    /// The strip as last laid out.
    var stripLayoutForTesting: PageStripLayout? { strip.layout }
    /// Hand-offs so far.
    var stripAdoptionCountForTesting: Int { strip.adoptionCount }
    /// Neighbouring sheets materialised so far.
    var stripMaterialiseCountForTesting: Int { strip.materialiseCount }
    /// Renders started for neighbouring sheets so far.
    var passiveRenderStartCountForTesting: Int { strip.passiveRenderStartCount }
    /// Presses on another sheet refused while work held the current one.
    var stripRefusedPressCountForTesting: Int { strip.refusedPressCount }
    /// Window re-bases so far.
    var stripRebaseCountForTesting: Int { strip.rebaseCount }

    /// The fraction of every visible sheet — the current page and its neighbours — that some
    /// raster covers on the frame the display would show now. Continuous scrolling's gate Z12.
    func visibleStripCoverageForTesting() -> Double {
        let visible = scrollView.documentVisibleRect
        var covered = pageView.drawnRasterCoverage(of: visible)
        for host in strip.hosts.values {
            let origin = host.pageView.frame.origin
            covered = min(covered, host.pageView.drawnRasterCoverage(of: visible.offsetBy(dx: -origin.x, dy: -origin.y)))
        }
        return covered
    }
}
