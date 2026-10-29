import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Everything one Split Canvas pane needs to draw its page: the page's box, its `/Rotate`,
/// and a region renderer aimed at the right document and page.
///
/// Built by ``ProjectWindowController/splitPaneRenderSource(for:)`` from the pane's
/// `documentID`/`pageID`, so the pane draws the drawing it names — never whatever
/// happens to be the front tab.
@MainActor
struct SplitPaneRenderSource {

    /// What the sheet shows, in page space: its view crop within the crop box
    /// (`PageDescriptor.viewBox`, NL-DOCS-16), else the crop box.
    let pageBox: PDFRectValue

    /// How the sheet stands on screen: the page's `/Rotate` plus its view rotation
    /// (`PageDescriptor.displayRotation`, NL-DOCS-07). The renderer returns its image in
    /// *display* space, so a pane that ignored this drew a rotated sheet transposed and
    /// squashed (BH-064), and one that took `/Rotate` alone drew a turned sheet unturned (T-003).
    var rotation: Int = 0

    /// What the source renders — the document and page — so a SwiftUI update that rebuilds
    /// an identical source does not throw away the pane's render (BH-349). Empty means
    /// "unknown": every assignment is then treated as a change, the conservative old
    /// behaviour.
    var identity: String = ""

    /// Rasterises a page-space region at a pixels-per-point density.
    /// Returns `nil` when the render is refused or the document has closed.
    let render: @MainActor (_ region: PDFRectValue, _ pixelsPerPoint: Double) async -> CGImage?

    /// The pane's geometry for this page.
    var geometry: SplitPaneGeometry { SplitPaneGeometry(pageBox: pageBox, rotation: rotation) }

    /// Whether two sources draw the same thing the same way.
    func isSameSource(as other: SplitPaneRenderSource?) -> Bool {
        guard let other, !identity.isEmpty else { return false }
        return identity == other.identity && pageBox == other.pageBox && rotation == other.rotation
    }
}

/// The page <-> pane mapping for one Split Canvas pane (IM-174).
///
/// A pane scrolls in **display space**: the sheet as it appears once `/Rotate` is applied,
/// y growing upwards (the pane view is unflipped), with its origin at the crop box's origin.
/// The mapping to page space goes through ``PageDisplayTransform`` — the same transform the
/// main canvas and its hit testing use — rather than a third hand-written formula, so a
/// rotated sheet scrolls, places and renders the same way in a pane as on the canvas.
struct SplitPaneGeometry: Equatable {
    let pageBox: PDFRectValue
    let rotation: Int

    private var transform: PageDisplayTransform {
        PageDisplayTransform(pageBox: pageBox, rotation: rotation, zoom: 1, origin: .zero)
    }

    /// The sheet's rectangle in display space: same origin as the crop box, sides swapped at
    /// 90° and 270°.
    var displayBox: PDFRectValue {
        let size = transform.displaySize
        return PDFRectValue(
            x: pageBox.minX, y: pageBox.minY,
            width: Double(size.width), height: Double(size.height)
        )
    }

    /// The page-space region a display-space rectangle covers, clamped to the crop box.
    func pageRegion(forDisplay display: PDFRectValue) -> PDFRectValue {
        let height = Double(transform.displaySize.height)
        // Display space is y-up; the transform's view space is y-down.
        let flipped = CGRect(
            x: display.minX - pageBox.minX,
            y: height - (display.maxY - pageBox.minY),
            width: display.size.width,
            height: display.size.height
        )
        return transform.pageRect(covering: flipped)
    }

    /// The display-space rectangle a page-space region occupies.
    func displayRegion(forPage page: PDFRectValue) -> PDFRectValue {
        let height = Double(transform.displaySize.height)
        let flipped = transform.viewRect(from: page)
        return PDFRectValue(
            x: Double(flipped.minX) + pageBox.minX,
            y: height - Double(flipped.maxY) + pageBox.minY,
            width: Double(flipped.width),
            height: Double(flipped.height)
        )
    }
}

/// The live page view inside one Split Canvas pane (LT-24).
///
/// A shared-render strategy rather than a second `PDFCanvasViewController` per pane: each
/// pane rasterises exactly its visible page region through the same engine-barrier
/// `PageRasterSource` the main canvas uses, at the pane's own zoom and scroll position. The
/// pane state itself lives in `SplitCanvasController`, which is what mirrors scroll, zoom
/// and page between panes when the sync toggles are on — this view only *reports* gestures
/// into the controller and draws whatever state comes back, so a follower pane never
/// re-broadcasts what it was told.
@MainActor
final class SplitPaneCanvasView: NSView {

