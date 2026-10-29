import Foundation
import ZPDFContracts
import ZPDFGeometry

/// One spatially indexed layer of a page's snap index.
///
/// A packed R-tree is bulk-loaded: it has no insert and no delete, which is exactly right for
/// the 250 000-primitive PDF layer that is built once and then only read, and exactly wrong for
/// the markup layer that changes on every drag. The layer therefore keeps three things:
///
/// - `committed` — the bulk-loaded array and its tree;
/// - `pending` — entries added since the last build, scanned linearly;
/// - `removed` — identifiers tombstoned out of `committed`.
///
/// A query answers from the tree, skips tombstones, and appends a linear scan of `pending`.
/// While `pending` is small that scan costs less than a rebuild would, so adding, moving or
/// deleting a markup is O(1) amortised in the page's primitive count and never touches the
/// vector layer. When `pending` or the tombstone set grows past
/// ``SnapLayer/compactionThreshold`` the layer compacts: one O(m log m) rebuild over the markup
/// layer alone.
///
/// `removed` is a `Set` and is only ever asked `contains`. It is never iterated, so it cannot
/// leak `Hasher`'s per-process seed into the candidate order (`QUALITY_BAR` 3.4 rule 1).
public struct SnapLayer: Sendable {

    /// Pending entries tolerated before a compaction. 256 linear box tests is well under the
    /// cost of rebuilding a Hilbert-sorted tree, and well under one frame at any index size.
    public static let compactionThreshold = 256

    public private(set) var committed: [SnapIndexEntry]
    public private(set) var tree: PackedRTree
    public private(set) var pending: [SnapIndexEntry]
    public private(set) var removed: Set<UInt64>

    /// Identifiers of the live entries: committed and not tombstoned, or pending.
    ///
    /// Markup and boundary identifiers are 32-bit content hashes inside a tagged partition, so
    /// two owners can collide. The index builder resolves collisions once at build time; an
    /// upsert has to resolve them against what is already here, because the tombstone set is
    /// keyed by identifier alone — a tombstone for one owner's entry hid the other owner's
    /// live entry with the same identifier, and the next compaction dropped it for good
    /// (CR-49). Like `removed`, this set is only ever asked `contains`.
    private var liveIdentifiers: Set<UInt64>

    /// Positions in `committed` of each owner's entries, so removing an owner tombstones its
    /// entries directly instead of comparing every committed entry's owner string. A markup
    /// drag upserts on every pointer event, and with 10 000 count points on the page the scan
    /// was 10 000 string comparisons per event (IM-092). Only ever looked up by key — never
    /// iterated — so `Hasher`'s seed cannot reach any order.
    private var ownerPositions: [String: [Int]]

    /// Bumped by every mutation. Callers cache derived state against it.
    public private(set) var generation: UInt64

    /// The only initialiser. An empty layer is `try SnapLayer(entries: [])`, which cannot
    /// actually throw — `PackedRTree` returns early for an empty box array and the node size is
    /// its own validated default — but the package forbids `fatalError` and a force unwrap is
    /// the same trap under another name, so the `throws` is honest and propagated.
    public init(entries: [SnapIndexEntry]) throws {
        let sorted = entries.sorted { $0.id < $1.id }
        do {
            self.tree = try PackedRTree(boxes: sorted.map(\.bounds))
        } catch let error as GeometryError {
            throw SnapEngineError.coordinateConversionFailed(String(describing: error))
        }
        self.committed = sorted
        self.pending = []
        self.removed = []
        self.liveIdentifiers = Set(sorted.map(\.id))
        self.ownerPositions = Self.ownerPositions(of: sorted)
        self.generation = 0
    }

    private static func ownerPositions(of entries: [SnapIndexEntry]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for (position, entry) in entries.enumerated() {
            guard let owner = entry.ownerID else { continue }
            result[owner, default: []].append(position)
        }
        return result
    }

    public var count: Int { committed.count - removed.count + pending.count }
    public var isEmpty: Bool { count == 0 }

    /// Every entry, in ascending identifier order. Used for compaction and for tests.
    public var allEntries: [SnapIndexEntry] {
        var result = committed.filter { !removed.contains($0.id) }
        result.append(contentsOf: pending)
        result.sort { $0.id < $1.id }
        return result
    }

    // MARK: - Mutation

