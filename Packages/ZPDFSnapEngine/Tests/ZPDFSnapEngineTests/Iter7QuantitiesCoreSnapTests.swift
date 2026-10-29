import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// Quality-loop iteration 7, area "quantities-core" (snap): X-042 (a three-point Arc Length is
/// indexed as the arc it measures, not two chords) and X-045 (Room Detection's face cap counts
/// faces, not seeds).
///
/// Every expected point and count is derived by hand beside it; each test states the old output.
@Suite("Iteration 7 quantities-core (snap)")
struct Iter7QuantitiesCoreSnapTests {

    typealias Fixtures = RegionTracerTests

    static func resolve(_ point: PDFPoint, page: PageDescriptor, index: SnapIndex) throws -> SnapResolution {
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

    static func arcLength(_ points: [PDFPoint], page: PageDescriptor) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000007a1")!),
            documentID: page.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .arcLength,
            subject: "Curved wall",
            author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: points),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: - X-042

    static let p0 = PDFPoint(x: 300, y: 300)
    static let p1 = PDFPoint(x: 350, y: 350)
    static let p2 = PDFPoint(x: 400, y: 300)

    /// Arc Length (300, 300) → (350, 350) → (400, 300): the semicircle about (350, 300) of r = 50,
    /// clockwise over the top — the arc `SegmentMath.arc(through:)` gives the engine. Projected:
    /// the arc, then its stored start, its centre and its stored end.
    /// Old output: one piece, `.polyline([(300, 300), (350, 350), (400, 300)], open)` — two chords.
    @Test("X-042: a three-point Arc Length is indexed as its arc, with its ends and centre")
    func arcLengthProjectsTheArc() throws {
        let page = try SnapScene.letterPage()
        let projected = try #require(SnapMarkupGeometry.from(Self.arcLength([Self.p0, Self.p1, Self.p2], page: page)))
        try #require(projected.geometry.count == 4, "\(projected.geometry)")
        guard case .ellipticalArc(let arc) = projected.geometry[0] else {
            Issue.record("expected the arc first, got \(projected.geometry[0])")
            return
        }
        let measured = try SegmentMath.arc(through: Self.p0, Self.p1, Self.p2)
        #expect(arc.center.distance(to: measured.center) <= 1e-9)
        #expect(arc.center.distance(to: PDFPoint(x: 350, y: 300)) <= 1e-9)
        #expect(Swift.abs(arc.radius - measured.radius) <= 1e-9)
        #expect(Swift.abs(arc.sweepAngle - measured.sweepAngle) <= 1e-12)
        #expect(Swift.abs(arc.sweepAngle - -Double.pi) <= 1e-12)
        #expect(projected.geometry[1] == .point(Self.p0))
        #expect(projected.geometry[3] == .point(Self.p2))
        guard case .point(let centre) = projected.geometry[2] else {
            Issue.record("expected the centre, got \(projected.geometry[2])")
            return
        }
        #expect(centre.distance(to: PDFPoint(x: 350, y: 300)) <= 1e-9)
        #expect((0..<4).map(projected.role(at:)) == [.outline, .outline, .centre, .outline])
    }