    /// A pane raster may not allocate more pixels than this. A pane is at most a quarter
    /// of a window, so this is generous — and a region request over it is rendered at a
    /// proportionally lower density rather than refused, because a soft page beats a
    /// placeholder (the exact trade the main canvas refuses for measurements, and a mode
    /// pane, which measures nothing, may take).
    static let maximumPanePixels = 12_000_000

    /// How long pan and zoom events must pause before a new raster starts. The stale image
    /// is moved with every event (IM-173), so the fingers are tracked without a render per
    /// event; rendering per event cancelled every render before it landed and froze a
    /// continuous pan (BH-346).
    static let renderDebounceNanoseconds: UInt64 = 40_000_000

    // MARK: Injected

    /// Renders a page-space region; swapped whenever the pane's document or page changes.
    var renderSource: SplitPaneRenderSource? {
        didSet {
            if let renderSource, renderSource.isSameSource(as: oldValue) { return }
            // A different drawing or page: the old pixels are not this pane's any more, even
            // if the new render fails (BH-348).
            clearImage()
            scheduleRender(debounced: false)
        }
    }

    /// Reports a pan, in display space. The receiver routes it into `SplitCanvasController`.
    var onPan: (@MainActor (PDFPointValue) -> Void)?
    /// Reports a zoom. The receiver routes it into `SplitCanvasController`, which clamps.
    var onZoom: (@MainActor (Double) -> Void)?
    /// Reports that the person touched this pane, which makes it the focused pane.
    var onFocus: (@MainActor () -> Void)?

    // MARK: Pane state, as last applied

    private(set) var zoom: Double = 1
    private(set) var scrollOffset: PDFPointValue = .zero

    // MARK: Render state, observable by tests

    /// The last page image actually rasterised, `nil` until the first render lands.
    /// Non-`nil` is what "this pane shows the drawing, not a placeholder" means.
    private(set) var lastRenderedImage: CGImage?
    /// The page-space region ``lastRenderedImage`` covers.
    private(set) var lastRenderedRegion: PDFRectValue?
    /// The display-space region ``lastRenderedImage`` covers — where it is placed.
    private(set) var lastRenderedDisplayRegion: PDFRectValue?
    /// How many renders were started. BH-349's counter.
    private(set) var renderStartCount = 0

    /// Whether the pane has real page pixels on screen.
    var hasLivePageContent: Bool { lastRenderedImage != nil }

    /// The frame the page image currently occupies, for IM-173's test.
    var imageFrameForTesting: CGRect { imageLayer.frame }

