import CoreGraphics
import Foundation
import ZPDFContracts

/// A hit from ``PackedRTree/nearest(to:maxDistance:)``.
public struct RTreeNeighbor: Hashable, Sendable {
    /// Index into the array of boxes the tree was built from.
    public let index: Int
    /// Distance from the query point to the item's **bounding box**, in PDF points. Zero when
    /// the point is inside the box.
    public let distance: Double

    public init(index: Int, distance: Double) {
        self.index = index
        self.distance = distance
    }
}

/// An immutable, bulk-loaded R-tree over axis-aligned page-space rectangles (spec 13.5).
///
/// # Shape
///
/// Hilbert-packed, flat-array, no per-node objects. Items are sorted by the Hilbert index of
/// their box centre, then packed `nodeSize` at a time into leaves, then those leaves are packed
/// into parents, level by level, until one root remains. Every node lives in the same four
/// `[Double]` coordinate arrays; a node's children are `nodeSize` consecutive slots starting at
/// `childOffsets[nodeIndex]`. There is no pointer chasing and no reference counting on the hot
/// path, which is why a 200 000-primitive page builds and queries in the times the benchmark
/// test prints. The layout and the traversal follow the design of the flatbush library
/// (github.com/mourner/flatbush).
///
/// # Immutability
///
/// The index is rebuilt, never mutated. A page's snap primitives are derived cache data keyed on
/// the PDF content hash: when the content changes the whole index is stale anyway, and an
/// insert-capable tree would cost a worse node layout on every query in exchange for an update
/// path nothing uses.
///
/// # Why `PDFRect`, not `CGRect`
///
/// Spec 13.5 sketches `SnapPrimitive.bounds` as `CGRect`; `ZPDFContracts` already made the
/// deliberate correction to ``PDFRect``, because `CGRect` is a view-space type whose y axis
/// flips with the host view. The index is strictly page space, bottom-left origin. `CGRect`
/// convenience overloads exist for callers already holding view-layer values, and they convert
/// component-wise without any flip — they do not make the tree view-space aware.
public struct PackedRTree: Sendable {

    /// Children per node. 16 is the flatbush default and measures best here too: 8 doubles the
    /// depth, 32 makes each rejected node cost twice as many box tests.
    public static let defaultNodeSize = 16

    private let nodeSize: Int
    private let itemCount: Int

    // Node boxes, leaves first (in Hilbert order), then each internal level, root last.
    private let minX: [Double]
    private let minY: [Double]
    private let maxX: [Double]
    private let maxY: [Double]

    /// For a leaf slot: the original index of the item. For an internal slot: the position of
    /// its first child in the box arrays.
    private let childOffsets: [Int]

    /// Exclusive end offset of each level in the box arrays. `levelBounds[0] == itemCount`.
    private let levelBounds: [Int]

    /// Bounding box of everything in the tree, or `nil` when empty.
    public let bounds: PDFRect?

    public var count: Int { itemCount }
    public var isEmpty: Bool { itemCount == 0 }

    // MARK: - Build

