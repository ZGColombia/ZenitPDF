import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Shared plumbing for the extraction tests.
///
/// Every PDF comes from `ZPDFTestingSupport`: the corpus carries a manifest with the
/// closed-form truth, and `QUALITY_BAR` 2.6 forbids an expected value produced by the
/// code under test. Nothing here hand-rolls a fixture.
enum ExtractionTestSupport {

    /// `QUALITY_BAR` S2: a snapped point must land within 1e-9 page points of the
    /// closed-form point. Extraction feeds that number, so it is held to the same bar.
    static let coordinateTolerance = 1e-9
    /// `QUALITY_BAR` S10: the page-space round trip is exact to 1e-12.
    static let roundTripTolerance = 1e-12

    /// One directory per test, removed afterwards, so the fixture cache is per test run.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ZPDFVectorExtraction-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes one fixture and extracts page `pageIndex` from it.
    static func extract(
        _ kind: FixtureKind,
        pageIndex: Int = 0,
        options: VectorExtractionOptions = .standard
    ) async throws -> (extraction: VectorPageExtraction, manifest: FixtureManifest, directory: URL) {
        let directory = try makeTemporaryDirectory()
        let handle = try ZPDFFixtures.make(kind, in: directory)
        let extractor = VectorExtractor(options: options)
        let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: pageIndex)
        return (extraction, handle.manifest, directory)
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The set of on-curve vertices of every emitted primitive, deduplicated and sorted,
    /// so a comparison against the manifest does not depend on emission order.
    static func sortedVertices(of extraction: VectorPageExtraction) -> [CGPoint] {
        var seen: [CGPoint] = []
        for primitive in extraction.primitives {
            switch primitive.geometry {
            case .line(let line):
                seen.append(line.start)
                seen.append(line.end)
            case .cubic(let cubic):
                seen.append(cubic.p0)
                seen.append(cubic.p3)
            case .rectangle(let quad):
                seen.append(contentsOf: quad.corners)
            case .ring(let ring):
                seen.append(contentsOf: ring.vertices)
            }
        }
        var unique: [CGPoint] = []
        for point in seen.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
            if let last = unique.last, last == point { continue }
            unique.append(point)
        }
        return unique
    }

    /// `true` when `point` is within ``coordinateTolerance`` of `expected`.
    static func isNear(
        _ point: CGPoint,
        _ expected: FixturePoint,
        tolerance: Double = coordinateTolerance
    ) -> Bool {
        abs(point.x - expected.x) <= tolerance && abs(point.y - expected.y) <= tolerance
    }

    /// Asserts that every manifest vertex of `path` appears among the extracted
    /// vertices, and reports the worst miss when it does not.
    static func expectVertices(
        of path: FixturePath,
        in extraction: VectorPageExtraction,
        tolerance: Double = coordinateTolerance,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let extracted = sortedVertices(of: extraction)
        for expected in path.points {
            let best = extracted.map { hypot($0.x - expected.x, $0.y - expected.y) }.min() ?? .infinity
            #expect(
                best <= tolerance,
                "path \(path.id): no extracted vertex within \(tolerance) of (\(expected.x), \(expected.y)); nearest was \(best)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Total length of every line segment plus the chord length of every cubic.
    static func totalSegmentLength(of extraction: VectorPageExtraction) -> Double {
        extraction.segmentPrimitives.reduce(0.0) { total, primitive in
            switch primitive.geometry {
            case .line(let line): return total + line.length
            case .cubic(let cubic): return total + VectorFlattener.standard.approximateLength(of: cubic)
            default: return total
            }
        }
    }
}

extension VectorFlattener {
    /// Polyline length of the flattened curve. An underestimate of the true arc length,
    /// converging from below as ``flatness`` shrinks.
    func approximateLength(of cubic: VectorCubic) -> Double {
        let points = flatten(cubic)
        var total = 0.0
        for index in 1..<Swift.max(points.count, 1) {
            total += (points[index] - points[index - 1]).magnitude
        }
        return total
    }
}
