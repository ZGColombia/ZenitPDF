import AppKit
import QuartzCore
import ZPDFDesignSystem

/// The canvas's document view (NL-PERF-05): a thin flipped container that holds the raster
/// layers underneath and the page view — markups, selection, the live overlay — on top.
///
/// ## Why a container
///
/// A zoom gesture used to re-lay out the document and redraw the whole visible page on the main
/// thread per event, resampling yesterday's raster on the CPU with `.high` interpolation — 11 ms
/// for the viewport alone, more than a whole 120 Hz frame.
/// Now a gesture frame changes **one transform**: ``liveTransform`` is written to this view's
/// layer's `sublayerTransform`, and the render server scales the rasters, the markups and the
/// live overlay together on the GPU. The main thread does O(1) work per frame, and the page is
/// laid out once, when the fingers lift.
///
/// AppKit manages a layer-backed view's frame, bounds and position; it does not touch
/// `sublayerTransform`, which is why the transform lives here rather than on the page view.
@MainActor
final class CanvasDocumentView: NSView {

    let rasterView = CanvasRasterLayerView()
    let pageView: CanvasPageView

    init(pageView: CanvasPageView) {
        self.pageView = pageView
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(rasterView)
        addSubview(pageView)
        pageView.rasterLayerView = rasterView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var isOpaque: Bool { false }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rasterView.frame = bounds
        pageView.frame = bounds
    }

    /// The live gesture transform, display = `liveTransform` × laid-out view point. Identity
    /// outside a gesture.
    var liveTransform: CGAffineTransform = .identity {
        didSet {
            guard liveTransform != oldValue else { return }
            applyLiveTransform()
        }
    }

    /// Core Animation applies `sublayerTransform` about the layer's anchor point A — a sublayer
    /// point x lands at A + T(x − A) — and AppKit uses A = (0, 0) for a layer-backed view today.
    /// Writing T = shift(+A) · L · shift(−A) makes the result L(x) whatever A is, measured rather
    /// than assumed (the anchor semantics were checked with `CALayer.render(in:)`).
    private func applyLiveTransform() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if liveTransform.isIdentity {
            layer.sublayerTransform = CATransform3DIdentity
        } else {
            let anchor = CGPoint(
                x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
                y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height
            )
            let applied = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .concatenating(liveTransform)
                .concatenating(CGAffineTransform(translationX: -anchor.x, y: -anchor.y))
            layer.sublayerTransform = CATransform3DMakeAffineTransform(applied)
        }
        CATransaction.commit()
    }
}

/// The page's pixels, as Core Animation layers (NL-PERF-05).
///
/// The page view used to draw every raster in `draw(_:)`: a 1:1 blit when settled, a CPU
/// resample while stale. Here each raster is a `CALayer` whose `contents` is set once, so a
/// settled tile is composited 1:1 (gates Z5 and Z6 hold exactly as before: the frames are the
/// same pixel-exact placements) and a stale one is scaled by the GPU, never by the main thread.
///
/// Stacking, bottom to top: the paper, the resident **base** raster of the whole page
/// (NL-PERF-02 — the sheet is never blank paper), then every tile ordered by its own raster
/// scale, so the sharpest picture of any spot is the one on top (level tiles and yesterday's
/// tiles, NL-PERF-06), then the vector underlay when it is exact for this zoom, and the tiles
/// made for the current zoom above all of it.
@MainActor
final class CanvasRasterLayerView: NSView {

    /// Where one raster sits in the stack.
    enum Role: Equatable {
        case base
        case level
        case stale
        case underlay
        case current
    }

    private let paperLayer = CALayer()
    private let baseLayer = CALayer()
    private let tilesLayer = CALayer()
    /// Tile layers by the identity of the image they show, so an update moves or keeps a layer
    /// rather than rebuilding it. Setting `contents` is the expensive part; it happens once.
    private var tileLayers: [ObjectIdentifier: CALayer] = [:]

    /// How many layer `contents` assignments the view has made. A test seam: a relayout must
    /// move layers, not re-upload their pixels.
    private(set) var contentsAssignmentCount = 0
    /// How many times the layer tree was re-stacked. A test seam: a gesture's first frame and
    /// its commit each cost one pass, not two or three (R-006).
    private(set) var updateCount = 0

    /// How many level-tile layers one update may create (K-14). The rest wait for the next
    /// update, which the canvas asks for on the next display frame.
    ///
    /// Measured with the gesture replay's per-frame table (R-005): the slowest Z11 frames were
    /// every gesture's first frame, and the time was the layer pass at the end of it — about a
    /// hundred level tiles, whose layers the settled page had dropped, created and given their
    /// contents in that one frame (1–3 ms of a 4 ms budget in a debug build, "level 0 → 110"
    /// in one step). Level tiles only sharpen a picture the resident base raster and the
    /// laid-out tiles already cover (gate Z12 reads the base), so taking them in a few frames
    /// costs no blank paper, and the coarser level, listed first, arrives first.
    static let levelLayerBudgetPerUpdate = 16

