import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

@Suite("Packed R-tree (spec 13.5)")
struct PackedRTreeTests {

    private func grid(_ side: Int, cell: Double = 10, size: Double = 4) -> [PDFRect] {
        var boxes: [PDFRect] = []
        boxes.reserveCapacity(side * side)
        for row in 0..<side {
            for column in 0..<side {
                boxes.append(
                    PDFRect(
                        x: Double(column) * cell,
                        y: Double(row) * cell,
                        width: size,
                        height: size
                    )
                )
            }
        }
        return boxes
    }

    // MARK: - Correctness

    @Test("An empty tree answers everything with nothing")
    func emptyTree() throws {
        let tree = try PackedRTree(boxes: [])
        #expect(tree.isEmpty)
        #expect(tree.bounds == nil)
        #expect(tree.query(PDFRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        #expect(tree.nearest(to: .zero, maxDistance: 1000) == nil)
    }

    @Test("A single-item tree is its own root")
    func singleItem() throws {
        let box = PDFRect(x: 5, y: 5, width: 2, height: 2)
        let tree = try PackedRTree(boxes: [box])
        #expect(tree.count == 1)
        #expect(tree.query(PDFRect(x: 0, y: 0, width: 100, height: 100)) == [0])
        #expect(tree.query(PDFRect(x: 100, y: 100, width: 1, height: 1)).isEmpty)
        let hit = try #require(tree.nearest(to: PDFPoint(x: 5, y: 0), maxDistance: 100))
        #expect(hit.index == 0)
        #expect(abs(hit.distance - 5) < 1e-12)
    }

    @Test("Query matches brute force on every node-size boundary", arguments: [2, 3, 4, 16, 64])
    func queryMatchesBruteForce(nodeSize: Int) throws {
        let boxes = grid(23)
        let tree = try PackedRTree(boxes: boxes, nodeSize: nodeSize)
        #expect(tree.count == boxes.count)

        var generator = SplitMix64(seed: 42)
        for _ in 0..<200 {
            let x = generator.nextDouble(in: -20...250)
            let y = generator.nextDouble(in: -20...250)
            let width = generator.nextDouble(in: 0...60)
            let height = generator.nextDouble(in: 0...60)
            let query = PDFRect(x: x, y: y, width: width, height: height)
            let expected = Set(boxes.indices.filter { boxes[$0].intersects(query) })
            #expect(Set(tree.query(query)) == expected)
        }
    }

    @Test("Nearest matches brute force, honours maxDistance and returns k in order")
    func nearestMatchesBruteForce() throws {
        let boxes = grid(19)
        let tree = try PackedRTree(boxes: boxes)

        func bruteForce(_ point: PDFPoint) -> [(Int, Double)] {
            boxes.indices.map { index -> (Int, Double) in
                let box = boxes[index]
                let dx = Swift.max(box.minX - point.x, Swift.max(0, point.x - box.maxX))
                let dy = Swift.max(box.minY - point.y, Swift.max(0, point.y - box.maxY))
                return (index, (dx * dx + dy * dy).squareRoot())
            }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        }

        var generator = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let point = PDFPoint(
                x: generator.nextDouble(in: -30...220),
                y: generator.nextDouble(in: -30...220)
            )
            let expected = bruteForce(point)
            let hit = try #require(tree.nearest(to: point, maxDistance: .greatestFiniteMagnitude))
            #expect(abs(hit.distance - expected[0].1) < 1e-9)

            let five = tree.nearest(to: point, maxDistance: .greatestFiniteMagnitude, limit: 5)
            #expect(five.count == 5)
            for (index, neighbour) in five.enumerated() {
                #expect(abs(neighbour.distance - expected[index].1) < 1e-9)
            }
            #expect(zip(five, five.dropFirst()).allSatisfy { $0.distance <= $1.distance })
        }

