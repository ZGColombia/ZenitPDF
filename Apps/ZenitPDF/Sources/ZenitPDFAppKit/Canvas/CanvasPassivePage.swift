import AppKit
import QuartzCore
import ZPDFAppCore
import ZPDFUIPresentation

/// The container the passive sheets of continuous scrolling live in: a flipped, layer-backed
/// view under the current page's rasters, as large as the document view. It takes no events
/// and is no accessibility element; the current page's view on top owns all of that.
@MainActor
final class CanvasPassiveHostView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var isOpaque: Bool { false }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// One materialised neighbouring sheet in continuous scrolling.
///
/// Made of the two classes the current page is made of, so it looks exactly like it: a
/// ``CanvasRasterLayerView`` for the pixels and a ``CanvasPageView`` in passive mode for the
/// ink. Its tiles live in the canvas's shared ``CanvasTileCache`` under the same grid the
/// current page uses, which is what makes the hand-off free: when the sheet becomes current,
/// every cell it showed is already cached and nothing is rendered; when the current sheet
/// becomes passive, it reads the same tiles back.
///
/// The views are placed in a frame snapped to whole points around the sheet's slot, so the
/// local coordinates keep the slot's sub-pixel phase and a settled tile stays a 1:1 copy.
/// Raster *planning* is done in document coordinates (``documentTransform``), exactly as the
/// current page plans, so both ask for the same cells.
@MainActor
final class CanvasPassivePage {

    /// How far, in view points, ink may reach beyond the sheet: pills, arrowheads, handles.
    static let inkReach: CGFloat = 64

    let pageID: UUID
    /// The raster caches' key for the page (``PDFCanvasViewController/rasterKey(of:)``).
    let rasterKey: Int
    let rasterView = CanvasRasterLayerView()
    let pageView = CanvasPageView()
    /// The shapes compiled for this sheet, kept across scene passes (IM-042).
    let shapeCache = CanvasShapeCache()

    /// The page as it was materialised; a change of its view makes a new sheet.
    var page: ZPDFUIPresentation.PageDescriptor?
    /// The cache keys of the tiles the last complete delivery showed, which a memory warning keeps.
    var tileKeys: [CanvasTileCache.Key] = []
    /// The sheet's transform in the document view's coordinates.
    private(set) var documentTransform: PageDisplayTransform?

    /// The whole-sheet stand-in raster and the bytes it holds.
    var base: PageRaster?
    var baseBytes: Int { base.map { $0.image.bytesPerRow * $0.image.height } ?? 0 }
    var baseTask: Task<Void, Never>?
    /// The long side, in pixels, the stand-in was asked for.
    var basePixelSize = 0

    /// The plan whose tiles are on screen, and the one a render is in flight for.
    var deliveredPlan: ViewportRasterPlan?
    var pendingPlan: ViewportRasterPlan?
    var renderTask: Task<Void, Never>?
    /// Supersedes a render whose result is no longer wanted.
    var renderGeneration = 0
    /// A newer plan arrived while a render was in flight: plan again when it lands.
    var needsReplan = false

    /// The coverage overlay and what it was computed from.
    var coverageCache: (count: Int, newest: Date?, overlay: CanvasPageView.CoverageOverlay?)?

    init(pageID: UUID, rasterKey: Int) {
        self.pageID = pageID
        self.rasterKey = rasterKey
        pageView.isPassive = true
        pageView.rasterLayerView = rasterView
    }

    /// Puts the sheet's two views into the host, raster under ink.
    func install(in host: NSView) {
        host.addSubview(rasterView)
        host.addSubview(pageView, positioned: .above, relativeTo: rasterView)
    }

    /// Takes the views out and stops every task. The tiles stay in the shared cache.
    func remove() {
        baseTask?.cancel()
        renderTask?.cancel()
        renderGeneration &+= 1
        rasterView.removeFromSuperview()
        pageView.removeFromSuperview()
    }

    /// Places the sheet at its slot.
    func place(_ transform: PageDisplayTransform) {
        guard transform != documentTransform else { return }
        documentTransform = transform
        let reach = Self.inkReach
        let slot = transform.pageFrame
        let origin = CGPoint(x: (slot.minX - reach).rounded(.down), y: (slot.minY - reach).rounded(.down))
        let frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: (slot.maxX + reach).rounded(.up) - origin.x,
            height: (slot.maxY + reach).rounded(.up) - origin.y
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rasterView.frame != frame { rasterView.frame = frame }
        if pageView.frame != frame { pageView.frame = frame }
        pageView.transform = PageDisplayTransform(
            pageBox: transform.pageBox,
            rotation: transform.rotation,
            zoom: transform.zoom,
            origin: CGPoint(x: transform.origin.x - origin.x, y: transform.origin.y - origin.y)
        )
        CATransaction.commit()
    }

    /// Forgets what is on screen so the next request plans afresh (a zoom, a layer change).
    func resetRaster() {
        renderTask?.cancel()
        renderGeneration &+= 1
        deliveredPlan = nil
        pendingPlan = nil
        needsReplan = false
        pageView.tileRasters = []
    }

    /// Drops the stand-in raster, giving its memory back.
    func dropBase() {
        baseTask?.cancel()
        baseTask = nil
        base = nil
        basePixelSize = 0
        pageView.baseRaster = nil
    }
}
