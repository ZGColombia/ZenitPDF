import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// IM-199: scratch-buffer overloads of PackedRTree.nearest and query, for the snap engine.
@Suite("PackedRTree scratch overloads (IM-199)")
struct RTreeScratchTests {

    static func tree(seed: UInt64, count: Int) throws -> (PackedRTree, [PDFRect]) {
        var state = seed
        func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let boxes = (0..<count).map { _ -> PDFRect in
            let x = unit() * 1000, y = unit() * 1000
            return PDFRect(corner: PDFPoint(x: x, y: y), opposite: PDFPoint(x: x + unit() * 20, y: y + unit() * 20))
        }
        return (try PackedRTree(boxes: boxes), boxes)
    }

    @Test("IM-199: scratch overloads return exactly what the allocating overloads return")
    func scratchOverloadsAreEquivalent() throws {
        let (tree, _) = try Self.tree(seed: 199, count: 5_000)
        var scratch = RTreeSearchScratch()
        var neighbours: [RTreeNeighbor] = [RTreeNeighbor(index: -1, distance: -1)]  // stale content must be cleared
        var hits: [Int] = []
        var state: UInt64 = 7
        for _ in 0..<500 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let x = Double(state >> 40) / Double(1 << 24) * 1000
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let y = Double(state >> 40) / Double(1 << 24) * 1000
            let point = PDFPoint(x: x, y: y)
            for limit in [1, 8, 512] {
                tree.nearest(to: point, maxDistance: 30, limit: limit, into: &neighbours, scratch: &scratch)
                #expect(neighbours == tree.nearest(to: point, maxDistance: 30, limit: limit))
            }
            let probe = PDFRect(corner: PDFPoint(x: x - 15, y: y - 15), opposite: PDFPoint(x: x + 15, y: y + 15))
            hits.removeAll(keepingCapacity: true)
            tree.query(probe, into: &hits, scratch: &scratch)
            #expect(hits == tree.query(probe))
        }
        // Invalid input clears the buffer, like the allocating overload's empty answer.
        tree.nearest(to: PDFPoint(x: 1, y: 1), maxDistance: -1, limit: 4, into: &neighbours, scratch: &scratch)
        #expect(neighbours.isEmpty)
    }

    @Test("IM-199: after warm-up the scratch buffers are reused, not reallocated")
    func scratchBuffersAreReused() throws {
        let (tree, _) = try Self.tree(seed: 99, count: 20_000)
        var scratch = RTreeSearchScratch()
        var neighbours: [RTreeNeighbor] = []
        let point = PDFPoint(x: 500, y: 500)
        tree.nearest(to: point, maxDistance: 40, limit: 512, into: &neighbours, scratch: &scratch)
        let heapCapacity = scratch.heap.capacity
        let resultCapacity = neighbours.capacity
        #expect(heapCapacity > 0)
        for _ in 0..<100 {
            tree.nearest(to: point, maxDistance: 40, limit: 512, into: &neighbours, scratch: &scratch)
        }
        // The same search never needs more room, so the storage it grew on the first call is
        // the storage every later call runs in.
        #expect(scratch.heap.capacity == heapCapacity)
        #expect(neighbours.capacity == resultCapacity)
    }
}
