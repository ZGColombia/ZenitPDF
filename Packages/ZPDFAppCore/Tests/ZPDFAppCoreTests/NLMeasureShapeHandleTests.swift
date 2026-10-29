import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-06: circle and arc handles. Every expected value is hand-derived at 1 m/pt.
@Suite("Circle and arc handles (NL-MEASURE-06)")
struct NLMeasureShapeHandleTests {

    static let page = PageID(UUID())

    /// A circle at (0,0), r 10: handles are the centre and the rim point (10, 0), after the
    /// free points.
    @Test("A circle's rim handle sets the radius; its centre moves it")
    func circle() throws {
        let geometry = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 99, y: 99)],
                                           circles: [CircleGeometry(center: PDFPoint(x: 0, y: 0), radius: 10)])
        #expect(MarkupVertexEditing.vertices(of: geometry) == [PDFPoint(x: 99, y: 99), PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)])
        // Rim to (0, 20): radius 20 (the distance from the centre).
        let rim = try #require(MarkupVertexEditing.replacing(vertexAt: 2, with: PDFPoint(x: 0, y: 20), in: geometry))
        #expect(rim.circles[0].radius == 20)
        #expect(rim.circles[0].center == PDFPoint(x: 0, y: 0))
        #expect(rim.points == geometry.points, "earlier vertices untouched")
        // Centre to (5, 5): same radius, moved.
        let moved = try #require(MarkupVertexEditing.replacing(vertexAt: 1, with: PDFPoint(x: 5, y: 5), in: geometry))
        #expect(moved.circles[0] == CircleGeometry(center: PDFPoint(x: 5, y: 5), radius: 10))
        // The rim on the centre would be a zero radius: refused.
        #expect(MarkupVertexEditing.replacing(vertexAt: 2, with: PDFPoint(x: 0, y: 0), in: geometry) == nil)
    }

    /// Arc at (0,0), r 10, from 0 sweeping +π/2 (quarter). Dragging the end to (−10, 0) makes
    /// it a half: sweep π, length 10π. Dragging the start to (0, −5) then gives r 5, start −π/2,
    /// end still at π: sweep 3π/2, length 5 · 3π/2 = 7.5π.
    @Test("An arc's ends move along the circle and set the radius; the other end stays")
    func arc() async throws {
        let quarter = ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 10, startAngle: 0, sweepAngle: .pi / 2)
        let geometry = MeasurementGeometry(pageID: Self.page, arcs: [quarter])
        let handles = MarkupVertexEditing.vertices(of: geometry)
        #expect(handles.count == 3)
        #expect(Swift.abs(handles[2].x) < 1e-12 && Swift.abs(handles[2].y - 10) < 1e-12)

        let half = try #require(MarkupVertexEditing.replacing(vertexAt: 2, with: PDFPoint(x: -10, y: 0), in: geometry))
        #expect(half.arcs[0].radius == 10)
        #expect(half.arcs[0].startAngle == 0)
        #expect(Swift.abs(half.arcs[0].sweepAngle - .pi) < 1e-12)

        let widened = try #require(MarkupVertexEditing.replacing(vertexAt: 1, with: PDFPoint(x: 0, y: -5), in: half))
        #expect(widened.arcs[0].radius == 5)
        #expect(Swift.abs(widened.arcs[0].startAngle + .pi / 2) < 1e-12)
        #expect(Swift.abs(widened.arcs[0].sweepAngle - 3 * .pi / 2) < 1e-12)

        // Through the engine: the arc length follows the handle, recomputed on commit.
        let documentID = DocumentID(UUID())
        let descriptor = ZPDFContracts.PageDescriptor(id: Self.page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        _ = try await session.calibrate(page: Self.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: Self.page, kind: .measurement, tool: .arcLength,
            subject: "Curved wall", author: "t", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(record))
        let before = NSDecimalNumber(decimal: try #require(await session.markup(record.id)?.measurement?[.arcLength]?.value)).doubleValue
        #expect(Swift.abs(before - 5 * .pi) < 5 * .pi * 1e-12)
        let outcome = try await session.apply(.editVertices(id: record.id, geometry: widened))
        let after = NSDecimalNumber(decimal: try #require(await session.markup(record.id)?.measurement?[.arcLength]?.value)).doubleValue
        #expect(Swift.abs(after - 7.5 * .pi) < 7.5 * .pi * 1e-12)
        _ = try await session.revert(outcome.inverse)
        let undone = NSDecimalNumber(decimal: try #require(await session.markup(record.id)?.measurement?[.arcLength]?.value)).doubleValue
        #expect(Swift.abs(undone - 5 * .pi) < 5 * .pi * 1e-12)
    }

    @Test("A clockwise arc stays clockwise; shape handles cannot be deleted; count marks keep their base")
    func clockwiseAndTopology() throws {
        let clockwise = ArcGeometry(center: PDFPoint(x: 0, y: 0), radius: 10, startAngle: 0, sweepAngle: -.pi / 2)
        let geometry = MeasurementGeometry(pageID: Self.page, arcs: [clockwise])
        // End from (0, −10) to (−10, 0): clockwise from 0 to π is −π.
        let edited = try #require(MarkupVertexEditing.replacing(vertexAt: 2, with: PDFPoint(x: -10, y: 0), in: geometry))
        #expect(Swift.abs(edited.arcs[0].sweepAngle + .pi) < 1e-12)

        let counted = MeasurementGeometry(
            pageID: Self.page,
            circles: [CircleGeometry(center: PDFPoint(x: 0, y: 0), radius: 3)],
            countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 1, y: 1))]
        )
        #expect(MarkupTopologyEditing.base(of: .countMarks, in: counted) == 0)
        #expect(MarkupVertexEditing.vertices(of: counted).first == PDFPoint(x: 1, y: 1))
    }
}