    private let imageLayer = CALayer()
    private var renderGeneration = 0
    private var renderTask: Task<Void, Never>?
    private var renderedBackingScale: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ZPDFColor.nsColor(.canvasBackdrop).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(NSLocalizedString(
            "Drawing pane",
            comment: "Accessibility label for a Split Canvas pane showing the drawing"
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Applying pane state

    /// Applies the pane's controller state. Re-renders only when something changed.
    func apply(zoom: Double, scrollOffset: PDFPointValue) {
        let clampedZoom = max(ViewportSnapshot.minimumZoom, min(ViewportSnapshot.maximumZoom, zoom))
        let zoomChanged = abs(clampedZoom - self.zoom) > 1e-9
        let offsetChanged = scrollOffset != self.scrollOffset
        guard zoomChanged || offsetChanged else { return }
        self.zoom = clampedZoom
        self.scrollOffset = scrollOffset
        // Move the pixels already on screen with the gesture, now (IM-173, BH-346).
        repositionImage()
        scheduleRender(debounced: true)
    }

    override func layout() {
        super.layout()
        repositionImage()
        scheduleRender(debounced: false)
    }

    /// A move between a 1x and a 2x display re-renders at the new density (BH-888).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        if let rendered = renderedBackingScale, abs(rendered - scale) < 0.01 { return }
        scheduleRender(debounced: false)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Gestures — reported into the controller, never applied locally

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let plainWheelZooms = ZenitCanvasScrollView.plainWheelZooms(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            precise: event.hasPreciseScrollingDeltas,
            shiftHeld: event.modifierFlags.contains(.shift),
            scrollingDeltaY: event.scrollingDeltaY,
            preference: !event.hasPreciseScrollingDeltas && event.phase == [] && ZenitCanvasPreferences.current.wheelZooms
        )
        if event.modifierFlags.contains(.command) || plainWheelZooms {
            // The main canvas's convention and its curve (IM-245): ⌘ + wheel zooms, and a plain
            // wheel does too under Settings ▸ Canvas ▸ "Mouse wheel zooms" (NL-UX-14).
            if let factor = ZenitCanvasScrollView.zoomFactor(
                scrollingDeltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                invertedFromDevice: event.isDirectionInvertedFromDevice
            ) {
                reportZoom(factor: factor, anchor: anchor)
            }
        } else {
            reportScroll(byViewDelta: Self.panDelta(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas
            ))
        }
    }

    /// Line height a mouse-wheel notch pans by. A wheel reports *lines*, and reading them as
    /// points panned one point per notch — a mouse user could not pan a pane (BH-887).
    static let wheelLineHeight: CGFloat = 16

    /// A scroll event's pan, in view points.
    static func panDelta(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, precise: Bool) -> CGSize {
        let scale: CGFloat = precise ? 1 : wheelLineHeight
        return CGSize(width: scrollingDeltaX * scale, height: scrollingDeltaY * scale)
    }

    override func magnify(with event: NSEvent) {
        reportZoom(factor: 1 + Double(event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    /// A pan gesture, in view points. Converted to display space and reported.
    func reportScroll(byViewDelta delta: CGSize) {
        guard zoom > 0, let renderSource else { return }
        onFocus?()
        var offset = scrollOffset
        // The view is not flipped, so view y and display y agree: dragging content down
        // (positive wheel delta) shows a higher part of the sheet.
        offset.x -= Double(delta.width) / zoom
        offset.y += Double(delta.height) / zoom
        onPan?(Self.clamp(
            offset: offset, viewSize: bounds.size, zoom: zoom, pageBox: renderSource.geometry.displayBox
        ))
    }

    /// A zoom gesture about a point in the pane (its centre when none is given). The
    /// controller clamps and mirrors the zoom; the offset is re-derived so the display point
    /// under the anchor stays under it, and re-clamped so a zoom can never strand the pane
    /// over blank space — it used to anchor at the bottom-left corner and could (BH-347).
    func reportZoom(factor: Double, anchor: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        onFocus?()
        let newZoom = max(ViewportSnapshot.minimumZoom, min(ViewportSnapshot.maximumZoom, zoom * factor))
        onZoom?(zoom * factor)
        guard let renderSource, zoom > 0 else { return }
        let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let offset = Self.anchoredOffset(
            offset: scrollOffset, oldZoom: zoom, newZoom: newZoom, anchorInView: point
        )
        onPan?(Self.clamp(
            offset: offset, viewSize: bounds.size, zoom: newZoom, pageBox: renderSource.geometry.displayBox
        ))
    }

    /// The scroll offset that keeps the display point under `anchorInView` fixed across a
    /// zoom change. Pure for tests.
    static func anchoredOffset(
        offset: PDFPointValue, oldZoom: Double, newZoom: Double, anchorInView: CGPoint
    ) -> PDFPointValue {
        guard oldZoom > 0, newZoom > 0 else { return offset }
        let anchorX = offset.x + Double(anchorInView.x) / oldZoom
        let anchorY = offset.y + Double(anchorInView.y) / oldZoom
        return PDFPointValue(
            x: anchorX - Double(anchorInView.x) / newZoom,
            y: anchorY - Double(anchorInView.y) / newZoom
        )
    }

    /// Keeps the visible region overlapping the sheet: at least a sliver of page stays in
    /// view on every axis, so a pane can never be panned into blank space it cannot find
    /// its way back from.
    static func clamp(
        offset: PDFPointValue,
        viewSize: CGSize,
        zoom: Double,
        pageBox: PDFRectValue
    ) -> PDFPointValue {
        guard zoom > 0 else { return offset }
        let visibleWidth = Double(viewSize.width) / zoom
        let visibleHeight = Double(viewSize.height) / zoom
        let margin = 24.0 / zoom
        let minX = pageBox.minX - max(0, visibleWidth - margin)
        let maxX = pageBox.maxX - min(visibleWidth, margin)
        let minY = pageBox.minY - max(0, visibleHeight - margin)
        let maxY = pageBox.maxY - min(visibleHeight, margin)
        return PDFPointValue(
            x: min(max(offset.x, minX), max(minX, maxX)),
            y: min(max(offset.y, minY), max(minY, maxY))
        )
    }

    // MARK: Rendering

    /// The display-space region the pane currently shows, intersected with the sheet.
    func visibleDisplayRegion() -> PDFRectValue? {
        guard let renderSource, zoom > 0,
              bounds.width > 1, bounds.height > 1 else { return nil }
        let box = renderSource.geometry.displayBox
        let visible = PDFRectValue(
            x: scrollOffset.x,
            y: scrollOffset.y,
            width: Double(bounds.width) / zoom,
            height: Double(bounds.height) / zoom
        )
        let minX = max(box.minX, visible.minX)
        let minY = max(box.minY, visible.minY)
        let maxX = min(box.maxX, visible.maxX)
        let maxY = min(box.maxY, visible.maxY)
        guard maxX - minX > 1e-6, maxY - minY > 1e-6 else { return nil }
        return PDFRectValue(
            origin: PDFPointValue(x: minX, y: minY),
            size: PDFSizeValue(width: maxX - minX, height: maxY - minY)
        )
    }

    /// The page-space region the pane currently shows — what is rasterised. On a rotated
    /// sheet this is the same page rect the main canvas reports for the same view (IM-174).
    func visiblePageRegion() -> PDFRectValue? {
        guard let renderSource, let display = visibleDisplayRegion() else { return nil }
        return renderSource.geometry.pageRegion(forDisplay: display)
    }

    /// Starts a superseding render of the visible region.
    func scheduleRender() { scheduleRender(debounced: false) }

    private func scheduleRender(debounced: Bool) {
        guard let renderSource else {
            renderTask?.cancel()
            clearImage()
            return
        }
        guard let display = visibleDisplayRegion() else {
            // Nothing of the sheet is in view: showing the old picture over blank space is
            // the stale state BH-347 described.
            renderTask?.cancel()
            clearImage()
            return
        }
        let region = renderSource.geometry.pageRegion(forDisplay: display)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var pixelsPerPoint = zoom * max(1, Double(backingScale))
        let pixels = display.size.width * display.size.height * pixelsPerPoint * pixelsPerPoint
        if pixels > Double(Self.maximumPanePixels) {
            pixelsPerPoint *= (Double(Self.maximumPanePixels) / pixels).squareRoot()
        }
        renderGeneration += 1
        let generation = renderGeneration
        let density = pixelsPerPoint
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: Self.renderDebounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
            guard let self, let renderSource = self.renderSource else { return }
            self.renderStartCount += 1
            let image = await renderSource.render(region, density)
            guard !Task.isCancelled, generation == self.renderGeneration else { return }
            guard let image else {
                // A refused render leaves nothing of an older source on screen: the source
                // swap already cleared it, and a same-source refusal keeps the last good
                // pixels, which are still this page's.
                return
            }
            self.renderedBackingScale = backingScale
            self.lastRenderedImage = image
            self.lastRenderedRegion = region
            self.lastRenderedDisplayRegion = display
            self.placeImage(image)
        }
    }

    private func clearImage() {
        lastRenderedImage = nil
        lastRenderedRegion = nil
        lastRenderedDisplayRegion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }

    /// Puts the rendered region's pixels exactly where that region sits in the pane.
    private func placeImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        repositionImage()
    }

    /// Re-places the current image for the current zoom and offset, without rendering.
    private func repositionImage() {
        guard let region = lastRenderedDisplayRegion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The view is unflipped, so display y and view y both grow upwards.
        imageLayer.frame = Self.imageFrame(for: region, scrollOffset: scrollOffset, zoom: zoom)
        CATransaction.commit()
    }

    /// Where a display-space region's pixels sit in the pane. Pure for tests.
    static func imageFrame(for region: PDFRectValue, scrollOffset: PDFPointValue, zoom: Double) -> CGRect {
        CGRect(
            x: CGFloat((region.minX - scrollOffset.x) * zoom),
            y: CGFloat((region.minY - scrollOffset.y) * zoom),
            width: CGFloat(region.size.width * zoom),
            height: CGFloat(region.size.height * zoom)
        )
    }

    /// Waits for the in-flight render, so a test can assert on the settled state.
    func settleRenderForTesting() async {
        await renderTask?.value
    }
}

/// Hosts ``SplitPaneCanvasView`` inside the shell's SwiftUI Split Canvas mode.
///
/// The pane state comes in from `SplitCanvasView`'s body — which re-evaluates whenever the
/// observable `SplitCanvasController` changes a pane — and gestures go back out through the
/// same controller, so sync between panes has exactly one authority.
struct SplitCanvasPaneLiveContent: NSViewRepresentable {

    let pane: SplitCanvasPaneState
    let renderSource: SplitPaneRenderSource
    let controller: SplitCanvasController

    func makeNSView(context: Context) -> SplitPaneCanvasView {
        let view = SplitPaneCanvasView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: SplitPaneCanvasView, context: Context) {
        configure(nsView)
    }

    /// The one wiring between a pane view and the controller — `makeNSView`,
    /// `updateNSView` and the regression tests all go through it, so a test that proves
    /// scroll sync proves the shipping wiring and not a copy of it.
    func configure(_ view: SplitPaneCanvasView) {
        let paneID = pane.id
        let controller = self.controller
        view.onPan = { offset in controller.setScrollOffset(offset, in: paneID) }
        view.onZoom = { zoom in controller.setZoom(zoom, in: paneID) }
        view.onFocus = { controller.focusPane(paneID) }
        view.renderSource = renderSource
        view.apply(zoom: pane.zoom, scrollOffset: pane.scrollOffset)
    }
}
