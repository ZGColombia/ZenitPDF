import CoreGraphics
import Foundation
import Metal
import ZPDFContracts

/// The production markup renderer.
///
/// # Structure of a frame
///
/// ```text
/// update(page:markups:selection:snapFeedback:viewport:)
///   ├─ ScenePreparer           compile only the markups whose (id, revision) changed
///   ├─ geometry pass upload    upsert changed slots into persistent arenas
///   │     segments · triangles · symbols (per atlas bucket) · glyphs (per font and bucket)
///   └─ overlay pass upload     selection handles and snap glyph, rebuilt whole, ~50 instances
///
/// renderOffscreen() / encodeFrame()
///   ├─ pass 1, multisampled     polygon fills, resolved on the way out
///   └─ pass 2, one sample       strokes · symbols · glyphs · overlay, over the resolved target
/// ```
///
/// Four pipelines, one draw call per arena, and the cut between the passes falls between two
/// categories of an order the frame already had. ``RenderPassPolicy`` says why the frame is in two
/// pieces and what holds the split to producing the identical picture; ``encode(into:)`` is still
/// the whole frame in one encoder, for a caller that has only one attachment to give.
///
/// Nothing in the geometry pass depends on zoom, pan or selection. Those live in a 64-byte
/// uniform block, so panning a 100 000-markup page writes 64 bytes and hovering over a markup
/// writes the overlay's few hundred. That is the design requirement — "a single markup moving must
/// not re-upload the whole page", "hover feedback never forces a full rebuild" — expressed as
/// where the bytes are, rather than as a promise about how often a code path runs.
///
/// The one exception is stated where it happens: text glyph quads are sized in device pixels, so
/// crossing a glyph-atlas size bucket rebuilds the text markups. A pan never does; a zoom step
/// does. ``RenderStatistics/dirtySlotCount`` reports it honestly rather than hiding it.
public final class MetalMarkupRenderer: OffscreenMarkupRendering {

    public let backend: RendererBackend = .metal

    private let pipelines: MetalPipelines
    private let preparer = ScenePreparer()

    private var segments: InstanceArena<SegmentInstance>
    private var triangles: InstanceArena<TriangleVertex>
    private var symbolArenas: [Int: InstanceArena<SymbolInstance>] = [:]
    private var glyphArenas: [GlyphArenaKey: InstanceArena<GlyphInstance>] = [:]
    private var symbolBucketByMarkup: [MarkupID: Int] = [:]
    private var glyphKeyByMarkup: [MarkupID: GlyphArenaKey] = [:]

    private var symbolTextures: [Int: AtlasTexture] = [:]
    private var glyphTextures: [GlyphArenaKey: AtlasTexture] = [:]

    private var overlaySegmentBuffer: (any MTLBuffer)?
    private var overlaySegmentCount = 0
    private var overlaySymbolBuffers: [Int: (buffer: any MTLBuffer, count: Int)] = [:]

    private var uniforms = FrameUniforms()
    private var scene: PreparedScene?
    private var isDisposed = false
    private var lastStatistics = RenderStatistics.empty

    private var msaaTexture: (any MTLTexture)?
    private var resolveTexture: (any MTLTexture)?
    private var readbackBuffer: (any MTLBuffer)?
    private var targetSize = PixelSize(width: 0, height: 0)

    // MARK: Submission state (viewport culling)
    //
    // The arenas are persistent and untouched by a viewport change; what changes is which of
    // their slots a frame *submits*. Every instanced vertex shader reads its instance through
    // one level of indirection — `instances[visible[iid]]` — so a draw covers exactly the
    // instance indices in a submission list. With no culling the list is the identity, shared
    // by every pass, and rebuilt only when it must grow.

    /// One markup's slot spans across the four arenas, cached flat by storage index so that
    /// rebuilding submission lists never hashes a `MarkupID` on the per-frame path.
    private struct MarkupSpans {
        var segOffset: Int32 = -1, segCount: Int32 = 0
        var triOffset: Int32 = -1, triCount: Int32 = 0
        var symBucket: Int32 = -1, symOffset: Int32 = -1, symCount: Int32 = 0
        var glyphKey: Int32 = -1, glyphOffset: Int32 = -1, glyphCount: Int32 = 0
        /// The markup is a highlighter (``CompiledMarkup/multiplies``).
        var multiplies = false
    }
    private var spans: [MarkupSpans] = []
    /// How many entries of ``spans`` multiply. While it is above zero every pass draws through
    /// submission lists split into blend runs, because a multiplying markup's instances need
    /// the multiply pipelines and painter's order must survive the switch (K-07).
    private var multiplyingMarkupCount = 0
    private var glyphKeyTable: [GlyphArenaKey] = []
    private var glyphKeyIndex: [GlyphArenaKey: Int] = [:]

    /// A contiguous stretch of a submission list drawn with one blend: normal source-over, or
    /// multiply for a highlighter. `start` and `count` are in list entries.
    struct BlendRun: Equatable {
        var start: Int
        var count: Int
        var multiplies: Bool
    }

    /// A growable GPU list of `uint32` instance (or vertex) indices.
    private final class SubmissionList {
        private(set) var buffer: (any MTLBuffer)?
        private(set) var count = 0
        private var capacity = 0
        /// The list cut into same-blend runs, in list order. One run for a scene with no
        /// highlighter, so such a frame draws exactly as it did before blend runs existed.
        private(set) var runs: [BlendRun] = []

        func set(_ values: [UInt32], runs: [BlendRun]? = nil, device: any MTLDevice, label: String) {
            self.runs = runs ?? (values.isEmpty ? [] : [BlendRun(start: 0, count: values.count, multiplies: false)])
            count = values.count
            guard !values.isEmpty else { return }
            if buffer == nil || capacity < values.count {
                var target = Swift.max(capacity * 2, 1_024)
                while target < values.count { target *= 2 }
                guard let replacement = device.makeBuffer(
                    length: target * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                ) else {
                    count = 0
                    return
                }
                replacement.label = label
                buffer = replacement
                capacity = target
            }
            values.withUnsafeBytes { source in
                guard let base = source.baseAddress, let buffer else { return }
                memcpy(buffer.contents(), base, values.count * MemoryLayout<UInt32>.stride)
            }
        }

        func clear() { count = 0; runs = [] }
        var residentByteCount: Int { capacity * MemoryLayout<UInt32>.stride }
    }

    private let segmentSubmission = SubmissionList()
    private let triangleSubmission = SubmissionList()
    private var symbolSubmission: [Int: SubmissionList] = [:]
    private var glyphSubmission: [GlyphArenaKey: SubmissionList] = [:]
    /// The identity list `0, 1, 2, …`, used by every uncculled draw and by the overlay.
    private let identitySubmission = SubmissionList()
    private var identityCount = 0
    private var submitsSubset = false
    private var builtVisibilityVersion: UInt64 = .max

    private struct GlyphArenaKey: Hashable {
        let font: String
        let bucket: Int
    }

    private struct AtlasTexture {
        var texture: any MTLTexture
        /// The atlas object the texture was made from. Held strongly, so its identity cannot be
        /// reused by a later allocation, and compared by identity: a re-created atlas for the
        /// same key restarts its generation at zero and can climb back to the stored number with
        /// its glyphs packed in a different order (BH-201).
        var source: AnyObject
        var generation: UInt64
        var width: Int
        var height: Int
    }

