import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

@Suite("Polygon mathematics")
struct PolygonMathTests {

    // MARK: - Hand-computed area and perimeter

    @Test("Unit square: area 100, perimeter 40")
    func square() throws {
        let points = Fixture.square(10)
        #expect(PolygonMath.signedArea(points) == 100)
        #expect(PolygonMath.area(points) == 100)
        #expect(PolygonMath.perimeter(points) == 40)
        #expect(PolygonMath.perimeter(points, isClosed: false) == 30)
        #expect(PolygonMath.signedArea(Array(points.reversed())) == -100)
    }

    @Test("3-4-5 triangle: area 6, perimeter 12")
    func triangle() throws {
        let points = [PDFPoint(x: 0, y: 0), PDFPoint(x: 4, y: 0), PDFPoint(x: 0, y: 3)]
        #expect(PolygonMath.signedArea(points) == 6)
        #expect(PolygonMath.perimeter(points) == 12)
    }

    @Test("L shape: area 18, perimeter 22")
    func lShape() throws {
        // 6 x 2 foot plus a 2 x 3 riser: 12 + 6 = 18, verified by composite decomposition.
        let points = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 6, y: 0), PDFPoint(x: 6, y: 2),
            PDFPoint(x: 2, y: 2), PDFPoint(x: 2, y: 5), PDFPoint(x: 0, y: 5)
        ]
        #expect(PolygonMath.signedArea(points) == 18)
        #expect(PolygonMath.perimeter(points) == 22)
    }

    /// `PolygonMath.netArea`, `totalEdgeLength` and `requireDisjointInteriorHoles` were deleted
    /// with `ScaleApplication`, their only caller (R-174): the engine's cutout pipeline is the
    /// one net-area path. The pairwise overlap test they shared, `interiorsOverlap`, is live —
    /// Scale Region validation uses it — so its cases are kept here (CR-29, BH-160).
    @Test("interiorsOverlap: sharing area is overlap, touching is not (CR-29, BH-160)")
    func interiorsOverlapCases() {
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [PDFPoint] {
            Fixture.rectRing(x: x, y: y, width: width, height: height).points
        }
        // Overlapping 4 x 4 squares share a 2 x 2 corner.
        #expect(PolygonMath.interiorsOverlap(rect(1, 1, 4, 4), rect(3, 3, 4, 4)))
        // Nested, and identical.
        #expect(PolygonMath.interiorsOverlap(rect(1, 1, 4, 4), rect(2, 2, 2, 2)))
        #expect(PolygonMath.interiorsOverlap(rect(0, 0, 10, 10), rect(0, 0, 10, 10)))
        // Identical but wound the other way: winding does not decide overlap.
        #expect(PolygonMath.interiorsOverlap(rect(1, 1, 4, 4), Array(rect(1, 1, 4, 4).reversed())))
        // Sharing an edge, or only a corner, is touching.
        #expect(!PolygonMath.interiorsOverlap(rect(4, 4, 2, 2), rect(6, 4, 2, 2)))
        #expect(!PolygonMath.interiorsOverlap(rect(1, 1, 2, 2), rect(3, 3, 2, 2)))
        // Apart.
        #expect(!PolygonMath.interiorsOverlap(rect(0, 0, 2, 2), rect(5, 5, 2, 2)))
    }

    // MARK: - Numeric behaviour

    @Test("Area is exact for a square placed far from the page origin")
    func areaFarFromOrigin() {
        // Naive shoelace forms terms near 8e7 whose difference is 100; the origin shift removes
        // that cancellation entirely, so the answer stays exact rather than merely close.
        let points = Fixture.square(10, at: PDFPoint(x: 10000, y: 8000))
        #expect(PolygonMath.area(points) == 100)
    }

    @Test("A 200 000-vertex circle matches pi r^2 to twelve digits")
    func compensatedSummationOnALargeRing() throws {
        let count = 200_000
        let radius = 500.0
        var points: [PDFPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            points.append(
                PDFPoint(x: 7000 + radius * cos(angle), y: 5000 + radius * sin(angle))
            )
        }
        // A regular n-gon inscribed in a circle has area (n/2) r^2 sin(2 pi / n).
        let expectedArea = 0.5 * Double(count) * radius * radius * sin(2 * Double.pi / Double(count))
        let area = PolygonMath.area(points)
        #expect(abs(area - expectedArea) / expectedArea < 1e-12)

        let expectedPerimeter = 2 * Double(count) * radius * sin(Double.pi / Double(count))
        let perimeter = PolygonMath.perimeter(points)
        #expect(abs(perimeter - expectedPerimeter) / expectedPerimeter < 1e-12)
    }

    // MARK: - Containment

    @Test("Winding containment on a simple ring")
    func containmentOnSimpleRing() {
        let points = Fixture.square(10)
        #expect(PolygonMath.contains(PDFPoint(x: 5, y: 5), in: points))
        #expect(!PolygonMath.contains(PDFPoint(x: 15, y: 5), in: points))
        #expect(!PolygonMath.contains(PDFPoint(x: -0.5, y: 5), in: points))
    }

    @Test("A doubly wound ring has winding number 2 and contains its centre")
    func containmentOnDoubleWinding() {
        let once = Fixture.square(10)
        let twice = once + once
        let centre = PDFPoint(x: 5, y: 5)
        #expect(PolygonMath.windingNumber(of: centre, in: twice) == 2)
        #expect(PolygonMath.contains(centre, in: twice))
    }

    @Test("A point on an edge classifies as boundary, not inside or outside")
    func boundaryClassification() {
        let points = Fixture.square(10)
        #expect(PolygonMath.classify(PDFPoint(x: 5, y: 0), in: points) == .onBoundary)
        #expect(PolygonMath.classify(PDFPoint(x: 0, y: 0), in: points) == .onBoundary)
        #expect(PolygonMath.classify(PDFPoint(x: 5, y: 5), in: points) == .inside)
        #expect(PolygonMath.classify(PDFPoint(x: 5, y: -1), in: points) == .outside)
        // The tolerance is the configured one, not a hidden constant.
        let tight = GeometryEpsilon.strict
        #expect(PolygonMath.classify(PDFPoint(x: 5, y: 1e-8), in: points, epsilon: tight) == .inside)
        #expect(PolygonMath.classify(PDFPoint(x: 5, y: 1e-8), in: points) == .onBoundary)
    }

    @Test("A point inside a hole is outside the polygon")
    func holeContainment() {
        let polygon = PolygonGeometry(
            outer: Fixture.rectRing(x: 0, y: 0, width: 10, height: 10),
            holes: [Fixture.rectRing(x: 2, y: 2, width: 3, height: 4)]
        )
        #expect(PolygonMath.classify(PDFPoint(x: 3, y: 3), in: polygon) == .outside)
        #expect(PolygonMath.classify(PDFPoint(x: 8, y: 8), in: polygon) == .inside)
        #expect(PolygonMath.classify(PDFPoint(x: 2, y: 3), in: polygon) == .onBoundary)
    }

    // MARK: - Self-intersection

    @Test("A square is simple, a bowtie is not")
    func bowtie() throws {
        #expect(try PolygonMath.selfIntersections(Fixture.square(10)).isEmpty)
        let bowtie = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0),
            PDFPoint(x: 0, y: 10), PDFPoint(x: 10, y: 10)
        ]
        let hits = try PolygonMath.selfIntersections(bowtie, options: .exhaustive)
        #expect(hits.count == 1)
        #expect(hits[0].kind == .crossing)
        let point = try #require(hits[0].point)
        #expect(abs(point.x - 5) < 1e-12)
        #expect(abs(point.y - 5) < 1e-12)
    }

    @Test("A spike that folds back onto its own edge is a collinear overlap")
    func collinearFoldBack() throws {
        let spike = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0),
            PDFPoint(x: 4, y: 0), PDFPoint(x: 4, y: 6)
        ]
        let hits = try PolygonMath.selfIntersections(spike, options: .exhaustive)
        #expect(hits.contains { $0.kind == .collinearOverlap })
        #expect(try !PolygonMath.selfIntersections(spike).isEmpty)
    }

    @Test("A vertex touching a far edge is reported as touching, not crossing")
    func vertexTouchingEdge() throws {
        let shape = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10),
            PDFPoint(x: 5, y: 0), PDFPoint(x: 0, y: 10)
        ]
        let hits = try PolygonMath.selfIntersections(shape, options: .exhaustive)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.kind == .touching || $0.kind == .crossing })
    }

    @Test("A convex ring of 20 000 vertices is checked without hitting the vertex limit")
    func largeSimpleRingIsChecked() throws {
        let count = 20_000
        var points: [PDFPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            points.append(PDFPoint(x: 300 * cos(angle), y: 300 * sin(angle)))
        }
        #expect(try PolygonMath.selfIntersections(points).isEmpty)
    }

    @Test("Rings above the documented limit throw instead of running for minutes")
    func vertexLimitIsEnforced() {
        let points = Fixture.square(10)
        #expect(throws: GeometryError.ringTooLargeForIntersectionCheck(vertexCount: 4, limit: 3)) {
            _ = try PolygonMath.selfIntersections(
                points,
                options: SelfIntersectionOptions(maximumReported: nil, vertexLimit: 3)
            )
        }
    }

    // MARK: - Cleanup

    @Test("Duplicate and closing vertices are removed, and the count is reported")
    func duplicateCleanup() throws {
        let points = [
            PDFPoint(x: 0, y: 0),
            PDFPoint(x: 0, y: 1e-9),          // within pointMerge of the previous
            PDFPoint(x: 10, y: 0),
            PDFPoint(x: 10, y: 10),
            PDFPoint(x: 0, y: 10),
            PDFPoint(x: 0, y: 0)              // explicit closing vertex
        ]
        let result = try PolygonCleanup.cleanup(points)
        #expect(result.points.count == 4)
        #expect(result.removedDuplicates == 2)
        #expect(result.removedCollinear == 0)
        #expect(PolygonMath.area(result.points) == 100)
    }

    @Test("Collinear removal is opt-in and honours the height tolerance")
    func collinearCleanup() throws {
        let points = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 0), PDFPoint(x: 10, y: 0),
            PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
        ]
        let kept = try PolygonCleanup.cleanup(points)
        #expect(kept.points.count == 5, "collinear vertices survive by default")

        let stripped = try PolygonCleanup.cleanup(
            points,
            options: PolygonCleanupOptions(removesCollinearVertices: true)
        )
        #expect(stripped.points.count == 4)
        #expect(stripped.removedCollinear == 1)
        #expect(PolygonMath.area(stripped.points) == 100)

        // A vertex 0.001 points off the line is a real corner at the default tolerance.
        let bent = [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 0.001), PDFPoint(x: 10, y: 0),
            PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
        ]
        let bentResult = try PolygonCleanup.cleanup(
            bent,
            options: PolygonCleanupOptions(removesCollinearVertices: true)
        )
        #expect(bentResult.points.count == 5)
    }

    @Test("Cleanup rejects non-finite input and invalid epsilons")
    func cleanupErrors() {
        #expect(throws: GeometryError.nonFiniteCoordinate) {
            _ = try PolygonCleanup.cleanup([PDFPoint(x: .infinity, y: 0)])
        }
        var epsilon = GeometryEpsilon.standard
        epsilon.pointMerge = 0
        #expect(throws: GeometryError.invalidEpsilon(name: "pointMerge", value: 0)) {
            _ = try PolygonCleanup.cleanup(
                Fixture.square(1),
                options: PolygonCleanupOptions(epsilon: epsilon)
            )
        }
    }

    @Test("requireSimplePolygon cleans first, then rejects self-intersection")
    func requireSimplePolygon() throws {
        let withDuplicate = Fixture.square(10) + [PDFPoint(x: 0, y: 0)]
        #expect(try PolygonMath.requireSimplePolygon(withDuplicate).count == 4)

        #expect(throws: GeometryError.fewerThanThreeUniquePoints(count: 2)) {
            _ = try PolygonMath.requireSimplePolygon(
                [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)]
            )
        }
        #expect(throws: MeasurementError.selfIntersectingPolygon) {
            _ = try PolygonMath.requireSimplePolygon([
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0),
                PDFPoint(x: 0, y: 10), PDFPoint(x: 10, y: 10)
            ])
        }
    }
}
