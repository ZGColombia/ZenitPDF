import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Quality-loop iteration 6, area "quantities-core" (snap): W-087 (intersection participants
/// must have a curve near the cursor; a markup arc is boxed as the arc, not its circle, and its
/// centre is a piece of its own) and W-088 (a vertex between two arc edges is offered as the
/// stored vertex, not as an end recomputed from centre and radius).
///
/// Every expected point is derived by hand beside it; each test states the old output.
@Suite("Iteration 6 quantities-core (snap)")
struct Iter6QuantitiesCoreSnapTests {

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

    static func measurement(_ tool: MeasurementTool, _ geometry: (PageID) -> MeasurementGeometry, page: PageDescriptor, id: String) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return MarkupRecord(
            id: MarkupID(UUID(uuidString: id)!),
            documentID: page.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: tool,
            subject: "Run",
            author: "A. Berg",
            geometry: geometry(page.id),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: - W-087: participants

    /// 24 closed square frames centred on the cursor (300, 300.3), half sides 100, 105, … 215 pt,
    /// so every frame's box contains the cursor (box distance 0) and its nearest edge is 100 pt
    /// or more away — far outside the 10 pt radius at 100 %, so none decomposes into a local curve.
    /// Two axis-aligned lines cross at (300.5, 300): y = 300 (box distance 0.3) and x = 300.5
    /// (box distance 0.5). The crossing is √(0.5² + 0.3²) ≈ 0.583 pt from the cursor.
    ///
    /// Old output: the 24 frames sorted ahead of both lines in `(box distance, id)` order and took
    /// all 24 intersection slots, so no crossing was solved and the winner was the midpoint of
    /// y = 300, (300, 300), 0.5 pt from the crossing — confirmed by running this test against
    /// the old prefix.
    @Test("W-087: frames round the cursor take no intersection slot, so the crossing under it wins")
    func framesDoNotCrowdOutTheCrossing() throws {
        let page = try SnapScene.letterPage()
        var primitives: [SnapPrimitive] = []
        for i in 0..<24 {
            let half = 100 + 5 * Double(i)
            primitives.append(try #require(SnapScene.polyline(
                id: UInt64(1 + i),
                [PDFPoint(x: 300 - half, y: 300 - half), PDFPoint(x: 300 + half, y: 300 - half),
                 PDFPoint(x: 300 + half, y: 300 + half), PDFPoint(x: 300 - half, y: 300 + half)],
                isClosed: true
            )))
        }
        primitives.append(SnapScene.segment(id: 100, PDFPoint(x: 250, y: 300), PDFPoint(x: 350, y: 300)))
        primitives.append(SnapScene.segment(id: 101, PDFPoint(x: 300.5, y: 250), PDFPoint(x: 300.5, y: 350)))
        let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)

        let resolution = try Self.resolve(PDFPoint(x: 300, y: 300.3), page: scene.page, index: scene.index)
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .intersection, "\(winner.kind) at \(winner.position)")
        #expect(winner.position.distance(to: PDFPoint(x: 300.5, y: 300)) <= 1e-9)
    }

    // MARK: - W-087: a shallow markup arc's box, and its centre

    /// A Polylength chain from A = (700, 5200) to B = (300, 5200), bulge 0.02. By hand: chord
    /// c = 400, b = tan(θ/4) = 0.02; r = c·(1 + b²)/(4b) = 400·1.0004/0.08 = 5002; the apothem
    /// r − s with sagitta s = b·c/2 = 4 is 4998; the edge runs in −x, whose left normal is −y, so
    /// the centre is (500, 5200 − 4998) = (500, 202) and the arc rises to (500, 202 + 5002) =
    /// (500, 5204).
    static let shallowPage: PageDescriptor = {
        try! SnapScene.letterPage(media: PDFRect(x: 0, y: 0, width: 1000, height: 5400))
    }()

    static let shallowChain: MarkupRecord = measurement(.polylength, { page in
        MeasurementGeometry(
            pageID: page,
            points: [PDFPoint(x: 700, y: 5200), PDFPoint(x: 300, y: 5200)],
            pointBulges: [0.02, 0]
        )
    }, page: shallowPage, id: "00000000-0000-4000-8000-0000000006a1")

    /// The arc's entry is boxed as the arc: x 300…700, y 5200…5204.
    /// Old output: its whole circle, x −4502…5502, y −4800…5204 — larger than the sheet, so the
    /// arc was a distance-0 entry (and an intersection participant) under every cursor on it.
    @Test("W-087: a shallow markup arc is indexed with the arc's own box, not its circle's")
    func shallowArcHasATightBox() throws {
        let projected = try #require(SnapMarkupGeometry.from(Self.shallowChain))
        let entries = try SnapIndexBuilder().markupEntries(projected)
        let arcEntry = try #require(entries.first { $0.primitive.kind == .ellipticalArc })
        let box = arcEntry.bounds
        #expect(Swift.abs(box.minX - 300) <= 1e-9 && Swift.abs(box.maxX - 700) <= 1e-9, "\(box)")
        #expect(Swift.abs(box.minY - 5200) <= 1e-9 && Swift.abs(box.maxY - 5204) <= 1e-9, "\(box)")
    }

    /// The centre (500, 202) is 4998 pt from the arc's box, so it is reached through its own
    /// piece: a pointer 0.5 pt off it snaps to it as a markup centre. Before the box was
    /// tightened the arc's circle box held the centre; this pins that tightening it lost nothing.
    @Test("W-087: the centre of a shallow markup arc stays a snap target")
    func shallowArcCentreIsReachable() throws {
        let scene = try SnapScene.withoutVectorContent(
            page: Self.shallowPage, markups: [try #require(SnapMarkupGeometry.from(Self.shallowChain))]
        )
        let resolution = try Self.resolve(PDFPoint(x: 500.3, y: 202.4), page: scene.page, index: scene.index)
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .markupCenter, "\(winner.kind) at \(winner.position)")
        #expect(winner.position.distance(to: PDFPoint(x: 500, y: 202)) <= 1e-9, "\(winner.position)")
    }

    // MARK: - W-088: the stored vertex between two arc edges

    /// A Polylength chain P0 = (400, 1500) → P1 = (1400, 1502) → P2 = (2400, 1503), both edges
    /// bulge 1.5e-5: two nearly straight arcs (sagitta b·c/2 ≈ 0.0075 pt, r ≈ 1.67e7 pt) that
    /// meet at P1 at about 0.06°, below S5's floor, so no crossing is offered there.
    static let wavePage: PageDescriptor = {
        try! SnapScene.letterPage(media: PDFRect(x: 0, y: 0, width: 3000, height: 2000))
    }()
    static let p0 = PDFPoint(x: 400, y: 1500)
    static let p1 = PDFPoint(x: 1400, y: 1502)
    static let p2 = PDFPoint(x: 2400, y: 1503)
    static let waveBulge = 1.5e-5

    /// A pointer 0.5 pt off P1 snaps to P1 itself, bit for bit, as a markup vertex.
    /// Old output: P1 was offered only as the first arc's recomputed `endPoint` and the second's
    /// `startPoint`, 1.80e-9 and 2.10e-9 pt off P1 (asserted below) — both outside S2's 1e-9;
    /// the old winner was (1400.0000000017972, 1502), confirmed against the old projection.
    @Test("W-088: a vertex between two arc edges snaps to the stored vertex exactly")
    func vertexBetweenArcsIsTheStoredOne() throws {
        let first = try #require(BulgeArc.arc(from: Self.p0, to: Self.p1, bulge: Self.waveBulge))
        let second = try #require(BulgeArc.arc(from: Self.p1, to: Self.p2, bulge: Self.waveBulge))
        // What the old projection offered at P1: both recomputed ends miss it by more than 1e-9.
        #expect(first.endPoint.distance(to: Self.p1) > 1e-9, "\(first.endPoint.distance(to: Self.p1))")
        #expect(second.startPoint.distance(to: Self.p1) > 1e-9, "\(second.startPoint.distance(to: Self.p1))")

        let record = Self.measurement(.polylength, { page in
            MeasurementGeometry(pageID: page, points: [Self.p0, Self.p1, Self.p2], pointBulges: [Self.waveBulge, Self.waveBulge, 0])
        }, page: Self.wavePage, id: "00000000-0000-4000-8000-0000000006a2")
        let projected = try #require(SnapMarkupGeometry.from(record))
        // Two arcs, then P0, the first centre, P1, the second centre and P2 — the stored chain
        // ends and the vertex between the arcs as outline points, each centre as a centre.
        try #require(projected.geometry.count == 7)
        #expect(Array(projected.geometry[2...]).filter { if case .point = $0 { true } else { false } }.count == 5)
        #expect(projected.geometry[2] == .point(Self.p0))
        #expect(projected.geometry[4] == .point(Self.p1))
        #expect(projected.geometry[6] == .point(Self.p2))
        #expect((0..<projected.geometry.count).map(projected.role(at:))
                == [.outline, .outline, .outline, .centre, .outline, .centre, .outline])

        let scene = try SnapScene.withoutVectorContent(page: Self.wavePage, markups: [projected])
        let resolution = try Self.resolve(PDFPoint(x: 1400.3, y: 1502.4), page: scene.page, index: scene.index)
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .markupVertex, "\(winner.kind) at \(winner.position)")
        #expect(winner.position == Self.p1, "\(winner.position.distance(to: Self.p1)) pt off the stored vertex")
    }

    /// A closed ring of two arcs — a lens — has both vertices between arcs: each is offered once,
    /// as the stored point, and each arc's centre once. Ring (200, 300) → (300, 300) → back,
    /// bulges 0.5 and 0.5: pieces = two arcs, then (200, 300), a centre, (300, 300), a centre.
    /// Old output: the two arcs alone, both vertices offered only as recomputed arc ends.
    @Test("W-088: a ring of arcs offers each stored vertex once")
    func ringOfArcsOffersEachVertexOnce() throws {
        let page = try SnapScene.letterPage()
        let record = Self.measurement(.area, { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 200, y: 300), PDFPoint(x: 300, y: 300)], isClosed: true, bulges: [0.5, 0.5]
            ))])
        }, page: page, id: "00000000-0000-4000-8000-0000000006a3")
        let projected = try #require(SnapMarkupGeometry.from(record))
        try #require(projected.geometry.count == 6)
        #expect(projected.geometry[2] == .point(PDFPoint(x: 200, y: 300)))
        #expect(projected.geometry[4] == .point(PDFPoint(x: 300, y: 300)))
        #expect((0..<projected.geometry.count).map(projected.role(at:))
                == [.outline, .outline, .outline, .centre, .outline, .centre])
    }
}
