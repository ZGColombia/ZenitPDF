import Foundation
import ZPDFContracts
import ZPDFGeometry

/// How much of the scene a frame is allowed to leave unsubmitted.
///
/// Culling is an optimisation with a correctness contract: **it must never change what is
/// visibly drawn**. The policy therefore has two independent levers with two different
/// justifications:
///
/// - **Viewport culling** never changes pixels at all. A markup is skipped only when its
///   padded page-space bounds — geometry bounds inflated by its own painted-ink allowance —
///   cannot intersect the drawable. The margin band exists purely as hysteresis, so a
///   one-pixel pan does not recompute the visible set sixty times a second.
/// - **The sub-pixel cutoff** does change pixels, deliberately and accountably: a markup whose
///   whole geometric extent projects below ``subPixelCutoffDevicePixels`` is dropped, counted
///   in ``RenderStatistics/subPixelMarkupCount``, and dropped **identically by both backends**,
///   because the decision is made once, on the CPU, in `Double`, by ``ScenePreparer`` — never
///   re-derived per backend in `Float`. The golden suite's cross-backend equality therefore
///   holds with the cutoff active. Text is exempt: a glyph's extent is a pixel quantity that
///   does not shrink with zoom, so the geometric test would lie about it.
public struct CullingPolicy: Sendable, Hashable {
    /// `false` submits everything, as the renderer did before viewport culling existed.
    public var isEnabled: Bool
    /// Hysteresis band beyond the drawable, in device pixels. The visible set is computed for
    /// the drawable grown by this band and reused while the drawable stays inside it.
    public var marginDevicePixels: Double
    /// Markups whose geometric extent projects below this many device pixels are not submitted.
    /// `0` disables the cutoff.
    public var subPixelCutoffDevicePixels: Double

    public init(
        isEnabled: Bool = true,
        marginDevicePixels: Double = 256,
        subPixelCutoffDevicePixels: Double = 0.5
    ) {
        self.isEnabled = isEnabled
        self.marginDevicePixels = marginDevicePixels
        self.subPixelCutoffDevicePixels = subPixelCutoffDevicePixels
    }

    public static let `default` = CullingPolicy()
    public static let disabled = CullingPolicy(isEnabled: false)
}

/// Which of a prepared scene's markups this frame submits.
///
/// Indices are into `PreparedScene.markups`, ascending — which is painter order, so a backend
/// can iterate the list directly and preserve draw order. `nil` means "everything": the fast
/// path, taken whenever nothing was culled and nothing fell below the cutoff, so a scene that
/// fits on screen costs exactly what it did before culling existed.
public struct SceneVisibility: Sendable {
    /// Storage indices to submit, ascending, or `nil` for all of them.
    public var visibleIndices: [Int]?
    /// Markups skipped because their padded bounds cannot touch the drawable.
    public var culledMarkupCount: Int
    /// Markups skipped because their geometric extent is below the sub-pixel cutoff. Never
    /// silent: reported here and in ``RenderStatistics/subPixelMarkupCount``.
    public var subPixelMarkupCount: Int
    /// Changes whenever the visible set is recomputed. Backends use it to know when their
    /// submission lists are stale.
    public var version: UInt64

    public init(
        visibleIndices: [Int]?,
        culledMarkupCount: Int,
        subPixelMarkupCount: Int,
        version: UInt64
    ) {
        self.visibleIndices = visibleIndices
        self.culledMarkupCount = culledMarkupCount
        self.subPixelMarkupCount = subPixelMarkupCount
        self.version = version
    }

    public static let everything = SceneVisibility(
        visibleIndices: nil,
        culledMarkupCount: 0,
        subPixelMarkupCount: 0,
        version: 0
    )
}