    /// Bulk-loads the tree.
    ///
    /// - Parameters:
    ///   - boxes: item bounds in page space. The index of a box in this array is the index the
    ///     queries return.
    ///   - nodeSize: children per node, 2...65 535.
    /// - Throws: ``GeometryError/invalidNodeSize(_:)`` or
    ///   ``GeometryError/nonFiniteBounds(index:)``.
    public init(boxes: [PDFRect], nodeSize: Int = PackedRTree.defaultNodeSize) throws {
        guard (2...65_535).contains(nodeSize) else {
            throw GeometryError.invalidNodeSize(nodeSize)
        }
        self.nodeSize = nodeSize
        self.itemCount = boxes.count

        guard !boxes.isEmpty else {
            self.minX = []
            self.minY = []
            self.maxX = []
            self.maxY = []
            self.childOffsets = []
            self.levelBounds = []
            self.bounds = nil
            return
        }

        // Standardise once, validate once.
        var itemMinX = [Double](repeating: 0, count: boxes.count)
        var itemMinY = [Double](repeating: 0, count: boxes.count)
        var itemMaxX = [Double](repeating: 0, count: boxes.count)
        var itemMaxY = [Double](repeating: 0, count: boxes.count)
        var totalMinX = Double.greatestFiniteMagnitude
        var totalMinY = Double.greatestFiniteMagnitude
        var totalMaxX = -Double.greatestFiniteMagnitude
        var totalMaxY = -Double.greatestFiniteMagnitude

        for (index, box) in boxes.enumerated() {
            guard box.isFinite else { throw GeometryError.nonFiniteBounds(index: index) }
            let standardized = box.standardized
            let lowX = standardized.origin.x
            let lowY = standardized.origin.y
            let highX = lowX + standardized.size.width
            let highY = lowY + standardized.size.height
            itemMinX[index] = lowX
            itemMinY[index] = lowY
            itemMaxX[index] = highX
            itemMaxY[index] = highY
            totalMinX = Swift.min(totalMinX, lowX)
            totalMinY = Swift.min(totalMinY, lowY)
            totalMaxX = Swift.max(totalMaxX, highX)
            totalMaxY = Swift.max(totalMaxY, highY)
        }

        self.bounds = PDFRect(
            corner: PDFPoint(x: totalMinX, y: totalMinY),
            opposite: PDFPoint(x: totalMaxX, y: totalMaxY)
        )

        // Level sizes.
        var levelEnds: [Int] = [boxes.count]
        var nodesAtLevel = boxes.count
        var totalNodes = boxes.count
        while nodesAtLevel > 1 {
            nodesAtLevel = (nodesAtLevel + nodeSize - 1) / nodeSize
            totalNodes += nodesAtLevel
            levelEnds.append(totalNodes)
        }
        self.levelBounds = levelEnds

        var nodeMinX = [Double](repeating: 0, count: totalNodes)
        var nodeMinY = [Double](repeating: 0, count: totalNodes)
        var nodeMaxX = [Double](repeating: 0, count: totalNodes)
        var nodeMaxY = [Double](repeating: 0, count: totalNodes)
        var offsets = [Int](repeating: 0, count: totalNodes)

        // Hilbert order. Ties break on the original index so the build is deterministic for a
        // given input — two runs, two machines, same tree, same query order.
        var hilbert = [UInt32](repeating: 0, count: boxes.count)
        for index in 0..<boxes.count {
            let centreX = (itemMinX[index] + itemMaxX[index]) / 2
            let centreY = (itemMinY[index] + itemMaxY[index]) / 2
            hilbert[index] = HilbertCurve.distance(
                x: HilbertCurve.quantise(centreX, lower: totalMinX, upper: totalMaxX),
                y: HilbertCurve.quantise(centreY, lower: totalMinY, upper: totalMaxY)
            )
        }
        let order = (0..<boxes.count).sorted { lhs, rhs in
            hilbert[lhs] == hilbert[rhs] ? lhs < rhs : hilbert[lhs] < hilbert[rhs]
        }

        for (slot, original) in order.enumerated() {
            nodeMinX[slot] = itemMinX[original]
            nodeMinY[slot] = itemMinY[original]
            nodeMaxX[slot] = itemMaxX[original]
            nodeMaxY[slot] = itemMaxY[original]
            offsets[slot] = original
        }

        // Pack level by level.
        var writeIndex = boxes.count
        var levelStart = 0
        for level in 0..<(levelEnds.count - 1) {
            let levelEnd = levelEnds[level]
            var position = levelStart
            while position < levelEnd {
                let groupEnd = Swift.min(position + nodeSize, levelEnd)
                var groupMinX = nodeMinX[position]
                var groupMinY = nodeMinY[position]
                var groupMaxX = nodeMaxX[position]
                var groupMaxY = nodeMaxY[position]
                for child in (position + 1)..<groupEnd {
                    groupMinX = Swift.min(groupMinX, nodeMinX[child])
                    groupMinY = Swift.min(groupMinY, nodeMinY[child])
                    groupMaxX = Swift.max(groupMaxX, nodeMaxX[child])
                    groupMaxY = Swift.max(groupMaxY, nodeMaxY[child])
                }
                nodeMinX[writeIndex] = groupMinX
                nodeMinY[writeIndex] = groupMinY
                nodeMaxX[writeIndex] = groupMaxX
                nodeMaxY[writeIndex] = groupMaxY
                offsets[writeIndex] = position
                writeIndex += 1
                position = groupEnd
            }
            levelStart = levelEnd
        }

        self.minX = nodeMinX
        self.minY = nodeMinY
        self.maxX = nodeMaxX
        self.maxY = nodeMaxY
        self.childOffsets = offsets
    }