    /// - Throws: ``RendererError`` when there is no device or the shaders will not compile.
    ///   Callers that want a guaranteed renderer use `MarkupRendererFactory` instead.
    public init(runtime: any MetalRuntimeProviding = DefaultMetalRuntime()) throws {
        let pipelines = try MetalPipelines(runtime: runtime)
        self.pipelines = pipelines
        self.segments = InstanceArena(
            device: pipelines.device,
            dead: .dead,
            label: "ZPDFRenderer.segments"
        )
        self.triangles = InstanceArena(
            device: pipelines.device,
            dead: .dead,
            label: "ZPDFRenderer.triangles"
        )
    }

    /// The GPU this renderer is bound to. Reported in the diagnostics panel.
    public var deviceName: String { pipelines.device.name }
    /// How many samples the fill pass uses: 8 where the device supports it, else 4, else 2, else 1.
    public var sampleCount: Int { pipelines.sampleCount }

    // MARK: - MarkupPageRendering

    public var statistics: RenderStatistics { lastStatistics }

    /// See ``CullingPolicy``. Forwarded to the preparer; the next `update` uses it.
    public var cullingPolicy: CullingPolicy {
        get { preparer.cullingPolicy }
        set { preparer.cullingPolicy = newValue }
    }

    /// See ``RenderPassPolicy``. Read when a frame is encoded, and by the uniform block, so a
    /// change takes effect on the next `update` and encode. The benchmark flips it between
    /// configurations in one process; nothing else in the product changes it.
    public var renderPassPolicy: RenderPassPolicy = .default {
        didSet {
            guard renderPassPolicy != oldValue else { return }
            uniforms.dashParameters.1 = Float(renderPassPolicy.segmentQuadPadPixels)
        }
    }

    public func update(
        page: PageDescriptor,
        markups: [RenderableMarkup],
        selection: SelectionSnapshot,
        snapFeedback: RenderSnapFeedback?,
        viewport: RenderViewport
    ) {
        guard !isDisposed else { return }
        let prepared: PreparedScene
        do {
            prepared = try preparer.prepare(
                page: page,
                markups: markups,
                selection: selection,
                snapFeedback: snapFeedback,
                viewport: viewport
            )
        } catch {
            RendererLog.logger.error(
                "scene preparation failed, keeping the previous frame: \(String(describing: error), privacy: .public)"
            )
            return
        }

        uniforms = Self.uniforms(
            for: prepared.transform,
            segmentQuadPad: renderPassPolicy.segmentQuadPadPixels
        )
        let rebucketed = uploadGeometry(prepared)
        uploadOverlay(prepared)
        refreshSubmission(prepared, rebucketed: rebucketed)

        var statistics = prepared.statistics
        statistics.dirtySlotCount = segments.frameDirtySlots + triangles.frameDirtySlots
            + symbolArenas.values.reduce(0) { $0 + $1.frameDirtySlots }
            + glyphArenas.values.reduce(0) { $0 + $1.frameDirtySlots }
        statistics.uploadedByteCount = segments.frameUploadedBytes + triangles.frameUploadedBytes
            + symbolArenas.values.reduce(0) { $0 + $1.frameUploadedBytes }
            + glyphArenas.values.reduce(0) { $0 + $1.frameUploadedBytes }
        statistics.residentByteCount = instanceResidentByteCount
        statistics.renderTargetByteCount = renderTargetByteCount
        lastStatistics = statistics
        scene = prepared
    }

    public func hitTest(pagePoint: CGPoint, toleranceInPagePoints: CGFloat) -> HitTestResult? {
        guard !isDisposed, let scene else { return nil }
        let point = PDFPoint(x: Double(pagePoint.x), y: Double(pagePoint.y))
        let tolerance = Double(toleranceInPagePoints)
        // The spatial index narrows the query to the markups near the point (IM-083).
        return SceneHitTester.hitTest(
            markups: scene.markups,
            candidates: preparer.hitCandidates(point: point, tolerance: tolerance, transform: scene.transform),
            overlay: scene.overlay,
            transform: scene.transform,
            point: point,
            tolerance: tolerance
        )
    }

    public func dispose() {
        isDisposed = true
        scene = nil
        segments.dispose()
        triangles.dispose()
        for arena in symbolArenas.values { arena.dispose() }
        for arena in glyphArenas.values { arena.dispose() }
        symbolArenas.removeAll()
        glyphArenas.removeAll()
        symbolTextures.removeAll()
        glyphTextures.removeAll()
        symbolBucketByMarkup.removeAll()
        glyphKeyByMarkup.removeAll()
        overlaySegmentBuffer = nil
        overlaySymbolBuffers.removeAll()
        spans.removeAll()
        multiplyingMarkupCount = 0
        glyphKeyTable.removeAll()
        glyphKeyIndex.removeAll()
        segmentSubmission.clear()
        triangleSubmission.clear()
        symbolSubmission.removeAll()
        glyphSubmission.removeAll()
        identitySubmission.clear()
        identityCount = 0
        submitsSubset = false
        builtVisibilityVersion = .max
        msaaTexture = nil
        resolveTexture = nil
        readbackBuffer = nil
        preparer.removeAll()
        lastStatistics = .empty
    }

    /// Total bytes resident in GPU instance storage, atlas textures and render targets:
    /// ``instanceResidentByteCount`` plus ``renderTargetByteCount``.
    public var residentByteCount: Int {
        instanceResidentByteCount + renderTargetByteCount
    }

    /// Bytes held for the scene itself — instance arenas, atlas textures, overlay buffers and
    /// submission lists. This is what `RenderStatistics.residentByteCount` reports: it is
    /// documented as instance storage, and gate Z7's underlay clause (16 MiB per page) is a
    /// ceiling on exactly that. Folding the render targets into it — BH-631 did, for a
    /// while — turned a drawable-size cost into a per-page one and failed the gate at 22.8 MB
    /// for an underlay whose instance storage had not changed.
    public var instanceResidentByteCount: Int {
        var total = segments.residentByteCount + triangles.residentByteCount
        for arena in symbolArenas.values { total += arena.residentByteCount }
        for arena in glyphArenas.values { total += arena.residentByteCount }
        for texture in symbolTextures.values { total += texture.width * texture.height }
        for texture in glyphTextures.values { total += texture.width * texture.height }
        total += (overlaySegmentBuffer?.length ?? 0)
        for entry in overlaySymbolBuffers.values { total += entry.buffer.length }
        total += segmentSubmission.residentByteCount + triangleSubmission.residentByteCount
        total += identitySubmission.residentByteCount
        for list in symbolSubmission.values { total += list.residentByteCount }
        for list in glyphSubmission.values { total += list.residentByteCount }
        return total
    }

    /// Bytes held by the render targets: the resolve texture, the multisample texture and the
    /// readback buffer, at their allocated capacity. The documentation always claimed these and
    /// the sum left them out (BH-631); they are reported here and in
    /// `RenderStatistics.renderTargetByteCount`, beside the instance figure rather than inside
    /// it. A memoryless multisample target reports what it actually occupies, which is nothing,
    /// so eight samples on an Apple-family GPU add no bytes here.
    public var renderTargetByteCount: Int {
        (resolveTexture?.allocatedSize ?? 0)
            + (msaaTexture?.allocatedSize ?? 0)
            + (readbackBuffer?.length ?? 0)
    }

    // MARK: - Geometry upload

