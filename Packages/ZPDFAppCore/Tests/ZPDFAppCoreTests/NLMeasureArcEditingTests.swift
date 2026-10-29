import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-05 first slice: bending a committed edge into an arc, and every edit that must keep
/// the bulges aligned. Hand-derived at 1 m/pt.
@Suite("Arc segments on committed markups (NL-MEASURE-05)")
struct NLMeasureArcEditingTests {

    static let page = PageID(UUID())

    /// Bulges equal within 1e-12 (tan(π/4) is 0.9999999999999999 in binary).
    static func near(_ values: [Double]?, _ expected: [Double]) -> Bool {
        guard let values, values.count == expected.count else { return false }
        return zip(values, expected).allSatisfy { Swift.abs($0 - $1) <= 1e-12 }
    }
    static let rectangle = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
        PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5), PDFPoint(x: 0, y: 5)
    ]))])

    /// The right side (10,0)→(10,5) through (12.5, 2.5): a half circle bulging out, bulge 1.
    @Test("Bending the right side through (12.5, 2.5) gives bulge 1; through the chord, straight")
    func bend() throws {
        let bent = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 12.5, y: 2.5), in: Self.rectangle, tool: .area))
        let bulges = try #require(bent.polygons.first?.outer.bulges)
        #expect(bulges.count == 4)
        #expect(Swift.abs(bulges[1] - 1) < 1e-12)
        #expect(bulges[0] == 0 && bulges[2] == 0 && bulges[3] == 0)
        // Bending inward through (8.75, 2.5): the circle through (10,0), (8.75,2.5), (10,5) has
        // sagitta 1.25 on a chord of 5, so |b| = 2·1.25/5 = 0.5, negative (clockwise).
        let inward = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 8.75, y: 2.5), in: Self.rectangle, tool: .area))
        #expect(Swift.abs((inward.polygons.first?.outer.bulges?[1] ?? 0) + 0.5) < 1e-12)
        // A point on the chord straightens it again, and a ring with no arc stores none.
        let straight = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 10, y: 1), in: bent, tool: .area))
        #expect(straight.polygons.first?.outer.bulges == nil)
        // A chain: the second edge of a polylength.
        let chain = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5)])
        let bentChain = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 12.5, y: 2.5), in: chain, tool: .polylength))
        #expect(bentChain.pointBulges?.count == 3)
        #expect(MarkupTopologyEditing.bending(edgeAfter: 2, through: PDFPoint(x: 1, y: 1), in: chain, tool: .polylength) == nil, "no edge after the last vertex")
    }

    @Test("Inserting and removing keep the bulges aligned; an arc is split, not refused")
    func topology() throws {
        let bent = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 12.5, y: 2.5), in: Self.rectangle, tool: .area))
        // Insert on the straight bottom edge: bulges gain a 0 after index 0.
        let inserted = try #require(MarkupTopologyEditing.inserting(PDFPoint(x: 5, y: 0), afterVertex: 0, in: bent, tool: .area))
        #expect(inserted.polygons.first?.outer.points.count == 5)
        #expect(Self.near(inserted.polygons.first?.outer.bulges, [0, 0, 1, 0, 0]))
        // Insert on the arc edge (ADR-0030 §5.6; old output: refused, `nil`): a point that projects
        // onto an end of the arc — (10, 2) projects radially onto the start (10, 0) — still cuts
        // nothing; one near the apex splits the semicircle into two quarter arcs, tan(π/8) each.
        #expect(MarkupTopologyEditing.inserting(PDFPoint(x: 10, y: 2), afterVertex: 1, in: bent, tool: .area) == nil)
        let apex = try #require(MarkupTopologyEditing.inserting(PDFPoint(x: 12.6, y: 2.5), afterVertex: 1, in: bent, tool: .area))
        let quarter = Foundation.tan(Double.pi / 8)
        #expect(Self.near(apex.polygons.first?.outer.bulges, [0, quarter, quarter, 0, 0]))
        #expect(Swift.abs((apex.polygons.first?.outer.points[2].x ?? 0) - 12.5) <= 1e-12)
        // Remove a vertex that ends the arc: refused; one that does not: allowed, bulge removed.
        #expect(MarkupTopologyEditing.removing(vertexAt: 1, in: inserted, tool: .area) != nil)
        #expect(MarkupTopologyEditing.removing(vertexAt: 2, in: inserted, tool: .area) == nil)
        #expect(MarkupTopologyEditing.removing(vertexAt: 3, in: inserted, tool: .area) == nil)
        let removed = try #require(MarkupTopologyEditing.removing(vertexAt: 1, in: inserted, tool: .area))
        #expect(Self.near(removed.polygons.first?.outer.bulges, [0, 1, 0, 0]))
    }

    /// Through the session: bent right side → area 50 + 3.125π, perimeter 25 + 2.5π; moving the
    /// markup keeps the arc; one undo straightens it; split now divides it exactly (ADR-0030 §5.6).
    @Test("The bent edge through the session: exact numbers, kept by a move, one undo, split exact")
    func session() async throws {
        let documentID = DocumentID(UUID())
        let descriptor = ZPDFContracts.PageDescriptor(id: Self.page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        _ = try await session.calibrate(page: Self.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 0)
        let record = ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: documentID, pageID: Self.page, kind: .measurement, tool: .area,
                                                subject: "Bay", author: "t", geometry: Self.rectangle, createdAt: stamp, modifiedAt: stamp)
        _ = try await session.apply(.addMarkup(record))
        let bent = try #require(MarkupTopologyEditing.bending(edgeAfter: 1, through: PDFPoint(x: 12.5, y: 2.5), in: Self.rectangle, tool: .area))
        let outcome = try await session.apply(.editVertices(id: record.id, geometry: bent))
        func value(_ field: ZPDFContracts.MeasurementField) async -> Double {
            NSDecimalNumber(decimal: await session.markup(record.id)?.measurement?[field]?.value ?? 0).doubleValue
        }
        let area = 50 + 3.125 * Double.pi, perimeter = 25 + 2.5 * Double.pi
        #expect(Swift.abs(await value(.netArea) - area) <= area * 1e-12)
        #expect(Swift.abs(await value(.perimeter) - perimeter) <= perimeter * 1e-12)

        _ = try await session.apply(.moveMarkup(id: record.id, dx: 3, dy: 4))
        #expect(Self.near(await session.markup(record.id)?.geometry?.polygons.first?.outer.bulges, [0, 1, 0, 0]))
        #expect(Swift.abs(await value(.netArea) - area) <= area * 1e-12)
        // Old output: `AreaSplitRefusal.hasArcs`. Moved by (3, 4), the line x = 8 cuts the 10 × 5
        // rectangle at 5 from its left side: parts 5 × 5 = 25 and 25 + 3.125π with the arc whole.
        let commands = try await session.splitCommands(markup: record.id, along: [PDFPoint(x: 8, y: -10), PDFPoint(x: 8, y: 20)])
        #expect(commands.count == 3)
        _ = try await session.revert(outcome.inverse)
        #expect(Swift.abs(await value(.netArea) - 50) <= 1e-12 * 50)
    }
}
