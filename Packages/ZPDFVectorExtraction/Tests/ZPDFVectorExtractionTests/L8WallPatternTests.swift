import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// L-74 (live test 8): Find Walls on a real roof plan listed every parallel-line spacing on the
/// sheet as a "wall" class, hatching and outlines among them. A class now says how much of its facing length repeats on both sides —
/// the mark of an evenly spaced pattern rather than a band of wall.
@Suite("L-74: wall classes that repeat like a pattern")
struct L8WallPatternTests {

    /// The 250 mm / 150 mm plan of `WallCentrelineTests`, plus a hatch of 20 parallel lines,
    /// 300 pt long and 10 pt (100 mm) apart, at x = 1200…1500, y = 0…190, clear of the walls.
    static func planWithHatch() -> [GeometryQuerySegment] {
        var segments = WallCentrelineTests.plan()
        for index in 0..<20 {
            let id = UInt64(1000 + index)
            let y = Double(index) * 10
            segments.append(GeometryQuerySegment(primitiveID: id, sourceObjectID: id, start: CGPoint(x: 1200, y: y),
                                                 end: CGPoint(x: 1500, y: y), strokeWidth: 0.25))
        }
        return segments
    }

    @Test("The walls repeat nowhere; the hatch repeats at its spacing and every multiple of it")
    func hatchClassesRepeatWallsDoNot() {
        let classes = WallCentrelineEngine(segments: Self.planWithHatch(), options: .calibrated(pointsPerMetre: 100)).takeoff().classes
        // Hand-derived classes: the walls at 15 and 25 pt; the hatch at k × 10 pt for every k with
        // k × 10 inside 5…60 pt (50…600 mm) — 10, 20, 30, 40, 50, 60 — each with (20 − k) pairs of
        // 300 pt, far over the 200 pt a class needs.
        #expect(classes.map { ($0.thicknessPoints * 100).rounded() / 100 } == [10, 15, 20, 25, 30, 40, 50, 60])
        for wall in classes {
            let thickness = (wall.thicknessPoints * 100).rounded() / 100
            if thickness == 15 || thickness == 25 {
                // No face of either wall has a line at the wall's thickness on its room side.
                #expect(wall.repeatingShare == 0, "\(thickness): \(wall.repeatingShare)")
                #expect(wall.isLikelyWall)
            } else {
                // At k × 10 pt the pairs are (i, i + k), i = 0…19 − k. Line j faces both ways when
                // k ≤ j ≤ 19 − k; a pair repeats when either of its lines does, which leaves out
                // only i with 19 − 2k < i < k — none for k ≤ 6. Every pair repeats over its whole
                // 300 pt: the share is exactly 1.
                #expect(abs(wall.repeatingShare - 1) < 1e-12, "\(thickness): \(wall.repeatingShare)")
                #expect(!wall.isLikelyWall)
            }
        }
    }

    @Test("A long wall with one short parallel line at its thickness beside it still reads as a wall")
    func wallWithAWorktopEdgeIsStillAWall() {
        // A 150 mm wall, faces y = 0 and y = 15, 10 m long (x = 0…1000 at 100 pt = 1 m), and a
        // 1 m worktop edge 15 pt beyond its upper face (y = 30, x = 400…500).
        func segment(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GeometryQuerySegment {
            GeometryQuerySegment(primitiveID: id, sourceObjectID: id, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1), strokeWidth: 0.5)
        }
        let segments = [segment(1, 0, 0, 1000, 0), segment(2, 0, 15, 1000, 15), segment(3, 400, 30, 500, 30)]
        let classes = WallCentrelineEngine(segments: segments, options: .calibrated(pointsPerMetre: 100)).takeoff().classes
        // Hand-derived: one class at 15 pt from two pairs, faces (1000 pt) and upper face–worktop
        // (100 pt); the 30 pt pair of the lower face and the worktop faces 100 pt, under the
        // 200 pt a class needs. The upper face faces 1000 pt down and 100 pt up, so both ways
        // over min(1000, 100) = 100 pt; each pair repeats by min(its overlap, 100):
        // (100 + 100) / (1000 + 100) = 0.1818…, under the 0.25 bound.
        #expect(classes.count == 1)
        let wall = classes.first
        #expect(abs((wall?.thicknessPoints ?? 0) - 15) < 1e-9)
        #expect(abs((wall?.repeatingShare ?? -1) - 200.0 / 1100.0) < 1e-12, "\(wall?.repeatingShare ?? -1)")
        #expect(wall?.isLikelyWall == true)
    }
}