    /// Uploads this frame's geometry and returns the storage indices whose symbol instances
    /// moved to a different atlas bucket without their markup changing (see
    /// ``rebucketSymbols(_:)``), so the submission lists can pick the new slots up.
    private func uploadGeometry(_ prepared: PreparedScene) -> [Int] {
        // Three cases, and the difference between them is the difference between 60 fps and 8.
        //
        // - Nothing changed: a pan, a hover, a zoom that did not cross a glyph size bucket. Not
        //   one byte of geometry is written and not one slot map is walked.
        // - Some markups changed: a drag, an edit. Only those slots are rewritten, and the arenas
        //   run in targeted mode so they do not walk their slot maps looking for removals.
        // - The topology changed: a markup was added, removed or reordered. Full sweep.
        let symbolScale = SymbolScale(prepared.transform)
        let scaleChanged = symbolScale != uploadedSymbolScale
        uploadedSymbolScale = symbolScale
        if prepared.topologyChanged {
            uploadAllSlots(prepared)
            return []
        }
        beginTargetedFrames()
        for index in prepared.changedIndices where index < prepared.markups.count {
            upload(prepared.markups[index], transform: prepared.transform)
        }
        let rebucketed = scaleChanged ? rebucketSymbols(prepared) : []
        endFrames()
        return rebucketed
    }

    /// The two numbers a symbol's device size depends on. A change in either can move a count
    /// marker to a different atlas bucket.
    private struct SymbolScale: Equatable {
        var pixelsPerPagePoint: Double
        var pixelsPerViewPoint: Double

        init(_ transform: RenderTransform) {
            pixelsPerPagePoint = transform.pixelsPerPagePoint
            pixelsPerViewPoint = transform.devicePixels(fromViewPoints: 1)
        }

        init(pixelsPerPagePoint: Double, pixelsPerViewPoint: Double) {
            self.pixelsPerPagePoint = pixelsPerPagePoint
            self.pixelsPerViewPoint = pixelsPerViewPoint
        }
    }
    private var uploadedSymbolScale = SymbolScale(pixelsPerPagePoint: .nan, pixelsPerViewPoint: .nan)

    /// Moves count markers whose size bucket changed with the zoom into the arena of their new
    /// bucket.
    ///
    /// A count symbol is not zoom-dependent to the preparer — its instances are in page points
    /// and do not change — so a pure zoom step recompiles nothing and `upload` never runs for
    /// it. But *which atlas* the marker samples does depend on zoom, and without this the marker
    /// kept its first zoom's 16-px tile stretched to 128 px while the Core Graphics oracle
    /// picked the 128-px atlas every frame (BH-199). Only markups that carry symbols are
    /// visited (their spans say so), and only those whose bucket actually moved are rewritten.
    private func rebucketSymbols(_ prepared: PreparedScene) -> [Int] {
        guard spans.count == prepared.markups.count else { return [] }
        let markups = prepared.markups
        var moved: [Int] = []
        for index in spans.indices where spans[index].symCount > 0 {
            let markup = markups[index]
            guard let first = markup.symbols.first,
                  let previous = symbolBucketByMarkup[markup.id]
            else { continue }
            let bucket = SymbolAtlas.bucket(
                forDeviceSize: symbolDevicePixels(first, transform: prepared.transform)
            )
            guard bucket != previous else { continue }
            uploadSymbols(markup, transform: prepared.transform)
            moved.append(index)
        }
        return moved
    }

    private func symbolDevicePixels(_ symbol: CompiledSymbol, transform: RenderTransform) -> Double {
        symbol.sizePagePoints > 0
            ? symbol.sizePagePoints * transform.pixelsPerPagePoint
            : transform.devicePixels(fromViewPoints: symbol.sizeViewPoints)
    }

    private func beginTargetedFrames() {
        segments.beginTargetedFrame()
        triangles.beginTargetedFrame()
        for arena in symbolArenas.values { arena.beginTargetedFrame() }
        for arena in glyphArenas.values { arena.beginTargetedFrame() }
    }

    private func endFrames() {
        segments.endFrame()
        triangles.endFrame()
        for arena in symbolArenas.values { arena.endFrame() }
        for arena in glyphArenas.values { arena.endFrame() }
    }

    private func uploadAllSlots(_ prepared: PreparedScene) {
        segments.beginFrame()
        triangles.beginFrame()
        for arena in symbolArenas.values { arena.beginFrame() }
        for arena in glyphArenas.values { arena.beginFrame() }
        for markup in prepared.markups {
            upload(markup, transform: prepared.transform)
        }
        endFrames()
        pruneRemovedMarkups(prepared)
    }

    /// Forgets the bucket and font key of every markup that is no longer in the scene.
    ///
    /// The arenas' sweep frees a removed markup's slots, but these two maps are only written by
    /// `upload`, which never runs for a markup that is gone — so every deleted count or label
    /// markup used to leave a permanent entry behind (BH-630). Topology frames are the only
    /// frames that can remove a markup, and they already walk every markup, so the pass costs
    /// one set build on a frame that is O(n) anyway.
    private func pruneRemovedMarkups(_ prepared: PreparedScene) {
        guard !symbolBucketByMarkup.isEmpty || !glyphKeyByMarkup.isEmpty else { return }
        var live = Set<MarkupID>(minimumCapacity: prepared.markups.count)
        for markup in prepared.markups { live.insert(markup.id) }
        if symbolBucketByMarkup.keys.contains(where: { !live.contains($0) }) {
            symbolBucketByMarkup = symbolBucketByMarkup.filter { live.contains($0.key) }
        }
        if glyphKeyByMarkup.keys.contains(where: { !live.contains($0) }) {
            glyphKeyByMarkup = glyphKeyByMarkup.filter { live.contains($0.key) }
        }
    }

    /// Markups the renderer still keeps a symbol bucket or glyph key for. For tests.
    var trackedAtlasMarkupCount: Int { symbolBucketByMarkup.count + glyphKeyByMarkup.count }

    private func upload(_ markup: CompiledMarkup, transform: RenderTransform) {
        if !markup.segments.isEmpty {
            segments.upsert(
                markup.id,
                revision: markup.revision,
                elements: markup.segments.map(Self.instance(from:))
            )
        } else {
            segments.release(markup.id)
        }

        if !markup.triangles.isEmpty {
            var vertices: [TriangleVertex] = []
            vertices.reserveCapacity(markup.triangles.count * 3)
            for triangle in markup.triangles {
                let color = packColor(triangle.color)
                vertices.append(TriangleVertex(
                    x: Float(triangle.a.x), y: Float(triangle.a.y), color: color
                ))
                vertices.append(TriangleVertex(
                    x: Float(triangle.b.x), y: Float(triangle.b.y), color: color
                ))
                vertices.append(TriangleVertex(
                    x: Float(triangle.c.x), y: Float(triangle.c.y), color: color
                ))
            }
            triangles.upsert(markup.id, revision: markup.revision, elements: vertices)
        } else {
            triangles.release(markup.id)
        }

        uploadSymbols(markup, transform: transform)

        if !markup.glyphs.isEmpty, let font = markup.glyphFontName, let bucket = markup.glyphBucket {
            let key = GlyphArenaKey(font: font, bucket: bucket)
            if let previous = glyphKeyByMarkup[markup.id], previous != key {
                glyphArenas[previous]?.release(markup.id)
            }
            glyphKeyByMarkup[markup.id] = key
            let atlas = preparer.glyphAtlases.atlas(fontName: font, deviceSize: Double(bucket))
            glyphArena(for: key).upsert(
                markup.id,
                revision: markup.revision,
                elements: markup.glyphs.map(Self.instance(from:))
            )
            refreshGlyphTexture(key: key, atlas: atlas)
        } else if let previous = glyphKeyByMarkup.removeValue(forKey: markup.id) {
            glyphArenas[previous]?.release(markup.id)
        }
    }

