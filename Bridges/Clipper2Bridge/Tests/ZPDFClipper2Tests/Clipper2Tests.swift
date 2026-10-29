import CoreGraphics
import XCTest

@testable import ZPDFClipper2

/// Deterministic geometry fixtures. No `Date()`, no `UUID()`, no randomness that
/// is not seeded — the stress case uses a fixed LCG so failures reproduce.
private enum Fixture {
    static func rectangle(x: Double, y: Double, width: Double, height: Double) -> ClipperPath {
        [
            CGPoint(x: x, y: y),
            CGPoint(x: x + width, y: y),
            CGPoint(x: x + width, y: y + height),
            CGPoint(x: x, y: y + height)
        ]
    }

    /// A clockwise ring, i.e. a hole when combined with a counter-clockwise outer ring.
    static func reversedRectangle(x: Double, y: Double, width: Double, height: Double) -> ClipperPath {
        rectangle(x: x, y: y, width: width, height: height).reversed()
    }

    /// Regular polygon approximating a circle. `segments` vertices, CCW.
    static func circle(center: CGPoint, radius: Double, segments: Int) -> ClipperPath {
        (0..<segments).map { index in
            let angle = 2.0 * Double.pi * Double(index) / Double(segments)
            return CGPoint(x: Double(center.x) + radius * cos(angle),
                           y: Double(center.y) + radius * sin(angle))
        }
    }
}

final class Clipper2BooleanTests: XCTestCase {

    // MARK: Square minus square

    func testSquareMinusFullyContainedSquareLeavesAnnulusOfCorrectArea() throws {
        let outer = [Fixture.rectangle(x: 0, y: 0, width: 100, height: 100)]
        let inner = [Fixture.rectangle(x: 25, y: 25, width: 50, height: 50)]

        let result = try Clipper2.difference(outer, inner)

        // Outer ring plus a hole.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(abs(Clipper2.area(of: result)), 100 * 100 - 50 * 50, accuracy: 1e-6)
        // Signed sum proves the hole winds opposite to the outer ring.
        XCTAssertLessThan(
            abs(Clipper2.area(of: result)),
            Clipper2.area(of: result[0]).magnitude + Clipper2.area(of: result[1]).magnitude
        )
    }

    func testSquareMinusOverlappingCornerSquare() throws {
        let subject = [Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)]
        let clip = [Fixture.rectangle(x: 5, y: 5, width: 10, height: 10)]

