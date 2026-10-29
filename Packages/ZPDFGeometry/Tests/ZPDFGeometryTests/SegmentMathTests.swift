import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

@Suite("Segment mathematics")
struct SegmentMathTests {

    private let horizontal = SegmentGeometry(
        start: PDFPoint(x: 0, y: 0),
        end: PDFPoint(x: 10, y: 0)
    )

    // MARK: - Nearest point and perpendicular foot

    @Test("Nearest point projects inside the segment")
    func nearestPointInside() {
        let result = SegmentMath.nearestPoint(on: horizontal, to: PDFPoint(x: 5, y: 3))
        #expect(result.point == PDFPoint(x: 5, y: 0))
        #expect(result.t == 0.5)
        #expect(result.distance == 3)
        #expect(!result.isEndpoint)
    }

    @Test("Nearest point clamps to an endpoint and says so")
    func nearestPointClamped() {
        let result = SegmentMath.nearestPoint(on: horizontal, to: PDFPoint(x: -5, y: 4))
        #expect(result.point == PDFPoint(x: 0, y: 0))
        #expect(result.t == 0)
        #expect(abs(result.distance - 41.0.squareRoot()) < 1e-12)
        #expect(result.isEndpoint)
    }

    @Test("A zero-length segment yields its own point rather than dividing by zero")
    func nearestPointOnDegenerateSegment() {
        let stub = SegmentGeometry(start: PDFPoint(x: 3, y: 4), end: PDFPoint(x: 3, y: 4))
        let result = SegmentMath.nearestPoint(on: stub, to: PDFPoint(x: 0, y: 0))
        #expect(result.point == PDFPoint(x: 3, y: 4))
        #expect(result.distance == 5)
        #expect(result.isEndpoint)
    }

