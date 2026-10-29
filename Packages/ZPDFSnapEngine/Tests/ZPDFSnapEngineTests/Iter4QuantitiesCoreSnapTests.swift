import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// Quality-loop iteration 4, area "quantities-core" (snap): U-085, U-086, U-088 and U-089.
///
/// Every expected point is derived by hand beside it; each test states the old output.
@Suite("Iteration 4 quantities-core (snap)")
struct Iter4QuantitiesCoreSnapTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-000000000850")!)
    static let stamp = Date(timeIntervalSince1970: 0)

    static func record(
        id: String = "00000000-0000-4000-8000-000000000851",
        kind: MarkupKind,
        tool: MeasurementTool? = nil,
        geometry: MeasurementGeometry,
        cutouts: [MarkupID] = []
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID(uuidString: id)!),
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000852")!),
            pageID: page, kind: kind, tool: tool, subject: "U-085", author: "A. Berg",
            geometry: geometry, cutoutMarkupIDs: cutouts, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func resolve(_ index: SnapIndex, at point: PDFPoint, anchor: PDFPoint? = nil) throws -> SnapResolution {
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(point, page: index.page, layout: layout),
                    layout: layout,
                    anchorPagePoint: anchor
                ),
                settings: .default
            ),
            in: index
        )
    }

    static func candidates(_ resolution: SnapResolution) -> [SnapCandidate] {
        [resolution.winner].compactMap { $0 } + resolution.alternatives
    }

    /// The ellipse annotation in the box (100, 100)–(300, 200): centre (200, 150), semi-axes 100
    /// across and 50 up.
    static let ellipse = record(kind: .ellipse, geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 200)]))

    static func ellipseIndex() throws -> SnapIndex {
        var index = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        try index.upsert(markup: try #require(SnapMarkupGeometry.from(ellipse)))
        return index
    }

    // MARK: - U-085

    /// A parent area with an Ellipse Cutout stores the cutout's 360-facet ring as a hole. The
    /// parent projects its outer ring only; its cutout projects its own ellipse. A polygon with a
    /// hole that is no cutout's (nothing in this product draws one) still projects it.
    /// Old output: the parent projected the hole ring too — 360 priority-0 markup vertices on top
    /// of the cutout's curve.
    @Test("U-085: a parent's cutout-derived holes are not indexed on the parent")
    func parentHolesFromCutoutsAreNotProjected() throws {
        let outer = PolygonRing(points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)])
        let facets = (0..<360).map { i -> PDFPoint in
            let angle = Double(i) * Double.pi / 180
            return PDFPoint(x: 300 + 100.0025 * cos(angle), y: 250 + 50.00125 * sin(angle))
        }
        let geometry = MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: outer, holes: [PolygonRing(points: facets)])])
        let cutoutID = MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000853")!)
        let parent = Self.record(kind: .measurement, tool: .area, geometry: geometry, cutouts: [cutoutID])
        #expect(try #require(SnapMarkupGeometry.from(parent)).geometry == [.polyline(points: outer.points, isClosed: true)])

        let plain = Self.record(kind: .measurement, tool: .area, geometry: geometry)
        #expect(try #require(SnapMarkupGeometry.from(plain)).geometry.count == 2, "a hole no cutout owns is still drawn and snapped")

        // Parent and cutout together: at the quadrant (400, 250) nothing is a markupVertex.
        let cutout = Self.record(
            id: cutoutID.rawValue.uuidString, kind: .measurement, tool: .ellipseCutout,
            geometry: MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 300)])
        )
        var index = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        try index.upsert(markup: try #require(SnapMarkupGeometry.from(parent)))
        try index.upsert(markup: try #require(SnapMarkupGeometry.from(cutout)))
        let near = Self.candidates(try Self.resolve(index, at: PDFPoint(x: 401, y: 251)))
        #expect(!near.contains { $0.kind == .markupVertex }, "\(near.map { ($0.kind, $0.position) })")
        #expect(near.contains { $0.kind == .markupCenter && $0.position == PDFPoint(x: 400, y: 250) })
    }

    // MARK: - U-088

    /// One traced area of 150 000 vertices (Region Trace allows 200 000; the index takes 100 000
    /// per ring) beside a Length (400, 100) → (500, 100) and ten vector segments: the page still
    /// builds, the Length's vertex (400, 100) is a markupVertex target, the vector layer holds its
    /// ten segments, and the huge ring alone is left out.
    /// Old output: `build` threw `indexTooLarge(count: 150000, limit: 100000)`, so no index was
    /// stored and every snap on the sheet failed ("Vector Snap could not index this page").
    @Test("U-088: one over-long markup ring is left out; the page's index still builds")
    func oversizeMarkupIsSkipped() throws {
        let page = try SnapScene.letterPage()
        let huge = SnapMarkupGeometry(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000880")!),
            geometry: [.polyline(points: (0..<150_000).map { i in
                let angle = Double(i) / 150_000 * 2 * Double.pi
                return PDFPoint(x: 200 + 100 * cos(angle), y: 500 + 100 * sin(angle))
            }, isClosed: true)]
        )
        let length = SnapMarkupGeometry(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000881")!),
            geometry: [.polyline(points: [PDFPoint(x: 400, y: 100), PDFPoint(x: 500, y: 100)], isClosed: false)]
        )
        let extraction = SnapIndexTests.extraction(primitives: (0..<10).map { SnapIndexTests.lineSegment($0) })
        let index = try SnapIndexBuilder().build(page: page, extraction: extraction, markups: [huge, length])
        #expect(index.vectorPrimitiveCount == 10)
        #expect(index.markupPrimitiveCount == 1)
        let winner = try #require(try Self.resolve(index, at: PDFPoint(x: 401, y: 101)).winner)
        #expect(winner.kind == .markupVertex && winner.position == PDFPoint(x: 400, y: 100))
        // The incremental path still refuses the ring with the typed error, and its caller drops it.
        var incremental = index
        #expect(throws: SnapEngineError.indexTooLarge(count: 150_000, limit: 100_000)) { try incremental.upsert(markup: huge) }
    }

    // MARK: - U-086

    /// `replaceBoundaries` makes the boundary layer hold exactly the set it is given: a zone ring
    /// (four corners and edges) and two calibration points; then the zone moved; then nothing.
    /// Asking again with an unchanged set changes nothing (no generation bump).
    /// Old output: the method did not exist and nothing fed the layer.
    @Test("U-086: the boundary layer follows the set it is given")
    func boundaryLayerFollows() throws {
        var index = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage()).index
        let zone = SnapBoundary(id: "zone:1", category: .zone, geometry: [.polyline(points: [
            PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 200), PDFPoint(x: 300, y: 300), PDFPoint(x: 200, y: 300)
        ], isClosed: true)])
        let calibration = SnapBoundary(id: "calibration:1", category: .calibrationPoint, geometry: [.point(PDFPoint(x: 50, y: 50)), .point(PDFPoint(x: 150, y: 50))])
        let added = index.replaceBoundaries(with: [zone, calibration])
        #expect(added)
        #expect(index.boundaryPrimitiveCount == 3)
        let edge = try #require(try Self.resolve(index, at: PDFPoint(x: 250, y: 201)).winner)
        #expect(edge.kind == .zoneBoundary && edge.position == PDFPoint(x: 250, y: 200))
        #expect(try Self.resolve(index, at: PDFPoint(x: 51, y: 51)).winner?.kind == .calibrationPoint)

        let generation = index.generation
        let unchanged = index.replaceBoundaries(with: [calibration, zone])
        #expect(!unchanged)
        #expect(index.generation == generation, "an unchanged set touches nothing")

        let moved = SnapBoundary(id: "zone:1", category: .zone, geometry: [.polyline(points: [
            PDFPoint(x: 400, y: 400), PDFPoint(x: 500, y: 400), PDFPoint(x: 500, y: 500), PDFPoint(x: 400, y: 500)
        ], isClosed: true)])
        let changed = index.replaceBoundaries(with: [moved, calibration])
        #expect(changed)
        #expect(try Self.resolve(index, at: PDFPoint(x: 250, y: 201)).winner == nil)
        #expect(try Self.resolve(index, at: PDFPoint(x: 450, y: 401)).winner?.kind == .zoneBoundary)

        let cleared = index.replaceBoundaries(with: [])
        #expect(cleared)
        #expect(index.boundaryPrimitiveCount == 0 && index.boundaries.isEmpty)
    }

    // MARK: - U-089

    /// The four quarter pieces of the ellipse recover the exact ellipse: centre (200, 150), and
    /// from it to each quarter's start and end quadrant, 100 across or 50 up.
    @Test("U-089: a quarter cubic of a markup ellipse is read back as its exact ellipse quarter")
    func quarterIsItsEllipse() throws {
        let pieces = try #require(SnapMarkupGeometry.from(Self.ellipse)).geometry
        var quarters: [SnapEllipseArc] = []
        for piece in pieces {
            guard case .cubicCurve(let p0, let p1, let p2, let p3) = piece else { continue }
            quarters.append(try #require(SnapEllipseArc(cubic: p0, p1, p2, p3)))
        }
        #expect(quarters.count == 4)
        for quarter in quarters {
            #expect(quarter.centre.distance(to: PDFPoint(x: 200, y: 150)) <= 1e-12)
            #expect(Swift.abs(quarter.u.magnitude * quarter.v.magnitude - 5000) <= 1e-9)
        }
        // A cubic that is not that construction is not taken for an ellipse.
        #expect(SnapEllipseArc(cubic: PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 30), PDFPoint(x: 20, y: -30), PDFPoint(x: 30, y: 0)) == nil)
    }

    /// The pointer 2 pt outside the ellipse along its normal at 40 parameters spread round the
    /// whole ellipse (none on a quadrant): the foot of the perpendicular is the curve point
    /// (200 + 100·cos t, 150 + 50·sin t) itself (2 pt is less than the smallest radius of
    /// curvature, b²/a = 25), and the winner lands on it within QUALITY_BAR S2's 1e-9 pt.
    /// Old output: the nearest point of the quarter cubic, up to 2.7e-4 × 100 = 0.027 pt away.
    @Test("U-089: an ellipse edge snap lands on the ellipse within 1e-9 pt")
    func edgeSnapIsOnTheEllipse() throws {
        let index = try Self.ellipseIndex()
        var worst = 0.0
        for step in 0..<40 {
            let t = (Double(step) + 0.37) * 2 * Double.pi / 40
            let onCurve = PDFPoint(x: 200 + 100 * cos(t), y: 150 + 50 * sin(t))
            let nx = cos(t) / 100, ny = sin(t) / 50, norm = (nx * nx + ny * ny).squareRoot()
            let pointer = PDFPoint(x: onCurve.x + 2 * nx / norm, y: onCurve.y + 2 * ny / norm)
            let winner = try #require(try Self.resolve(index, at: pointer).winner)
            #expect(winner.kind == .markupEdge, "t = \(t): \(winner.kind)")
            worst = Swift.max(worst, winner.position.distance(to: onCurve))
        }
        #expect(worst <= 1e-9, "worst \(worst) pt off the ellipse")
    }

    /// Tangents from the anchor (500, 150), 300 to the right of the centre on the major axis: the
    /// tangent points of x²/a² + y²/b² = 1 from (X, 0) are x = a²/X, y = ±b·√(1 − a²/X²) — here
    /// (33.33…, ±47.140…) from the centre. The upper one is on the first quarter.
    /// A vertical line x = 250 meets the first quarter at y = 50·√(1 − 0.25) = 43.30127… above
    /// the centre: (250, 193.30127…).
    /// Old output: both on the quarter cubic, about 0.01 pt off.
    @Test("U-089: tangents and crossings on an ellipse quarter are on the ellipse")
    func tangentAndCrossingAreExact() throws {
        let quarter = SnapEllipseArc(centre: PDFPoint(x: 200, y: 150), u: PDFVector(dx: 100, dy: 0), v: PDFVector(dx: 0, dy: 50))
        let thetas = quarter.tangentParameters(from: PDFPoint(x: 500, y: 150))
        #expect(thetas.count == 1)
        let expected = PDFPoint(x: 200 + 10_000.0 / 300, y: 150 + 50 * (1 - 1.0 / 9).squareRoot())
        #expect(quarter.point(at: try #require(thetas.first)).distance(to: expected) <= 1e-9)

        let crossing = SnapIntersectionSolver.intersections(
            .line(SegmentGeometry(start: PDFPoint(x: 250, y: 0), end: PDFPoint(x: 250, y: 300))),
            .ellipseArc(quarter),
            near: PDFPoint(x: 250, y: 193),
            within: 5
        )
        #expect(crossing.count == 1)
        let point = try #require(crossing.first).point
        #expect(point.distance(to: PDFPoint(x: 250, y: 150 + 50 * 0.75.squareRoot())) <= 1e-9, "\(point)")

        // Through the engine: an anchor at (500, 150) offers the tangent point as a markupEdge.
        let index = try Self.ellipseIndex()
        let near = Self.candidates(try Self.resolve(index, at: PDFPoint(x: expected.x + 1, y: expected.y + 1), anchor: PDFPoint(x: 500, y: 150)))
        #expect(near.contains { $0.kind == .markupEdge && $0.position.distance(to: expected) <= 1e-9 },
                "\(near.map { ($0.kind, $0.position) })")
    }

    /// The first quarter's midpoint by arc length, against an independent oracle: the arc length
    /// integrated by composite Simpson over 20 000 panels, and its half found by bisection.
    /// Old output: the arc-length midpoint of the quarter cubic, about 0.01 pt off the ellipse.
    @Test("U-089: an ellipse quarter's midpoint is halfway along the ellipse")
    func quarterMidpointIsOnTheEllipse() throws {
        let quarter = SnapEllipseArc(centre: PDFPoint(x: 200, y: 150), u: PDFVector(dx: 100, dy: 0), v: PDFVector(dx: 0, dy: 50))
        func speed(_ t: Double) -> Double { (pow(100 * sin(t), 2) + pow(50 * cos(t), 2)).squareRoot() }
        func simpson(_ upper: Double) -> Double {
            let n = 20_000
            let h = upper / Double(n)
            var sum = speed(0) + speed(upper)
            for i in 1..<n { sum += (i % 2 == 1 ? 4 : 2) * speed(Double(i) * h) }
            return sum * h / 3
        }
        let half = simpson(Double.pi / 2) / 2
        var lo = 0.0, hi = Double.pi / 2
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if simpson(mid) < half { lo = mid } else { hi = mid }
        }
        let expected = quarter.point(at: 0.5 * (lo + hi))
        #expect(quarter.arcLengthMidpoint.distance(to: expected) <= 1e-9, "\(quarter.arcLengthMidpoint) for \(expected)")
    }
}
