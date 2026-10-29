import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// NL-AUTO-20: wall takeoff from parallel pairs, against a hand centreline takeoff.
///
/// The plan, at 100 pt = 1 m: a 10 m × 6 m building with 250 mm outer walls (outer face
/// (0,0)–(1000,600), inner face 25 pt in, broken where the partition meets it, as a CAD plan
/// draws it) and one 150 mm partition at x = 492.5…507.5 from face to face, with a 0.90 m door
/// (the faces stop at y = 250 and resume at y = 340).
///
/// Hand takeoff, centreline method, walls that meet at an L-corner joined at the corner, a wall
/// that stops against another stopped at its face:
/// - 250 mm class: the centreline rectangle (12.5,12.5)–(987.5,587.5), perimeter
///   2 × (975 + 575) = 3100 pt = **31.00 m**, no opening.
/// - 150 mm class: (250 − 25) + (575 − 340) = 225 + 235 = 460 pt = **4.60 m**, one opening of
///   90 pt = **0.90 m** excluded and listed.
@Suite("Wall centrelines from parallel pairs — NL-AUTO-20")
struct WallCentrelineTests {

    static func plan() -> [GeometryQuerySegment] {
        var id: UInt64 = 0
        var segments: [GeometryQuerySegment] = []
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            id += 1
            segments.append(GeometryQuerySegment(primitiveID: id, sourceObjectID: id, start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1), strokeWidth: 0.5))
        }
        // Outer face.
        line(0, 0, 1000, 0); line(1000, 0, 1000, 600); line(1000, 600, 0, 600); line(0, 600, 0, 0)
        // Inner face, broken at the partition top and bottom.
        line(25, 25, 492.5, 25); line(507.5, 25, 975, 25)
        line(975, 25, 975, 575)
        line(975, 575, 507.5, 575); line(492.5, 575, 25, 575)
        line(25, 575, 25, 25)
        // Partition faces with the door gap.
        line(492.5, 25, 492.5, 250); line(492.5, 340, 492.5, 575)
        line(507.5, 25, 507.5, 250); line(507.5, 340, 507.5, 575)
        return segments
    }

    static let engine = WallCentrelineEngine(segments: plan(), options: .calibrated(pointsPerMetre: 100))

    @Test("Two classes are found: 150 mm and 250 mm")
    func classes() {
        let classes = Self.engine.takeoff().classes.map(\.thicknessPoints)
        #expect(classes.count == 2)
        #expect(abs(classes[0] - 15) < 0.01)
        #expect(abs(classes[1] - 25) < 0.01)
    }

    @Test("The 250 mm class is the 31.00 m centreline perimeter, one closed chain, no opening")
    func outerWalls() throws {
        let walls = Self.engine.takeoff().classes
        let outer = try #require(walls.first { abs($0.thicknessPoints - 25) < 0.01 })
        #expect(abs(outer.lengthPoints - 3100) / 3100 < 0.005, "hand takeoff 3100 pt, got \(outer.lengthPoints)")
        #expect(abs(outer.lengthPoints - 3100) < 1e-6, "exact on this plan")
        #expect(outer.openings.isEmpty)
        #expect(outer.centrelines.count == 1)
        let loop = try #require(outer.centrelines.first)
        #expect(loop.count == 5 && loop.first == loop.last, "one closed loop of four corners")
        let xs = Set(loop.map { ($0.x * 10).rounded() / 10 }), ys = Set(loop.map { ($0.y * 10).rounded() / 10 })
        #expect(xs == [12.5, 987.5] && ys == [12.5, 587.5], "corners on the centreline rectangle")
    }

    @Test("The 150 mm class is 4.60 m, stopped at the outer walls' faces, with the 0.90 m door excluded and listed")
    func partition() throws {
        let walls = Self.engine.takeoff().classes
        let partition = try #require(walls.first { abs($0.thicknessPoints - 15) < 0.01 })
        #expect(abs(partition.lengthPoints - 460) < 1e-6, "hand takeoff 460 pt, got \(partition.lengthPoints)")
        #expect(partition.openings.count == 1)
        #expect(abs((partition.openings.first?.widthPoints ?? 0) - 90) < 1e-6)
        #expect(abs((partition.openings.first?.midpoint.y ?? 0) - 295) < 1e-6)
        #expect(partition.centrelines.count == 2, "the door splits the partition in two runs")
        for run in partition.centrelines {
            #expect(run.allSatisfy { abs($0.x - 500) < 1e-9 }, "on the partition's centreline")
            #expect(run.allSatisfy { $0.y >= 25 - 1e-9 && $0.y <= 575 + 1e-9 }, "a T-junction stops at the face, never runs into the outer wall")
        }
    }

    @Test("Dimension-line clutter below the class threshold makes no class; an empty page makes nothing")
    func clutterAndEmpty() {
        // Two parallel 1 m lines 20 cm apart: a pair, but less than the 2 m a class needs.
        let clutter = [
            GeometryQuerySegment(primitiveID: 1, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)),
            GeometryQuerySegment(primitiveID: 2, start: CGPoint(x: 0, y: 20), end: CGPoint(x: 100, y: 20)),
        ]
        #expect(WallCentrelineEngine(segments: clutter, options: .calibrated(pointsPerMetre: 100)).takeoff().classes.isEmpty)
        #expect(WallCentrelineEngine(segments: [], options: .calibrated(pointsPerMetre: 100)).takeoff() == .init(classes: [], isTruncated: false))
    }

    @Test("The same plan turned 30° gives the same lengths within 0.5 %: nothing depends on the page axes")
    func rotated() throws {
        let angle = 30.0 * .pi / 180
        func turn(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * cos(angle) - p.y * sin(angle) + 400, y: p.x * sin(angle) + p.y * cos(angle) + 50) }
        let turned = Self.plan().map { GeometryQuerySegment(primitiveID: $0.primitiveID, start: turn($0.start), end: turn($0.end)) }
        let walls = WallCentrelineEngine(segments: turned, options: .calibrated(pointsPerMetre: 100)).takeoff().classes
        let outer = try #require(walls.first { abs($0.thicknessPoints - 25) < 0.1 })
        let partition = try #require(walls.first { abs($0.thicknessPoints - 15) < 0.1 })
        #expect(abs(outer.lengthPoints - 3100) / 3100 < 0.005, "\(outer.lengthPoints)")
        #expect(abs(partition.lengthPoints - 460) / 460 < 0.005, "\(partition.lengthPoints)")
        #expect(partition.openings.count == 1)
    }
}
