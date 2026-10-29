import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// CR-47: the grid walker's row/column advance was unclamped.
///
/// `index(_:origin:size:limit:)` clamps an endpoint's cell to the grid, but the crossing
/// parameters the walk steps by are computed from the raw coordinates. An endpoint a hair
/// past a boundary that the clamp folds into the last cell therefore leaves the walk one
/// step to take that the end cell does not, and the step names a cell outside the grid —
/// which, in the build passes, is an index past the end of `counts` and a trap.
struct SegmentGridWalkerTests {

    static func segment(_ id: UInt64, _ a: CGPoint, _ b: CGPoint) -> GeometryQuerySegment {
        GeometryQuerySegment(
            primitiveID: id, parentID: nil, sourceObjectID: id, start: a, end: b,
            strokeWidth: 1, confidence: 1, layerID: nil
        )
    }

    /// The cells one walk names, and whether every one of them is inside the grid.
    static func walk(
        _ walker: GeometrySegmentGrid.Walker, _ segment: GeometryQuerySegment
    ) -> (cells: [Int], allInside: Bool) {
        var cells: [Int] = []
        walker.visit(segment) { cells.append($0) }
        let inside = cells.allSatisfy { $0 >= 0 && $0 < walker.columns * walker.rows }
        return (cells, inside)
    }

    @Test("A segment straddling a row boundary in a one-row grid stays inside the grid (CR-47)")
    func rowBoundaryStraddleStaysInside() {
        // Found by the search below on the unclamped walker: origin (12.5, 0), cell 7.25,
        // 9 × 1 cells. Both endpoints sit within 1e-13 of y = 7.25, the boundary of a row
        // the grid does not have, on opposite sides of it. The bit patterns are exact.
        let p = CGPoint(
            x: Double(bitPattern: 4_634_098_463_447_973_888),
            y: Double(bitPattern: 4_619_848_792_751_996_112)
        )
        let q = CGPoint(
            x: Double(bitPattern: 4_631_037_423_076_244_920),
            y: Double(bitPattern: 4_619_848_792_751_996_930)
        )
        let walker = GeometrySegmentGrid.Walker(
            originX: 12.5, originY: 0, cellSize: 7.25, columns: 9, rows: 1
        )
        let result = Self.walk(walker, Self.segment(1, p, q))
        // Old output: the second cell named was 13, in a grid of 9.
        #expect(result.allInside, "cells named: \(result.cells)")
        #expect(result.cells.first == 7)
        let endCell = walker.clampedRow(q.y) * walker.columns + walker.clampedColumn(q.x)
        #expect(result.cells.last == endCell)
    }

    @Test("Across boundary-hugging segments the walk never names a cell outside the grid")
    func boundaryHuggingSegmentsStayInside() {
        // Deterministic LCG so a failure is reproducible from its trial number.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let ulp = 1.0.ulp
        let nudges = [0.0, ulp, -ulp, 1e-13, -1e-13, 1e-9, -1e-9]
        var failures: [String] = []
        for trial in 0..<50_000 {
            let cellSize = [1.0, 0.5, 3.0, 7.25, 0.1][trial % 5]
            let columns = 1 + Int(next() * 12)
            let rows = 1 + Int(next() * 12)
            let originX = [0.0, -100.0, 12.5, 1e6][trial % 4]
            let originY = [0.0, 33.0, -7.75, 2.5e5][(trial / 4) % 4]
            let walker = GeometrySegmentGrid.Walker(
                originX: originX, originY: originY, cellSize: cellSize, columns: columns, rows: rows
            )
            func cornerish() -> CGPoint {
                let cx = Double(Int(next() * Double(columns + 1)))
                let cy = Double(Int(next() * Double(rows + 1)))
                let x = originX + cx * cellSize
                let y = originY + cy * cellSize
                return CGPoint(
                    x: x + nudges[Int(next() * 7)] * Swift.max(1, abs(x)),
                    y: y + nudges[Int(next() * 7)] * Swift.max(1, abs(y))
                )
            }
            let p = cornerish()
            let q = cornerish()
            let result = Self.walk(walker, Self.segment(UInt64(trial), p, q))
            if !result.allInside {
                failures.append("trial \(trial): p \(p) q \(q) grid \(columns)x\(rows) cell \(cellSize)")
            }
            // The walk must also still reach the end cell: a clamp that stops early would
            // leave part of the segment unindexed.
            let endCell = walker.clampedRow(q.y) * columns + walker.clampedColumn(q.x)
            if !result.cells.contains(endCell) {
                failures.append("trial \(trial): end cell \(endCell) not visited: \(result.cells)")
            }
        }
        // Old output: the first failure at trial 18 (the case above), 9 in 50 000 trials.
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test("The index built over a straddling segment answers a query rather than trapping")
    func gridBuildsOverStraddlingSegment() throws {
        // The same two endpoints, through the public engine: the grid's two build passes
        // index `counts[cell * buckets + bucket + 1]`, so a cell past the grid was a trap.
        let p = CGPoint(
            x: Double(bitPattern: 4_634_098_463_447_973_888),
            y: Double(bitPattern: 4_619_848_792_751_996_112)
        )
        let q = CGPoint(
            x: Double(bitPattern: 4_631_037_423_076_244_920),
            y: Double(bitPattern: 4_619_848_792_751_996_930)
        )
        let engine = try GeometryQueryEngine(
            segments: [Self.segment(1, p, q), Self.segment(2, CGPoint(x: 12.5, y: 0), CGPoint(x: 77.75, y: 0))],
            curves: []
        )
        let pairs = engine.parallelPairs(gap: 7.25, tolerance: 0.1, angleToleranceDegrees: 1)
        #expect(!pairs.wasRejected)
    }
}
