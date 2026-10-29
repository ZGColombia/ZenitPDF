import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// BH-060 / BH-327: one finite but absurd coordinate made the dense slot array unbounded.
///
/// The scanner keeps any finite coordinate, and a segment with one end on the sheet
/// survives the crop-box filter, so a hostile `l` to `x = 1e30` reaches the query engine.
/// The grid grew its cells by doubling at most 64 times; a span of `1e30` needs about 90
/// doublings from a 301 pt reach, so the loop gave up with both axes clamped to
/// 4 000 000 cells and allocated `4e6 × 4e6 × 120 + 1` `Int32`s — a petabyte, a trap.
/// Between roughly `1e10` and that point the loop fitted, but with the entire real
/// drawing collapsed into one cell, so the "linear" query was `n²`.
///
/// Every expected value is derived by hand beside it (`QUALITY_BAR` 2.6).
struct SegmentGridHostileExtentTests {

    static func segment(_ id: UInt64, _ a: CGPoint, _ b: CGPoint) -> GeometryQuerySegment {
        GeometryQuerySegment(primitiveID: id, start: a, end: b)
    }

    /// Two horizontal walls 300 apart, plus one diagonal to `(far, far)` from on the sheet.
    static func scene(far: Double) -> [GeometryQuerySegment] {
        [
            segment(1, CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)),
            segment(2, CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)),
            segment(3, CGPoint(x: 10, y: 10), CGPoint(x: far, y: far))
        ]
    }

    @Test(
        "A segment reaching 1e25, 1e28 or 1e30 neither traps nor collapses the sheet into one cell (BH-060, BH-327)",
        arguments: [1e25, 1e28, 1e30, 1e300]
    )
    func absurdCoordinateIsClampedNotIndexed(far: Double) throws {
        let segments = Self.scene(far: far)
        let angles = segments.map(\.lineAngle)
        // gap 300 + tolerance 1 = reach 301; the default 1.5° gives π / (1.5π/180) = 120
        // angle buckets exactly.
        let grid = GeometrySegmentGrid(
            segments: segments, angles: angles, reach: 301,
            angleToleranceRadians: 1.5 * .pi / 180
        )
        // Old output at 1e30: a trap allocating 4e6 × 4e6 × 120 + 1 Int32 slots
        // (7.7 PB). At 1e25: 3 603 × 3 603 × 120 = 1.56e9 slots, two 6.2 GB arrays, and
        // both real walls in cell (0, 0) alongside the diagonal.
        //
        // The robust extent drops the single outlying endpoint on each axis, so the
        // grid covers x ∈ [0, 400], y ∈ [0, 300] at the reach as cell size:
        // columns = ⌊400 / 301⌋ + 1 = 2, rows = ⌊300 / 301⌋ + 1 = 1.
        #expect(grid.bucketCount == 120)
        #expect(grid.cellSize == 301)
        #expect(grid.columns == 2)
        #expect(grid.rows == 1)
        #expect(grid.slotStart.count == 2 * 1 * 120 + 1)
        // Each wall runs x = 0…400 over cells of 301, so it crosses columns 0 and 1; the
        // diagonal's far end clamps into column 1 of row 0, so it too is in both columns
        // of its row rather than nowhere: 2 + 2 + 2 entries.
        #expect(grid.entries.count == 2 + 2 + 2)

        // Through the public query: the two walls pair, the diagonal pairs with nothing.
        let engine = try GeometryQueryEngine(segments: segments)
        let result = engine.parallelPairs(gap: 300, tolerance: 1)
        #expect(result.status == .complete)
        #expect(result.count == 1)
        #expect(result.matches.first?.firstPrimitiveID == 1)
        #expect(result.matches.first?.secondPrimitiveID == 2)
    }

    @Test("A sheet with no outlier is indexed at the reach as before")
    func ordinarySheetIsUnchanged() {
        // Non-vacuity for the robust extent: with every endpoint on the sheet the grid
        // covers the full extent, x ∈ [0, 400], y ∈ [0, 300], at cell size 301.
        let segments = Array(Self.scene(far: 100).prefix(2))
        let grid = GeometrySegmentGrid(
            segments: segments, angles: segments.map(\.lineAngle), reach: 301,
            angleToleranceRadians: 1.5 * .pi / 180
        )
        #expect(grid.cellSize == 301)
        #expect(grid.columns == 2)
        #expect(grid.rows == 1)
        #expect(grid.originX == 0 && grid.originY == 0)
    }

    @Test("Outliers spread over every scale still terminate with a bounded slot array")
    func outliersAtEveryScaleStillFit() throws {
        // Ten segments whose far ends sit at 1e3, 1e6, …, 1e30: no percentile trim can
        // exclude them all, so the doubling must run past 64 steps until the index
        // fits. It terminates because a span over an infinite cell size is one cell.
        var segments: [GeometryQuerySegment] = []
        for (index, exponent) in stride(from: 3, through: 30, by: 3).enumerated() {
            let far = pow(10.0, Double(exponent))
            segments.append(Self.segment(UInt64(index + 1), CGPoint(x: 0, y: Double(index)), CGPoint(x: far, y: Double(index))))
        }
        let grid = GeometrySegmentGrid(
            segments: segments, angles: segments.map(\.lineAngle), reach: 301,
            angleToleranceRadians: 1.5 * .pi / 180
        )
        #expect(grid.slotStart.count <= GeometrySegmentGrid.maximumSlotCount + 1)
        let engine = try GeometryQueryEngine(segments: segments)
        let result = engine.parallelPairs(gap: 1, tolerance: 0.5, minimumOverlap: 100)
        // Every consecutive pair is 1 apart and overlaps for at least 1e3: 9 pairs.
        #expect(result.status == .complete)
        #expect(result.count == 9)
    }
}