    /// `CGRect` convenience for callers holding view-layer rectangles. Converts component-wise;
    /// no y flip is applied or implied.
    public init(cgBoxes: [CGRect], nodeSize: Int = PackedRTree.defaultNodeSize) throws {
        try self.init(
            boxes: cgBoxes.map {
                PDFRect(
                    x: Double($0.minX),
                    y: Double($0.minY),
                    width: Double($0.width),
                    height: Double($0.height)
                )
            },
            nodeSize: nodeSize
        )
    }

    // MARK: - Query

    /// Every item whose bounding box intersects `rect`, as indices into the build array.
    ///
    /// The result is a **bounding-box** answer: the caller still has to test the real geometry.
    /// Order is the tree's internal (Hilbert) order, not the build order, because sorting would
    /// dominate the cost of a query that typically returns a handful of items.
    public func query(_ rect: PDFRect) -> [Int] {
        var results: [Int] = []
        query(rect, into: &results)
        return results
    }

    /// Appends matches to an existing buffer, so a hit-test loop can reuse one allocation.
    public func query(_ rect: PDFRect, into results: inout [Int]) {
        var scratch = RTreeSearchScratch()
        query(rect, into: &results, scratch: &scratch)
    }

    /// ``query(_:into:)`` with the traversal stack taken from caller-owned scratch, so a caller
    /// that queries once per pointer event allocates nothing per query once the buffers have
    /// grown (IM-199). Appends to `results` exactly as ``query(_:into:)`` does.
    public func query(_ rect: PDFRect, into results: inout [Int], scratch: inout RTreeSearchScratch) {
        scratch.stack.removeAll(keepingCapacity: true)
        guard itemCount > 0 else { return }
        let box = rect.standardized
        let queryMinX = box.origin.x
        let queryMinY = box.origin.y
        let queryMaxX = queryMinX + box.size.width
        let queryMaxY = queryMinY + box.size.height

        var nodeIndex = minX.count - 1

        while true {
            let end = Swift.min(nodeIndex + nodeSize, levelEnd(containing: nodeIndex))
            for position in nodeIndex..<end {
                if queryMaxX < minX[position] || queryMinX > maxX[position]
                    || queryMaxY < minY[position] || queryMinY > maxY[position] {
                    continue
                }
                if nodeIndex >= itemCount {
                    scratch.stack.append(childOffsets[position])
                } else {
                    results.append(childOffsets[position])
                }
            }
            guard let next = scratch.stack.popLast() else { break }
            nodeIndex = next
        }
    }

    /// `CGRect` convenience.
    public func query(_ rect: CGRect) -> [Int] {
        query(
            PDFRect(
                x: Double(rect.minX),
                y: Double(rect.minY),
                width: Double(rect.width),
                height: Double(rect.height)
            )
        )
    }

    /// The nearest item within `maxDistance`, by distance to its bounding box.
    public func nearest(to point: PDFPoint, maxDistance: Double) -> RTreeNeighbor? {
        nearest(to: point, maxDistance: maxDistance, limit: 1).first
    }

    /// The `limit` nearest items within `maxDistance`, closest first.
    ///
    /// Best-first branch and bound over a binary min-heap keyed on box distance. A node is only
    /// expanded when its box distance is smaller than the current answer, so the search touches
    /// a number of nodes proportional to the local density rather than to the page's primitive
    /// count — which is what makes a 6-point snap radius on a 200 000-primitive page cost the
    /// same as on a 200-primitive one.
    ///
    /// Distances are to the **bounding box**. For a snap the caller refines against the real
    /// primitive geometry, which can only ever increase the distance, so a box-distance
    /// pre-filter never discards a true nearest neighbour.
    public func nearest(to point: PDFPoint, maxDistance: Double, limit: Int) -> [RTreeNeighbor] {
        var results: [RTreeNeighbor] = []
        var scratch = RTreeSearchScratch()
        nearest(to: point, maxDistance: maxDistance, limit: limit, into: &results, scratch: &scratch)
        return results
    }

