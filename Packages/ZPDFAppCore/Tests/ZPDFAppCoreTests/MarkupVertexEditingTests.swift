import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// The index contract behind the Select tool's vertex handles.
///
/// A handle is an integer, and `DocumentCommand.editVertices` replaces a whole geometry, so
/// the *only* thing keeping the dragged handle and the edited vertex in step is that
/// ``MarkupVertexEditing/vertices(of:)`` and ``MarkupVertexEditing/replacing(vertexAt:with:in:)``
/// walk the six collections in the same order. If they ever disagree, dragging the top-left
/// corner of a wall would move a count mark on the other side of the page, and no
/// higher-level test would say which of the two was wrong.
struct MarkupVertexEditingTests {

    private let page = PageID(UUID())

    private func geometry() -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: page,
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)],
            segments: [SegmentGeometry(start: PDFPoint(x: 20, y: 0), end: PDFPoint(x: 30, y: 0))],
            polygons: [
                PolygonGeometry(
                    outer: PolygonRing(points: [
                        PDFPoint(x: 40, y: 0), PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 10)
                    ]),
                    holes: [PolygonRing(points: [
                        PDFPoint(x: 42, y: 2), PDFPoint(x: 44, y: 2), PDFPoint(x: 44, y: 4)
                    ])]
                )
            ],
            circles: [CircleGeometry(center: PDFPoint(x: 100, y: 100), radius: 5)],
            countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 60, y: 0))]
        )
    }

    @Test("The vertex list is points, then segment ends, then rings, then count marks")
    func theOrderIsCanonical() {
        let vertices = MarkupVertexEditing.vertices(of: geometry())
        // NL-MEASURE-06 appends a stored circle's two shape handles — its centre (100) and its
        // rim point at angle 0 (105) — after the count marks, so every earlier index is what it
        // was. Old: 11 entries, no circle handles.
        #expect(vertices.map(\.x) == [0, 10, 20, 30, 40, 50, 50, 42, 44, 44, 60, 100, 105])
        #expect(vertices.count == 13)
    }

    @Test("Replacing a vertex by index edits exactly that vertex, in every collection")
    func replacingHitsTheRightVertex() throws {
        let original = geometry()
        let moved = PDFPoint(x: 999, y: 999)
        // The true vertices; the circle's handles have their own meaning (the rim sets the
        // radius, the centre carries the rim along) and are tested in NLMeasureShapeHandleTests.
        for index in MarkupVertexEditing.vertices(of: original).indices.dropLast(2) {
            let edited = try #require(
                MarkupVertexEditing.replacing(vertexAt: index, with: moved, in: original)
            )
            let after = MarkupVertexEditing.vertices(of: edited)
            #expect(after[index] == moved, "index \(index) did not land on the vertex it names")
            for other in after.indices where other != index {
                #expect(
                    after[other] == MarkupVertexEditing.vertices(of: original)[other],
                    "index \(index) also moved vertex \(other)"
                )
            }
        }
    }

    @Test("An index that names no vertex is refused rather than guessed at")
    func staleIndicesAreRefused() {
        let original = geometry()
        #expect(MarkupVertexEditing.replacing(vertexAt: -1, with: .zero, in: original) == nil)
        #expect(MarkupVertexEditing.replacing(vertexAt: 13, with: .zero, in: original) == nil)
        #expect(MarkupVertexEditing.replacing(vertexAt: 99, with: .zero, in: original) == nil)
    }

    @Test("Translating moves every coordinate and nothing else")
    func translatingMovesEverything() {
        let original = geometry()
        let moved = MarkupVertexEditing.translating(original, dx: 5, dy: -3)
        let before = MarkupVertexEditing.vertices(of: original)
        let after = MarkupVertexEditing.vertices(of: moved)
        #expect(after.count == before.count)
        for (a, b) in zip(before, after) {
            #expect(b.x == a.x + 5)
            #expect(b.y == a.y - 3)
        }
        // Circles and arcs travel too — a moved markup that leaves its circle behind is a
        // markup that measures one thing and draws another.
        #expect(moved.circles.first?.center == PDFPoint(x: 105, y: 97))
        #expect(moved.circles.first?.radius == 5, "a translation is not a resize")
        #expect(moved.polygons.first?.outer.isClosed == original.polygons.first?.outer.isClosed)
    }
}