    @Test("Perpendicular foot is unclamped; nearest point is clamped")
    func perpendicularFoot() throws {
        let foot = try SegmentMath.perpendicularFoot(
            from: PDFPoint(x: -5, y: 4),
            onLineThrough: horizontal.start,
            and: horizontal.end
        )
        #expect(foot == PDFPoint(x: -5, y: 0))
        #expect(throws: GeometryError.degenerateSegment) {
            _ = try SegmentMath.perpendicularFoot(
                from: .zero,
                onLineThrough: PDFPoint(x: 1, y: 1),
                and: PDFPoint(x: 1, y: 1)
            )
        }
    }

    @Test("Signed distance is positive to the left of the directed line")
    func signedDistance() throws {
        #expect(
            try SegmentMath.signedDistance(
                from: PDFPoint(x: 5, y: 3),
                toLineThrough: horizontal.start,
                and: horizontal.end
            ) == 3
        )
        #expect(
            try SegmentMath.signedDistance(
                from: PDFPoint(x: 5, y: -3),
                toLineThrough: horizontal.start,
                and: horizontal.end
            ) == -3
        )
    }

    // MARK: - Intersection

    @Test("Crossing diagonals meet at the midpoint of both")
    func crossing() throws {
        let a = SegmentGeometry(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 10, y: 10))
        let b = SegmentGeometry(start: PDFPoint(x: 0, y: 10), end: PDFPoint(x: 10, y: 0))
        guard case .point(let point, let t, let u) = SegmentMath.intersect(a, b) else {
            Issue.record("expected a point intersection")
            return
        }
        #expect(abs(point.x - 5) < 1e-12)
        #expect(abs(point.y - 5) < 1e-12)
        #expect(abs(t - 0.5) < 1e-12)
        #expect(abs(u - 0.5) < 1e-12)
    }

    @Test("Non-touching segments on crossing lines report none")
    func linesCrossButSegmentsDoNot() {
        let a = SegmentGeometry(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 1, y: 1))
        let b = SegmentGeometry(start: PDFPoint(x: 8, y: 10), end: PDFPoint(x: 10, y: 8))
        #expect(SegmentMath.intersect(a, b) == SegmentIntersection.none)
    }

    @Test("Parallel but separated segments are parallelDisjoint, not none")
    func parallelDisjoint() {
        let above = SegmentGeometry(start: PDFPoint(x: 0, y: 1), end: PDFPoint(x: 10, y: 1))
        #expect(SegmentMath.intersect(horizontal, above) == .parallelDisjoint)
    }

    @Test("Collinear segments that overlap return the shared span and its parameters")
    func collinearOverlap() {
        let other = SegmentGeometry(start: PDFPoint(x: 5, y: 0), end: PDFPoint(x: 15, y: 0))
        guard case .collinearOverlap(let span, let tRange, _) =
            SegmentMath.intersect(horizontal, other) else {
            Issue.record("expected a collinear overlap")
            return
        }
        #expect(span.start == PDFPoint(x: 5, y: 0))
        #expect(span.end == PDFPoint(x: 10, y: 0))
        #expect(abs(tRange.lowerBound - 0.5) < 1e-12)
        #expect(abs(tRange.upperBound - 1.0) < 1e-12)
    }

    @Test("Collinear segments meeting end to end collapse to a single point")
    func collinearTouch() {
        let other = SegmentGeometry(start: PDFPoint(x: 10, y: 0), end: PDFPoint(x: 20, y: 0))
        guard case .point(let point, let t, _) = SegmentMath.intersect(horizontal, other) else {
            Issue.record("expected a point intersection")
            return
        }
        #expect(abs(point.x - 10) < 1e-9)
        #expect(abs(t - 1) < 1e-9)
    }

    @Test("Collinear but separated segments are parallelDisjoint")
    func collinearDisjoint() {
        let other = SegmentGeometry(start: PDFPoint(x: 15, y: 0), end: PDFPoint(x: 20, y: 0))
        #expect(SegmentMath.intersect(horizontal, other) == .parallelDisjoint)
    }

    @Test("The parallel test is scale free: long near-parallel edges still cross")
    func parallelThresholdIsScaleFree() {
        // Two 3000-point edges half a degree apart. A raw cross-product threshold would call
        // these parallel because the cross product is large in absolute terms.
        let angle = 0.5 * Double.pi / 180
        let a = SegmentGeometry(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 3000, y: 0))
        let b = SegmentGeometry(
            start: PDFPoint(x: 0, y: -10),
            end: PDFPoint(x: 3000 * cos(angle), y: -10 + 3000 * sin(angle))
        )
        if case .point = SegmentMath.intersect(a, b) {} else {
            Issue.record("expected the two near-parallel long edges to cross")
        }

        // Two 2-point edges five degrees apart are not parallel either.
        let short1 = SegmentGeometry(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 2, y: 0))
        let short2 = SegmentGeometry(start: PDFPoint(x: 1, y: -1), end: PDFPoint(x: 1.1, y: 1))
        if case .point = SegmentMath.intersect(short1, short2) {} else {
            Issue.record("expected the two short edges to cross")
        }
    }

    @Test("Degenerate inputs are treated as points")
    func degenerateIntersection() {
        let point = SegmentGeometry(start: PDFPoint(x: 5, y: 0), end: PDFPoint(x: 5, y: 0))
        guard case .point(let hit, _, _) = SegmentMath.intersect(point, horizontal) else {
            Issue.record("expected the point to lie on the segment")
            return
        }
        #expect(hit == PDFPoint(x: 5, y: 0))

        let offLine = SegmentGeometry(start: PDFPoint(x: 5, y: 1), end: PDFPoint(x: 5, y: 1))
        #expect(SegmentMath.intersect(offLine, horizontal) == SegmentIntersection.none)
    }

    // MARK: - Circles and arcs

    @Test("Circumcircle of a right triangle")
    func circumcircle() throws {
        let circle = try SegmentMath.circumcircle(
            PDFPoint(x: 0, y: 0),
            PDFPoint(x: 10, y: 0),
            PDFPoint(x: 0, y: 10)
        )
        #expect(abs(circle.center.x - 5) < 1e-12)
        #expect(abs(circle.center.y - 5) < 1e-12)
        #expect(abs(circle.radius - 50.0.squareRoot()) < 1e-12)
    }

    @Test("Collinear and near-collinear triples are rejected on a normalised measure")
    func circumcircleRejectsCollinear() {
        #expect(throws: GeometryError.self) {
            _ = try SegmentMath.circumcircle(
                PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 0), PDFPoint(x: 10, y: 0)
            )
        }
        // Measure = 1e-8 / 10^2 = 1e-10, below the 1e-9 default threshold.
        #expect(throws: GeometryError.self) {
            _ = try SegmentMath.circumcircle(
                PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 1e-9), PDFPoint(x: 10, y: 0)
            )
        }
        // Scaling the whole triple by 1000 leaves the measure unchanged: still rejected.
        #expect(throws: GeometryError.self) {
            _ = try SegmentMath.circumcircle(
                PDFPoint(x: 0, y: 0), PDFPoint(x: 5000, y: 1e-6), PDFPoint(x: 10000, y: 0)
            )
        }
        // A genuinely small but well formed triangle is accepted.
        #expect(throws: Never.self) {
            _ = try SegmentMath.circumcircle(
                PDFPoint(x: 0, y: 0), PDFPoint(x: 0.001, y: 0.0005), PDFPoint(x: 0.002, y: 0)
            )
        }
    }

    @Test("Three-point arc sweeps through the middle point, in either direction")
    func threePointArc() throws {
        let counterClockwise = try SegmentMath.arc(
            through: PDFPoint(x: 10, y: 0),
            PDFPoint(x: 0, y: 10),
            PDFPoint(x: -10, y: 0)
        )
        #expect(abs(counterClockwise.radius - 10) < 1e-12)
        #expect(abs(counterClockwise.sweepAngle - Double.pi) < 1e-12)
        #expect(abs(counterClockwise.pdfArcLength - 10 * Double.pi) < 1e-11)

        let clockwise = try SegmentMath.arc(
            through: PDFPoint(x: 10, y: 0),
            PDFPoint(x: 0, y: -10),
            PDFPoint(x: -10, y: 0)
        )
        #expect(abs(clockwise.sweepAngle + Double.pi) < 1e-12)
        #expect(abs(clockwise.pdfArcLength - 10 * Double.pi) < 1e-11)
    }

    @Test("Midpoint and parametric point")
    func midpointAndParameter() {
        #expect(SegmentMath.midpoint(of: horizontal) == PDFPoint(x: 5, y: 0))
        #expect(SegmentMath.point(on: horizontal, at: 2) == PDFPoint(x: 20, y: 0))
        #expect(SegmentMath.point(on: horizontal, at: -0.5) == PDFPoint(x: -5, y: 0))
    }
}