    private func uploadSymbols(_ markup: CompiledMarkup, transform: RenderTransform) {
        if let first = markup.symbols.first {
            let devicePixels = symbolDevicePixels(first, transform: transform)
            if let atlas = preparer.symbolAtlases.atlas(forDeviceSize: devicePixels) {
                let bucket = atlas.tileSize
                if let previous = symbolBucketByMarkup[markup.id], previous != bucket {
                    symbolArenas[previous]?.release(markup.id)
                }
                symbolBucketByMarkup[markup.id] = bucket
                symbolArena(for: bucket).upsert(
                    markup.id,
                    revision: markup.revision,
                    elements: markup.symbols.compactMap { Self.instance(from: $0, atlas: atlas) }
                )
                refreshSymbolTexture(bucket: bucket, atlas: atlas)
            }
        } else if let previous = symbolBucketByMarkup.removeValue(forKey: markup.id) {
            symbolArenas[previous]?.release(markup.id)
        }
    }

    private func symbolArena(for bucket: Int) -> InstanceArena<SymbolInstance> {
        if let existing = symbolArenas[bucket] { return existing }
        let created = InstanceArena<SymbolInstance>(
            device: pipelines.device,
            dead: .dead,
            label: "ZPDFRenderer.symbols.\(bucket)"
        )
        created.beginTargetedFrame()
        symbolArenas[bucket] = created
        return created
    }

    private func glyphArena(for key: GlyphArenaKey) -> InstanceArena<GlyphInstance> {
        if let existing = glyphArenas[key] { return existing }
        let created = InstanceArena<GlyphInstance>(
            device: pipelines.device,
            dead: .dead,
            label: "ZPDFRenderer.glyphs.\(key.font).\(key.bucket)"
        )
        created.beginTargetedFrame()
        glyphArenas[key] = created
        return created
    }

    // MARK: - Submission maintenance

    /// Brings the span cache and the submission lists up to date with this frame's uploads and
    /// visibility. Called once per `update`, after the arenas have settled (a topology frame
    /// may have compacted them, which moves slots).
    private func refreshSubmission(_ prepared: PreparedScene, rebucketed: [Int]) {
        if prepared.topologyChanged || spans.count != prepared.markups.count {
            rebuildSpans(prepared)
        } else {
            for index in prepared.changedIndices where index >= 0 && index < spans.count {
                refreshSpan(at: index, prepared)
            }
            for index in rebucketed where index >= 0 && index < spans.count {
                refreshSpan(at: index, prepared)
            }
        }

        let slotsChanged = prepared.topologyChanged || !prepared.changedIndices.isEmpty
            || !rebucketed.isEmpty
        let visibleIndices = prepared.visibility.visibleIndices
        // A highlighter needs the multiply pipelines for its own instances, and only the
        // submission lists can say where a markup's instances start and stop in painter's order,
        // so a scene holding one draws through them even when nothing is culled (K-07).
        if visibleIndices != nil || multiplyingMarkupCount > 0 {
            if !submitsSubset || slotsChanged
                || builtVisibilityVersion != prepared.visibility.version {
                rebuildSubmissionLists(visibleIndices ?? Array(spans.indices))
                submitsSubset = true
                builtVisibilityVersion = prepared.visibility.version
            }
        } else {
            submitsSubset = false
            builtVisibilityVersion = .max
        }

        // The identity list serves the overlay always, and every geometry pass when nothing is
        // culled. It only ever grows.
        var identityNeeded = overlaySegmentCount
        for entry in overlaySymbolBuffers.values {
            identityNeeded = Swift.max(identityNeeded, entry.count)
        }
        if !submitsSubset {
            identityNeeded = Swift.max(identityNeeded, segments.highWaterMark)
            for arena in symbolArenas.values {
                identityNeeded = Swift.max(identityNeeded, arena.highWaterMark)
            }
            for arena in glyphArenas.values {
                identityNeeded = Swift.max(identityNeeded, arena.highWaterMark)
            }
        }
        ensureIdentity(identityNeeded)
    }

    private func rebuildSpans(_ prepared: PreparedScene) {
        spans = [MarkupSpans](repeating: MarkupSpans(), count: prepared.markups.count)
        multiplyingMarkupCount = 0
        for index in prepared.markups.indices {
            refreshSpan(at: index, prepared)
        }
    }

    private func refreshSpan(at index: Int, _ prepared: PreparedScene) {
        let id = prepared.markups[index].id
        var span = MarkupSpans()
        span.multiplies = prepared.markups[index].multiplies
        if span.multiplies != spans[index].multiplies {
            multiplyingMarkupCount += span.multiplies ? 1 : -1
        }
        if let slot = segments.slotSpan(of: id) {
            span.segOffset = Int32(slot.offset)
            span.segCount = Int32(slot.count)
        }
        if let slot = triangles.slotSpan(of: id) {
            span.triOffset = Int32(slot.offset)
            span.triCount = Int32(slot.count)
        }
        if let bucket = symbolBucketByMarkup[id], let slot = symbolArenas[bucket]?.slotSpan(of: id) {
            span.symBucket = Int32(bucket)
            span.symOffset = Int32(slot.offset)
            span.symCount = Int32(slot.count)
        }
        if let key = glyphKeyByMarkup[id], let slot = glyphArenas[key]?.slotSpan(of: id) {
            span.glyphKey = Int32(submissionKeyIndex(of: key))
            span.glyphOffset = Int32(slot.offset)
            span.glyphCount = Int32(slot.count)
        }
        spans[index] = span
    }

    private func submissionKeyIndex(of key: GlyphArenaKey) -> Int {
        if let existing = glyphKeyIndex[key] { return existing }
        glyphKeyTable.append(key)
        glyphKeyIndex[key] = glyphKeyTable.count - 1
        return glyphKeyTable.count - 1
    }

    /// One pass's list under construction: the indices and their same-blend runs.
    private struct PendingList {
        var values: [UInt32] = []
        var runs: [BlendRun] = []

        mutating func append(offset: Int32, count: Int32, multiplies: Bool) {
            let start = UInt32(truncatingIfNeeded: offset)
            let added = Int(count)
            if var last = runs.last, last.multiplies == multiplies {
                last.count += added
                runs[runs.count - 1] = last
            } else {
                runs.append(BlendRun(start: values.count, count: added, multiplies: multiplies))
            }
            for element in 0..<UInt32(truncatingIfNeeded: count) {
                values.append(start &+ element)
            }
        }
    }

