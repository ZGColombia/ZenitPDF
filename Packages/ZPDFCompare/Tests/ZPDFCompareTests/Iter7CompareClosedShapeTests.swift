import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// X-040: a closed subpath is extracted twice — one subpath-level parent (`.rectangle` or
/// `.closedSubpath`) and one `.lineSegment` child per edge, all with the same confidence —
/// and the geometry pass compared both forms. One moved rectangle came back as five `moved`
/// rows, and an unchanged one counted five times in `unchangedCount` and the page total.
///
/// Every page here is one letter sheet written byte by byte, so the content stream is
/// exactly the operators named in each test.
struct Iter7CompareClosedShapeTests {

    private static let letter = FixtureRect(x: 0, y: 0, width: 612, height: 792)

    /// A stroked `re` rectangle at (x, y), 200 × 150 pt unless widened.
    private static func rectangle(x: Double, y: Double, width: Double = 200, paint: String = "S") -> String {
        "2 w\n0 G\n0 g\n\(x) \(y) \(width) 150 re\n\(paint)\n"
    }

    /// A stroked five-vertex closed polyline (`m l l l l h S`), shifted by (dx, dy).
    private static func pentagon(dx: Double, dy: Double) -> String {
        let vertices: [(Double, Double)] = [(100, 400), (220, 400), (260, 470), (160, 520), (90, 470)]
        var content = "2 w\n0 G\n"
        for (index, vertex) in vertices.enumerated() {
            content += "\(vertex.0 + dx) \(vertex.1 + dy) \(index == 0 ? "m" : "l")\n"
        }
        return content + "h\nS\n"
    }

    private static func extract(
        _ content: String,
        options: VectorExtractionOptions = .standard
    ) async throws -> VectorPageExtraction {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-x040-\(UUID().uuidString).pdf")
        try RevisionPDFWriter.data(mediaBox: letter, content: content).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await VectorExtractor(options: options).extract(documentAt: url, pageIndex: 0)
    }

    @Test("X-040: the fixture really carries a parent and four edge children per rectangle")
    func fixtureEmitsParentAndChildren() async throws {
        let extraction = try await Self.extract(Self.rectangle(x: 100, y: 100))
        // By hand: one `re` is one closed subpath — 1 `.rectangle` parent plus 4 edges.
        #expect(extraction.shapePrimitives.count == 1)
        #expect(extraction.segmentPrimitives.count == 4)
        let parent = try #require(extraction.shapePrimitives.first)
        #expect(!parent.isEdgeOfShape)
        #expect(extraction.segmentPrimitives.allSatisfy { $0.isEdgeOfShape && $0.parentID == parent.id })
        #expect(extraction.segmentPrimitives.allSatisfy { $0.confidence == parent.confidence })
    }

    @Test("X-040: a rectangle compared with itself is one unchanged shape, not five")
    func unchangedRectangleCountsOnce() async throws {
        let extraction = try await Self.extract(Self.rectangle(x: 100, y: 100))
        let outcome = try VectorDiffEngine.diff(baseline: extraction, revised: extraction, alignment: .identity)
        #expect(outcome.differences.isEmpty)
        // Old output: unchangedCount 5, baselinePrimitiveCount 5 (parent + 4 edges).
        #expect(outcome.unchangedCount == 1)
        #expect(outcome.baselinePrimitiveCount == 1)
        #expect(outcome.revisedPrimitiveCount == 1)
    }

