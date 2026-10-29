import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Quality-loop iteration 3, area "quantities-core": snap finding T-071 — a markup snaps where it
/// is drawn. An ellipse is its inscribed curve, never its box corners; a turned annotation snaps
/// at its turned outline; a measured chain offers its straight edges.
///
/// Every expected point is derived by hand beside it. Each test states the output the old
/// projection (`SnapMarkupGeometry.from`, which read every stored point as a priority-0 vertex)
/// produced.
@Suite("Iteration 3 quantities-core (snap)")
struct Iter3QuantitiesCoreSnapTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000071a1")!)

    static func record(
        kind: MarkupKind,
        tool: MeasurementTool? = nil,
        geometry: MeasurementGeometry,
        rotation: Double? = nil
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        var record = MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000071a2")!),
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-0000000071a3")!),
            pageID: page,
            kind: kind,
            tool: tool,
            subject: "T-071",
            author: "test",
            geometry: geometry,
            createdAt: stamp,
            modifiedAt: stamp
        )
        record.style.rotationDegrees = rotation
        return record
    }

    static func points(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    static func resolve(_ record: MarkupRecord, at point: PDFPoint) throws -> SnapResolution {
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

    static func candidates(_ resolution: SnapResolution) -> [SnapCandidate] {
        [resolution.winner].compactMap { $0 } + resolution.alternatives
    }

    /// The ellipse annotation drawn in the box (100, 100)–(300, 200): centre (200, 150), semi-axes
    /// 100 across and 50 up.
    static let ellipse = record(kind: .ellipse, geometry: MeasurementGeometry(pageID: page, points: points([(100, 100), (300, 200)])))

    // MARK: - Ellipses

    /// The pointer 2 pt inside the box corner (300, 200). Nothing is drawn there: the ellipse
    /// passes 30 pt away, so nothing of this markup is in reach.
    /// Old output: the winner was a markupVertex at the corner (300, 200) — priority 0, ahead of
    /// any PDF endpoint up to 6 view points nearer.
    @Test("T-071: an ellipse's box corner is not a snap target")
    func ellipseCornerIsNotATarget() throws {
        let resolution = try Self.resolve(Self.ellipse, at: PDFPoint(x: 298, y: 198))
        let near = Self.candidates(resolution).filter { $0.position.distance(to: PDFPoint(x: 300, y: 200)) <= 1e-6 }
        #expect(near.isEmpty, "\(near.map { ($0.kind, $0.position) })")
        #expect(!Self.candidates(resolution).contains { $0.kind == .markupVertex })
    }

    /// The pointer 2 pt outside the ellipse along its normal at parameter t = π/3: the curve point
    /// is (200 + 100·cos t, 150 + 50·sin t) = (250, 193.301…), the outward normal is
    /// (cos t / 100, sin t / 50) normalised. The snap lands on the curve as a markupEdge, within
    /// QUALITY_BAR S2's 1e-9 pt of the true ellipse (U-089 tightened this from the quarter-cubic's
    /// 2.7e-4 × 100 = 0.027 pt; old output 0.0093 pt off). The quadrant point
    /// (300, 150) is offered as markupCenter — what a markup circle's quadrants are — and the
    /// centre (200, 150) as markupCenter.
    /// Old output: no candidate on the curve at all (the ellipse contributed its two corners only).
    @Test("T-071: the ellipse curve, its quadrant points and its centre are targets")
    func ellipseCurveIsATarget() throws {
        let t = Double.pi / 3
        let onCurve = PDFPoint(x: 200 + 100 * Foundation.cos(t), y: 150 + 50 * Foundation.sin(t))
        let nx = Foundation.cos(t) / 100, ny = Foundation.sin(t) / 50
        let length = (nx * nx + ny * ny).squareRoot()
        let pointer = PDFPoint(x: onCurve.x + 2 * nx / length, y: onCurve.y + 2 * ny / length)
        let winner = try #require(try Self.resolve(Self.ellipse, at: pointer).winner)
        #expect(winner.kind == .markupEdge)
        #expect(winner.position.distance(to: onCurve) <= 1e-9, "\(winner.position)")

        let quadrant = Self.candidates(try Self.resolve(Self.ellipse, at: PDFPoint(x: 301, y: 151)))
        #expect(quadrant.contains { $0.kind == .markupCenter && $0.position == PDFPoint(x: 300, y: 150) },
                "\(quadrant.map { ($0.kind, $0.position) })")
        let centre = Self.candidates(try Self.resolve(Self.ellipse, at: PDFPoint(x: 201, y: 151)))
        #expect(centre.contains { $0.kind == .markupCenter && $0.position == PDFPoint(x: 200, y: 150) })
        #expect(!centre.contains { $0.kind == .markupVertex })
    }

    /// A round ellipse is a circle primitive (centre (150, 150), radius 50); an Ellipse Area stored
    /// as its four box corners and an Ellipse Cutout stored as the box ring are the same inscribed
    /// ellipse — no box corner, no box edge.
    /// Old output: the round one was its two corners; the Ellipse Area four priority-0 corners;
    /// the Ellipse Cutout the box ring, its four edges and their midpoints.
    @Test("T-071: round ellipses are circles; Ellipse Area and Ellipse Cutout are their ellipses")
    func ellipseToolsProjectTheirEllipse() throws {
        let round = Self.record(kind: .ellipse, geometry: MeasurementGeometry(pageID: Self.page, points: Self.points([(100, 100), (200, 200)])))
        #expect(try #require(SnapMarkupGeometry.from(round)).geometry == [.circle(CircleGeometry(center: PDFPoint(x: 150, y: 150), radius: 50))])

        let corners = Self.points([(100, 100), (300, 100), (300, 200), (100, 200)])
        let area = Self.record(kind: .measurement, tool: .ellipseArea, geometry: MeasurementGeometry(pageID: Self.page, points: corners))
        let cutout = Self.record(kind: .polygon, tool: .ellipseCutout, geometry: MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: PolygonRing(points: corners))]))
        let annotation = try #require(SnapMarkupGeometry.from(Self.ellipse)).geometry
        for record in [area, cutout] {
            let projected = try #require(SnapMarkupGeometry.from(record))
            #expect(projected.geometry == annotation)
            #expect(projected.roles == [.smoothCurve, .smoothCurve, .smoothCurve, .smoothCurve, .centre])
            let resolution = try Self.resolve(record, at: PDFPoint(x: 299, y: 199))
            #expect(!Self.candidates(resolution).contains { $0.position.distance(to: PDFPoint(x: 300, y: 200)) <= 1e-6 })
            // The box's bottom edge y = 100 at x = 150 is 6.7 pt from the ellipse: no target on it.
            let edge = Self.candidates(try Self.resolve(record, at: PDFPoint(x: 150, y: 101)))
            #expect(!edge.contains { Swift.abs($0.position.y - 100) <= 1e-9 && $0.kind == .markupEdge })
        }
    }

    // MARK: - Rotation

    /// A rectangle annotation (100, 100)–(200, 150) turned 90°: the canvas turns it about its box
    /// centre (150, 125), so the stored corner (200, 150) is drawn at (150 − 25, 125 + 50) =
    /// (125, 175). The pointer 1 pt off that drawn corner snaps to it; the pointer 1 pt off the
    /// stored corner, where nothing is drawn, does not snap to (200, 150).
    /// Old output: the rectangle snapped at its unturned corners — (200, 150) won as a markupVertex
    /// and nothing was offered at (125, 175).
    @Test("T-071: a turned rectangle snaps at its drawn corners")
    func rotatedRectangle() throws {
        let rectangle = Self.record(
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: PolygonRing(points: Self.points([(100, 100), (200, 100), (200, 150), (100, 150)])))]),
            rotation: 90
        )
        #expect(rectangle.styleRotationCentre == PDFPoint(x: 150, y: 125))
        // A callout turns about its text box — the two corners after its target — as the canvas
        // turns it: target (0, 0), box (100, 100)–(200, 150), centre (150, 125).
        let callout = Self.record(kind: .callout, geometry: MeasurementGeometry(pageID: Self.page, points: Self.points([(0, 0), (100, 100), (200, 150)])), rotation: 30)
        #expect(callout.styleRotationCentre == PDFPoint(x: 150, y: 125))
        let drawn = rectangle.drawnPosition(of: PDFPoint(x: 200, y: 150))
        #expect(drawn.distance(to: PDFPoint(x: 125, y: 175)) <= 1e-12)

        let winner = try #require(try Self.resolve(rectangle, at: PDFPoint(x: 126, y: 176)).winner)
        #expect(winner.kind == .markupVertex)
        #expect(winner.position.distance(to: PDFPoint(x: 125, y: 175)) <= 1e-9)
        let stored = Self.candidates(try Self.resolve(rectangle, at: PDFPoint(x: 201, y: 151)))
        #expect(!stored.contains { $0.position.distance(to: PDFPoint(x: 200, y: 150)) <= 1e-6 })

        // A measurement never turns: an Area with a rotation in its style snaps as stored.
        var area = rectangle
        area.kind = .measurement
        area.tool = .area
        #expect(!area.turnsWithStyleRotation)
        let unturned = try #require(try Self.resolve(area, at: PDFPoint(x: 201, y: 151)).winner)
        #expect(unturned.position == PDFPoint(x: 200, y: 150))
    }

    /// A turned ellipse turns with its curve: the ellipse above turned 90° about (200, 150) has its
    /// quadrant (300, 150) drawn at (200, 250).
    @Test("T-071: a turned ellipse turns its quadrant points")
    func rotatedEllipse() throws {
        var turned = Self.ellipse
        turned.style.rotationDegrees = 90
        let quadrant = Self.candidates(try Self.resolve(turned, at: PDFPoint(x: 201, y: 251)))
        #expect(quadrant.contains { $0.kind == .markupCenter && $0.position.distance(to: PDFPoint(x: 200, y: 250)) <= 1e-9 },
                "\(quadrant.map { ($0.kind, $0.position) })")
    }

    // MARK: - Chains

    /// A Length (100, 100) → (300, 100): the pointer 1 pt above (150, 100) snaps to the nearest
    /// point of the edge, (150, 100), as a markupEdge; near (200, 100) the edge's midpoint is
    /// offered. A Polyline annotation is read the same way.
    /// Old output: the chain was its two vertices, 50 and 100 pt away — nothing in reach.
    @Test("T-071: a Length's straight edge offers its nearest point and its midpoint")
    func lengthEdgeAndMidpoint() throws {
        let length = Self.record(kind: .measurement, tool: .length, geometry: MeasurementGeometry(pageID: Self.page, points: Self.points([(100, 100), (300, 100)])))
        for record in [length, Self.record(kind: .polyline, geometry: length.geometry!)] {
            let winner = try #require(try Self.resolve(record, at: PDFPoint(x: 150, y: 101)).winner)
            #expect(winner.kind == .markupEdge)
            #expect(winner.position.distance(to: PDFPoint(x: 150, y: 100)) <= 1e-9)
            let middle = Self.candidates(try Self.resolve(record, at: PDFPoint(x: 201.5, y: 101)))
            #expect(middle.contains { $0.kind == .markupEdge && $0.position == PDFPoint(x: 200, y: 100) },
                    "\(middle.map { ($0.kind, $0.position) })")
        }
        // A text box's two corners are not a chain: no edge runs between them. The box-drawn
        // kinds are read as their drawn frame, below.
        let text = Self.record(kind: .text, geometry: MeasurementGeometry(pageID: Self.page, points: Self.points([(100, 100), (300, 200)])))
        #expect(SnapMarkupGeometry.from(text) == nil)
    }

    // MARK: - Box-drawn kinds (ADR-0037 §4.3)

    /// The box (100, 100)–(300, 200) as stored by a box-drawn markup: two opposite corners.
    static let box = MeasurementGeometry(pageID: page, points: points([(100, 100), (300, 200)]))

    /// The frame the canvas strokes round that box, in its drawing order.
    static let frame: [PrimitiveGeometry] = [
        .polyline(points: points([(100, 100), (300, 100), (300, 200), (100, 200)]), isClosed: true)
    ]

    /// A Text box with neither a border nor a fill draws its words and nothing round them
    /// (`CanvasSceneBuilder`: no stroke), so nothing of it is a snap target — above all not its
    /// two stored corners, which were priority-0 vertices where nothing is drawn.
    /// Old output: `.point(100, 100)` and `.point(300, 200)`; the pointer 1 pt off (300, 200)
    /// was captured by a markupVertex there.
    @Test("T-071: an unframed Text box offers nothing at its corners")
    func unframedTextBox() throws {
        let text = Self.record(kind: .text, geometry: Self.box)
        #expect(text.storesBoxCorners)
        #expect(text.drawnFrameBox == nil)
        #expect(SnapMarkupGeometry.from(text) == nil)
    }

    /// A bordered Text box, a filled Text box, a Note, a Link and an Image each draw the frame
    /// (100, 100)–(300, 200). The snap geometry is that closed ring: the pointer 1 pt inside
    /// (300, 100) — a corner that is drawn but never stored — snaps to it as a markupVertex, and
    /// the pointer 1 pt above (150, 100) lands on the bottom edge there as a markupEdge (the
    /// nearest corner is 50 pt away).
    /// Old output: the two stored corners only — nothing at (300, 100) or (100, 200) and nothing
    /// on any edge; both probes found no candidate of the markup.
    @Test("T-071: a framed box snaps at its four drawn corners and along its edges")
    func framesSnapAsDrawn() throws {
        var bordered = Self.record(kind: .text, geometry: Self.box)
        bordered.style.textStyle = MarkupTextStyle(boxBorder: true)
        var filled = Self.record(kind: .text, geometry: Self.box)
        filled.style.fill = RGBAColor(red: 1, green: 1, blue: 0, alpha: 0.2)
        let note = Self.record(kind: .note, geometry: Self.box)
        let link = Self.record(kind: .hyperlink, geometry: Self.box)
        let image = Self.record(kind: .image, geometry: Self.box)
        for record in [bordered, filled, note, link, image] {
            #expect(record.drawnFrameBox == PDFRect(x: 100, y: 100, width: 200, height: 100), "\(record.kind)")
            #expect(try #require(SnapMarkupGeometry.from(record)).geometry == Self.frame, "\(record.kind)")
            let corner = try #require(try Self.resolve(record, at: PDFPoint(x: 299, y: 101)).winner)
            #expect(corner.kind == .markupVertex && corner.position == PDFPoint(x: 300, y: 100), "\(record.kind): \(corner.kind) \(corner.position)")
            let edge = try #require(try Self.resolve(record, at: PDFPoint(x: 150, y: 101)).winner)
            #expect(edge.kind == .markupEdge, "\(record.kind): \(edge.kind)")
            #expect(edge.position.distance(to: PDFPoint(x: 150, y: 100)) <= 1e-9, "\(record.kind): \(edge.position)")
        }
    }

    /// A Callout with target (50, 50) and text box (100, 100)–(200, 150) draws its leader's head
    /// at the target and its box always: the snap geometry is the target point and the box ring,
    /// so the unstored corner (200, 100) snaps. A clouded callout — a Cloud whose points are
    /// [target, corner, corner] beside its ring — adds the same target and frame to its ring.
    /// Old output: three bare points (50, 50), (100, 100), (200, 150); nothing at (200, 100).
    @Test("T-071: a callout snaps at its target and its whole drawn box")
    func calloutFrame() throws {
        let stored = MeasurementGeometry(pageID: Self.page, points: Self.points([(50, 50), (100, 100), (200, 150)]))
        let ring: PrimitiveGeometry = .polyline(points: Self.points([(100, 100), (200, 100), (200, 150), (100, 150)]), isClosed: true)
        let callout = Self.record(kind: .callout, geometry: stored)
        #expect(callout.calloutTarget == PDFPoint(x: 50, y: 50))
        #expect(try #require(SnapMarkupGeometry.from(callout)).geometry == [.point(PDFPoint(x: 50, y: 50)), ring])
        let corner = try #require(try Self.resolve(callout, at: PDFPoint(x: 199, y: 101)).winner)
        #expect(corner.kind == .markupVertex && corner.position == PDFPoint(x: 200, y: 100), "\(corner.kind) \(corner.position)")

        var clouded = stored
        let cloudRing = PolygonRing(points: Self.points([(90, 90), (210, 90), (210, 160), (90, 160)]), isClosed: true)
        clouded.polygons = [PolygonGeometry(outer: cloudRing)]
        let cloud = Self.record(kind: .cloud, geometry: clouded)
        #expect(try #require(SnapMarkupGeometry.from(cloud)).geometry == [
            .point(PDFPoint(x: 50, y: 50)), ring, .polyline(points: cloudRing.points, isClosed: true)
        ])
    }

    /// A bordered Text box turned 90° turns its frame about the box centre (200, 150), as the
    /// canvas turns it: the stored-order corner (300, 100) is drawn at
    /// (200 + 50, 150 + 100) = (250, 250), and snaps there.
    @Test("T-071: a turned frame snaps at its turned corners")
    func turnedFrame() throws {
        var text = Self.record(kind: .text, geometry: Self.box, rotation: 90)
        text.style.textStyle = MarkupTextStyle(boxBorder: true)
        let corner = try #require(try Self.resolve(text, at: PDFPoint(x: 251, y: 249)).winner)
        #expect(corner.kind == .markupVertex)
        #expect(corner.position.distance(to: PDFPoint(x: 250, y: 250)) <= 1e-9, "\(corner.position)")
    }
}
