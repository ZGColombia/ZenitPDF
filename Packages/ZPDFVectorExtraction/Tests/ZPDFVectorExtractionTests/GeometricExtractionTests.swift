import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Closed-form geometry: every expected number comes from the fixture manifest, which
/// derived it from a formula and never from this extractor (`QUALITY_BAR` 2.6).
struct GeometricExtractionTests {

    @Test("A single line is extracted at exactly the manifest's coordinates")
    func singleLine() async throws {
        let result = try await ExtractionTestSupport.extract(.singleLine)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .available)
        #expect(result.extraction.primitives.count == 1)

        let path = try #require(result.manifest.path(id: "line"))
        let primitive = try #require(result.extraction.primitives.first)
        #expect(primitive.kind == .lineSegment)
        guard case .line(let line) = primitive.geometry else {
            Issue.record("expected a line, got \(primitive.geometry)")
            return
        }
        #expect(ExtractionTestSupport.isNear(line.start, path.points[0]))
        #expect(ExtractionTestSupport.isNear(line.end, path.points[1]))
        #expect(abs(line.length - path.length) <= ExtractionTestSupport.coordinateTolerance)
        #expect(primitive.paint == .stroked)
        #expect(primitive.confidence == VectorConfidence.stroked)
        #expect(primitive.nestingDepth == 0)
    }

    @Test("A rectangle drawn as m/l/l/l/h yields one closed subpath and four segments")
    func rectangle() async throws {
        let result = try await ExtractionTestSupport.extract(.rectangle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "rect"))
        #expect(result.extraction.availability == .available)
        #expect(result.extraction.shapePrimitives.count == 1)
        #expect(result.extraction.segmentPrimitives.count == 4)

        let shape = try #require(result.extraction.shapePrimitives.first)
        #expect(shape.kind == .closedSubpath)
        guard case .ring(let ring) = shape.geometry else {
            Issue.record("expected a ring, got \(shape.geometry)")
            return
        }
        #expect(ring.isClosed)
        #expect(!ring.containsCurves)
        #expect(ring.vertices.count == path.points.count)
        for (extracted, expected) in zip(ring.vertices, path.points) {
            #expect(ExtractionTestSupport.isNear(extracted, expected))
        }

        // The four edges must sum to the manifest perimeter exactly.
        let perimeter = ExtractionTestSupport.totalSegmentLength(of: result.extraction)
        #expect(abs(perimeter - path.length) <= ExtractionTestSupport.coordinateTolerance)

        // Every segment names the shape as its parent, and all share one source object.
        for segment in result.extraction.segmentPrimitives {
            #expect(segment.parentID == shape.id)
            #expect(segment.sourceObjectID == shape.sourceObjectID)
        }
    }

    @Test("A concave L-shape keeps all six manifest vertices and its exact perimeter")
    func lShape() async throws {
        let result = try await ExtractionTestSupport.extract(.lShape)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "l-shape"))
        ExtractionTestSupport.expectVertices(of: path, in: result.extraction)
        #expect(result.extraction.segmentPrimitives.count == 6)
        let perimeter = ExtractionTestSupport.totalSegmentLength(of: result.extraction)
        #expect(abs(perimeter - path.length) <= ExtractionTestSupport.coordinateTolerance)
    }

    @Test(
        "A polygon with holes yields one subpath per ring",
        arguments: [
            (FixtureKind.polygonOneHole, "square-one-hole", 2),
            (FixtureKind.polygonThreeHoles, "square-three-holes", 4)
        ]
    )
    func polygonsWithHoles(kind: FixtureKind, pathID: String, ringCount: Int) async throws {
        let result = try await ExtractionTestSupport.extract(kind)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: pathID))
        #expect(result.extraction.shapePrimitives.count == ringCount)
        ExtractionTestSupport.expectVertices(of: path, in: result.extraction)

        // Hole vertices are geometry a user snaps to just as much as the outer ring.
        let extracted = ExtractionTestSupport.sortedVertices(of: result.extraction)
        for hole in path.holes {
            for expected in hole {
                let nearest = extracted
                    .map { hypot($0.x - expected.x, $0.y - expected.y) }
                    .min() ?? .infinity
                #expect(nearest <= ExtractionTestSupport.coordinateTolerance)
            }
        }

        // Filled *and* stroked, so both roles must be recorded.
        for primitive in result.extraction.primitives {
            #expect(primitive.paint.contains(.filled))
            #expect(primitive.paint.contains(.stroked))
        }

        let perimeter = ExtractionTestSupport.totalSegmentLength(of: result.extraction)
        #expect(abs(perimeter - path.length) <= ExtractionTestSupport.coordinateTolerance)
    }

    @Test("Cubic Béziers survive extraction as curves with the manifest's control points")
    func bezierCircleKeepsCurves() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "circle"))
        let curves = result.extraction.primitives.filter { $0.kind == .cubicCurve }
        #expect(curves.count == path.cubics.count)

        for (primitive, expected) in zip(curves, path.cubics) {
            guard case .cubic(let cubic) = primitive.geometry else {
                Issue.record("expected a cubic, got \(primitive.geometry)")
                continue
            }
            #expect(ExtractionTestSupport.isNear(cubic.p0, expected.p0))
            #expect(ExtractionTestSupport.isNear(cubic.p1, expected.p1))
            #expect(ExtractionTestSupport.isNear(cubic.p2, expected.p2))
            #expect(ExtractionTestSupport.isNear(cubic.p3, expected.p3))
        }

        // The ring records the on-curve points only, without repeating the first.
        let shape = try #require(result.extraction.shapePrimitives.first)
        guard case .ring(let ring) = shape.geometry else {
            Issue.record("expected a ring, got \(shape.geometry)")
            return
        }
        #expect(ring.containsCurves)
        #expect(ring.vertices.count == 4)
    }

    @Test("Exact cubic bounds are tighter than the control hull and contain the curve")
    func cubicBoundsAreExact() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        for primitive in result.extraction.primitives where primitive.kind == .cubicCurve {
            guard case .cubic(let cubic) = primitive.geometry else { continue }
            let bounds = cubic.bounds
            #expect(cubic.controlHullBounds.contains(bounds))
            // 64 samples along the curve must all lie inside the reported bounds, with a
            // slack of one ulp-scale epsilon for the arithmetic.
            for step in 0...64 {
                let point = cubic.point(at: Double(step) / 64)
                #expect(bounds.inset(by: -1e-9).contains(point))
            }
        }
    }
}