/// Decides, once per frame and once for both backends, which markups are submitted.
///
/// # Where the numbers come from
///
/// The spatial index is `ZPDFGeometry.PackedRTree` over each markup's geometry bounds inflated
/// by its **page-point** ink padding (stroke width). The pixel-sized part of the ink — the
/// stroke floor, the antialiasing feather, glyph quads — cannot go into a zoom-independent
/// tree, so it is handled on the query side: the drawable rectangle is expanded by the largest
/// ``CompiledMarkup/paddingDevicePixels`` in the scene, converted to page points at the current
/// zoom. Anything the query rejects therefore cannot have painted a pixel inside the drawable,
/// which is the whole correctness argument, and the partial-viewport golden test checks it
/// pixel for pixel.
///
/// # Incremental maintenance
///
/// The tree is rebuilt when the topology changes — a user action, and cheaper than the full
/// recompile that accompanies it. A drag patches the flat arrays and marks the index **stale**
/// for that markup: stale markups are unconditionally treated as candidates until the tree is
/// rebuilt, so a markup dragged off its indexed position can never be wrongly culled. The tree
/// is rebuilt outright once staleness passes a threshold.
final class SceneCuller {

    private static let staleRebuildThreshold = 1_024
    /// Antialiasing and MSAA slack added to every query, in device pixels.
    private static let pixelSlack = 4.0

    // Flat per-storage-index data. No dictionaries on the per-frame path.
    private var boxMinX: [Double] = []
    private var boxMinY: [Double] = []
    private var boxMaxX: [Double] = []
    private var boxMaxY: [Double] = []
    /// Geometric extent in page points; `.infinity` for markups exempt from the cutoff (text),
    /// `-1` for markups with no bounds (never indexed, always submitted).
    private var extent: [Double] = []
    private var hasBounds: [Bool] = []

    private var tree: PackedRTree?
    /// Tree item index -> storage index.
    private var treeStorage: [Int] = []
    /// Storage indices with no usable bounds: always submitted.
    private var unbounded: [Int] = []
    private var stale: Set<Int> = []
    private var needsRebuild = true
    private var maxPaddingDevicePixels = 0.0

    // The cache that makes a pan cheap.
    private var cachedQueryRect: PDFRect?
    private var cachedPixelsPerPagePoint = Double.nan
    private var cachedPolicy: CullingPolicy?
    private var cachedVisibility: SceneVisibility?
    private var version: UInt64 = 0

    // Scratch, reused across frames.
    private var marks: [Bool] = []
    private var hits: [Int] = []

    // MARK: - Maintenance

    func removeAll() {
        boxMinX = []; boxMinY = []; boxMaxX = []; boxMaxY = []
        extent = []; hasBounds = []
        tree = nil; treeStorage = []; unbounded = []
        stale.removeAll()
        needsRebuild = true
        maxPaddingDevicePixels = 0
        invalidateCache()
    }

    /// Full resynchronisation after a topology change.
    func rebuild(markups: [CompiledMarkup]) {
        let count = markups.count
        boxMinX = [Double](repeating: 0, count: count)
        boxMinY = [Double](repeating: 0, count: count)
        boxMaxX = [Double](repeating: 0, count: count)
        boxMaxY = [Double](repeating: 0, count: count)
        extent = [Double](repeating: -1, count: count)
        hasBounds = [Bool](repeating: false, count: count)
        maxPaddingDevicePixels = 0
        for index in 0..<count {
            record(markups[index], at: index)
        }
        stale.removeAll()
        needsRebuild = true
        invalidateCache()
    }

    /// Patches the flat arrays for markups whose geometry changed in place.
    func update(markups: [CompiledMarkup], at indices: [Int]) {
        guard !indices.isEmpty else { return }
        guard markups.count == extent.count else {
            // The caller's storage and ours disagree; resynchronise rather than guess.
            rebuild(markups: markups)
            return
        }
        for index in indices where index >= 0 && index < markups.count {
            record(markups[index], at: index)
            stale.insert(index)
        }
        if stale.count > Self.staleRebuildThreshold { needsRebuild = true }
        invalidateCache()
    }