    /// Level tiles the last update held back for want of budget.
    private(set) var deferredLayerCount = 0
    /// The rasters on screen after the last update, with the rectangle each occupies in the
    /// view's own (laid-out) coordinates. Gate Z12's coverage is computed from this.
    private(set) var displayed: [(role: Role, raster: PageRaster, frame: CGRect)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.masksToBounds = false
        for sublayer in [paperLayer, baseLayer, tilesLayer] {
            sublayer.actions = Self.noActions
            layer.addSublayer(sublayer)
        }
        paperLayer.backgroundColor = CanvasMarkupStyle.paper.cgColor
        paperLayer.isOpaque = true
        baseLayer.contentsGravity = .resize
        baseLayer.minificationFilter = .trilinear
        baseLayer.magnificationFilter = .linear
        baseLayer.isOpaque = true
        baseLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var isOpaque: Bool { false }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    /// The page view on top owns every event.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesLayer.frame = bounds
        CATransaction.commit()
    }

    /// No implicit animation on any property: a tile that slides into place is a tile that
    /// was in the wrong place for a quarter of a second.
    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        "hidden": NSNull(), "zPosition": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        "sublayers": NSNull(), "transform": NSNull(), "opacity": NSNull()
    ]

    /// Puts the page's rasters on screen for a layout.
    ///
    /// - Parameters:
    ///   - transform: the laid-out page transform, or `nil` when no page shows.
    ///   - backingScale: device pixels per view point.
    ///   - base: the resident whole-page raster.
    ///   - rasters: every other raster, each with its role.
    ///   - filtersForMotion: a gesture transform is scaling the tree; filter every layer.
    func update(
        transform: PageDisplayTransform?,
        backingScale: CGFloat,
        base: PageRaster?,
        rasters: [(role: Role, raster: PageRaster)],
        filtersForMotion: Bool = false
    ) {
        updateCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let transform else {
            paperLayer.isHidden = true
            baseLayer.isHidden = true
            baseLayer.contents = nil
            for layer in tileLayers.values { layer.removeFromSuperlayer() }
            tileLayers.removeAll()
            deferredLayerCount = 0
            displayed = []
            return
        }
        var shown: [(role: Role, raster: PageRaster, frame: CGRect)] = []
        paperLayer.isHidden = false
        paperLayer.frame = transform.pageFrame

        if let base {
            let placement = base.placement(in: transform, backingScale: backingScale)
            if (baseLayer.contents as AnyObject?) !== (base.layerContents as AnyObject) {
                baseLayer.contents = base.layerContents
                contentsAssignmentCount &+= 1
            }
            baseLayer.frame = placement.destination
            baseLayer.isHidden = false
            shown.append((.base, base, placement.destination))
        } else {
            baseLayer.isHidden = true
            baseLayer.contents = nil
        }

        var keep: Set<ObjectIdentifier> = []
        var createdLevelLayers = 0
        var deferred = 0
        for (role, raster) in rasters {
            let id = ObjectIdentifier(raster.image)
            guard !keep.contains(id) else { continue }
            let existing = tileLayers[id]
            if existing == nil, role == .level {
                guard createdLevelLayers < Self.levelLayerBudgetPerUpdate else {
                    deferred += 1
                    continue
                }
                createdLevelLayers += 1
            }
            keep.insert(id)
            let placement = raster.placement(in: transform, backingScale: backingScale)
            let layer: CALayer
            if let existing {
                layer = existing
            } else {
                layer = CALayer()
                layer.actions = Self.noActions
                layer.contentsGravity = .resize
                layer.magnificationFilter = .linear
                layer.minificationFilter = .trilinear
                layer.isOpaque = true
                layer.contents = raster.layerContents
                contentsAssignmentCount &+= 1
                tileLayers[id] = layer
                tilesLayer.addSublayer(layer)
            }
            // K-14: only what changed is written. Every update walks every tile layer — a level
            // tile landing mid-gesture re-stacks them all — and a Core Animation setter records
            // the property in the transaction whether or not the value moved.
            if layer.contentsScale != backingScale { layer.contentsScale = backingScale }
            if layer.frame != placement.destination { layer.frame = placement.destination }
            let z = Self.zPosition(role: role, scale: raster.scale)
            if layer.zPosition != z { layer.zPosition = z }
            // A settled tile is a 1:1 copy; asking the compositor for a filter there would be
            // asking it to interpolate between pixels that already line up.
            // While a gesture scales the whole tree, every layer is resampled and wants the
            // smooth filters.
            let copies = placement.isPixelExact && !filtersForMotion
            let magnification: CALayerContentsFilter = copies ? .nearest : .linear
            let minification: CALayerContentsFilter = copies ? .nearest : .trilinear
            if layer.magnificationFilter != magnification { layer.magnificationFilter = magnification }
            if layer.minificationFilter != minification { layer.minificationFilter = minification }
            shown.append((role, raster, placement.destination))
        }
        for (id, layer) in tileLayers where !keep.contains(id) {
            layer.removeFromSuperlayer()
            tileLayers.removeValue(forKey: id)
        }
        deferredLayerCount = deferred
        displayed = shown
    }

    /// Sharper on top: a raster's own scale orders it among the level and stale tiles; the
    /// underlay sits above those and the current zoom's tiles above everything.
    static func zPosition(role: Role, scale: CGFloat) -> CGFloat {
        switch role {
        case .base: return -1_000
        case .level, .stale: return log2(max(scale, 1e-6))
        case .underlay: return 500
        case .current: return 1_000
        }
    }
}