        let result = try Clipper2.difference(subject, clip)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(abs(Clipper2.area(of: result)), 100 - 25, accuracy: 1e-6)
        XCTAssertEqual(result[0].count, 6, "L-shape has six corners")
    }

    func testSquareMinusIdenticalSquareIsEmpty() throws {
        let square = [Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)]
        XCTAssertTrue(try Clipper2.difference(square, square).isEmpty)
    }

    func testSquareMinusDisjointSquareIsUnchangedInArea() throws {
        let subject = [Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)]
        let clip = [Fixture.rectangle(x: 100, y: 100, width: 10, height: 10)]

        let result = try Clipper2.difference(subject, clip)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(abs(Clipper2.area(of: result)), 100, accuracy: 1e-6)
    }

    // MARK: Overlapping triangles

    /// Two equilateral triangles forming a Star of David. The overlap is the
    /// central regular hexagon of side a/3, i.e. exactly 2/3 of one triangle.
    func testOverlappingTrianglesIntersectionIsCentralHexagon() throws {
        let up: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 45, y: 77.94228634059948)
        ]
        let down: ClipperPath = [
            CGPoint(x: 0, y: 51.96152422706632),
            CGPoint(x: 90, y: 51.96152422706632),
            CGPoint(x: 45, y: -25.980762113533157)
        ]
        let triangleArea = abs(Clipper2.area(of: up))

        let intersection = try Clipper2.intersection([up], [down])
        XCTAssertEqual(intersection.count, 1)
        XCTAssertEqual(intersection[0].count, 6, "Star of David core is a hexagon")
        XCTAssertEqual(abs(Clipper2.area(of: intersection)), triangleArea * 2.0 / 3.0, accuracy: 1e-4)
        // Cross-check against the closed form for a regular hexagon of side 30.
        XCTAssertEqual(
            abs(Clipper2.area(of: intersection)),
            1.5 * 3.0.squareRoot() * 30 * 30,
            accuracy: 1e-4
        )

        let union = try Clipper2.union([up], [down])
        XCTAssertEqual(union.count, 1)
        XCTAssertEqual(union[0].count, 12, "Star of David outline has twelve vertices")
    }

    func testDisjointTrianglesHaveEmptyIntersection() throws {
        let a: ClipperPath = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        let b: ClipperPath = [CGPoint(x: 10, y: 10), CGPoint(x: 11, y: 10), CGPoint(x: 10, y: 11)]
        XCTAssertTrue(try Clipper2.intersection([a], [b]).isEmpty)
    }

    // MARK: Polygon with a hole

    func testPolygonWithHoleSurvivesUnionAndKeepsBothRings() throws {
        let withHole = [
            Fixture.rectangle(x: 0, y: 0, width: 100, height: 100),
            Fixture.reversedRectangle(x: 40, y: 40, width: 20, height: 20)
        ]

        let normalized = try Clipper2.normalized(withHole)

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(abs(Clipper2.area(of: normalized)), 10_000 - 400, accuracy: 1e-6)
    }

    func testHoleIsFilledWhenUnionedWithAPatch() throws {
        let withHole = [
            Fixture.rectangle(x: 0, y: 0, width: 100, height: 100),
            Fixture.reversedRectangle(x: 40, y: 40, width: 20, height: 20)
        ]
        let patch = [Fixture.rectangle(x: 40, y: 40, width: 20, height: 20)]

        let result = try Clipper2.union(withHole, patch)

        XCTAssertEqual(result.count, 1, "hole is gone")
        XCTAssertEqual(abs(Clipper2.area(of: result)), 10_000, accuracy: 1e-6)
    }

    func testEvenOddTreatsSecondRingAsHoleRegardlessOfWinding() throws {
        // Both rings wound the same way: NonZero fills the inner square,
        // EvenOdd punches it out. This is the fill-rule parameter doing its job.
        let sameWinding = [
            Fixture.rectangle(x: 0, y: 0, width: 100, height: 100),
            Fixture.rectangle(x: 40, y: 40, width: 20, height: 20)
        ]

        let nonZero = try Clipper2.normalized(sameWinding, fillRule: .nonZero)
        XCTAssertEqual(abs(Clipper2.area(of: nonZero)), 10_000, accuracy: 1e-6)

        let evenOdd = try Clipper2.normalized(sameWinding, fillRule: .evenOdd)
        XCTAssertEqual(abs(Clipper2.area(of: evenOdd)), 10_000 - 400, accuracy: 1e-6)
        XCTAssertEqual(evenOdd.count, 2)
    }

    func testDifferenceCarvesAHoleOutOfTheMiddle() throws {
        let plate = [Fixture.rectangle(x: 0, y: 0, width: 20, height: 20)]
        let bore = [Fixture.circle(center: CGPoint(x: 10, y: 10), radius: 4, segments: 256)]

        let result = try Clipper2.difference(plate, bore)

        XCTAssertEqual(result.count, 2)
        let holeArea = abs(Clipper2.area(of: bore))
        // 1e-4 not 1e-6: the 256-gon vertices are irrational and get snapped to
        // the 1e-6 pt lattice, which shifts the measured area by about 2e-6.
        XCTAssertEqual(abs(Clipper2.area(of: result)), 400 - holeArea, accuracy: 1e-4)
        // An inscribed 256-gon is 0.0051 short of the true circle area.
        XCTAssertEqual(holeArea, Double.pi * 16, accuracy: 0.006)
        XCTAssertLessThan(holeArea, Double.pi * 16, "inscribed polygon undershoots")
    }
}

final class Clipper2DegenerateInputTests: XCTestCase {