        // maxDistance is respected exactly.
        let far = PDFPoint(x: 10_000, y: 10_000)
        #expect(tree.nearest(to: far, maxDistance: 100) == nil)
        #expect(tree.nearest(to: far, maxDistance: .greatestFiniteMagnitude) != nil)
    }

    @Test("A point inside a box is at distance zero")
    func insideBoxIsZeroDistance() throws {
        let tree = try PackedRTree(boxes: grid(5))
        let hit = try #require(tree.nearest(to: PDFPoint(x: 21, y: 21), maxDistance: 10))
        #expect(hit.distance == 0)
    }

    @Test("Degenerate input: identical boxes, zero-size boxes, one column")
    func degenerateInput() throws {
        let identical = [PDFRect](repeating: PDFRect(x: 3, y: 3, width: 1, height: 1), count: 100)
        let tree = try PackedRTree(boxes: identical)
        #expect(tree.query(PDFRect(x: 3, y: 3, width: 0, height: 0)).count == 100)

        let points = (0..<50).map { PDFRect(x: 0, y: Double($0), width: 0, height: 0) }
        let column = try PackedRTree(boxes: points)
        #expect(column.query(PDFRect(x: -1, y: -1, width: 2, height: 60)).count == 50)
        let hit = try #require(column.nearest(to: PDFPoint(x: 5, y: 25), maxDistance: 10))
        #expect(abs(hit.distance - 5) < 1e-12)
    }

    @Test("Bad node sizes and non-finite boxes throw")
    func invalidInput() {
        #expect(throws: GeometryError.invalidNodeSize(1)) {
            _ = try PackedRTree(boxes: [PDFRect.zero], nodeSize: 1)
        }
        #expect(throws: GeometryError.nonFiniteBounds(index: 1)) {
            _ = try PackedRTree(boxes: [
                PDFRect(x: 0, y: 0, width: 1, height: 1),
                PDFRect(x: .nan, y: 0, width: 1, height: 1)
            ])
        }
    }

    @Test("The build is deterministic for identical input")
    func deterministicBuild() throws {
        var generator = SplitMix64(seed: 99)
        let boxes = (0..<5000).map { _ -> PDFRect in
            PDFRect(
                x: generator.nextDouble(in: 0...1000),
                y: generator.nextDouble(in: 0...1000),
                width: generator.nextDouble(in: 0...5),
                height: generator.nextDouble(in: 0...5)
            )
        }
        let first = try PackedRTree(boxes: boxes)
        let second = try PackedRTree(boxes: boxes)
        let query = PDFRect(x: 100, y: 100, width: 50, height: 50)
        #expect(first.query(query) == second.query(query))
    }

    @Test("CGRect overloads convert component-wise without a flip")
    func cgRectBridging() throws {
        let tree = try PackedRTree(cgBoxes: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        #expect(tree.query(CGRect(x: 5, y: 5, width: 1, height: 1)) == [0])
        #expect(tree.bounds == PDFRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("Benchmark: 200 000 primitives, build time and query p95", .timeLimit(.minutes(2)))
    func benchmark() throws {
        let primitiveCount = 200_000
        let queryCount = 10_000
        let pageWidth = 3370.0   // A0 landscape in points
        let pageHeight = 2384.0

        var generator = SplitMix64(seed: 0x5EED)
        var boxes: [PDFRect] = []
        boxes.reserveCapacity(primitiveCount)
        for _ in 0..<primitiveCount {
            let x = generator.nextDouble(in: 0...pageWidth)
            let y = generator.nextDouble(in: 0...pageHeight)
            // Most PDF vector primitives are short strokes; a few are long ones.
            let long = generator.nextDouble(in: 0...1) < 0.02
            let width = generator.nextDouble(in: 0...(long ? 400 : 8))
            let height = generator.nextDouble(in: 0...(long ? 400 : 8))
            boxes.append(PDFRect(x: x, y: y, width: width, height: height))
        }

        let clock = ContinuousClock()
        var tree: PackedRTree?
        let buildDuration = try clock.measure {
            tree = try PackedRTree(boxes: boxes)
        }
        let index = try #require(tree)
        #expect(index.count == primitiveCount)

        // A snap-radius sized window, which is the query the hit tester actually issues.
        var queryGenerator = SplitMix64(seed: 0xB0B)
        var queryRects: [PDFRect] = []
        queryRects.reserveCapacity(queryCount)
        for _ in 0..<queryCount {
            let x = queryGenerator.nextDouble(in: 0...pageWidth)
            let y = queryGenerator.nextDouble(in: 0...pageHeight)
            queryRects.append(PDFRect(x: x - 6, y: y - 6, width: 12, height: 12))
        }

        var durations = [Double](repeating: 0, count: queryCount)
        var totalHits = 0
        var buffer: [Int] = []
        buffer.reserveCapacity(256)
        for position in 0..<queryCount {
            buffer.removeAll(keepingCapacity: true)
            let elapsed = clock.measure {
                index.query(queryRects[position], into: &buffer)
            }
            durations[position] = Double(elapsed.components.attoseconds) / 1e18
                + Double(elapsed.components.seconds)
            totalHits += buffer.count
        }
        durations.sort()
        let p50 = durations[queryCount / 2]
        let p95 = durations[Int(Double(queryCount) * 0.95)]
        let p99 = durations[Int(Double(queryCount) * 0.99)]

        var nearestDurations = [Double](repeating: 0, count: queryCount)
        for position in 0..<queryCount {
            let centre = PDFPoint(
                x: queryRects[position].midX,
                y: queryRects[position].midY
            )
            let elapsed = clock.measure {
                _ = index.nearest(to: centre, maxDistance: 24)
            }
            nearestDurations[position] = Double(elapsed.components.attoseconds) / 1e18
                + Double(elapsed.components.seconds)
        }
        nearestDurations.sort()
        let nearestP95 = nearestDurations[Int(Double(queryCount) * 0.95)]

        let buildSeconds = Double(buildDuration.components.attoseconds) / 1e18
            + Double(buildDuration.components.seconds)

        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("""

        PackedRTree benchmark (\(configuration) build, \(primitiveCount) primitives, node size \
        \(PackedRTree.defaultNodeSize))
          build            : \(String(format: "%.1f", buildSeconds * 1000)) ms
          query x\(queryCount)   : p50 \(String(format: "%.1f", p50 * 1e6)) us, \
        p95 \(String(format: "%.1f", p95 * 1e6)) us, p99 \(String(format: "%.1f", p99 * 1e6)) us
          nearest x\(queryCount) : p95 \(String(format: "%.1f", nearestP95 * 1e6)) us
          mean hits/query  : \(String(format: "%.2f", Double(totalHits) / Double(queryCount)))

        """)

        // Loose ceilings: these guard against an algorithmic regression (a linear scan would be
        // three orders of magnitude slower), not against machine-to-machine variation.
        #expect(buildSeconds < 30)
        #expect(p95 < 0.01)
        #expect(totalHits > 0)
    }
}