    private func record(_ markup: CompiledMarkup, at index: Int) {
        maxPaddingDevicePixels = Swift.max(maxPaddingDevicePixels, markup.paddingDevicePixels)
        guard let bounds = markup.bounds, bounds.isFinite else {
            hasBounds[index] = false
            extent[index] = -1
            return
        }
        let pad = Swift.max(0, markup.paddingPagePoints)
        boxMinX[index] = bounds.minX - pad
        boxMinY[index] = bounds.minY - pad
        boxMaxX[index] = bounds.maxX + pad
        boxMaxY[index] = bounds.maxY + pad
        hasBounds[index] = true
        // Text is exempt from the sub-pixel cutoff: its ink is pixel-sized and does not
        // shrink with zoom, so a geometric extent test would drop legible labels.
        //
        // Everything else is measured by its **ink**, not its centreline: the stroke width is
        // part of what is painted. A 0.4 pt line stroked 8 pt wide with round caps — a drawn
        // dot — used to measure 0.4 and vanish below 125 % although its ink is 8 pt across
        // (BH-621). `pad` is the full width, which is the extent a stroke adds across its
        // centreline.
        extent[index] = markup.glyphs.isEmpty
            ? Swift.max(bounds.width, bounds.height) + pad
            : .infinity
    }

    private func rebuildTreeIfNeeded() {
        guard needsRebuild else { return }
        needsRebuild = false
        stale.removeAll()
        treeStorage.removeAll(keepingCapacity: true)
        unbounded.removeAll(keepingCapacity: true)
        var boxes: [PDFRect] = []
        boxes.reserveCapacity(extent.count)
        for index in 0..<extent.count {
            if hasBounds[index] {
                treeStorage.append(index)
                boxes.append(PDFRect(
                    corner: PDFPoint(x: boxMinX[index], y: boxMinY[index]),
                    opposite: PDFPoint(x: boxMaxX[index], y: boxMaxY[index])
                ))
            } else {
                unbounded.append(index)
            }
        }
        // Bounds were validated finite when the markups compiled, so this cannot throw for
        // them; if it ever does, the honest degradation is "no culling", not a crash.
        tree = try? PackedRTree(boxes: boxes)
        if tree == nil && !boxes.isEmpty {
            treeStorage.removeAll()
            unbounded = Array(0..<extent.count)
        }
    }

    // MARK: - Hit-test candidates

    /// Storage indices whose painted ink could lie within `tolerance` page points of `point`,
    /// topmost first (descending storage index, which is reverse painter order), or `nil` when
    /// the index is out of step with the store and the caller must scan linearly.
    ///
    /// The same superset argument as ``visibility(markups:transform:policy:)``: the tree's boxes
    /// hold every page-sized part of the ink, and the query is grown by the scene's largest
    /// pixel-sized allowance at this zoom, so a markup the query misses cannot be hit. Stale and
    /// unbounded markups are always candidates (IM-083).
    func hitCandidates(
        markupCount: Int,
        point: PDFPoint,
        tolerance: Double,
        pixelsPerPagePoint ppp: Double
    ) -> [Int]? {
        guard markupCount == extent.count, ppp > 0, ppp.isFinite, point.isFinite,
              tolerance.isFinite
        else { return nil }
        rebuildTreeIfNeeded()
        let allowance = Swift.max(0, tolerance) + (maxPaddingDevicePixels + Self.pixelSlack) / ppp
        let query = PDFRect(
            corner: PDFPoint(x: point.x - allowance, y: point.y - allowance),
            opposite: PDFPoint(x: point.x + allowance, y: point.y + allowance)
        )
        var found: [Int] = []
        if let tree {
            var treeHits: [Int] = []
            tree.query(query, into: &treeHits)
            found.reserveCapacity(treeHits.count + unbounded.count + stale.count)
            for hit in treeHits where hit < treeStorage.count { found.append(treeStorage[hit]) }
        }
        found.append(contentsOf: unbounded)
        found.append(contentsOf: stale)
        found.sort(by: >)
        var unique: [Int] = []
        unique.reserveCapacity(found.count)
        for index in found where index < markupCount && unique.last != index {
            unique.append(index)
        }
        return unique
    }

