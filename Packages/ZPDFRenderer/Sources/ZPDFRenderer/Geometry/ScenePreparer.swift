import Foundation
import ZPDFContracts

/// The compiled scene, held by reference.
///
/// A class, not an array in a struct, and the reason is measurable. `PreparedScene` outlives the
/// call that produced it — the renderer keeps it for hit testing — so if it held the array by
/// value, the next frame's in-place update of one element would see a reference count of two and
/// copy all hundred thousand `CompiledMarkup` values before writing. That copy alone cost more
/// than the entire frame budget.
public final class CompiledMarkupStore {
    /// Painter order: back to front, `(zIndex, id)` ascending, which is a total order.
    public internal(set) var markups: [CompiledMarkup] = []

    init() {}
}

/// One frame's worth of scene, compiled and ordered, ready for either backend.
public struct PreparedScene {
    public let store: CompiledMarkupStore
    /// Painter-ordered compiled markups. Reading this is free; it is the store's own array.
    public var markups: [CompiledMarkup] { store.markups }
    /// Page-space bounds by markup, for the overlay and the hit tester.
    public var bounds: [MarkupID: PDFRect]
    public var overlay: OverlayBuilder.Overlay
    public var transform: RenderTransform
    public var statistics: RenderStatistics
    /// Which markups this frame submits, decided once here for both backends, so viewport
    /// culling and the sub-pixel cutoff can never make the oracle and the GPU disagree.
    public var visibility: SceneVisibility
    /// Indices into ``markups`` whose instances changed this frame.
    public var changedIndices: [Int]
    /// True when markups were added, removed or reordered, so a backend cannot rely on
    /// ``changedIndices`` alone and must resynchronise its slot map.
    public var topologyChanged: Bool

    init(
        store: CompiledMarkupStore,
        bounds: [MarkupID: PDFRect],
        overlay: OverlayBuilder.Overlay,
        transform: RenderTransform,
        statistics: RenderStatistics,
        visibility: SceneVisibility,
        changedIndices: [Int],
        topologyChanged: Bool
    ) {
        self.store = store
        self.bounds = bounds
        self.overlay = overlay
        self.transform = transform
        self.statistics = statistics
        self.visibility = visibility
        self.changedIndices = changedIndices
        self.topologyChanged = topologyChanged
    }
}

/// Compiles a markup list into instances, and — the part that decides whether the renderer makes
/// 60 fps — works out how little of that it can get away with doing.
///
/// # The diff, and why it is positional
///
/// A frame hands over the whole markup array. Finding out what changed by looking each markup up
/// in a dictionary costs a `UUID` hash per markup; at a hundred thousand markups, sixty times a
/// second, that alone is most of a frame. So the preparer keeps the previous frame's
/// `(id, revision, zIndex, hidden)` in a flat array and compares **positionally**: sixteen bytes
/// and two integers per markup, no hashing, no allocation, and a branch that is almost never
/// taken.
///
/// That works because of how the caller behaves. An app that is panning hands over the identical
/// array; an app that is dragging one markup hands over a copy with one element mutated. In both
/// cases the positions line up and the scan finds either nothing or one changed index. Only when
/// a markup is added, removed or reordered do the positions stop lining up, and only then does
/// the preparer fall back to the full dictionary-based rebuild — which is the right trade,
/// because adding a markup is a user action at human speed, not a per-frame event.
public final class ScenePreparer {

    public let glyphAtlases = GlyphAtlasCache()
    public let symbolAtlases = SymbolAtlasCache()
    public var overlayBuilder = OverlayBuilder()

    /// The culling behaviour every prepared frame uses. Settable so the golden suite can render
    /// the same viewport with and without culling and require the two rasters byte-identical.
    public var cullingPolicy = CullingPolicy.default

    private let culler = SceneCuller()

    private let store = CompiledMarkupStore()
    private var boundsByID: [MarkupID: PDFRect] = [:]

