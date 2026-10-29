import Foundation
import ZPDFContracts
import ZPDFGeometry

/// A page's snap index: three spatially indexed layers over the three geometry sources of
/// `SNAP_CONTRACT` 13.2, plus the availability state of `SNAP_CONTRACT` 13.11.
///
/// The index stores **primitives**, never derived snap targets. Endpoints, midpoints, centres,
/// quadrants, perpendicular feet, tangents and — above all — intersections are computed lazily
/// inside the query radius by ``SnapTargetGenerator``. Precomputing them globally would multiply
/// a 250 000-primitive page into millions of points and make the intersection set quadratic in
/// the page, which is the difference between an 8 ms query and an unusable one.
public struct SnapIndex: Sendable {

    public let page: PageDescriptor

    public private(set) var availability: SnapIndexAvailability
    public let limits: SnapIndexLimits

    private var vectorLayer: SnapLayer
    private var markupLayer: SnapLayer
    private var boundaryLayer: SnapLayer

    /// The boundaries the boundary layer answers for, by identity — what
    /// ``replaceBoundaries(with:)`` compares a new set against. A boundary that could not be
    /// indexed is listed with no entries, so asking again does not churn the layer.
    public private(set) var boundaries: [String: SnapBoundary]

    /// Bumped by every mutation of any layer, so a UI can invalidate an overlay cheaply.
    public private(set) var generation: UInt64

    public var pageID: PageID { page.id }

    public var vectorPrimitiveCount: Int { vectorLayer.count }
    public var markupPrimitiveCount: Int { markupLayer.count }
    public var boundaryPrimitiveCount: Int { boundaryLayer.count }
    public var primitiveCount: Int {
        vectorLayer.count + markupLayer.count + boundaryLayer.count
    }

    init(
        page: PageDescriptor,
        availability: SnapIndexAvailability,
        limits: SnapIndexLimits,
        vectorLayer: SnapLayer,
        markupLayer: SnapLayer,
        boundaryLayer: SnapLayer,
        boundaries: [String: SnapBoundary] = [:]
    ) {
        self.page = page
        self.availability = availability
        self.limits = limits
        self.vectorLayer = vectorLayer
        self.markupLayer = markupLayer
        self.boundaryLayer = boundaryLayer
        self.boundaries = boundaries
        self.generation = 0
    }

    // MARK: - Incremental markup and boundary updates

    /// Adds or replaces one markup. The vector layer is not touched, not re-sorted and not
    /// re-hashed; only the markup layer's small tree can be rebuilt, and only when its pending
    /// buffer overflows.
    public mutating func upsert(markup: SnapMarkupGeometry) throws {
        let entries = try SnapIndexBuilder(limits: limits).markupEntries(markup)
        markupLayer.upsert(ownerID: markup.id.rawValue.uuidString, entries: entries)
        generation &+= 1
    }

    /// Removes one markup. A move is `upsert`; a delete is this.
    public mutating func remove(markupID: MarkupID) {
        markupLayer.removeOwner(markupID.rawValue.uuidString)
        generation &+= 1
    }

    public mutating func upsert(boundary: SnapBoundary) throws {
        let entries = try SnapIndexBuilder(limits: limits).boundaryEntries(boundary)
        boundaryLayer.upsert(ownerID: boundary.id, entries: entries)
        boundaries[boundary.id] = boundary
        generation &+= 1
    }

    public mutating func remove(boundaryID: String) {
        boundaryLayer.removeOwner(boundaryID)
        boundaries.removeValue(forKey: boundaryID)
        generation &+= 1
    }

