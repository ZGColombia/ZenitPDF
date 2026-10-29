import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Iteration 4, U-082: Find Walls lists doors and windows as
/// openings, never the gap between two unrelated collinear walls or the place where a thinner
/// wall crosses a thicker one. All plans at 100 pt = 1 m.
@Suite("Iter4 wall openings")
struct Iter4WallOpeningTests {

    private static func takeoff(_ lines: [(Double, Double, Double, Double)]) -> WallCentrelineEngine.Takeoff {
        let segments = lines.enumerated().map { index, line in
            GeometryQuerySegment(primitiveID: UInt64(index + 1), sourceObjectID: UInt64(index + 1),
                                 start: CGPoint(x: line.0, y: line.1), end: CGPoint(x: line.2, y: line.3), strokeWidth: 0.5)
        }
        return WallCentrelineEngine(segments: segments, options: .calibrated(pointsPerMetre: 100)).takeoff()
    }

    @Test("U-082: two collinear 200 mm walls 5 m apart are two runs and no opening")
    func collinearWallsFarApart() throws {
        // Wall A x 0…300, wall B x 800…1100, faces at y 100 and 120.
        let result = Self.takeoff([
            (0, 100, 300, 100), (0, 120, 300, 120),
            (800, 100, 1_100, 100), (800, 120, 1_100, 120),
        ])
        let wall = try #require(result.classes.first)
        #expect(result.classes.count == 1 && abs(wall.thicknessPoints - 20) < 0.01)
        // Hand takeoff: 300 + 300 = 600 pt in two runs; the 500 pt gap is 5 m, wider than any door.
        #expect(abs(wall.lengthPoints - 600) < 1e-6, "\(wall.lengthPoints)")
        #expect(wall.centrelines.count == 2)
        // Old output: openings [500 pt at (550, 110)] — "(1 opening left out)".
        #expect(wall.openings.isEmpty, "\(wall.openings)")
    }

    @Test("U-082: a 100 mm partition crossing a 200 mm wall is a junction, not a 0.2 m opening")
    func thinWallCrossesThickWall() throws {
        // The 200 mm wall runs through, faces y 100 and 120 from x 0 to 1000. The 100 mm
        // partition's faces x 495 and 505 stop at the wall's faces: y −200…100 and 120…420.
        let result = Self.takeoff([
            (0, 100, 1_000, 100), (0, 120, 1_000, 120),
            (495, -200, 495, 100), (505, -200, 505, 100),
            (495, 120, 495, 420), (505, 120, 505, 420),
        ])
        #expect(result.classes.map { ($0.thicknessPoints * 100).rounded() / 100 } == [10, 20])
        let partition = try #require(result.classes.first { abs($0.thicknessPoints - 10) < 0.01 })
        let wall = try #require(result.classes.first { abs($0.thicknessPoints - 20) < 0.01 })
        // Old output: the partition listed one opening of 20 pt (0.2 m) at (500, 110), since its
        // 20 pt gap is wider than its 15 pt junction gap.
        #expect(partition.openings.isEmpty, "\(partition.openings)")
        #expect(wall.openings.isEmpty)
        // Lengths are unchanged: 300 + 300 pt of partition in two runs, 1000 pt of wall.
        #expect(abs(partition.lengthPoints - 600) < 1e-6 && partition.centrelines.count == 2)
        #expect(abs(wall.lengthPoints - 1_000) < 1e-6)
    }

    @Test("U-082: a 0.90 m door right beside a T-junction lists the door's own width")
    func doorBesideATJunction() throws {
        // A 200 mm wall, faces y 100 and 120, x 0…1000. A 100 mm partition (faces x 495 and 505)
        // stops at its upper face y = 120 and runs to y = 420. A 90 pt door x 505…595 goes through
        // both faces, and the upper face is also broken where the partition meets it (495…505).
        let result = Self.takeoff([
            (0, 100, 505, 100), (595, 100, 1_000, 100),
            (0, 120, 495, 120), (595, 120, 1_000, 120),
            (495, 120, 495, 420), (505, 120, 505, 420),
        ])
        let wall = try #require(result.classes.first { abs($0.thicknessPoints - 20) < 0.01 })
        // The wall's midline breaks from x 495 to 595: 10 pt of partition footprint, 90 pt of door.
        // Old output: one opening of 100 pt centred at x 545.
        #expect(wall.openings.count == 1, "\(wall.openings)")
        let door = try #require(wall.openings.first)
        #expect(abs(door.widthPoints - 90) < 1e-6, "\(door.widthPoints)")
        #expect(abs(door.midpoint.x - 550) < 1e-6 && abs(door.midpoint.y - 110) < 1e-6)
    }

    @Test("U-082: a door of 3 m is still an opening; 3.1 m is two walls")
    func openingWidthLimit() throws {
        func openings(gap: Double) throws -> [WallCentrelineEngine.Opening] {
            let result = Self.takeoff([
                (0, 100, 300, 100), (0, 120, 300, 120),
                (300 + gap, 100, 600 + gap, 100), (300 + gap, 120, 600 + gap, 120),
            ])
            return try #require(result.classes.first).openings
        }
        let widest = try openings(gap: 300)
        #expect(widest.count == 1 && abs((widest.first?.widthPoints ?? 0) - 300) < 1e-9)
        #expect(try openings(gap: 310).isEmpty)
    }
}