    /// The previous frame's markup identity, in caller order.
    private struct Key {
        var id: MarkupID
        var revision: UInt64
        var zIndex: Int
        var isHidden: Bool
        /// Text is pixel-sized and the measurement grammar's decorations are view-sized, so a
        /// zoom step invalidates those markups while leaving every other one alone.
        var isZoomDependent: Bool
    }
    private var previousKeys: [Key] = []
    /// Per caller index: whether that markup is currently counted as rejected, and whether its
    /// dash was truncated. Kept so the statistics describe the whole scene on every frame, not
    /// just the markups this frame happened to recompile (BH-626).
    private var rejectedByCaller: [Bool] = []
    private var truncatedByCaller: [Bool] = []
    private var rejectedTotal = 0
    private var truncatedTotal = 0
    /// Caller index to index in ``store``. Valid only while the topology is unchanged.
    private var storageIndexByCallerIndex: [Int] = []
    /// Device pixels per page point at the last compile, because glyph quads are pixel sized.
    private var compiledPixelsPerPagePoint: Double = .nan
    /// Page points per view point at the last compile, because the measurement grammar's
    /// decorations are view sized.
    private var compiledPagePointsPerViewPoint: Double = .nan
    /// Bumped every time the compile scale changes. Folded into the **compiled** revision of
    /// zoom-dependent markups, because their instances change with zoom even when the producer's
    /// revision does not — and a downstream slot cache that skips writes on an unchanged
    /// `(id, revision, count)`, which is exactly what `InstanceArena` does, would otherwise keep
    /// the previous zoom's geometry. The producer's own revision is never touched; the fold is
    /// `revision &+ (generation << 32)`, which cannot repeat for one markup because the
    /// generation is monotonic and producers bump revisions by one, not by 2³².
    private var scaleGeneration: UInt64 = 0

    /// The sign pattern of the pixel-to-page map's linear part — which way the page is turned
    /// and flipped — at the last compile.
    private struct Orientation: Equatable {
        var a: Int, b: Int, c: Int, d: Int
        init(_ affine: RenderTransform.Affine) {
            func sign(_ value: Double) -> Int { value > 1e-12 ? 1 : (value < -1e-12 ? -1 : 0) }
            a = sign(affine.a); b = sign(affine.b); c = sign(affine.c); d = sign(affine.d)
        }
        init() { a = 2; b = 2; c = 2; d = 2 }
    }
    private var compiledOrientation = Orientation()

    /// Markups recompiled during the last prepare.
    public private(set) var recompiledCount = 0

    /// Running instance totals, maintained as markups are compiled.
    ///
    /// Summing them by walking the compiled array every frame is the obvious way to write this
    /// and it costs about eight milliseconds at a hundred thousand markups — the loop copies each
    /// `CompiledMarkup`, which retains and releases its four instance arrays. That is half a
    /// frame budget spent producing a diagnostic counter.
    private var totals = InstanceTotals()

    private struct InstanceTotals {
        var segments = 0
        var triangles = 0
        var symbols = 0
        var glyphs = 0
        var bytes = 0

        mutating func add(_ markup: CompiledMarkup) {
            segments += markup.segments.count
            triangles += markup.triangles.count
            symbols += markup.symbols.count
            glyphs += markup.glyphs.count
            bytes += markup.instanceByteCount
        }

        mutating func subtract(_ markup: CompiledMarkup) {
            segments -= markup.segments.count
            triangles -= markup.triangles.count
            symbols -= markup.symbols.count
            glyphs -= markup.glyphs.count
            bytes -= markup.instanceByteCount
        }

        mutating func reset() { self = InstanceTotals() }
    }

    public init() {}