    func testSelfIntersectingBowtieIsNormalisedIntoTwoTriangles() throws {
        // A bowtie: the crossing makes the naive shoelace area zero.
        let bowtie: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10),
            CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0)
        ]
        XCTAssertEqual(Clipper2.area(of: bowtie), 0, accuracy: 1e-12)

        let normalized = try Clipper2.normalized([bowtie], fillRule: .nonZero)

        XCTAssertEqual(normalized.count, 2, "one triangle per lobe")
        // Each lobe is a triangle with base 10 and height 5.
        XCTAssertEqual(abs(Clipper2.area(of: normalized[0])), 25, accuracy: 1e-4)
        XCTAssertEqual(abs(Clipper2.area(of: normalized[1])), 25, accuracy: 1e-4)
        for lobe in normalized { XCTAssertEqual(lobe.count, 3) }
    }

    func testSelfIntersectingBowtieUnderEvenOddIsTheSameTwoLobes() throws {
        let bowtie: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10),
            CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0)
        ]
        let normalized = try Clipper2.normalized([bowtie], fillRule: .evenOdd)
        XCTAssertEqual(abs(Clipper2.area(of: normalized)), 50, accuracy: 1e-4)
    }

    func testDoublyWoundSquareCollapsesUnderNonZeroButVanishesUnderEvenOdd() throws {
        let square = Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)

        let nonZero = try Clipper2.normalized([square, square], fillRule: .nonZero)
        XCTAssertEqual(abs(Clipper2.area(of: nonZero)), 100, accuracy: 1e-6)

        let evenOdd = try Clipper2.normalized([square, square], fillRule: .evenOdd)
        XCTAssertTrue(evenOdd.isEmpty, "two coincident rings cancel under even-odd")
    }

    func testEmptyInputProducesEmptyOutputForEveryOperation() throws {
        let empty: ClipperPaths = []
        let square = [Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)]

        XCTAssertTrue(try Clipper2.union(empty).isEmpty)
        XCTAssertTrue(try Clipper2.union(empty, empty).isEmpty)
        XCTAssertTrue(try Clipper2.intersection(empty, square).isEmpty)
        XCTAssertTrue(try Clipper2.intersection(square, empty).isEmpty)
        XCTAssertTrue(try Clipper2.difference(empty, square).isEmpty)
    }

    func testPathsWithFewerThanThreeVerticesAreHandledWithoutCrashing() throws {
        let emptyRing: ClipperPaths = [[]]
        let point: ClipperPaths = [[CGPoint(x: 1, y: 2)]]
        let segment: ClipperPaths = [[CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0)]]

        XCTAssertTrue(try Clipper2.union(emptyRing).isEmpty)
        XCTAssertTrue(try Clipper2.union(point).isEmpty)
        XCTAssertTrue(try Clipper2.union(segment).isEmpty, "zero-area sliver")

        XCTAssertEqual(Clipper2.area(of: ClipperPath()), 0)
        XCTAssertEqual(Clipper2.area(of: [CGPoint(x: 1, y: 1)] as ClipperPath), 0)
        XCTAssertEqual(Clipper2.area(of: segment[0]), 0)
    }

    func testDuplicateAndCollinearVerticesAreRemoved() throws {
        let messy: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 0),
            CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
            CGPoint(x: 0, y: 10)
        ]
        let cleaned = try Clipper2.normalized([messy])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned[0].count, 4)
        XCTAssertEqual(
            try Clipper2.normalized([messy], preservingCollinearVertices: true)[0].count, 5,
            "the collinear midpoint at (5, 0) survives when asked for"
        )
        XCTAssertEqual(abs(Clipper2.area(of: cleaned)), 100, accuracy: 1e-6)
    }

    func testNonFiniteCoordinatesThrowInsteadOfTrapping() {
        let broken: ClipperPaths = [[
            CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: 10)
        ]]
        XCTAssertThrowsError(try Clipper2.union(broken)) { error in
            XCTAssertEqual(error as? ClipperError, .nonFiniteCoordinate)
        }

        let infinite: ClipperPaths = [[
            CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: 10)
        ]]
        XCTAssertThrowsError(try Clipper2.union(infinite)) { error in
            XCTAssertEqual(error as? ClipperError, .nonFiniteCoordinate)
        }
    }

    func testCoordinatesBeyondTheIntegerLatticeThrowOverflow() {
        let huge: ClipperPaths = [[
            CGPoint(x: 0, y: 0), CGPoint(x: 1e18, y: 0), CGPoint(x: 0, y: 1e18)
        ]]
        XCTAssertThrowsError(try Clipper2.union(huge)) { error in
            XCTAssertEqual(error as? ClipperError, .coordinateOverflow)
        }
    }

    func testInvalidScaleIsRejectedAtConstruction() {
        XCTAssertNil(ClipperScale(0))
        XCTAssertNil(ClipperScale(-1))
        XCTAssertNil(ClipperScale(.nan))
        XCTAssertNil(ClipperScale(.infinity))
        XCTAssertEqual(ClipperScale.pagePoints.value, 1e6)
    }
}

