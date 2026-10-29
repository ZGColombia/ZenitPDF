import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Adaptive flattening: for indexing and hit testing only, never for stored geometry.
struct FlatteningTests {

    @Test("Flattening stays inside the configured flatness on the fixture's circle")
    func flatnessBoundIsHonoured() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        for flatness in [1.0, 0.1, 0.01, 0.001] {
            let flattener = VectorFlattener(flatness: flatness)
            for primitive in result.extraction.primitives where primitive.kind == .cubicCurve {
                guard case .cubic(let cubic) = primitive.geometry else { continue }
                let polyline = flattener.flatten(cubic)
                #expect(polyline.count >= 2)
                #expect(polyline.first == cubic.p0)
                #expect(polyline.last == cubic.p3)

                // Every sample of the true curve is within `flatness` of the polyline,
                // with a small allowance for the fact that the flatness test bounds the
                // control-point deviation rather than the curve deviation directly.
                var worst = 0.0
                for step in 0...200 {
                    let point = cubic.point(at: Double(step) / 200)
                    worst = max(worst, distance(from: point, toPolyline: polyline))
                }
                #expect(
                    worst <= flatness * 1.5,
                    "flatness \(flatness): worst deviation was \(worst)"
                )
            }
        }
    }

    @Test("A finer flatness never produces a coarser polyline")
    func finerFlatnessSubdividesMore() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let primitive = try #require(result.extraction.primitives.first { $0.kind == .cubicCurve })
        guard case .cubic(let cubic) = primitive.geometry else { return }

        var previous = 0
        for flatness in [10.0, 1.0, 0.1, 0.01, 0.001] {
            let count = VectorFlattener(flatness: flatness).flatten(cubic).count
            #expect(count >= previous)
            previous = count
        }
    }

    @Test("Flattened arc length converges on the manifest's circumference")
    func arcLengthConverges() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "circle"))
        let flattener = VectorFlattener(flatness: 0.001)
        var total = 0.0
        for primitive in result.extraction.primitives where primitive.kind == .cubicCurve {
            guard case .cubic(let cubic) = primitive.geometry else { continue }
            total += flattener.approximateLength(of: cubic)
        }
        // The manifest records the *true* circle circumference and the documented
        // 2.7253e-4 relative radial error of the four-arc approximation. The polyline is
        // an underestimate of the Bézier length, so a one-sided relative bound is right.
        let relative = abs(total - path.length) / path.length
        #expect(relative <= 1e-3, "relative arc-length error was \(relative)")
    }

    @Test("Flattening is bounded for pathological input and never subdivides forever")
    func flatteningIsBounded() {
        let flattener = VectorFlattener(flatness: 1e-12, maximumSubdivisionDepth: 8, maximumPointsPerCurve: 64)
        let huge = VectorCubic(
            p0: CGPoint(x: -1e12, y: -1e12),
            p1: CGPoint(x: 1e12, y: -1e12),
            p2: CGPoint(x: -1e12, y: 1e12),
            p3: CGPoint(x: 1e12, y: 1e12)
        )
        #expect(flattener.flatten(huge).count <= 64 + 1)

        let nonFinite = VectorCubic(
            p0: CGPoint(x: 0, y: 0),
            p1: CGPoint(x: Double.nan, y: 0),
            p2: CGPoint(x: 0, y: Double.infinity),
            p3: CGPoint(x: 1, y: 1)
        )
        #expect(flattener.flatten(nonFinite).count == 2)

        let degenerate = VectorCubic(p0: .zero, p1: .zero, p2: .zero, p3: .zero)
        #expect(flattener.flatten(degenerate).count == 2)
    }

    @Test("Flattening a whole primitive closes rings and passes lines through")
    func flattenPrimitive() async throws {
        let result = try await ExtractionTestSupport.extract(.rectangle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let flattener = VectorFlattener.standard
        let shape = try #require(result.extraction.shapePrimitives.first)
        let ring = flattener.flatten(shape)
        #expect(ring.count == 5)
        #expect(ring.first == ring.last)

        let segment = try #require(result.extraction.segmentPrimitives.first)
        #expect(flattener.flatten(segment).count == 2)
    }

    @Test("A ring that contains curves has no polyline of its own; its cubics do (CR-36)")
    func curvedRingFlattensToNothing() async throws {
        let result = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(result.directory) }

        let flattener = VectorFlattener.standard
        let ring = try #require(result.extraction.shapePrimitives.first)
        guard case let .ring(geometry) = ring.geometry else {
            Issue.record("expected the circle's subpath to be a ring")
            return
        }
        #expect(geometry.containsCurves)
        // Old output: 5 points — the four axis vertices closed back to the first, the
        // inscribed square of a circle, which no flatness makes an outline.
        #expect(flattener.flatten(ring).isEmpty)

        // The outline is the children's: four cubics, each a real polyline.
        let children = result.extraction.primitives.filter { $0.parentID == ring.id }
        #expect(children.count == 4)
        #expect(children.allSatisfy { flattener.flatten($0).count > 2 })
    }

    private func distance(from point: CGPoint, toPolyline polyline: [CGPoint]) -> Double {
        guard polyline.count >= 2 else { return .infinity }
        var best = Double.infinity
        for index in 1..<polyline.count {
            best = min(best, distance(from: point, toSegment: polyline[index - 1], polyline[index]))
        }
        return best
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