    /// The cursor 0.3 pt outside the arc at 45°: (350 + 50.3·cos 45°, 300 + 50.3·sin 45°). The arc
    /// point under it is (350 + 50·cos 45°, 300 + 50·sin 45°) = (385.3553391, 335.3553391).
    /// Old output (asserted on the old projection below): no markup target — the nearest chord,
    /// (350, 350)–(400, 300), is 14.9 pt away, outside the 10 pt radius.
    @Test("X-042: the cursor by the drawn arc snaps onto the arc")
    func cursorSnapsOntoTheArc() throws {
        let page = try SnapScene.letterPage()
        let projected = try #require(SnapMarkupGeometry.from(Self.arcLength([Self.p0, Self.p1, Self.p2], page: page)))
        let c = Foundation.cos(Double.pi / 4)
        let cursor = PDFPoint(x: 350 + 50.3 * c, y: 300 + 50.3 * c)
        let onArc = PDFPoint(x: 350 + 50 * c, y: 300 + 50 * c)

        let scene = try SnapScene.withoutVectorContent(page: page, markups: [projected])
        let winner = try #require(try Self.resolve(cursor, page: scene.page, index: scene.index).winner)
        #expect(winner.kind == .markupEdge, "\(winner.kind) at \(winner.position)")
        #expect(winner.position.distance(to: onArc) <= 1e-9, "\(winner.position.distance(to: onArc)) pt off the arc")

        let old = SnapMarkupGeometry(id: projected.id, geometry: [.polyline(points: [Self.p0, Self.p1, Self.p2], isClosed: false)])
        let oldScene = try SnapScene.withoutVectorContent(page: page, markups: [old])
        let oldWinner = try Self.resolve(cursor, page: oldScene.page, index: oldScene.index).winner
        #expect(oldWinner == nil, "the old chords offered \(String(describing: oldWinner))")
    }

    // MARK: - X-045

    /// An `n × n` grid of 100 pt cells drawn as `n + 1` horizontal and `n + 1` vertical lines:
    /// `n²` bounded faces of 10 000 pt² each, every one a room under ``roomOptions``.
    static func grid(_ n: Int) -> [VectorPrimitive] {
        var lines: [VectorPrimitive] = []
        var id: UInt64 = 1
        let extent = Double(n) * 100
        for index in 0...n {
            let at = Double(index) * 100
            lines.append(Fixtures.line(id, 0, at, extent, at)); id += 1
            lines.append(Fixtures.line(id, at, 0, at, extent)); id += 1
        }
        return lines
    }

    static let roomOptions = RoomDetector.Options(
        minimumArea: 1_000, maximumArea: 50_000, minimumWidth: 20, maximumClosureWidth: 60
    )

    /// A 3 × 3 grid has 9 qualifying faces; a cap of 9 reads them all, a cap of 8 stops at 8.
    /// Old output: every face gives 5 seeds (one per scan height in a square), so the seed count
    /// passed 9 after the second face — 2 rooms, `truncated` — and passed 8 at the same face.
    @Test("X-045: the face cap counts faces — a cap of 9 reads all 9 faces")
    func capCountsFaces() throws {
        let prepared = RegionTracer.prepare(primitives: Self.grid(3))
        var options = Self.roomOptions
        options.maximumFaces = 9
        guard case .rooms(let rooms, let truncated) = RoomDetector.detect(prepared, options: options) else {
            Issue.record("expected rooms")
            return
        }
        #expect(!truncated)
        #expect(rooms.count == 9, "\(rooms.count)")
        #expect(rooms.allSatisfy { Swift.abs($0.region.area - 10_000) <= 1e-9 })

        options.maximumFaces = 8
        guard case .rooms(let capped, let cut) = RoomDetector.detect(prepared, options: options) else {
            Issue.record("expected rooms")
            return
        }
        #expect(cut, "a ninth qualifying face is left out and said so")
        #expect(capped.count == 8, "\(capped.count)")
    }

    /// The finding's band: a 21 × 21 grid has 441 qualifying faces, between 400 and the default
    /// cap of 2 000, so every room is proposed and nothing is said to be left out.
    /// Old output: 400 faces gave the 2 000th seed, the search stopped — 400 rooms, `truncated`.
    @Test("X-045: 441 rooms under the default cap of 2 000 faces are all proposed")
    func defaultCapReadsFourHundredFortyOneFaces() throws {
        let prepared = RegionTracer.prepare(primitives: Self.grid(21))
        guard case .rooms(let rooms, let truncated) = RoomDetector.detect(prepared, options: Self.roomOptions) else {
            Issue.record("expected rooms")
            return
        }
        #expect(Self.roomOptions.maximumFaces == 2_000)
        #expect(!truncated)
        #expect(rooms.count == 441, "\(rooms.count)")
    }
}