final class Clipper2PointInPolygonTests: XCTestCase {

    func testContainmentOnASquare() throws {
        let square = Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)

        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 5, y: 5), in: square), .inside)
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 15, y: 5), in: square), .outside)
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: -0.001, y: 5), in: square), .outside)
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 0, y: 5), in: square), .onBoundary)
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 10, y: 10), in: square), .onBoundary)
    }

    func testBoundaryInclusionIsCallerControlled() throws {
        let square = Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)
        let corner = CGPoint(x: 0, y: 0)
        XCTAssertTrue(try Clipper2.contains(corner, in: square, includingBoundary: true))
        XCTAssertFalse(try Clipper2.contains(corner, in: square, includingBoundary: false))
    }

    func testContainmentIgnoresWindingDirection() throws {
        let ccw = Fixture.rectangle(x: 0, y: 0, width: 10, height: 10)
        let cw = Fixture.reversedRectangle(x: 0, y: 0, width: 10, height: 10)
        let point = CGPoint(x: 2, y: 8)
        XCTAssertEqual(try Clipper2.containment(of: point, in: ccw), .inside)
        XCTAssertEqual(try Clipper2.containment(of: point, in: cw), .inside)
    }

    func testDegeneratePolygonsReportOutside() throws {
        XCTAssertEqual(try Clipper2.containment(of: .zero, in: ClipperPath()), .outside)
        XCTAssertEqual(
            try Clipper2.containment(of: .zero, in: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]),
            .outside
        )
    }

    func testConcavePolygonNotchIsOutside() throws {
        // A "C" shape: the notch between the arms must read as outside.
        let cShape: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 3),
            CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 7), CGPoint(x: 10, y: 7),
            CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)
        ]
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 1, y: 5), in: cShape), .inside)
        XCTAssertEqual(try Clipper2.containment(of: CGPoint(x: 7, y: 5), in: cShape), .outside)
    }
}

final class Clipper2AreaTests: XCTestCase {

    func testSignedAreaFollowsWinding() {
        let ccw = Fixture.rectangle(x: 0, y: 0, width: 4, height: 3)
        XCTAssertEqual(Clipper2.area(of: ccw), 12, accuracy: 1e-12)
        XCTAssertEqual(Clipper2.area(of: ccw.reversed()), -12, accuracy: 1e-12)
    }

    func testAreaIsTranslationInvariantEvenFarFromTheOrigin() {
        let near = Fixture.rectangle(x: 0, y: 0, width: 1, height: 1)
        let far = Fixture.rectangle(x: 1_000_000, y: 1_000_000, width: 1, height: 1)
        XCTAssertEqual(Clipper2.area(of: near), Clipper2.area(of: far), accuracy: 1e-9)
    }

    /// The Kahan compensation earns its keep here: a fine circle whose terms
    /// differ in magnitude by many orders still lands on pi * r^2.
    func testKahanSummationKeepsAFineCircleAccurate() {
        let segments = 100_000
        let radius = 1_000.0
        let circle = Fixture.circle(center: CGPoint(x: 250_000, y: 250_000),
                                    radius: radius, segments: segments)
        let exact = 0.5 * Double(segments) * radius * radius
            * sin(2 * Double.pi / Double(segments))
        XCTAssertEqual(Clipper2.area(of: circle), exact, accuracy: abs(exact) * 1e-12)
    }

    func testAreaOfPathsSubtractsHoles() {
        let withHole = [
            Fixture.rectangle(x: 0, y: 0, width: 10, height: 10),
            Fixture.reversedRectangle(x: 2, y: 2, width: 2, height: 2)
        ]
        XCTAssertEqual(Clipper2.area(of: withHole), 100 - 4, accuracy: 1e-12)
    }

    func testAreaAppliesNoRounding() {
        // 0.1 + 0.2 style residue must survive: no internal display rounding.
        let sliver: ClipperPath = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1e-7, y: 0), CGPoint(x: 1e-7, y: 1e-7)
        ]
        XCTAssertEqual(Clipper2.area(of: sliver), 0.5e-14, accuracy: 1e-28)
        XCTAssertNotEqual(Clipper2.area(of: sliver), 0)
    }
}

