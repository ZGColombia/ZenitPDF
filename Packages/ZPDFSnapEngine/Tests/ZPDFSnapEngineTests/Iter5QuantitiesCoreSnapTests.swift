import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Quality-loop iteration 5, area "quantities-core" (snap): V-083 (a circle or arc against an
/// ellipse quarter walks the quarter, in either argument order) and V-085 (a hidden cutout's hole,
/// still drawn on its visible parent, stays a snap target).
///
/// Every expected point is derived by hand beside it; each test states the old output.
@Suite("Iteration 5 quantities-core (snap)")
struct Iter5QuantitiesCoreSnapTests {

    // MARK: - V-083

    /// The quarter P(θ) = (30·cos θ, 20·sin θ), θ in [0, π/2].
    static let quarter = SnapEllipseArc(centre: PDFPoint(x: 0, y: 0), u: PDFVector(dx: 30, dy: 0), v: PDFVector(dx: 0, dy: 20))

    /// The quarter at θ = π/4: (30·√2/2, 20·√2/2) = (15√2, 10√2).
    static let atQuarterPi = PDFPoint(x: 15 * 2.0.squareRoot(), y: 10 * 2.0.squareRoot())

    /// The quarter at θ = 5π/12: cos 75° = (√6 − √2)/4, sin 75° = (√6 + √2)/4, so
    /// (7.5·(√6 − √2), 5·(√6 + √2)) ≈ (7.765, 19.319). 14.41 pt from `atQuarterPi`.
    static let atFiveTwelfthsPi = PDFPoint(
        x: 7.5 * (6.0.squareRoot() - 2.0.squareRoot()),
        y: 5 * (6.0.squareRoot() + 2.0.squareRoot())
    )

    /// The circle of R = 500 through both points, its centre on the chord's perpendicular
    /// bisector at √(R² − (c/2)²) from the chord's midpoint, on the side away from the quarter's
    /// centre: ≈ (194.08, 483.31). Between the two points the quarter lies inside the circle and
    /// its ends lie outside it ((30, 0) is 10.4 pt outside, (0, 20) 2.3 pt), so these are the
    /// only two crossings; they cross at 13.5° and 11.7°, so S3's 1e-9 pt applies.
    static let circleCentre: PDFPoint = {
        let a = atQuarterPi, b = atFiveTwelfthsPi
        let mid = PDFPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let chord = a.distance(to: b)
        var nx = -(b.y - a.y) / chord, ny = (b.x - a.x) / chord
        if nx * mid.x + ny * mid.y < 0 { nx = -nx; ny = -ny }
        let apothem = (500.0 * 500.0 - chord * chord / 4).squareRoot()
        return PDFPoint(x: mid.x + nx * apothem, y: mid.y + ny * apothem)
    }()

    static var focus: PDFPoint {
        PDFPoint(x: (atQuarterPi.x + atFiveTwelfthsPi.x) / 2, y: (atQuarterPi.y + atFiveTwelfthsPi.y) / 2)
    }

    /// Both crossings, ascending in x: (7.765, 19.319) then (21.213, 14.142), each within 1e-9 pt.
    static func expectBothCrossings(_ found: [SnapIntersectionSolver.Intersection], _ label: String) {
        #expect(found.count == 2, "\(label): \(found.map(\.point))")
        guard found.count == 2 else { return }
        #expect(found[0].point.distance(to: atFiveTwelfthsPi) <= 1e-9, "\(label): \(found[0].point.distance(to: atFiveTwelfthsPi)) pt off")
        #expect(found[1].point.distance(to: atQuarterPi) <= 1e-9, "\(label): \(found[1].point.distance(to: atQuarterPi)) pt off")
    }

    /// A round Ellipse Area (a circle) whose edge cuts an Ellipse Cutout's quarter twice, 14.4 pt
    /// apart, found in both argument orders.
    /// Old output: with the circle first, `[]` — the circle was walked in 64 steps 49 pt apart, so
    /// both crossings fell inside one step and no sign change was seen; the quarter first found both.
    @Test("V-083: a circle crossing an ellipse quarter twice gives both crossings in either order")
    func circleCrossesQuarterEitherOrder() {
        let circle = SnapCurve.circle(CircleGeometry(center: Self.circleCentre, radius: 500))
        let quarter = SnapCurve.ellipseArc(Self.quarter)
        Self.expectBothCrossings(SnapIntersectionSolver.intersections(circle, quarter, near: Self.focus, within: 30), "circle first")
        Self.expectBothCrossings(SnapIntersectionSolver.intersections(quarter, circle, near: Self.focus, within: 30), "quarter first")
    }

    /// A bulged area edge — an arc of the same circle, from −2.8 rad through 3π/4, which holds both
    /// crossing angles (≈ −1.924 and −1.953 rad from its centre) — against the same quarter.
    /// Old output: with the arc first, `[]` — its 64 steps are 0.0368 rad (18.4 pt) apart, and no
    /// step lands between the crossings, 0.0288 rad apart.
    @Test("V-083: a bulged arc crossing an ellipse quarter twice gives both crossings in either order")
    func arcCrossesQuarterEitherOrder() {
        let arc = SnapCurve.arc(ArcGeometry(center: Self.circleCentre, radius: 500, startAngle: -2.8, sweepAngle: 0.75 * Double.pi))
        let quarter = SnapCurve.ellipseArc(Self.quarter)
        Self.expectBothCrossings(SnapIntersectionSolver.intersections(arc, quarter, near: Self.focus, within: 30), "arc first")
        Self.expectBothCrossings(SnapIntersectionSolver.intersections(quarter, arc, near: Self.focus, within: 30), "quarter first")
    }

    /// A cubic that is the straight line x = 15 from (15, 0) to (15, 30) (controls at the thirds)
    /// crosses the quarter where 30·cos θ = 15: θ = π/3, the point (15, 10√3). Either order walks
    /// the quarter now, and both give that point.
    @Test("V-083: a cubic against an ellipse quarter is order-independent")
    func cubicCrossesQuarterEitherOrder() {
        let cubic = SnapCurve.cubic(p0: PDFPoint(x: 15, y: 0), p1: PDFPoint(x: 15, y: 10), p2: PDFPoint(x: 15, y: 20), p3: PDFPoint(x: 15, y: 30))
        let quarter = SnapCurve.ellipseArc(Self.quarter)
        let expected = PDFPoint(x: 15, y: 10 * 3.0.squareRoot())
        let forward = SnapIntersectionSolver.intersections(cubic, quarter, near: expected, within: 20)
        let backward = SnapIntersectionSolver.intersections(quarter, cubic, near: expected, within: 20)
        #expect(forward.count == 1 && backward.count == 1, "\(forward.map(\.point)) / \(backward.map(\.point))")
        for found in forward + backward {
            #expect(found.point.distance(to: expected) <= 1e-9, "\(found.point.distance(to: expected)) pt off")
        }
    }

    // MARK: - V-085

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-000000000950")!)
    static let stamp = Date(timeIntervalSince1970: 0)
    static let parentID = MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000951")!)
    static let cutoutID = MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000952")!)

    static func record(id: MarkupID, tool: MeasurementTool, geometry: MeasurementGeometry, cutouts: [MarkupID] = [], hidden: Bool = false) -> MarkupRecord {
        var record = MarkupRecord(
            id: id,
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000953")!),
            pageID: page, kind: .measurement, tool: tool, subject: "V-085", author: "A. Berg",
            geometry: geometry, parentMarkupID: tool == .area ? nil : parentID, cutoutMarkupIDs: cutouts,
            createdAt: stamp, modifiedAt: stamp
        )
        record.hidden = hidden
        return record
    }

    /// The 400 × 300 area (100, 100)–(500, 400) whose stored hole is `hole`, owned by one cutout.
    static func parent(hole: PolygonRing) -> MarkupRecord {
        let outer = PolygonRing(points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)])
        return record(id: parentID, tool: .area,
                      geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: outer, holes: [hole])]),
                      cutouts: [cutoutID])
    }

    static func candidates(_ index: SnapIndex, at point: PDFPoint) throws -> [SnapCandidate] {
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(viewPoint: try SnapReplay.viewPoint(point, page: index.page, layout: layout), layout: layout),
                settings: .default
            ),
            in: index
        )
        return [resolution.winner].compactMap { $0 } + resolution.alternatives
    }

    /// An Ellipse Cutout dragged over (200, 200)–(400, 300) — centre (300, 250), semi-axes 100 and
    /// 50 — and hidden. The parent's stored hole is the 360-facet ring the canvas strokes. Projected
    /// with the hidden cutout, the parent carries the cutout's own pieces (its four quarters and its
    /// centre, exactly what the visible cutout projects), never the facet ring. The pointer 2 pt
    /// outside the curve at t = π/3 — curve point (350, 250 + 25√3) — lands on the curve as a
    /// markupEdge within S2's 1e-9 pt, and no candidate near it is a markupVertex (U-085 kept).
    /// Old output: no candidate at all — the parent skipped its hole and the hidden cutout
    /// projected nothing, while the canvas went on drawing the hole.
    @Test("V-085: a hidden Ellipse Cutout's hole snaps on its ellipse through the parent")
    func hiddenEllipseCutoutHoleIsSnapped() throws {
        let facets = PolygonRing(points: (0..<360).map { i in
            let angle = Double(i) * Double.pi / 180
            return PDFPoint(x: 300 + 100.0025 * cos(angle), y: 250 + 50.00125 * sin(angle))
        })
        let parent = Self.parent(hole: facets)
        let box = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 300)])
        let hidden = Self.record(id: Self.cutoutID, tool: .ellipseCutout, geometry: box, hidden: true)
        let shown = Self.record(id: Self.cutoutID, tool: .ellipseCutout, geometry: box)

        #expect(SnapMarkupGeometry.from(hidden) == nil, "a hidden cutout projects nothing itself")
        let outerOnly = try #require(SnapMarkupGeometry.from(parent))
        let projected = try #require(SnapMarkupGeometry.from(parent, unprojectedCutouts: [hidden]))
        let own = try #require(SnapMarkupGeometry.from(shown))
        #expect(projected.geometry == outerOnly.geometry + own.geometry)
        #expect((0..<projected.geometry.count).map(projected.role(at:))
                == (0..<outerOnly.geometry.count).map(outerOnly.role(at:)) + (0..<own.geometry.count).map(own.role(at:)))
        // A record that is not one of the parent's cutouts adds nothing.
        let stranger = Self.record(id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000954")!), tool: .ellipseCutout, geometry: box, hidden: true)
        #expect(try #require(SnapMarkupGeometry.from(parent, unprojectedCutouts: [stranger])).geometry == outerOnly.geometry)

        var before = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        try before.upsert(markup: outerOnly)
        let t = Double.pi / 3
        let onCurve = PDFPoint(x: 300 + 100 * cos(t), y: 250 + 50 * sin(t))
        let nx = cos(t) / 100, ny = sin(t) / 50, norm = (nx * nx + ny * ny).squareRoot()
        let pointer = PDFPoint(x: onCurve.x + 2 * nx / norm, y: onCurve.y + 2 * ny / norm)
        #expect(try Self.candidates(before, at: pointer).isEmpty, "the old projection: nothing to snap to")

        var index = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        try index.upsert(markup: projected)
        let near = try Self.candidates(index, at: pointer)
        let winner = try #require(near.first)
        #expect(winner.kind == .markupEdge && winner.source == .zenitMarkup, "\(winner.kind) \(winner.position)")
        #expect(winner.position.distance(to: onCurve) <= 1e-9, "\(winner.position.distance(to: onCurve)) pt off the ellipse")
        #expect(!near.contains { $0.kind == .markupVertex }, "\(near.map { ($0.kind, $0.position) })")
        // The quadrant (400, 250) is offered as a markupCenter, as on the visible cutout.
        #expect(try Self.candidates(index, at: PDFPoint(x: 401, y: 251)).contains { $0.kind == .markupCenter && $0.position == PDFPoint(x: 400, y: 250) })
    }

    /// A Polygon Cutout (200, 200)–(300, 200)–(300, 300)–(200, 300), hidden. The pointer 1 pt
    /// inside the hole's bottom edge at (250, 201) lands on that edge at (250, 200) — its nearest
    /// point (markupEdge) or its midpoint — and 1 pt off the corner (201, 201) on the markupVertex
    /// (200, 200).
    /// Old output: no candidate at either pointer.
    @Test("V-085: a hidden Polygon Cutout's hole edges and corners stay snap targets")
    func hiddenPolygonCutoutHoleIsSnapped() throws {
        let square = PolygonRing(points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 200), PDFPoint(x: 300, y: 300), PDFPoint(x: 200, y: 300)])
        let parent = Self.parent(hole: square)
        let hidden = Self.record(id: Self.cutoutID, tool: .polygonCutout,
                                 geometry: MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: square)]), hidden: true)
        let projected = try #require(SnapMarkupGeometry.from(parent, unprojectedCutouts: [hidden]))
        #expect(projected.geometry.last == .polyline(points: square.points, isClosed: true))

        var index = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        try index.upsert(markup: projected)
        let edge = try #require(try Self.candidates(index, at: PDFPoint(x: 250, y: 201)).first)
        #expect(edge.source == .zenitMarkup && edge.position.distance(to: PDFPoint(x: 250, y: 200)) <= 1e-9, "\(edge.kind) \(edge.position)")
        #expect(edge.kind == .markupEdge || edge.kind == .midpoint, "\(edge.kind)")
        let corner = try #require(try Self.candidates(index, at: PDFPoint(x: 201, y: 201)).first)
        #expect(corner.kind == .markupVertex && corner.position == PDFPoint(x: 200, y: 200), "\(corner.kind) \(corner.position)")
    }
}