    /// Concatenates the visible markups' slot spans into one `uint32` list per pass. Painter
    /// order is preserved because `visible` is ascending storage order and each span is
    /// appended whole; each list also records where its highlighter runs begin and end.
    private func rebuildSubmissionLists(_ visible: [Int]) {
        var seg = PendingList()
        var tri = PendingList()
        var sym: [Int: PendingList] = [:]
        var gly: [Int: PendingList] = [:]
        for index in visible {
            guard index >= 0, index < spans.count else { continue }
            let span = spans[index]
            if span.segCount > 0 {
                seg.append(offset: span.segOffset, count: span.segCount, multiplies: span.multiplies)
            }
            if span.triCount > 0 {
                tri.append(offset: span.triOffset, count: span.triCount, multiplies: span.multiplies)
            }
            if span.symCount > 0 {
                sym[Int(span.symBucket), default: PendingList()].append(
                    offset: span.symOffset,
                    count: span.symCount,
                    multiplies: span.multiplies
                )
            }
            if span.glyphCount > 0 {
                gly[Int(span.glyphKey), default: PendingList()].append(
                    offset: span.glyphOffset,
                    count: span.glyphCount,
                    multiplies: span.multiplies
                )
            }
        }
        let device = pipelines.device
        segmentSubmission.set(seg.values, runs: seg.runs, device: device, label: "ZPDFRenderer.submit.segments")
        triangleSubmission.set(tri.values, runs: tri.runs, device: device, label: "ZPDFRenderer.submit.triangles")
        for (bucket, list) in symbolSubmission where sym[bucket] == nil { list.clear() }
        for (bucket, pending) in sym {
            let list = symbolSubmission[bucket] ?? {
                let created = SubmissionList()
                symbolSubmission[bucket] = created
                return created
            }()
            list.set(pending.values, runs: pending.runs, device: device, label: "ZPDFRenderer.submit.symbols.\(bucket)")
        }
        var glyByKey: [GlyphArenaKey: PendingList] = [:]
        for (keyIndex, pending) in gly where keyIndex >= 0 && keyIndex < glyphKeyTable.count {
            glyByKey[glyphKeyTable[keyIndex]] = pending
        }
        for (key, list) in glyphSubmission where glyByKey[key] == nil { list.clear() }
        for (key, pending) in glyByKey {
            let list = glyphSubmission[key] ?? {
                let created = SubmissionList()
                glyphSubmission[key] = created
                return created
            }()
            list.set(pending.values, runs: pending.runs, device: device, label: "ZPDFRenderer.submit.glyphs")
        }
    }

    private func ensureIdentity(_ needed: Int) {
        guard needed > identityCount || identitySubmission.buffer == nil else { return }
        let target = Swift.max(needed, 1_024)
        identitySubmission.set(
            (0..<UInt32(target)).map { $0 },
            device: pipelines.device,
            label: "ZPDFRenderer.submit.identity"
        )
        identityCount = target
    }

    // MARK: - Overlay upload

    /// The overlay is rebuilt whole, every frame, on purpose: it is tens of instances, and
    /// rebuilding it is cheaper than diffing it — and, more importantly, it means a hover can
    /// never mark a geometry buffer dirty.
    private func uploadOverlay(_ prepared: PreparedScene) {
        let overlay = prepared.overlay
        overlaySegmentCount = overlay.segments.count
        if overlay.segments.isEmpty {
            overlaySegmentBuffer = nil
        } else {
            let instances = overlay.segments.map(Self.instance(from:))
            overlaySegmentBuffer = makeBuffer(instances, label: "ZPDFRenderer.overlay.segments")
        }

        overlaySymbolBuffers.removeAll(keepingCapacity: true)
        guard !overlay.symbols.isEmpty else { return }
        let transform = prepared.transform
        var byBucket: [Int: [SymbolInstance]] = [:]
        for symbol in overlay.symbols {
            let devicePixels = symbol.sizePagePoints > 0
                ? symbol.sizePagePoints * transform.pixelsPerPagePoint
                : transform.devicePixels(fromViewPoints: symbol.sizeViewPoints)
            guard let atlas = preparer.symbolAtlases.atlas(forDeviceSize: devicePixels),
                  let instance = Self.instance(from: symbol, atlas: atlas)
            else { continue }
            byBucket[atlas.tileSize, default: []].append(instance)
            refreshSymbolTexture(bucket: atlas.tileSize, atlas: atlas)
        }
        for (bucket, instances) in byBucket {
            guard let buffer = makeBuffer(instances, label: "ZPDFRenderer.overlay.symbols.\(bucket)")
            else { continue }
            overlaySymbolBuffers[bucket] = (buffer, instances.count)
        }
    }

