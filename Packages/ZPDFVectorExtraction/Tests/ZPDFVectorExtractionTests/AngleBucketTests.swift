import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// BH-325 / BH-326: the angle-bucket count rounded **up**, so buckets were narrower than
/// the tolerance whenever `π / tolerance` was not an integer, and two segments within
/// tolerance could sit two buckets apart — outside the centre ± 1 probe — and never be
/// compared, in a result reported `.complete`. The default 1.5° divides 180° exactly,
/// which is why nothing caught it.
///
/// Every expected value is derived by hand beside it (`QUALITY_BAR` 2.6).
struct AngleBucketTests {

    /// Segment A of length 400 from the origin at `alpha`; segment B of length 400 at
    /// `beta`, centred 300 along A's left normal from A's midpoint. B's midpoint projects
    /// onto A's midpoint, so the separation measured at the middle of the shared span is
    /// exactly 300 whatever the small angle between them.
    static func pair(alphaDegrees: Double, betaDegrees: Double) -> [GeometryQuerySegment] {
        let alpha = alphaDegrees * .pi / 180
        let beta = betaDegrees * .pi / 180
        let a = GeometryQuerySegment(
            primitiveID: 1, start: .zero, end: CGPoint(x: 400 * cos(alpha), y: 400 * sin(alpha))
        )
        let mid = CGPoint(x: 200 * cos(alpha) - 300 * sin(alpha), y: 200 * sin(alpha) + 300 * cos(alpha))
        let b = GeometryQuerySegment(
            primitiveID: 2,
            start: CGPoint(x: mid.x - 200 * cos(beta), y: mid.y - 200 * sin(beta)),
            end: CGPoint(x: mid.x + 200 * cos(beta), y: mid.y + 200 * sin(beta))
        )
        return [a, b]
    }

    @Test(
        "Two segments inside the angle tolerance but two narrow buckets apart are still paired (BH-325, BH-326)",
        arguments: [
            // tolerance 1.75°: old bucket count ceil(180 / 1.75) = ceil(102.86) = 103,
            // width 1.7476°; A at 1.7470° → bucket 0, B at 3.4960° → bucket 2 (3.4960 /
            // 1.7476 = 2.0005). Difference 1.749° ≤ 1.75°, yet buckets 0 and 2 are never
            // probed together. New count floor(102.86) = 102, width 1.7647°: B → bucket 1.
            (tolerance: 1.75, alpha: 1.7470, beta: 3.4960),
            // tolerance 1.4°: old ceil(128.57) = 129, width 1.3953°; A at 1.3950° → 0,
            // B at 2.7940° → 2 (2.7940 / 1.3953 = 2.0024). New floor = 128, width
            // 1.40625°: B → 1.
            (tolerance: 1.4, alpha: 1.3950, beta: 2.7940)
        ]
    )
    func inToleranceNeighboursTwoBucketsApartArePaired(
        _ scenario: (tolerance: Double, alpha: Double, beta: Double)
    ) throws {
        let segments = Self.pair(alphaDegrees: scenario.alpha, betaDegrees: scenario.beta)
        let engine = try GeometryQueryEngine(segments: segments)
        let result = engine.parallelPairs(
            gap: 300, tolerance: 1, angleToleranceDegrees: scenario.tolerance
        )
        // Old output: 0 matches, status .complete, examinedCount 0.
        #expect(result.status == .complete)
        #expect(result.count == 1)
        let match = try #require(result.matches.first)
        #expect(abs(match.separationPoints - 300) < 1e-6)
        #expect(abs(match.angleDifferenceDegrees - (scenario.beta - scenario.alpha)) < 1e-6)

        // The bucket width is at least the tolerance, as the grid's own header requires.
        let grid = GeometrySegmentGrid(
            segments: segments, angles: segments.map(\.lineAngle), reach: 301,
            angleToleranceRadians: scenario.tolerance * .pi / 180
        )
        #expect(Double.pi / Double(grid.bucketCount) >= scenario.tolerance * .pi / 180)
        #expect(grid.bucketCount == Int((180 / scenario.tolerance).rounded(.down)))
    }

    @Test("A tolerance that divides 180° exactly keeps its bucket count, and a tolerance wider than 180° gives one bucket")
    func exactDivisorsAndDegenerateTolerances() {
        let segments = Self.pair(alphaDegrees: 0, betaDegrees: 0)
        let angles = segments.map(\.lineAngle)
        // 1.5° → 120 buckets exactly, unchanged from before.
        let standard = GeometrySegmentGrid(
            segments: segments, angles: angles, reach: 301, angleToleranceRadians: 1.5 * .pi / 180
        )
        #expect(standard.bucketCount == 120)
        // 200° → floor(0.9) = 0, clamped to 1.
        let wide = GeometrySegmentGrid(
            segments: segments, angles: angles, reach: 301, angleToleranceRadians: 200 * .pi / 180
        )
        #expect(wide.bucketCount == 1)
        // 0.01° → 18 000, clamped to 1024 — coarser than the tolerance, which is safe.
        let fine = GeometrySegmentGrid(
            segments: segments, angles: angles, reach: 301, angleToleranceRadians: 0.01 * .pi / 180
        )
        #expect(fine.bucketCount == GeometrySegmentGrid.maximumAngleBuckets)
    }
}