    public func prepare(
        page: PageDescriptor,
        markups: [RenderableMarkup],
        selection: SelectionSnapshot,
        snapFeedback: RenderSnapFeedback?,
        viewport: RenderViewport
    ) throws -> PreparedScene {
        let transform = try RenderTransform(page: page, viewport: viewport)
        let pixelsPerPagePoint = transform.pixelsPerPagePoint
        let pagePointsPerViewPoint = transform.pagePoints(fromViewPoints: 1)
        let compiler = MarkupCompiler(
            glyphAtlases: glyphAtlases,
            pixelsPerPagePoint: pixelsPerPagePoint,
            pagePointsPerViewPoint: pagePointsPerViewPoint,
            pixelToPage: transform.pixelToPage
        )
        let orientation = Orientation(transform.pixelToPage)

        // Text instances are pixel sized and the measurement grammar's decorations are view
        // sized, so a zoom step invalidates those markups while leaving every other one alone.
        // A turn of the page does too: a label's page-space bounds are its pixel box mapped
        // through the frame's rotation.
        let scaleChanged = compiledPixelsPerPagePoint != pixelsPerPagePoint
            || compiledPagePointsPerViewPoint != pagePointsPerViewPoint
            || compiledOrientation != orientation
        if scaleChanged { scaleGeneration &+= 1 }
        var changedIndices: [Int] = []
        var topologyChanged = false

        if previousKeys.count != markups.count {
            topologyChanged = true
        } else {
            for index in markups.indices {
                let previous = previousKeys[index]
                let current = markups[index]
                if previous.id != current.id || previous.zIndex != current.zIndex {
                    topologyChanged = true
                    break
                }
                if previous.revision != current.revision
                    || previous.isHidden != current.isHidden
                    || (scaleChanged && previous.isZoomDependent) {
                    changedIndices.append(index)
                }
            }
        }

        if topologyChanged {
            rebuildAll(markups, compiler: compiler)
            changedIndices = Array(store.markups.indices)
            culler.rebuild(markups: store.markups)
        } else if !changedIndices.isEmpty {
            let needsRebuild = updateChanged(changedIndices, markups, compiler: compiler, into: &changedIndices)
            if needsRebuild {
                // A markup that was hidden or rejected during the last rebuild has no storage
                // slot; now that it compiles it must get one immediately, by a full rebuild —
                // not stay invisible until some unrelated add/remove happens to rebuild (CR-73).
                rebuildAll(markups, compiler: compiler)
                changedIndices = Array(store.markups.indices)
                culler.rebuild(markups: store.markups)
                topologyChanged = true
            } else {
                culler.update(markups: store.markups, at: changedIndices)
            }
        }
        compiledPixelsPerPagePoint = pixelsPerPagePoint
        compiledPagePointsPerViewPoint = pagePointsPerViewPoint
        compiledOrientation = orientation
        // Atlases created during this compile could not evict the ones the previous frame's
        // markups still pinned; now that the store holds this frame's references, return the
        // cache to its bound over the atlases nothing points into any more.
        glyphAtlases.trim()
        recompiledCount = topologyChanged ? store.markups.count : changedIndices.count

        let overlay = overlayBuilder.build(
            selection: selection,
            snapFeedback: snapFeedback,
            bounds: boundsByID,
            transform: transform
        )

        let visibility = culler.visibility(
            markups: store.markups,
            transform: transform,
            policy: cullingPolicy
        )

        var statistics = RenderStatistics()
        statistics.markupCount = store.markups.count
        statistics.rejectedMarkupCount = rejectedTotal
        statistics.truncatedDashCount = truncatedTotal
        statistics.lineInstanceCount = totals.segments + overlay.segments.count
        statistics.triangleCount = totals.triangles
        statistics.symbolInstanceCount = totals.symbols + overlay.symbols.count
        statistics.glyphInstanceCount = totals.glyphs
        statistics.culledMarkupCount = visibility.culledMarkupCount
        statistics.subPixelMarkupCount = visibility.subPixelMarkupCount

        return PreparedScene(
            store: store,
            bounds: boundsByID,
            overlay: overlay,
            transform: transform,
            statistics: statistics,
            visibility: visibility,
            changedIndices: changedIndices,
            topologyChanged: topologyChanged
        )
    }

    // MARK: - Rebuild paths

