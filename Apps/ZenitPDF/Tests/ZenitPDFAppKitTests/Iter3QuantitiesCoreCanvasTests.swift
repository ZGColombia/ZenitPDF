import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality-loop iteration 3, area "quantities-core", T-071 (re-fix): a markup is drawn where it
/// snaps. A committed Ellipse Area and Ellipse Cutout are drawn as the ellipse the engine measures
/// and the snap index offers (`MarkupRecord.inscribedEllipseBox`), and a box-drawn markup's frame
/// is the one the snap index offers (`MarkupRecord.drawnFrameBox`), ADR-0037 §4.3.
///
/// Each test states what the canvas drew before the fix.
@MainActor
@Suite("Iteration 3 quantities-core (canvas)", .appTierSerialised)
struct Iter3QuantitiesCoreCanvasTests {

    static let pageID = UUID(uuidString: "00000000-0000-4000-8000-0000000071c1")!
    static let parentID = MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000071c2")!)

    static func record(
        _ kind: ZPDFContracts.MarkupKind,
        tool: MeasurementTool? = nil,
        geometry: MeasurementGeometry,
        parent: MarkupID? = nil
    ) -> MarkupRecord {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(UUID()),
            pageID: PageID(pageID),
            kind: kind,
            tool: tool,
            style: MarkupStyle(fill: RGBAColor(red: 0, green: 0, blue: 1, alpha: 0.18)),
            geometry: geometry,
            parentMarkupID: parent,
            createdAt: now,
            modifiedAt: now
        )
    }

    static func points(_ pairs: [(Double, Double)]) -> [PDFPoint] {
        pairs.map { PDFPoint(x: $0.0, y: $0.1) }
    }

    static func shape(of record: MarkupRecord) throws -> CanvasMarkupShape {
        try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: pageID).first)
    }

    /// The box (100, 100)–(300, 200) every record below is drawn from.
    static let twoCorners = points([(100, 100), (300, 200)])
    static let fourCorners = points([(100, 100), (300, 100), (300, 200), (100, 200)])

    /// How far a drawn point is from the ellipse inscribed in that box — centre (200, 150),
    /// semi-axes 100 and 50 — as |((x − 200)/100)² + ((y − 150)/50)² − 1|.
    static func offEllipse(_ point: PDFPointValue) -> Double {
        let u = (point.x - 200) / 100
        let v = (point.y - 150) / 50
        return Swift.abs(u * u + v * v - 1)
    }

    /// The box corners, where nothing of an inscribed ellipse is drawn.
    static let corners = [(100.0, 100.0), (300.0, 100.0), (300.0, 200.0), (100.0, 200.0)]
        .map { PDFPointValue(x: $0.0, y: $0.1) }

    /// Asserts that `stroke` is the inscribed ellipse: closed, never dimensioned, 72 facets all on
    /// the curve, none at a box corner.
    static func expectEllipse(_ stroke: CanvasStroke, filled: Bool, _ comment: String) {
        #expect(stroke.closed, "\(comment)")
        #expect(!stroke.dimensioned, "\(comment)")
        #expect(stroke.filled == filled, "\(comment)")
        #expect(stroke.points.count == 72, "\(comment): \(stroke.points.count) points")
        let worst = stroke.points.map(offEllipse).max() ?? .infinity
        #expect(worst <= 1e-12, "\(comment): off the ellipse by \(worst)")
        let atCorner = stroke.points.filter { point in corners.contains { $0.distance(to: point) <= 1 } }
        #expect(atCorner.isEmpty, "\(comment): drawn at box corners \(atCorner)")
    }

    // MARK: - Ellipse Area and Ellipse Cutout are drawn as their ellipse

    /// An Ellipse Area as the drag commits it (two box corners, kind `.measurement`) and as four
    /// box corners: one closed, filled, undimensioned 72-facet ellipse on
    /// ((x − 200)/100)² + ((y − 150)/50)² = 1.
    /// Old output: the point-path branch — one open, dimensioned stroke through the stored corners
    /// (the diagonal (100, 100)–(300, 200) for two; the open box polyline for four).
    @Test("T-071: a committed Ellipse Area is drawn as its ellipse, not through its box corners")
    func ellipseAreaIsDrawnAsItsEllipse() throws {
        for stored in [Self.twoCorners, Self.fourCorners] {
            let area = Self.record(.measurement, tool: .ellipseArea, geometry: MeasurementGeometry(pageID: PageID(Self.pageID), points: stored))
            let strokes = try Self.shape(of: area).strokes
            #expect(strokes.count == 1, "\(stored.count) corners: \(strokes.count) strokes")
            let stroke = try #require(strokes.first)
            Self.expectEllipse(stroke, filled: true, "Ellipse Area, \(stored.count) corners")
        }
    }

    /// An Ellipse Cutout child (kind `.polygon`, a parent set) stored as its box ring and as the
    /// drag's two corners: one closed, undimensioned ellipse, left unfilled like every cutout child
    /// (the parent's even-odd fill leaves the hole clear, BH-340).
    /// Old output: the box ring (100, 100)–(300, 200) for the ring, and a dimensioned diagonal for
    /// the two corners.
    @Test("T-071: a committed Ellipse Cutout is drawn as its ellipse, not as its box")
    func ellipseCutoutIsDrawnAsItsEllipse() throws {
        let ring = MeasurementGeometry(pageID: PageID(Self.pageID), polygons: [PolygonGeometry(outer: PolygonRing(points: Self.fourCorners, isClosed: true))])
        let pair = MeasurementGeometry(pageID: PageID(Self.pageID), points: Self.twoCorners)
        for (name, geometry) in [("ring", ring), ("two corners", pair)] {
            let cutout = Self.record(.polygon, tool: .ellipseCutout, geometry: geometry, parent: Self.parentID)
            let strokes = try Self.shape(of: cutout).strokes
            #expect(strokes.count == 1, "\(name): \(strokes.count) strokes")
            let stroke = try #require(strokes.first)
            Self.expectEllipse(stroke, filled: false, "Ellipse Cutout, \(name)")
        }
    }

    /// The drawn ellipse and the snapped ellipse are one ellipse: the quadrant points the snap
    /// index offers — the ends of its four quarter curves, (300, 150), (200, 200), (100, 150) and
    /// (200, 100) — are vertices of the drawn outline (facets 0, 18, 36 and 54 of 72), and the
    /// snap's centre (200, 150) is the drawn outline's centre.
    /// Old output: the snap offered these points on a curve the canvas never drew.
    @Test("T-071: the drawn ellipse is the one the snap index offers")
    func drawnEllipseIsTheSnappedEllipse() throws {
        let area = Self.record(.measurement, tool: .ellipseArea, geometry: MeasurementGeometry(pageID: PageID(Self.pageID), points: Self.twoCorners))
        let cutout = Self.record(.polygon, tool: .ellipseCutout, geometry: MeasurementGeometry(pageID: PageID(Self.pageID), polygons: [PolygonGeometry(outer: PolygonRing(points: Self.fourCorners, isClosed: true))]), parent: Self.parentID)
        for record in [area, cutout] {
            let drawn = try #require(try Self.shape(of: record).strokes.first).points
            let snapped = try #require(SnapMarkupGeometry.from(record))
            var quadrants: [PDFPoint] = []
            var centre: PDFPoint?
            for (index, piece) in snapped.geometry.enumerated() {
                switch (piece, snapped.role(at: index)) {
                case (.cubicCurve(let start, _, _, _), .smoothCurve): quadrants.append(start)
                case (.point(let point), .centre): centre = point
                default: Issue.record("unexpected snap piece \(piece)")
                }
            }
            #expect(quadrants == Self.points([(300, 150), (200, 200), (100, 150), (200, 100)]))
            for (quadrant, facet) in zip(quadrants, [0, 18, 36, 54]) {
                #expect(drawn[facet].distance(to: PDFPointValue(x: quadrant.x, y: quadrant.y)) <= 1e-12,
                        "facet \(facet) \(drawn[facet]) vs snap quadrant \(quadrant)")
            }
            #expect(centre == PDFPoint(x: 200, y: 150))
        }
    }

    // MARK: - A box-drawn frame is drawn where it snaps

    /// A bordered Text box, a Note and a Link draw the frame (100, 100)–(300, 200) as their one
    /// stroke, and a Callout (target (50, 50), box (100, 100)–(300, 200)) draws it as its box
    /// stroke; in every case the drawn corners are the snap index's ring, in the same order. An
    /// unframed Text box draws no stroke and has no snap geometry.
    /// Old output (snap side): the stored corners only — two of the four drawn corners, no edge;
    /// and the unframed Text box's two corners as priority-0 vertices where nothing was drawn.
    @Test("T-071: box frames are drawn where they snap; an unframed Text box snaps nowhere")
    func framesDrawnWhereTheySnap() throws {
        let box = MeasurementGeometry(pageID: PageID(Self.pageID), points: Self.twoCorners)
        var bordered = Self.record(.text, geometry: box)
        bordered.style = MarkupStyle(textStyle: MarkupTextStyle(boxBorder: true))
        let note = Self.record(.note, geometry: box)
        let link = Self.record(.hyperlink, geometry: box)
        let callout = Self.record(.callout, geometry: MeasurementGeometry(pageID: PageID(Self.pageID), points: Self.points([(50, 50), (100, 100), (300, 200)])))
        let expected = Self.fourCorners.map { PDFPointValue(x: $0.x, y: $0.y) }
        for (record, strokeIndex) in [(bordered, 0), (note, 0), (link, 0), (callout, 1)] {
            let strokes = try Self.shape(of: record).strokes
            let frame = try #require(strokes.indices.contains(strokeIndex) ? strokes[strokeIndex] : nil, "\(record.kind)")
            #expect(frame.closed && frame.points == expected, "\(record.kind): drawn \(frame.points)")
            let snapped = try #require(SnapMarkupGeometry.from(record)).geometry
            guard case .polyline(let ring, true)? = snapped.last else {
                Issue.record("\(record.kind): snap geometry \(snapped)")
                continue
            }
            #expect(ring.map { PDFPointValue(x: $0.x, y: $0.y) } == frame.points, "\(record.kind): snap ring \(ring)")
        }

        // Words and nothing round them: the shape carries its text and no stroke.
        var plain = Self.record(.text, geometry: box)
        plain.style = MarkupStyle()
        plain.caption = "Check on site"
        let words = try Self.shape(of: plain)
        #expect(words.text == "Check on site")
        #expect(words.strokes.isEmpty)
        #expect(SnapMarkupGeometry.from(plain) == nil)
    }
}
