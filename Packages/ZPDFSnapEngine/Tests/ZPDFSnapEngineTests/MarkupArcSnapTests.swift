import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// NL-MEASURE-05 (ADR-0030 §5.6): a markup's arc edge snaps as the arc, not as its chord.
///
/// The markup is the golden shape at page scale: the rectangle (100,100)–(300,100)–(300,200)–
/// (100,200) whose right side (300,100)→(300,200) is an outward semicircle, bulge 1 — centre
/// (300, 150), radius 50, apex (350, 150).
@Suite("Snapping to a markup's arc edge (NL-MEASURE-05)")
struct MarkupArcSnapTests {

    static let record: MarkupRecord = {
        let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-00000000a0c1")!)
        let stamp = Date(timeIntervalSince1970: 0)
        return MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-00000000a0c2")!),
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-00000000a0c3")!),
            pageID: page,
            kind: .measurement,
            tool: .area,
            subject: "Bay",
            author: "test",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)],
                isClosed: true,
                bulges: [0, 1, 0, 0]
            ))]),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }()

    static func resolve(_ point: PDFPoint) throws -> SnapResolution {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index
        try index.upsert(markup: try #require(SnapMarkupGeometry.from(record)))
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(viewPoint: try SnapReplay.viewPoint(point, page: page, layout: layout), layout: layout),
                settings: .default
            ),
            in: index
        )
    }

    @Test("The arc edge is projected as an arc; straight edges stay one run each")
    func projection() throws {
        let projected = try #require(SnapMarkupGeometry.from(Self.record))
        let geometry = projected.geometry
        // Old output: one closed polyline of the four vertices, the arc snapping as the chord x = 300.
        // Now: the bottom edge, the arc, and the top and left edges as one run — three drawn
        // pieces — then the arc's centre as a piece of its own (W-087: the arc's box no longer
        // reaches it). Both arc ends sit on a straight run, so no vertex piece is added (W-088).
        #expect(geometry.count == 4)
        #expect((0..<geometry.count).map(projected.role(at:)) == [.outline, .outline, .outline, .centre])
        guard case let .ellipticalArc(arc)? = geometry.first(where: { if case .ellipticalArc = $0 { return true } else { return false } }) else {
            Issue.record("no arc primitive"); return
        }
        #expect(Swift.abs(arc.center.x - 300) <= 1e-12 && Swift.abs(arc.center.y - 150) <= 1e-12)
        #expect(Swift.abs(arc.radius - 50) <= 1e-12)
        #expect(geometry[3] == .point(arc.center))
        // A chain's arc edge is an arc primitive too, and its straight runs are polylines with
        // edges and midpoints (T-071, ADR-0037): the chain (100,100) → (300,100) ⌒ (300,200) →
        // (100,200) is a run, the arc, and a run.
        // Old output: the four vertices as bare points plus the arc — no straight edge snappable.
        var chainRecord = Self.record
        chainRecord.geometry = MeasurementGeometry(
            pageID: Self.record.pageID,
            points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)],
            pointBulges: [0, 1, 0, 0]
        )
        let chain = try #require(SnapMarkupGeometry.from(chainRecord)).geometry
        // Three drawn pieces, then the arc's centre (W-087).
        #expect(chain.count == 4)
        #expect(chain.first == .polyline(points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)], isClosed: false))
        #expect(chain[2] == .polyline(points: [PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)], isClosed: false))
        if case .ellipticalArc = chain[1] {} else { Issue.record("the middle piece should be the arc, got \(chain[1])") }
        if case .point(let centre) = chain[3] {
            #expect(Swift.abs(centre.x - 300) <= 1e-12 && Swift.abs(centre.y - 150) <= 1e-12)
        } else {
            Issue.record("the last piece should be the arc's centre, got \(chain[3])")
        }
    }

    /// A pointer 2 pt outside the arc at 30° from the centre, (300 + 52·cos 30°, 150 + 52·sin 30°),
    /// snaps to the nearest point of the arc, (300 + 50·cos 30°, 150 + 50·sin 30°) = (343.301…, 175):
    /// exactly on the circle. The chord x = 300 is 45 pt away and would not be in reach.
    @Test("Nearest point on the arc: exactly on the circle")
    func nearestOnArc() throws {
        let angle = Double.pi / 6
        let resolution = try Self.resolve(PDFPoint(x: 300 + 52 * Foundation.cos(angle), y: 150 + 52 * Foundation.sin(angle)))
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .markupEdge)
        #expect(Swift.abs(winner.position.x - (300 + 50 * Foundation.cos(angle))) <= 1e-9)
        #expect(Swift.abs(winner.position.y - (150 + 50 * Foundation.sin(angle))) <= 1e-9)
    }

    /// Near the apex the arc's midpoint (350, 150) — by length, the point halfway round the
    /// semicircle — is a candidate, as a markup edge's midpoint. The pointer sits 1.8 pt off it, so
    /// the nearer projection onto the arc may win; the midpoint must be in the ranked list.
    @Test("The arc midpoint (350, 150) is offered")
    func arcMidpoint() throws {
        let resolution = try Self.resolve(PDFPoint(x: 351.5, y: 151))
        let candidates = [resolution.winner].compactMap { $0 } + resolution.alternatives
        #expect(candidates.contains { $0.kind == .markupEdge && Swift.abs($0.position.x - 350) <= 1e-9 && Swift.abs($0.position.y - 150) <= 1e-9 },
                "\(candidates.map { ($0.kind, $0.position) })")
        // Every markup-edge candidate lies on the circle, none on the chord x = 300.
        for candidate in candidates where candidate.kind == .markupEdge {
            #expect(Swift.abs(candidate.position.distance(to: PDFPoint(x: 300, y: 150)) - 50) <= 1e-9)
        }
    }
}