    /// The slow path: recompile everything, re-sort, rebuild the index and the bounds map.
    private func rebuildAll(_ markups: [RenderableMarkup], compiler: MarkupCompiler) {
        var compiled: [CompiledMarkup] = []
        compiled.reserveCapacity(markups.count)
        var callerIndexOf: [Int] = []
        callerIndexOf.reserveCapacity(markups.count)
        rejectedByCaller = [Bool](repeating: false, count: markups.count)
        truncatedByCaller = [Bool](repeating: false, count: markups.count)
        rejectedTotal = 0
        truncatedTotal = 0

        // The whole scene is about to be re-pinned, so the previous frame's references go first
        // and each result is pinned the moment it compiles. Pinning only after the loop (as
        // before S-100) left every atlas created earlier in this pass unreferenced while later
        // markups compiled: the seventeenth distinct (font, bucket) evicted the first, and the
        // backend re-fetched a fresh, empty atlas for glyphs whose tiles pointed into the old
        // one — blank labels on every first frame, which is every raster snippet export.
        glyphAtlases.unpinAll()
        for (callerIndex, markup) in markups.enumerated() {
            guard var result = compiler.compile(markup) else {
                setFlags(at: callerIndex, rejected: !markup.isHidden, truncated: false)
                continue
            }
            pinGlyphAtlas(of: result)
            // A markup whose fill could not be triangulated is compiled (its stroke may draw) but
            // its dropped fill is counted as a rejection rather than lost silently (CR-80).
            setFlags(at: callerIndex, rejected: result.fillRejected, truncated: result.dashTruncated)
            result.revision = effectiveRevision(for: markup)
            compiled.append(result)
            callerIndexOf.append(callerIndex)
        }

        // Painter order, by a total key so the result never depends on the caller's array order.
        // The identifier comparison is on the UUID's raw bytes; formatting it as a string, which
        // is the obvious way to write this, allocates twice per comparison and cost more than the
        // whole frame budget at a hundred thousand markups.
        var order = Array(compiled.indices)
        order.sort { lhs, rhs in
            let left = compiled[lhs], right = compiled[rhs]
            if left.zIndex != right.zIndex { return left.zIndex < right.zIndex }
            return Self.isOrderedBefore(left.id, right.id)
        }

        var sorted: [CompiledMarkup] = []
        sorted.reserveCapacity(order.count)
        var indexByCaller = [Int](repeating: -1, count: markups.count)
        var bounds: [MarkupID: PDFRect] = [:]
        bounds.reserveCapacity(order.count)
        for (position, source) in order.enumerated() {
            sorted.append(compiled[source])
            indexByCaller[callerIndexOf[source]] = position
            if let box = compiled[source].bounds { bounds[compiled[source].id] = box }
        }

        // Totals only: every stored markup's atlas was pinned as it compiled, above.
        totals.reset()
        for markup in sorted { totals.add(markup) }
        store.markups = sorted
        boundsByID = bounds
        storageIndexByCallerIndex = indexByCaller
        previousKeys = markups.map { Self.key(for: $0) }
    }

    /// Updates one caller index's scene-wide rejection and truncation flags and the totals.
    private func setFlags(at callerIndex: Int, rejected: Bool, truncated: Bool) {
        guard callerIndex >= 0, callerIndex < rejectedByCaller.count else { return }
        if rejectedByCaller[callerIndex] != rejected {
            rejectedTotal += rejected ? 1 : -1
            rejectedByCaller[callerIndex] = rejected
        }
        if truncatedByCaller[callerIndex] != truncated {
            truncatedTotal += truncated ? 1 : -1
            truncatedByCaller[callerIndex] = truncated
        }
    }

    /// The fast path: recompile only the markups whose revision moved, in place.
    ///
    /// Returns whether a full rebuild is required — when a markup that had no storage slot (it
    /// was hidden or rejected at the last rebuild) now compiles and so needs one (CR-73). The
    /// scene-wide rejection and truncation counts are kept up to date as it goes.
    private func updateChanged(
        _ callerIndices: [Int],
        _ markups: [RenderableMarkup],
        compiler: MarkupCompiler,
        into storageIndices: inout [Int]
    ) -> Bool {
        var needsRebuild = false
        var updated: [Int] = []
        updated.reserveCapacity(callerIndices.count)
        for callerIndex in callerIndices {
            let markup = markups[callerIndex]
            previousKeys[callerIndex] = Self.key(for: markup)
            let position = storageIndexByCallerIndex[callerIndex]
            guard position >= 0, position < store.markups.count else {
                // The markup has no slot (hidden or rejected at the last rebuild). If it now
                // compiles it needs one, so the layout must be rebuilt this frame — otherwise it
                // stays invisible until an unrelated topology change. If it still does not
                // compile, there is nothing to do.
                if compiler.compile(markup) != nil {
                    needsRebuild = true
                } else {
                    setFlags(at: callerIndex, rejected: !markup.isHidden, truncated: false)
                }
                continue
            }
            guard var result = compiler.compile(markup) else {
                setFlags(at: callerIndex, rejected: !markup.isHidden, truncated: false)
                // Keep the slot but empty it, so the index stays valid until a full rebuild.
                account(removing: store.markups[position])
                store.markups[position].segments = []
                store.markups[position].triangles = []
                store.markups[position].symbols = []
                store.markups[position].glyphs = []
                store.markups[position].revision = effectiveRevision(for: markup)
                account(adding: store.markups[position])
                boundsByID.removeValue(forKey: markup.id)
                updated.append(position)
                continue
            }
            setFlags(at: callerIndex, rejected: result.fillRejected, truncated: result.dashTruncated)
            result.revision = effectiveRevision(for: markup)
            account(removing: store.markups[position])
            account(adding: result)
            store.markups[position] = result
            if let box = result.bounds { boundsByID[result.id] = box }
            updated.append(position)
        }
        storageIndices = updated
        return needsRebuild
    }