    /// Adds or replaces every entry owned by `ownerID`.
    ///
    /// Replacement is remove-then-add so that a markup whose vertex count changed does not
    /// leave stale primitives behind. An entry whose identifier is already live in this layer
    /// is given the next free identifier above it, so no two live entries ever share one; an
    /// owner that re-upserts its own entries keeps its identifiers, because its old ones are
    /// tombstoned first and a tombstoned identifier is free.
    public mutating func upsert(ownerID: String, entries: [SnapIndexEntry]) {
        removeOwner(ownerID)
        for entry in entries {
            let resolved = resolvingIdentifier(of: entry)
            liveIdentifiers.insert(resolved.id)
            pending.append(resolved)
        }
        generation &+= 1
        compactIfNeeded()
    }

    public mutating func removeOwner(_ ownerID: String) {
        var didChange = false
        if let positions = ownerPositions.removeValue(forKey: ownerID) {
            for position in positions {
                let entry = committed[position]
                guard !removed.contains(entry.id) else { continue }
                removed.insert(entry.id)
                liveIdentifiers.remove(entry.id)
                didChange = true
            }
        }
        let before = pending.count
        pending.removeAll { entry in
            guard entry.ownerID == ownerID else { return false }
            liveIdentifiers.remove(entry.id)
            return true
        }
        if pending.count != before { didChange = true }
        if didChange {
            generation &+= 1
            compactIfNeeded()
        }
    }

    /// `entry`, or a copy of it under the first identifier at or above its own that no live
    /// entry holds. Probing upwards is the same rule the index builder applies, so an entry
    /// resolves to the same identifier whether it arrived at build time or by upsert.
    private func resolvingIdentifier(of entry: SnapIndexEntry) -> SnapIndexEntry {
        guard liveIdentifiers.contains(entry.id) else { return entry }
        var probe: UInt64 = 0
        var id = entry.id
        repeat {
            probe &+= 1
            id = entry.id &+ probe
        } while liveIdentifiers.contains(id)
        let primitive = SnapPrimitive(
            id: id,
            bounds: entry.primitive.bounds,
            kind: entry.primitive.kind,
            geometry: entry.primitive.geometry,
            sourceObjectID: entry.primitive.sourceObjectID,
            confidence: entry.primitive.confidence,
            layerID: entry.primitive.layerID
        )
        return SnapIndexEntry(
            primitive: primitive,
            source: entry.source,
            ownerID: entry.ownerID,
            kindSet: entry.kindSet
        )
    }

    private mutating func compactIfNeeded() {
        let needsCompaction = pending.count > Self.compactionThreshold
            || (removed.count > 64 && removed.count * 4 > committed.count)
        guard needsCompaction else { return }
        compact()
    }

    /// Rebuilds the packed tree over the live entries of this layer only.
    public mutating func compact() {
        let entries = allEntries
        guard let rebuilt = try? PackedRTree(boxes: entries.map(\.bounds)) else { return }
        committed = entries
        tree = rebuilt
        pending.removeAll(keepingCapacity: true)
        removed.removeAll(keepingCapacity: true)
        liveIdentifiers = Set(entries.map(\.id))
        ownerPositions = Self.ownerPositions(of: entries)
    }

    // MARK: - Query

    /// Every entry whose bounding box intersects `rect`, in ascending identifier order.
    ///
    /// The sort is what makes the result independent of the tree's Hilbert traversal order and
    /// of whether an entry is committed or pending, which is what makes the engine's answer
    /// independent of the order the markups were inserted in.
    public func query(_ rect: PDFRect, into results: inout [SnapIndexEntry]) {
        var hits: [Int] = []
        hits.reserveCapacity(32)
        tree.query(rect, into: &hits)
        for position in hits {
            let entry = committed[position]
            if removed.contains(entry.id) { continue }
            results.append(entry)
        }
        for entry in pending where entry.bounds.intersects(rect) {
            results.append(entry)
        }
    }