    /// ``nearest(to:maxDistance:limit:)`` into caller-owned buffers (IM-199).
    ///
    /// `results` is cleared (capacity kept) and filled with exactly what the allocating
    /// overload returns, closest first; the search heap lives in `scratch`. A snap engine that
    /// threads one scratch and one result buffer through every pointer event does no heap
    /// allocation on this path once they have grown to the working size.
    public func nearest(
        to point: PDFPoint,
        maxDistance: Double,
        limit: Int,
        into results: inout [RTreeNeighbor],
        scratch: inout RTreeSearchScratch
    ) {
        results.removeAll(keepingCapacity: true)
        scratch.heap.removeAll()
        guard itemCount > 0, limit > 0, maxDistance.isFinite, maxDistance >= 0,
              point.isFinite else { return }

        let maxSquared = maxDistance * maxDistance
        results.reserveCapacity(Swift.min(limit, itemCount))
        var heap = scratch.heap
        scratch.heap = RTreeSearchHeap()
        defer { scratch.heap = heap }

        heap.push(RTreeSearchHeap.Entry(squaredDistance: 0, nodeIndex: minX.count - 1, isItem: false))

        while let entry = heap.pop() {
            if entry.squaredDistance > maxSquared { break }
            if entry.isItem {
                results.append(
                    RTreeNeighbor(
                        index: entry.nodeIndex,
                        distance: entry.squaredDistance.squareRoot()
                    )
                )
                if results.count == limit { break }
                continue
            }
            let nodeIndex = entry.nodeIndex
            let end = Swift.min(nodeIndex + nodeSize, levelEnd(containing: nodeIndex))
            let isLeafLevel = nodeIndex < itemCount
            for position in nodeIndex..<end {
                let distance = squaredBoxDistance(from: point, to: position)
                guard distance <= maxSquared else { continue }
                heap.push(
                    RTreeSearchHeap.Entry(
                        squaredDistance: distance,
                        nodeIndex: childOffsets[position],
                        isItem: isLeafLevel
                    )
                )
            }
        }
    }

    // MARK: - Internals

    @inline(__always)
    private func squaredBoxDistance(from point: PDFPoint, to position: Int) -> Double {
        let dx = Swift.max(minX[position] - point.x, Swift.max(0, point.x - maxX[position]))
        let dy = Swift.max(minY[position] - point.y, Swift.max(0, point.y - maxY[position]))
        return dx * dx + dy * dy
    }

    /// The exclusive end of the level a node index belongs to. Levels are few (log_16 n, so at
    /// most five for 200 000 items), which is why a linear scan beats a binary search here.
    @inline(__always)
    private func levelEnd(containing nodeIndex: Int) -> Int {
        for end in levelBounds where nodeIndex < end { return end }
        return minX.count
    }
}

/// Reusable buffers for ``PackedRTree`` searches (IM-199): the nearest-neighbour heap and the
/// query traversal stack. Create one per worker, pass it `inout` to the scratch overloads, and
/// the searches stop allocating once the buffers have reached their working size. A scratch
/// carries no results between calls — every search clears it first — so reusing one can never
/// change an answer.
public struct RTreeSearchScratch: Sendable {
    var heap = RTreeSearchHeap()
    var stack: [Int] = []

    public init() {}
}

/// A binary min-heap specialised for the nearest-neighbour search.
///
/// Hand-rolled because `Array.sorted` per push would dominate the search, and because the entry
/// is three words that must stay in a contiguous buffer.
struct RTreeSearchHeap: Sendable {
    struct Entry: Sendable {
        let squaredDistance: Double
        /// For an item entry: the original item index. For a node entry: the node's start slot.
        let nodeIndex: Int
        let isItem: Bool
    }

    private var storage: [Entry] = []

    var isEmpty: Bool { storage.isEmpty }

    /// Buffer capacity, for the reuse test.
    var capacity: Int { storage.capacity }

    mutating func removeAll() { storage.removeAll(keepingCapacity: true) }

    mutating func push(_ entry: Entry) {
        storage.append(entry)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].squaredDistance < storage[parent].squaredDistance else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard let first = storage.first else { return nil }
        let last = storage.removeLast()
        if !storage.isEmpty {
            storage[0] = last
            var parent = 0
            let count = storage.count
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < count,
                   storage[left].squaredDistance < storage[smallest].squaredDistance {
                    smallest = left
                }
                if right < count,
                   storage[right].squaredDistance < storage[smallest].squaredDistance {
                    smallest = right
                }
                if smallest == parent { break }
                storage.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return first
    }
}