    /// Adds a compiled markup to the running totals and pins the glyph atlas its quads point
    /// into, so the cache can never evict an atlas a stored markup still samples (BH-031).
    private func account(adding markup: CompiledMarkup) {
        totals.add(markup)
        pinGlyphAtlas(of: markup)
    }

    /// Pins the glyph atlas a compiled markup's quads point into, if it has any.
    private func pinGlyphAtlas(of markup: CompiledMarkup) {
        if !markup.glyphs.isEmpty, let font = markup.glyphFontName, let bucket = markup.glyphBucket {
            glyphAtlases.pin(fontName: font, bucket: bucket)
        }
    }

    /// The inverse of ``account(adding:)``.
    private func account(removing markup: CompiledMarkup) {
        totals.subtract(markup)
        if !markup.glyphs.isEmpty, let font = markup.glyphFontName, let bucket = markup.glyphBucket {
            glyphAtlases.unpin(fontName: font, bucket: bucket)
        }
    }

    /// The revision stamped onto the compiled result: the producer's own for zoom-independent
    /// shapes, and the producer's folded with ``scaleGeneration`` for zoom-dependent ones, so
    /// every downstream `(id, revision)` cache sees a change exactly when the instances may
    /// have changed. See ``scaleGeneration``.
    private func effectiveRevision(for markup: RenderableMarkup) -> UInt64 {
        markup.shape.isZoomDependent
            ? markup.revision &+ (scaleGeneration << 32)
            : markup.revision
    }

    private static func key(for markup: RenderableMarkup) -> Key {
        Key(
            id: markup.id,
            revision: markup.revision,
            zIndex: markup.zIndex,
            isHidden: markup.isHidden,
            isZoomDependent: markup.shape.isZoomDependent
        )
    }

    /// Byte-order comparison of two identifiers, allocation free.
    static func isOrderedBefore(_ lhs: MarkupID, _ rhs: MarkupID) -> Bool {
        let a = lhs.rawValue.uuid
        let b = rhs.rawValue.uuid
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        if a.4 != b.4 { return a.4 < b.4 }
        if a.5 != b.5 { return a.5 < b.5 }
        if a.6 != b.6 { return a.6 < b.6 }
        if a.7 != b.7 { return a.7 < b.7 }
        if a.8 != b.8 { return a.8 < b.8 }
        if a.9 != b.9 { return a.9 < b.9 }
        if a.10 != b.10 { return a.10 < b.10 }
        if a.11 != b.11 { return a.11 < b.11 }
        if a.12 != b.12 { return a.12 < b.12 }
        if a.13 != b.13 { return a.13 < b.13 }
        if a.14 != b.14 { return a.14 < b.14 }
        return a.15 < b.15
    }

    /// The storage indices of the last prepared scene that a hit test at `point` needs to look
    /// at, topmost first, or `nil` when the spatial index cannot answer and the caller should
    /// scan every markup. See ``SceneHitTester/hitTest(markups:candidates:overlay:transform:point:tolerance:)``.
    public func hitCandidates(point: PDFPoint, tolerance: Double, transform: RenderTransform) -> [Int]? {
        culler.hitCandidates(
            markupCount: store.markups.count,
            point: point,
            tolerance: tolerance,
            pixelsPerPagePoint: transform.pixelsPerPagePoint
        )
    }

    /// Bytes held by the CPU-side caches.
    public var residentByteCount: Int {
        totals.bytes + glyphAtlases.residentByteCount + symbolAtlases.residentByteCount
    }

    public func removeAll() {
        culler.removeAll()
        totals.reset()
        store.markups = []
        boundsByID.removeAll()
        previousKeys.removeAll()
        rejectedByCaller.removeAll()
        truncatedByCaller.removeAll()
        rejectedTotal = 0
        truncatedTotal = 0
        storageIndexByCallerIndex.removeAll()
        compiledPixelsPerPagePoint = .nan
        compiledPagePointsPerViewPoint = .nan
        compiledOrientation = Orientation()
        // The generation is deliberately NOT reset: a consumer may keep slots across a
        // `removeAll`, and a monotonic generation can never hand it a revision it has seen.
        glyphAtlases.removeAll()
        symbolAtlases.removeAll()
        recompiledCount = 0
    }
}