    /// The entries the engine's truncation can keep: every live entry whose bounding-box
    /// distance to `point` is at most `maxDistance`, restricted — when the layer holds more —
    /// to those that can still be among the `limit` nearest by `(box distance, id)`.
    ///
    /// The tree's best-first k-nearest search touches nodes in proportion to the local density
    /// rather than to the search box, which at 5 % zoom holds tens of thousands of entries of
    /// which 512 are kept; the box query copied every one of them per pointer move (IM-009).
    /// The answer is exact, not approximate: when `limit` live entries are found, everything at
    /// the `limit`-th box distance is fetched as well, so a tie at the boundary is decided by
    /// the caller's `(distance, id)` order exactly as it was over the full box result. Entries
    /// that are pending are appended by a linear scan, as in ``query(_:into:)``.
    public func nearest(
        to point: PDFPoint,
        maxDistance: Double,
        limit: Int,
        into results: inout [SnapIndexEntry]
    ) {
        var scratch = SnapQueryScratch()
        nearest(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
    }

    /// ``nearest(to:maxDistance:limit:into:)`` with the R-tree heap, the neighbour list and the
    /// tie-cutoff hit list taken from caller-owned scratch (IM-199), so a resolve per pointer
    /// event allocates nothing on this path once the buffers have grown. Appends exactly the
    /// entries, in exactly the order, the allocating overload appends.
    public func nearest(
        to point: PDFPoint,
        maxDistance: Double,
        limit: Int,
        into results: inout [SnapIndexEntry],
        scratch: inout SnapQueryScratch
    ) {
        guard limit > 0, maxDistance >= 0 else { return }
        // Tombstoned entries are still in the tree; asking for that many more means a tombstone
        // can never displace a live answer.
        tree.nearest(
            to: point, maxDistance: maxDistance, limit: limit + removed.count,
            into: &scratch.neighbours, scratch: &scratch.tree
        )
        let neighbours = scratch.neighbours
        var live = 0
        var cutoff: Double?
        for neighbour in neighbours {
            let entry = committed[neighbour.index]
            if removed.contains(entry.id) { continue }
            live += 1
            if live == limit {
                cutoff = neighbour.distance
                break
            }
        }

        if let cutoff {
            // Everything at or inside the limit-th distance, ties included: the box query with
            // that radius is a superset, and the exact box distance, computed the same way the
            // engine's truncation computes it, is what decides.
            //
            // The box is grown by a few ulps of the largest magnitude involved. The tree forms
            // its far edge as `(x − cutoff) + 2·cutoff`, which can round below `x + cutoff`, and
            // an entry exactly at the cutoff on that side — the limit-th answer itself — was
            // then excluded. It happens wherever the cutoff exceeds the coordinate (a cursor near
            // the page's left or bottom edge at low zoom): a few percent of such placements
            // (R-180). The slack only widens the prefilter; the exact filter below decides.
            let slack = Swift.max(Swift.abs(point.x), Swift.abs(point.y), cutoff) * 4 * Double.ulpOfOne
            let reach = cutoff + slack
            scratch.hits.removeAll(keepingCapacity: true)
            scratch.hits.reserveCapacity(limit + 32)
            tree.query(
                PDFRect(
                    x: point.x - reach, y: point.y - reach,
                    width: 2 * reach, height: 2 * reach
                ),
                into: &scratch.hits,
                scratch: &scratch.tree
            )
            for position in scratch.hits {
                let entry = committed[position]
                if removed.contains(entry.id) { continue }
                guard SnapTargetGenerator.boxDistance(from: point, to: entry.bounds) <= cutoff else {
                    continue
                }
                results.append(entry)
            }
        } else {
            for neighbour in neighbours {
                let entry = committed[neighbour.index]
                if removed.contains(entry.id) { continue }
                results.append(entry)
            }
        }

        for entry in pending
        where SnapTargetGenerator.boxDistance(from: point, to: entry.bounds) <= maxDistance {
            results.append(entry)
        }
    }
}

/// Reusable buffers for one snap query path (IM-199): the R-tree search scratch, the neighbour
/// list and the tie-cutoff hits of ``SnapLayer``, and the candidate-entry list of
/// ``SnapIndex/nearestEntries(to:maxDistance:limit:into:scratch:)``. ``SnapEngine`` keeps one and
/// threads it through every resolve. Every use clears what it reads, so reuse cannot change an
/// answer.
public struct SnapQueryScratch: Sendable {
    var tree = RTreeSearchScratch()
    var neighbours: [RTreeNeighbor] = []
    var hits: [Int] = []
    var entries: [SnapIndexEntry] = []

    public init() {}
}