    private func invalidateCache() {
        cachedQueryRect = nil
        cachedVisibility = nil
        cachedPixelsPerPagePoint = .nan
    }

    // MARK: - The per-frame decision

    func visibility(
        markups: [CompiledMarkup],
        transform: RenderTransform,
        policy: CullingPolicy
    ) -> SceneVisibility {
        guard policy.isEnabled, !markups.isEmpty, markups.count == extent.count else {
            return .everything
        }
        let ppp = transform.pixelsPerPagePoint
        guard ppp > 0, ppp.isFinite else { return .everything }

        // The drawable in page space, derived from the transform — never from the caller's
        // advisory `visiblePageRect`, because correctness is at stake here.
        let size = transform.viewport.pixelSize
        let corners = [
            transform.pagePoint(from: PixelPoint(x: 0, y: 0)),
            transform.pagePoint(from: PixelPoint(x: Double(size.width), y: 0)),
            transform.pagePoint(from: PixelPoint(x: 0, y: Double(size.height))),
            transform.pagePoint(from: PixelPoint(x: Double(size.width), y: Double(size.height)))
        ]
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for corner in corners {
            guard corner.x.isFinite, corner.y.isFinite else { return .everything }
            minX = Swift.min(minX, corner.x); maxX = Swift.max(maxX, corner.x)
            minY = Swift.min(minY, corner.y); maxY = Swift.max(maxY, corner.y)
        }
        // Pixel-sized ink — stroke floors, feathering, glyph quads — expressed in page points
        // at this zoom. Everything page-sized is already inside the tree's boxes.
        let pixelAllowance = (maxPaddingDevicePixels + Self.pixelSlack) / ppp
        let required = PDFRect(
            corner: PDFPoint(x: minX - pixelAllowance, y: minY - pixelAllowance),
            opposite: PDFPoint(x: maxX + pixelAllowance, y: maxY + pixelAllowance)
        )

        if let cached = cachedVisibility,
           let cachedRect = cachedQueryRect,
           cachedPixelsPerPagePoint == ppp,
           cachedPolicy == policy,
           cachedRect.contains(required) {
            return cached
        }

        rebuildTreeIfNeeded()

        let band = policy.marginDevicePixels / ppp
        let query = required.insetBy(band)

        if marks.count != markups.count {
            marks = [Bool](repeating: false, count: markups.count)
        } else {
            for index in marks.indices { marks[index] = false }
        }
        hits.removeAll(keepingCapacity: true)
        if let tree {
            tree.query(query, into: &hits)
            for hit in hits { marks[treeStorage[hit]] = true }
        }
        for index in unbounded { marks[index] = true }
        for index in stale where index < marks.count { marks[index] = true }

        let cutoff = Swift.max(0, policy.subPixelCutoffDevicePixels)
        var visible: [Int] = []
        visible.reserveCapacity(markups.count)
        var culled = 0
        var subPixel = 0
        for index in 0..<markups.count {
            guard marks[index] else {
                culled += 1
                continue
            }
            if cutoff > 0, hasBounds[index], extent[index] * ppp < cutoff {
                subPixel += 1
                continue
            }
            visible.append(index)
        }

        version &+= 1
        let result: SceneVisibility
        if culled == 0 && subPixel == 0 {
            result = SceneVisibility(
                visibleIndices: nil,
                culledMarkupCount: 0,
                subPixelMarkupCount: 0,
                version: version
            )
        } else {
            result = SceneVisibility(
                visibleIndices: visible,
                culledMarkupCount: culled,
                subPixelMarkupCount: subPixel,
                version: version
            )
        }
        cachedQueryRect = query
        cachedPixelsPerPagePoint = ppp
        cachedPolicy = policy
        cachedVisibility = result
        return result
    }
}