    @Test("X-040: a moved closed shape is one moved row with the exact translation", arguments: ["S", "f", "B"])
    func movedRectangleIsOneRow(_ paint: String) async throws {
        let baseline = try await Self.extract(Self.rectangle(x: 100, y: 100, paint: paint))
        let revised = try await Self.extract(Self.rectangle(x: 112, y: 108, paint: paint))
        let outcome = try VectorDiffEngine.diff(baseline: baseline, revised: revised, alignment: .identity)
        // Old output: 5 `.moved` differences and 5 regions — the parent and each of its 4 edges,
        // every one translated by (12, 8).
        #expect(outcome.differences.count == 1, "\(outcome.differences.map(\.kind))")
        #expect(outcome.regions.count == 1)
        #expect(outcome.movedCount == 1)
        #expect(outcome.unchangedCount == 0)
        #expect(outcome.baselinePrimitiveCount == 1)
        let moved = try #require(outcome.differences.first)
        let translation = try #require(moved.detail.translation)
        #expect(abs(Double(translation.x) - 12) < 1e-9 && abs(Double(translation.y) - 8) < 1e-9)
        let parent = try #require(baseline.shapePrimitives.first)
        #expect(moved.detail.baselinePrimitiveIDs == [parent.id])
        // The row frames both positions: (100, 100)…(300, 250) ∪ (112, 108)…(312, 258).
        #expect(rectsAreEqual(moved.bounds, CGRect(x: 100, y: 100, width: 212, height: 158), tolerance: 1e-9),
                "\(describe(moved.bounds))")
    }

    @Test("X-040: a moved closed polyline is one moved row")
    func movedClosedPolylineIsOneRow() async throws {
        let baseline = try await Self.extract(Self.pentagon(dx: 0, dy: 0))
        let revised = try await Self.extract(Self.pentagon(dx: -6, dy: 15))
        #expect(baseline.shapePrimitives.map(\.kind) == [.closedSubpath])
        let outcome = try VectorDiffEngine.diff(baseline: baseline, revised: revised, alignment: .identity)
        // Old output: 6 `.moved` rows — the ring plus its 5 edges (4 drawn, 1 closed by `h`).
        #expect(outcome.differences.count == 1)
        #expect(outcome.movedCount == 1)
        let translation = try #require(outcome.differences.first?.detail.translation)
        #expect(abs(Double(translation.x) + 6) < 1e-9 && abs(Double(translation.y) - 15) < 1e-9)
    }

    @Test("X-040: a rectangle widened on one side is one removal and one addition")
    func widenedRectangleIsTwoRows() async throws {
        let baseline = try await Self.extract(Self.rectangle(x: 100, y: 100))
        let revised = try await Self.extract(Self.rectangle(x: 100, y: 100, width: 230))
        let outcome = try VectorDiffEngine.diff(baseline: baseline, revised: revised, alignment: .identity)
        // By hand: the right side moves +30 pt, so the corner centroid moves +15 pt — not a
        // uniform move, not the same anchor — and the engine's rule makes it one removal plus
        // one addition. Old output: 7 rows — the right edge moved, the top and bottom edges
        // removed + added (their centroids moved 15 pt), and the parent removed + added; the
        // unchanged left edge made unchangedCount 1.
        #expect(outcome.differences.count == 2, "\(outcome.differences.map(\.kind))")
        #expect(outcome.removedCount == 1)
        #expect(outcome.addedCount == 1)
        #expect(outcome.unchangedCount == 0)
    }

    @Test("X-040: without shape primitives the segments still stand for themselves")
    func segmentsWithoutParentsAreStillCompared() async throws {
        let options = VectorExtractionOptions(emitsShapePrimitives: false)
        let baseline = try await Self.extract(Self.rectangle(x: 100, y: 100), options: options)
        let revised = try await Self.extract(Self.rectangle(x: 112, y: 108), options: options)
        #expect(baseline.shapePrimitives.isEmpty)
        #expect(baseline.segmentPrimitives.allSatisfy { !$0.isEdgeOfShape })
        let outcome = try VectorDiffEngine.diff(baseline: baseline, revised: revised, alignment: .identity)
        // No parent to stand for them: each of the 4 edges is its own moved row.
        #expect(outcome.baselinePrimitiveCount == 4)
        #expect(outcome.differences.count == 4)
        #expect(outcome.movedCount == 4)
    }
}