    private func makeBuffer<Element>(_ elements: [Element], label: String) -> (any MTLBuffer)? {
        guard !elements.isEmpty else { return nil }
        let byteCount = elements.count * MemoryLayout<Element>.stride
        guard let buffer = pipelines.device.makeBuffer(length: byteCount, options: .storageModeShared)
        else { return nil }
        buffer.label = label
        elements.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            memcpy(buffer.contents(), base, byteCount)
        }
        return buffer
    }

    // MARK: - Instance conversion

    private static func instance(from segment: CompiledSegment) -> SegmentInstance {
        var flags = UInt32(segment.startCap.rawValue) | (UInt32(segment.endCap.rawValue) << 2)
        let runs = segment.dash.runArray
        flags |= UInt32(runs.count) << 4
        return SegmentInstance(
            dashRuns: (
                Float(runs.count > 0 ? runs[0] : 0),
                Float(runs.count > 1 ? runs[1] : 0),
                Float(runs.count > 2 ? runs[2] : 0),
                Float(runs.count > 3 ? runs[3] : 0)
            ),
            p0x: Float(segment.start.x), p0y: Float(segment.start.y),
            p1x: Float(segment.end.x), p1y: Float(segment.end.y),
            width: Float(segment.widthPagePoints),
            dashOffset: Float(segment.dashOffsetPagePoints + segment.dash.phase),
            color: packColor(segment.color),
            flags: flags
        )
    }

    private static func instance(from symbol: CompiledSymbol, atlas: SymbolAtlas) -> SymbolInstance? {
        guard let tile = atlas.tile(for: symbol.symbol) else { return nil }
        let uv = tile.texelUV
        return SymbolInstance(
            uv: (Float(uv.0), Float(uv.1), Float(uv.2), Float(uv.3)),
            centerX: Float(symbol.center.x),
            centerY: Float(symbol.center.y),
            sizePagePoints: Float(symbol.sizePagePoints),
            sizeViewPoints: Float(symbol.sizeViewPoints),
            color: packColor(symbol.color),
            rotationRadians: Float(symbol.rotationDegrees * .pi / 180)
        )
    }

    private static func instance(from glyph: CompiledGlyph) -> GlyphInstance {
        // Texel coordinates: the atlas may grow taller after this instance is written, and a
        // coordinate normalised against today's height would point at the wrong row tomorrow
        // (BH-200). The sampler is unnormalised to match.
        let uv = glyph.tile.texelUV
        return GlyphInstance(
            uv: (Float(uv.0), Float(uv.1), Float(uv.2), Float(uv.3)),
            anchorX: Float(glyph.anchor.x),
            anchorY: Float(glyph.anchor.y),
            offsetX: Float(glyph.offsetX),
            offsetY: Float(glyph.offsetY),
            widthPixels: Float(glyph.widthPixels),
            heightPixels: Float(glyph.heightPixels),
            color: packColor(glyph.color),
            // The quad's turn rides in the flags word's upper half (T-065), so the instance
            // stays 48 bytes; zero for every screen-upright label.
            flags: UInt32(glyph.rotationSteps) << MetalInstanceLayout.glyphRotationShift
        )
    }

    private static func uniforms(
        for transform: RenderTransform,
        segmentQuadPad: Double
    ) -> FrameUniforms {
        let matrix = transform.pageToPixel
        let size = transform.viewport.pixelSize
        return FrameUniforms(
            matrix: (Float(matrix.a), Float(matrix.b), Float(matrix.c), Float(matrix.d)),
            translationAndViewport: (
                Float(matrix.tx), Float(matrix.ty),
                Float(Swift.max(1, size.width)), Float(Swift.max(1, size.height))
            ),
            strokeParameters: (
                Float(transform.pixelsPerPagePoint),
                Float(RenderTransform.minimumStrokeDevicePixels),
                Float(RenderTransform.maximumStrokeDevicePixels),
                Float(transform.viewport.backingScale)
            ),
            dashParameters: (Float(DashPattern.minimumRunPixels), Float(segmentQuadPad), 0, 0)
        )
    }

    // MARK: - Atlas textures

    private func refreshSymbolTexture(bucket: Int, atlas: SymbolAtlas) {
        if let existing = symbolTextures[bucket],
           existing.source === atlas,
           existing.width == atlas.bitmap.width,
           existing.height == atlas.bitmap.height {
            return
        }
        guard let texture = makeTexture(from: atlas.bitmap) else { return }
        symbolTextures[bucket] = AtlasTexture(
            texture: texture,
            source: atlas,
            generation: 0,
            width: atlas.bitmap.width,
            height: atlas.bitmap.height
        )
    }

    private func refreshGlyphTexture(key: GlyphArenaKey, atlas: GlyphAtlas) {
        if let existing = glyphTextures[key],
           existing.source === atlas,
           existing.generation == atlas.generation {
            return
        }
        guard let texture = makeTexture(from: atlas.bitmap) else { return }
        glyphTextures[key] = AtlasTexture(
            texture: texture,
            source: atlas,
            generation: atlas.generation,
            width: atlas.bitmap.width,
            height: atlas.bitmap.height
        )
    }

    private func makeTexture(from bitmap: AlphaBitmap) -> (any MTLTexture)? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: bitmap.width,
            height: bitmap.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = pipelines.device.makeTexture(descriptor: descriptor) else { return nil }
        bitmap.coverage.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bitmap.width
            )
        }
        return texture
    }

    // MARK: - Encoding

    /// The four materials a frame is batched into. One pipeline each, one bind each, however
    /// many markups there are.
    private enum MaterialPass: Hashable {
        case triangle, segment, symbol, glyph
        case multiplyTriangle, multiplySegment, multiplySymbol, multiplyGlyph
    }

    /// Draws `drawCount` instanced quads through `list`, one draw per blend run when the list
    /// is a submission list, binding the normal or the multiply pipeline for each run. With
    /// the identity list (no culling, no highlighter) it is the single draw it always was.
    private func drawInstancedQuads(
        encoder: any MTLRenderCommandEncoder,
        list: SubmissionList,
        drawCount: Int,
        usesRuns: Bool,
        normal: (pass: MaterialPass, state: any MTLRenderPipelineState),
        multiply: (pass: MaterialPass, state: any MTLRenderPipelineState),
        boundPipeline: inout MaterialPass?,
        draws: inout Int,
        pipelineBinds: inout Int
    ) {
        guard let visible = list.buffer else { return }
        let runs = usesRuns ? list.runs : [BlendRun(start: 0, count: drawCount, multiplies: false)]
        for run in runs where run.count > 0 {
            let chosen = run.multiplies ? multiply : normal
            if boundPipeline != chosen.pass {
                encoder.setRenderPipelineState(chosen.state)
                boundPipeline = chosen.pass
                pipelineBinds += 1
            }
            encoder.setVertexBuffer(visible, offset: run.start * MemoryLayout<UInt32>.stride, index: 2)
            draws += 1
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: run.count
            )
        }
    }

    /// Encodes the whole frame into one render encoder, everything at that encoder's sample count.
    ///
    /// Exposed so an `MTKView`'s draw loop can hand its own drawable's encoder over. This is the
    /// **single-pass** frame; a caller that wants the split of ``RenderPassPolicy`` calls
    /// ``encodeFillPass(into:)`` and ``encodeInkPass(into:)`` into two encoders instead, and
    /// ``requiresSeparateInkPass`` says which of the two shapes the current policy asks for.
    ///
    /// - Parameter attachmentSampleCount: the sample count of the encoder's colour attachment.
    ///   An encoder cannot be asked for it, and a pipeline built for one sample count is invalid
    ///   on an attachment of another — the previous `encode(into:)` always bound the
    ///   multisampled set, which Metal validation rejects on an `MTKView`'s default one-sample
    ///   drawable (BH-202). Only ``sampleCount`` and `1` have pipelines; any other count
    ///   encodes nothing and logs, rather than encoding something undefined.
    public func encode(into encoder: any MTLRenderCommandEncoder, attachmentSampleCount: Int) {
        resetPassStatistics()
        let set: MaterialPipelines
        if attachmentSampleCount == pipelines.sampleCount {
            set = pipelines.multisampled
        } else if attachmentSampleCount == 1 {
            set = pipelines.singleSample
        } else {
            RendererLog.logger.error(
                "no pipelines for a \(attachmentSampleCount)-sample attachment (have \(self.pipelines.sampleCount) and 1); frame not encoded"
            )
            return
        }
        encodeFills(into: encoder, using: set)
        encodeInk(into: encoder, using: set)
    }

    /// `true` when the current ``renderPassPolicy`` wants fills and ink in separate passes.
    ///
    /// A device with no multisampling has nothing to split: both sets are the same pipelines and
    /// one pass draws the identical picture more cheaply than two.
    public var requiresSeparateInkPass: Bool {
        renderPassPolicy.splitsInkPass && pipelines.sampleCount > 1
    }

    /// Pass one of the split: polygon fills, into the multisample attachment.
    ///
    /// Resets the frame's draw-call and pipeline-bind counters, so it must be encoded first.
    public func encodeFillPass(into encoder: any MTLRenderCommandEncoder) {
        resetPassStatistics()
        encodeFills(into: encoder, using: pipelines.multisampled)
    }

    /// Pass two of the split: strokes, symbols, glyphs and the overlay, into the resolved
    /// attachment at one sample per pixel. Accumulates onto pass one's counters.
    public func encodeInkPass(into encoder: any MTLRenderCommandEncoder) {
        encodeInk(into: encoder, using: pipelines.singleSample)
    }

    private func resetPassStatistics() {
        lastStatistics.drawCallCount = 0
        lastStatistics.pipelineStateChangeCount = 0
    }

    /// Polygon fills.
    ///
    /// Category order across the whole frame is fills, strokes, symbols, labels, then the overlay.
    /// Painter's order *within* a category follows the buffer, which follows z; *across*
    /// categories it is the category order, not z. That is a deliberate choice and the Core
    /// Graphics oracle makes the identical one, so the two agree: it reflects how a takeoff
    /// overlay reads — area shading behind, its outline on top of it, count markers and labels
    /// above both — and it is what allows one draw call per category instead of one per markup.
    ///
    /// It is also what makes the pass split possible at all: fills are already a prefix of the
    /// draw order, so cutting the frame between them and everything else does not reorder a
    /// single primitive.
    private func encodeFills(
        into encoder: any MTLRenderCommandEncoder,
        using set: MaterialPipelines
    ) {
        guard !isDisposed, scene != nil else { return }
        var frame = uniforms
        let uniformSize = MemoryLayout<FrameUniforms>.stride
        // Counted, not assumed. `RenderStatistics.drawCallCount` and
        // `pipelineStateChangeCount` are what let `MaterialBatchingTests` assert that this pass
        // costs the same number of state changes at a hundred markups and at a hundred thousand.
        var draws = 0
        var pipelineBinds = 0
        var boundPipeline: MaterialPass?

        // Which instances the pass covers. With no culling: the identity list over the whole
        // arena, so the draw is exactly what it was before submission lists existed. With
        // culling: the per-pass list the CPU-side culler produced.
        if submitsSubset {
            if triangleSubmission.count > 0,
               let buffer = triangles.buffer,
               let indexBuffer = triangleSubmission.buffer {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
                // One draw per blend run: a single run, and so a single draw, unless the scene
                // holds a highlighter (K-07).
                for run in triangleSubmission.runs where run.count > 0 {
                    let pass: MaterialPass = run.multiplies ? .multiplyTriangle : .triangle
                    if boundPipeline != pass {
                        encoder.setRenderPipelineState(run.multiplies ? set.multiplyTriangle : set.triangle)
                        boundPipeline = pass
                        pipelineBinds += 1
                    }
                    draws += 1
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: run.count,
                        indexType: .uint32,
                        indexBuffer: indexBuffer,
                        indexBufferOffset: run.start * MemoryLayout<UInt32>.stride
                    )
                }
            }
        } else if triangles.highWaterMark > 0, let buffer = triangles.buffer {
            if boundPipeline != .triangle {
                encoder.setRenderPipelineState(set.triangle)
                boundPipeline = .triangle
                pipelineBinds += 1
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            draws += 1
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: triangles.highWaterMark
            )
        }

        lastStatistics.drawCallCount += draws
        lastStatistics.pipelineStateChangeCount += pipelineBinds
    }

    /// Strokes, symbols, glyphs and the overlay: everything whose coverage the shaders compute
    /// for themselves, and therefore everything that gains nothing from a multisampled
    /// attachment. See ``RenderPassPolicy``.
    private func encodeInk(
        into encoder: any MTLRenderCommandEncoder,
        using set: MaterialPipelines
    ) {
        guard !isDisposed, scene != nil else { return }
        var frame = uniforms
        let uniformSize = MemoryLayout<FrameUniforms>.stride
        var draws = 0
        var pipelineBinds = 0
        var boundPipeline: MaterialPass?

        let segmentList = submitsSubset ? segmentSubmission : identitySubmission
        let segmentDrawCount = submitsSubset ? segmentSubmission.count : segments.highWaterMark
        if segmentDrawCount > 0, let buffer = segments.buffer, segmentList.buffer != nil {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            drawInstancedQuads(
                encoder: encoder, list: segmentList, drawCount: segmentDrawCount,
                usesRuns: submitsSubset,
                normal: (.segment, set.segment), multiply: (.multiplySegment, set.multiplySegment),
                boundPipeline: &boundPipeline, draws: &draws, pipelineBinds: &pipelineBinds
            )
        }

        encoder.setFragmentSamplerState(pipelines.atlasSampler, index: 0)

        for (bucket, arena) in symbolArenas.sorted(by: { $0.key < $1.key }) {
            let list = submitsSubset ? symbolSubmission[bucket] : identitySubmission
            let drawCount = submitsSubset ? (list?.count ?? 0) : arena.highWaterMark
            guard drawCount > 0, let buffer = arena.buffer,
                  let list, list.buffer != nil,
                  let texture = symbolTextures[bucket]
            else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            encoder.setFragmentTexture(texture.texture, index: 0)
            drawInstancedQuads(
                encoder: encoder, list: list, drawCount: drawCount,
                usesRuns: submitsSubset,
                normal: (.symbol, set.symbol), multiply: (.multiplySymbol, set.multiplySymbol),
                boundPipeline: &boundPipeline, draws: &draws, pipelineBinds: &pipelineBinds
            )
        }

        for (key, arena) in glyphArenas.sorted(by: {
            ($0.key.font, $0.key.bucket) < ($1.key.font, $1.key.bucket)
        }) {
            let list = submitsSubset ? glyphSubmission[key] : identitySubmission
            let drawCount = submitsSubset ? (list?.count ?? 0) : arena.highWaterMark
            guard drawCount > 0, let buffer = arena.buffer,
                  let list, list.buffer != nil,
                  let texture = glyphTextures[key]
            else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            encoder.setFragmentTexture(texture.texture, index: 0)
            drawInstancedQuads(
                encoder: encoder, list: list, drawCount: drawCount,
                usesRuns: submitsSubset,
                normal: (.glyph, set.glyph), multiply: (.multiplyGlyph, set.multiplyGlyph),
                boundPipeline: &boundPipeline, draws: &draws, pipelineBinds: &pipelineBinds
            )
        }

        // The overlay pass: its own buffers, encoded last, touching no geometry arena. It is
        // never culled — selection handles and the snap glyph are interface state that must
        // stay on screen — so it always draws through the identity list.
        if overlaySegmentCount > 0, let buffer = overlaySegmentBuffer,
           let identity = identitySubmission.buffer {
            if boundPipeline != .segment {
                encoder.setRenderPipelineState(set.segment)
                boundPipeline = .segment
                pipelineBinds += 1
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            encoder.setVertexBuffer(identity, offset: 0, index: 2)
            draws += 1
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: overlaySegmentCount
            )
        }
        for (bucket, entry) in overlaySymbolBuffers.sorted(by: { $0.key < $1.key }) {
            guard let texture = symbolTextures[bucket],
                  let identity = identitySubmission.buffer
            else { continue }
            if boundPipeline != .symbol {
                encoder.setRenderPipelineState(set.symbol)
                boundPipeline = .symbol
                pipelineBinds += 1
            }
            encoder.setVertexBuffer(entry.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&frame, length: uniformSize, index: 1)
            encoder.setVertexBuffer(identity, offset: 0, index: 2)
            encoder.setFragmentTexture(texture.texture, index: 0)
            draws += 1
            encoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: entry.count
            )
        }

        lastStatistics.drawCallCount += draws
        lastStatistics.pipelineStateChangeCount += pipelineBinds
    }

    /// Builds a command buffer for the current scene and returns it committed but not waited on.
    ///
    /// The benchmarks call this to time frame build plus encode without the GPU's own execution
    /// time folded in, which is the number the 16.6 ms budget is actually about on the CPU side.
    @discardableResult
    public func encodeFrame() throws -> any MTLCommandBuffer {
        guard !isDisposed else { throw RendererError.disposed }
        guard let scene else { throw RendererError.noSceneToRender }
        try prepareTargets(scene.transform.viewport.pixelSize)
        guard let commandBuffer = pipelines.commandQueue.makeCommandBuffer() else {
            throw RendererError.commandEncodingFailed("no command buffer")
        }
        try encodeScene(into: commandBuffer)
        commandBuffer.commit()
        return commandBuffer
    }

    /// Encodes the frame's one or two render passes into a command buffer, honouring
    /// ``renderPassPolicy``. The targets must already be prepared.
    private func encodeScene(into commandBuffer: any MTLCommandBuffer) throws {
        if requiresSeparateInkPass {
            guard let fillDescriptor = renderPassDescriptor(stage: .fills) else {
                throw RendererError.commandEncodingFailed("no render pass descriptor")
            }
            guard let fillEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fillDescriptor)
            else { throw RendererError.commandEncodingFailed("no render command encoder") }
            fillEncoder.label = "ZPDFRenderer.fills (multisampled)"
            restrictToTarget(fillEncoder)
            encodeFillPass(into: fillEncoder)
            fillEncoder.endEncoding()

            guard let inkDescriptor = renderPassDescriptor(stage: .ink) else {
                throw RendererError.commandEncodingFailed("no render pass descriptor")
            }
            guard let inkEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: inkDescriptor)
            else { throw RendererError.commandEncodingFailed("no render command encoder") }
            inkEncoder.label = "ZPDFRenderer.ink (single sample)"
            restrictToTarget(inkEncoder)
            encodeInkPass(into: inkEncoder)
            inkEncoder.endEncoding()
            return
        }

        guard let descriptor = renderPassDescriptor(stage: .whole) else {
            throw RendererError.commandEncodingFailed("no render pass descriptor")
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw RendererError.commandEncodingFailed("no render command encoder")
        }
        encoder.label = "ZPDFRenderer.frame"
        restrictToTarget(encoder)
        encode(into: encoder, attachmentSampleCount: msaaTexture == nil ? 1 : pipelines.sampleCount)
        encoder.endEncoding()
    }

    // MARK: - OffscreenMarkupRendering

    public func renderOffscreen() throws -> RasterImage {
        let size = try renderIntoReadback()
        guard let readbackBuffer else { throw RendererError.textureReadbackFailed("no readback buffer") }
        let byteCount = size.width * size.height * 4
        let raw = readbackBuffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
        let bytes = Array(UnsafeBufferPointer(start: raw, count: byteCount))
        guard let image = RasterImage.fromBGRA(width: size.width, height: size.height, bytes: bytes)
        else { throw RendererError.textureReadbackFailed("byte count mismatch") }
        return image
    }

    /// Renders the current scene and returns it as a `CGImage`, with **one** copy of the pixels.
    ///
    /// ``renderOffscreen()`` copies the readback buffer into an array, swizzles it byte by byte
    /// into a second one, and a caller that wants a `CGImage` then copies it a third time. This
    /// hands Core Graphics the target's own byte order instead — BGRA, premultiplied, which is
    /// `byteOrder32Little | premultipliedFirst` — so the only copy is the one that detaches the
    /// image from the reusable readback buffer (IM-084). Same pixels: the golden suite checks
    /// `RasterImage.fromCGImage(renderOffscreenImage())` against ``renderOffscreen()`` byte for
    /// byte.
    public func renderOffscreenImage() throws -> CGImage {
        let size = try renderIntoReadback()
        guard let readbackBuffer else { throw RendererError.textureReadbackFailed("no readback buffer") }
        let bytesPerRow = size.width * 4
        let data = Data(bytes: readbackBuffer.contents(), count: bytesPerRow * size.height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw RendererError.textureReadbackFailed("could not wrap the pixels in a CGImage") }
        return image
    }

    /// Encodes the scene, blits the resolved target into the readback buffer at a tight row
    /// pitch, and waits. Returns the rendered size.
    private func renderIntoReadback() throws -> PixelSize {
        guard !isDisposed else { throw RendererError.disposed }
        guard let scene else { throw RendererError.noSceneToRender }
        let size = scene.transform.viewport.pixelSize
        try prepareTargets(size)
        guard let resolveTexture, let readbackBuffer else {
            throw RendererError.textureReadbackFailed("no render target")
        }

        guard let commandBuffer = pipelines.commandQueue.makeCommandBuffer() else {
            throw RendererError.commandEncodingFailed("no command buffer")
        }
        try encodeScene(into: commandBuffer)

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.commandEncodingFailed("no blit encoder")
        }
        blit.copy(
            from: resolveTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: size.width * 4,
            destinationBytesPerImage: size.width * size.height * 4
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.commandEncodingFailed(String(describing: error))
        }
        return size
    }

    /// The allocated size of the render targets, which is at least ``targetSize`` and usually
    /// larger: see ``prepareTargets(_:)``.
    private var targetCapacity = PixelSize(width: 0, height: 0)
    /// How many times the render targets have been (re)allocated. For tests (IM-197).
    public private(set) var targetAllocationCount = 0

    /// The allocation granularity of the render targets, in pixels per side.
    static let targetGranularity = 256

    /// Makes sure the targets can hold `size`, reallocating only when they cannot — or when they
    /// are more than four times the area they are being used for, so a shrinking sheet gives the
    /// memory back.
    ///
    /// The targets are allocated rounded up to ``targetGranularity``-pixel steps and the frame is
    /// drawn into their top-left `size` corner (the viewport and scissor are set to it, the blit
    /// reads only it). When the sheet is smaller than the window the viewport's size changes on
    /// every zoom event, and reallocating the resolve texture, the multisample texture and the
    /// readback buffer each time was megabytes of allocation per gesture step (IM-197).
    private func prepareTargets(_ size: PixelSize) throws {
        guard size.width > 0, size.height > 0 else {
            throw RendererError.invalidViewport(reason: "empty drawable")
        }
        guard size.width <= RenderLimits.maximumTargetPixels,
              size.height <= RenderLimits.maximumTargetPixels
        else { throw RendererError.targetTooLarge(size) }
        targetSize = size
        let fits = resolveTexture != nil
            && size.width <= targetCapacity.width && size.height <= targetCapacity.height
        let wasteful = targetCapacity.pixelCount > 4 * Swift.max(size.pixelCount, Self.targetGranularity * Self.targetGranularity)
        guard !fits || wasteful else { return }

        func rounded(_ value: Int) -> Int {
            let step = Self.targetGranularity
            return Swift.min(RenderLimits.maximumTargetPixels, (value + step - 1) / step * step)
        }
        let capacity = PixelSize(width: rounded(size.width), height: rounded(size.height))

        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pipelines.pixelFormat,
            width: capacity.width,
            height: capacity.height,
            mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .private
        guard let resolve = pipelines.device.makeTexture(descriptor: resolveDescriptor) else {
            throw RendererError.pipelineCreationFailed("resolve texture allocation failed")
        }

        if pipelines.sampleCount > 1 {
            let msaaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pipelines.pixelFormat,
                width: capacity.width,
                height: capacity.height,
                mipmapped: false
            )
            msaaDescriptor.textureType = .type2DMultisample
            msaaDescriptor.sampleCount = pipelines.sampleCount
            msaaDescriptor.usage = .renderTarget
            // Memoryless where the hardware allows it: the multisample target is written, read by
            // the resolve and never touched again, so on a tile-based GPU it never has to leave
            // tile memory. At eight samples on a 3200 x 2000 drawable that is 200 MB of traffic a
            // frame that simply does not happen.
            msaaDescriptor.storageMode = pipelines.device.supportsFamily(.apple1)
                ? .memoryless
                : .private
            guard let msaa = pipelines.device.makeTexture(descriptor: msaaDescriptor) else {
                throw RendererError.pipelineCreationFailed("multisample texture allocation failed")
            }
            msaaTexture = msaa
        } else {
            msaaTexture = nil
        }

        guard let readback = pipelines.device.makeBuffer(
            length: capacity.width * capacity.height * 4,
            options: .storageModeShared
        ) else {
            throw RendererError.pipelineCreationFailed("readback buffer allocation failed")
        }

        resolveTexture = resolve
        readbackBuffer = readback
        targetCapacity = capacity
        targetAllocationCount += 1
    }

    /// Confines an encoder to the part of the (possibly larger) targets this frame uses.
    private func restrictToTarget(_ encoder: any MTLRenderCommandEncoder) {
        let width = targetSize.width, height = targetSize.height
        guard width > 0, height > 0 else { return }
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0,
            width: Double(width), height: Double(height),
            znear: 0, zfar: 1
        ))
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
    }

    /// Which of the frame's passes a descriptor is for.
    private enum PassStage {
        /// The whole frame in one pass, at the device's sample count.
        case whole
        /// Split pass one: fills into the multisample target, resolved on the way out.
        case fills
        /// Split pass two: ink straight onto the resolved target, one sample, loading rather
        /// than clearing so pass one's fills are what it blends over.
        case ink
    }

    private func renderPassDescriptor(stage: PassStage) -> MTLRenderPassDescriptor? {
        guard let resolveTexture else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        switch stage {
        case .whole, .fills:
            if let msaaTexture {
                attachment.texture = msaaTexture
                attachment.resolveTexture = resolveTexture
                attachment.storeAction = .multisampleResolve
            } else {
                attachment.texture = resolveTexture
                attachment.storeAction = .store
            }
            attachment.loadAction = .clear
            attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .ink:
            attachment.texture = resolveTexture
            attachment.storeAction = .store
            attachment.loadAction = .load
        }
        return descriptor
    }
}