final class Clipper2StressTests: XCTestCase {

    /// Deterministic 64-bit linear congruential generator (Knuth's MMIX
    /// constants). Seeded, so a failing run is reproducible.
    private struct SeededGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnitInterval() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    func testTenThousandVertexBooleanWithTiming() throws {
        let vertexCount = 10_000
        var generator = SeededGenerator(seed: 0x5A5A_1234_DEAD_BEEF)

        // A 10 000-vertex star-ish ring: radius wobbles, so the outline is
        // heavily convex/concave and the engine cannot take shortcuts.
        var subject = ClipperPath()
        subject.reserveCapacity(vertexCount)
        for index in 0..<vertexCount {
            let angle = 2.0 * Double.pi * Double(index) / Double(vertexCount)
            let radius = 400.0 + 60.0 * sin(angle * 37.0) + 8.0 * generator.nextUnitInterval()
            subject.append(CGPoint(x: 500 + radius * cos(angle), y: 500 + radius * sin(angle)))
        }
        XCTAssertEqual(subject.count, vertexCount)

        let clip = [Fixture.circle(center: CGPoint(x: 560, y: 480), radius: 380, segments: 2_048)]

        let unionStart = ContinuousClock.now
        let unioned = try Clipper2.union([subject])
        let unionDuration = ContinuousClock.now - unionStart

        let intersectStart = ContinuousClock.now
        let intersected = try Clipper2.intersection([subject], clip)
        let intersectDuration = ContinuousClock.now - intersectStart

        let differenceStart = ContinuousClock.now
        let differenced = try Clipper2.difference([subject], clip)
        let differenceDuration = ContinuousClock.now - differenceStart

        let subjectArea = abs(Clipper2.area(of: unioned))
        let intersectArea = abs(Clipper2.area(of: intersected))
        let differenceArea = abs(Clipper2.area(of: differenced))

        print("""
        [Clipper2 stress] \(vertexCount) input vertices, clip = 2048-gon
          union(self)   \(unionDuration) -> \(unioned.count) paths, \
        \(unioned.reduce(0) { $0 + $1.count }) vertices
          intersection  \(intersectDuration) -> \(intersected.count) paths, \
        \(intersected.reduce(0) { $0 + $1.count }) vertices
          difference    \(differenceDuration) -> \(differenced.count) paths, \
        \(differenced.reduce(0) { $0 + $1.count }) vertices
          areas: subject \(subjectArea), inter \(intersectArea), diff \(differenceArea)
        """)

        XCTAssertGreaterThan(subjectArea, 0)
        XCTAssertGreaterThan(intersectArea, 0)
        // A ∩ B and A − B partition A exactly.
        XCTAssertEqual(intersectArea + differenceArea, subjectArea, accuracy: subjectArea * 1e-6)

        // Loose ceiling: the point is to catch a pathological regression, not
        // to benchmark the machine.
        XCTAssertLessThan(unionDuration, .seconds(10))
        XCTAssertLessThan(intersectDuration, .seconds(10))
    }

    func testManySmallPathsUnionIntoASingleGrid() throws {
        // 40 x 40 = 1600 abutting squares must union into one 40x40 block.
        var tiles = ClipperPaths()
        for row in 0..<40 {
            for column in 0..<40 {
                tiles.append(Fixture.rectangle(
                    x: Double(column), y: Double(row), width: 1, height: 1
                ))
            }
        }
        let start = ContinuousClock.now
        let merged = try Clipper2.union(tiles)
        let duration = ContinuousClock.now - start
        print("[Clipper2 stress] union of \(tiles.count) unit squares took \(duration)")

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].count, 4, "collinear tile joints are dropped by default")
        XCTAssertEqual(abs(Clipper2.area(of: merged)), 1600, accuracy: 1e-6)

        // Upstream Clipper2 keeps every tile joint: 40 per side.
        let verbose = try Clipper2.union(tiles, preservingCollinearVertices: true)
        XCTAssertEqual(verbose.count, 1)
        XCTAssertEqual(verbose[0].count, 160)
        XCTAssertEqual(abs(Clipper2.area(of: verbose)), 1600, accuracy: 1e-6)
    }
}
