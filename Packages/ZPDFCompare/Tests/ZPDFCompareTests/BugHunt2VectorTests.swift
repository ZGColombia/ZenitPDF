import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCompare
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// Bug hunt 2 — the geometry signal.
struct BugHunt2VectorTests {

    private func extract(_ url: URL) async throws -> VectorPageExtraction {
        try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
    }

    /// BH-016. A hand alignment always carries a little rotation. 5e-5 rad moves no vertex of
    /// the fixture by more than ~0.05 pt (inside the 0.1 pt tolerance), yet it shifts the far
    /// end of every vertical edge by several 1e-4 pt quanta in x.
    ///
    /// Old output: the canonical lexicographic sort flipped the revised vertical edges,
    /// index-wise distance became the edge length, and the unchanged page came back with
    /// `reshapedCount > 0` and `unchangedCount < 6`.
    @Test("BH-016: a tiny alignment rotation leaves an unchanged page unchanged", arguments: [5e-5, -5e-5])
    func tinyRotationIsNotReshape(_ radians: Double) async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let extraction = try await extract(pair.baselineURL)
        let alignment = AlignmentTransform.similarity(scale: 1, rotationRadians: radians, translation: .zero)
        let outcome = try VectorDiffEngine.diff(baseline: extraction, revised: extraction, alignment: alignment)
        #expect(outcome.reshapedCount == 0)
        #expect(outcome.differences.isEmpty)
        #expect(outcome.unchangedCount == outcome.baselinePrimitiveCount)
    }

    private func shape(_ vertices: [CGPoint], closed: Bool) -> VectorDiffEngine.Shape {
        VectorDiffEngine.Shape(
            id: 1, kind: closed ? .rectangle : .lineSegment, vertices: vertices,
            bounds: .zero, anchor: .zero, strokeWidth: 1, confidence: 1, isClosedLoop: closed
        )
    }

    @Test("BH-016: correspondence still matches reversed segments and rotated closed starts")
    func correspondenceIsOrderIndependent() throws {
        let line = shape([CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)], closed: false)
        let reversed = shape([CGPoint(x: 99.97, y: 100), CGPoint(x: 100, y: 0)], closed: false)
        let distance = try #require(VectorDiffEngine.Shape.maximumVertexDistance(line, reversed))
        #expect(distance < 0.031)

        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let a = shape(square, closed: true)
        // Other start corner, other direction, moved by (5, 7).
        let moved = [square[2], square[1], square[0], square[3]].map { CGPoint(x: $0.x + 5, y: $0.y + 7) }
        let b = shape(moved, closed: true)
        let offset = try #require(VectorDiffEngine.Shape.uniformOffset(from: a, to: b, tolerance: 0.1))
        #expect(abs(offset.x - 5) < 1e-12 && abs(offset.y - 7) < 1e-12)
        #expect(VectorDiffEngine.Shape.maximumVertexDistance(a, shape([square[1], square[2], square[3], square[0]], closed: true)) == 0)
    }
}