    /// Makes the boundary layer hold exactly `newBoundaries` — Project Zone and Scale Region
    /// outlines and calibration points, as the document has them now (U-086): each one gone is
    /// removed, each one new or changed is upserted, and one unchanged is not touched. A boundary
    /// that cannot be indexed is left out on its own, as ``SnapIndexBuilder/build(page:extraction:availability:markups:boundaries:hiddenLayerIDs:cancellation:)``
    /// leaves it out. Returns whether anything changed.
    @discardableResult
    public mutating func replaceBoundaries(with newBoundaries: [SnapBoundary]) -> Bool {
        let wanted = Dictionary(newBoundaries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var changed = false
        for id in boundaries.keys.sorted() where wanted[id] == nil {
            remove(boundaryID: id)
            changed = true
        }
        for id in wanted.keys.sorted() {
            guard let boundary = wanted[id], boundaries[id] != boundary else { continue }
            if (try? upsert(boundary: boundary)) == nil {
                boundaryLayer.removeOwner(id)
                boundaries[id] = boundary
                generation &+= 1
            }
            changed = true
        }
        return changed
    }

    /// Replaces the vector layer with a caller-supplied entry set.
    ///
    /// The normal path is ``SnapIndexBuilder/build(page:extraction:availability:markups:boundaries:hiddenLayerIDs:cancellation:)``,
    /// which bridges what the extractor produced. This exists for the case where the geometry
    /// was produced somewhere else — a differential run against a second extractor, or a
    /// synthetic scene — and it does not invent an availability: the caller states it.
    public mutating func installVectorEntries(
        _ entries: [SnapIndexEntry],
        availability: SnapIndexAvailability? = nil
    ) throws {
        guard entries.count <= limits.maximumPrimitives else {
            throw SnapEngineError.indexTooLarge(count: entries.count, limit: limits.maximumPrimitives)
        }
        for entry in entries {
            guard entry.primitive.isConsistent else {
                throw SnapEngineError.inconsistentPrimitive(id: entry.id)
            }
            // The same ring bound both shipping paths enforce: the extractor bridge drops an
            // over-long ring and the markup path refuses one. A caller-supplied ring is refused
            // with the same typed error rather than indexed (BH-671).
            if case .polyline(let points, _) = entry.primitive.geometry,
               points.count > limits.maximumRingVertices {
                throw SnapEngineError.indexTooLarge(
                    count: points.count, limit: limits.maximumRingVertices
                )
            }
        }
        // The layer keys tombstones, hysteresis identity and intersection ownership by
        // identifier, so two live entries may never share one. Both builder paths resolve
        // collisions before the layer is built; this path skipped it and two primitives with
        // one id became two indistinguishable live entries (BH-219, BH-664). Same rule, same
        // deterministic probe order, so the result is a function of the entry set.
        vectorLayer = try SnapLayer(
            entries: SnapIndexBuilder(limits: limits).resolveCollisions(entries)
        )
        if let availability {
            self.availability = availability
        } else if entries.isEmpty {
            self.availability = .unavailable(.noVectorContent)
        }
        generation &+= 1
    }

    // MARK: - Query

    /// Every entry whose bounding box intersects `rect`, in ascending identifier order.
    ///
    /// Vector entries are withheld entirely unless ``availability`` allows them: S14 requires
    /// that no vector candidate is *ever* emitted for a page reported as unavailable, and the
    /// cheapest way to guarantee that is never to let one out of the index.
    public func entries(intersecting rect: PDFRect) -> [SnapIndexEntry] {
        var results = unorderedEntries(intersecting: rect)
        results.sort { $0.id < $1.id }
        return results
    }

    /// The same set as ``entries(intersecting:)``, in whatever order the three layers'
    /// traversals produced it: the gather step of ``entries(intersecting:)``, which sorts it.
    ///
    /// The engine does not query by box: it reads ``nearestEntries(to:maxDistance:limit:)``,
    /// which a test holds to the same set this box query would have kept (IM-009).
    func unorderedEntries(intersecting rect: PDFRect) -> [SnapIndexEntry] {
        var results: [SnapIndexEntry] = []
        results.reserveCapacity(64)
        if availability.allowsVectorCandidates {
            vectorLayer.query(rect, into: &results)
        }
        markupLayer.query(rect, into: &results)
        boundaryLayer.query(rect, into: &results)
        return results
    }

    /// The entries the engine's truncation to `limit` primitives can keep, from all three
    /// layers, in whatever order the layers produced them.
    ///
    /// Each layer contributes every live entry within `maxDistance` of `point` when it holds
    /// no more than `limit` of them, and otherwise exactly those at or inside its `limit`-th
    /// box distance (see ``SnapLayer/nearest(to:maxDistance:limit:into:)``). The union
    /// therefore contains every entry that can be among the `limit` nearest overall by
    /// `(box distance, id)`, so ``SnapTargetGenerator/localPrimitives(_:cursor:radius:)`` keeps
    /// the identical set it kept from ``unorderedEntries(intersecting:)`` — the search box
    /// result — while touching a number of tree nodes proportional to `limit` and the local
    /// density rather than to the box (IM-009). `QUALITY_BAR` S1 and S15 hold either way, and
    /// a test asserts the two routes agree.
    public func nearestEntries(to point: PDFPoint, maxDistance: Double, limit: Int) -> [SnapIndexEntry] {
        var results: [SnapIndexEntry] = []
        results.reserveCapacity(64)
        var scratch = SnapQueryScratch()
        nearestEntries(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
        return results
    }

    /// ``nearestEntries(to:maxDistance:limit:)`` into a caller-owned buffer (cleared first,
    /// capacity kept) with the layers' search buffers taken from `scratch` (IM-199).
    public func nearestEntries(
        to point: PDFPoint,
        maxDistance: Double,
        limit: Int,
        into results: inout [SnapIndexEntry],
        scratch: inout SnapQueryScratch
    ) {
        results.removeAll(keepingCapacity: true)
        if availability.allowsVectorCandidates {
            vectorLayer.nearest(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
        }
        markupLayer.nearest(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
        boundaryLayer.nearest(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
    }

    /// Test and diagnostic accessor: every live entry of one layer, ordered by identifier.
    public func allEntries(in layer: SnapLayerKind) -> [SnapIndexEntry] {
        switch layer {
        case .vector: vectorLayer.allEntries
        case .markup: markupLayer.allEntries
        case .boundary: boundaryLayer.allEntries
        }
    }
}

/// A cooperative cancellation predicate for index building.
///
/// An index build walks untrusted geometry and must be interruptible, but it is synchronous and
/// runs off any actor, so `Task.isCancelled` is not available to it. The caller supplies the
/// predicate; the builder checks it every ``SnapCancellation/checkInterval`` primitives.
public struct SnapCancellation: Sendable {
    public let isCancelled: @Sendable () -> Bool
    public let checkInterval: Int

    public init(checkInterval: Int = 4096, isCancelled: @escaping @Sendable () -> Bool) {
        self.checkInterval = Swift.max(1, checkInterval)
        self.isCancelled = isCancelled
    }

    public static let never = SnapCancellation { false }

    /// Bridges Swift concurrency cancellation into the synchronous builder.
    public static var task: SnapCancellation { SnapCancellation { Task.isCancelled } }
}
