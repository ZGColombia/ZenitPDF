import Foundation
import Testing
import ZPDFContracts

/// X-042 (a three-point Arc Length
/// is drawn and snapped as the arc it measures) and X-046 (one style-rotation box for the canvas
/// and the snap index). Every expected value is derived by hand beside it; each test states the
/// old output.
@Suite("X-042 and X-046 — arc length and rotation boxes (contracts)")
struct Iter7QuantitiesCoreContractTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000007c1")!)
    static let document = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-0000000007c2")!)

    static func record(_ kind: MarkupKind, tool: MeasurementTool? = nil, points: [PDFPoint], bulges: [Double]? = nil) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000007c3")!),
            documentID: document,
            pageID: page,
            kind: kind,
            tool: tool,
            subject: "Run",
            author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page, points: points, pointBulges: bulges),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: - X-042

    /// Arc Length (300, 300) → (350, 350) → (400, 300): the semicircle about (350, 300) of r = 50,
    /// clockwise from the left end over the top to the right end. As a chain: (300, 300) → (400,
    /// 300) with bulge −tan(π/4) = −1 (a clockwise half turn), the arc's centre (350, 300), radius
    /// 50 and sweep −π.
    /// Old output: no such rule — the canvas and the snap index read the three points as the open
    /// polyline (300, 300) → (350, 350) → (400, 300), two chords.
    @Test("X-042: a three-point Arc Length is drawn as the arc through its points")
    func arcLengthChainIsTheArc() throws {
        let p0 = PDFPoint(x: 300, y: 300), p1 = PDFPoint(x: 350, y: 350), p2 = PDFPoint(x: 400, y: 300)
        let chain = try #require(Self.record(.measurement, tool: .arcLength, points: [p0, p1, p2]).drawnPointChain)
        #expect(chain.points == [p0, p2])
        #expect(!chain.isClosed)
        let bulges = try #require(chain.bulges)
        #expect(bulges.count == 2 && bulges[1] == 0)
        #expect(Swift.abs(bulges[0] - -1) <= 1e-15, "\(bulges[0])")
        let arc = try #require(BulgeArc.arc(from: p0, to: p2, bulge: bulges[0]))
        #expect(arc.center.distance(to: PDFPoint(x: 350, y: 300)) <= 1e-12)
        #expect(Swift.abs(arc.radius - 50) <= 1e-12)
        #expect(Swift.abs(arc.sweepAngle - -Double.pi) <= 1e-12)
        // The through point lies on the drawn arc.
        #expect(Swift.abs(arc.center.distance(to: p1) - arc.radius) <= 1e-12)
    }

    /// A quarter arc drawn the other way round — (10, 0) → (7.0710678, 7.0710678) → (0, 10) about
    /// the origin, counter-clockwise — has bulge tan(π/8) = 0.41421356 and sweep +π/2.
    @Test("X-042: a counter-clockwise Arc Length bends the other way")
    func counterClockwiseArc() throws {
        let s = 10 * 0.7071067811865476
        let chain = try #require(Self.record(.measurement, tool: .arcLength, points: [
            PDFPoint(x: 10, y: 0), PDFPoint(x: s, y: s), PDFPoint(x: 0, y: 10)
        ]).drawnPointChain)
        let bulge = try #require(chain.bulges?.first)
        #expect(Swift.abs(bulge - Foundation.tan(Double.pi / 8)) <= 1e-12, "\(bulge)")
        let arc = try #require(BulgeArc.arc(from: PDFPoint(x: 10, y: 0), to: PDFPoint(x: 0, y: 10), bulge: bulge))
        #expect(arc.center.distance(to: PDFPoint(x: 0, y: 0)) <= 1e-12)
        #expect(Swift.abs(arc.sweepAngle - Double.pi / 2) <= 1e-12)
    }

    /// What is not a three-point arc keeps the stored chain: collinear points (which the engine
    /// refuses), two coincident points, four points (an unrepaired old record), and every other
    /// tool — a Polylength of the same three points stays its two chords.
    @Test("X-042: only a true three-point Arc Length becomes an arc")
    func otherChainsAreUnchanged() throws {
        let three = [PDFPoint(x: 300, y: 300), PDFPoint(x: 350, y: 350), PDFPoint(x: 400, y: 300)]
        let polylength = try #require(Self.record(.measurement, tool: .polylength, points: three).drawnPointChain)
        #expect(polylength.points == three && polylength.bulges == nil)
        let collinear = [PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 0), PDFPoint(x: 10, y: 0)]
        #expect(try #require(Self.record(.measurement, tool: .arcLength, points: collinear).drawnPointChain).points == collinear)
        // On the line's extension, a hair off it: |cross| = 10 · 1e-8 over maxEdge² = 20² is
        // 2.5e-10, under the engine's 1e-9 floor, so no absurd giant arc is drawn either.
        let beyond = [PDFPoint(x: 0, y: 0), PDFPoint(x: 20, y: 1e-8), PDFPoint(x: 10, y: 0)]
        #expect(try #require(Self.record(.measurement, tool: .arcLength, points: beyond).drawnPointChain).points == beyond)
        let doubled = [PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)]
        #expect(try #require(Self.record(.measurement, tool: .arcLength, points: doubled).drawnPointChain).points == doubled)
        let four = three + [PDFPoint(x: 450, y: 350)]
        #expect(try #require(Self.record(.measurement, tool: .arcLength, points: four).drawnPointChain).points == four)
        // A chain's own arc edges are kept as stored.
        let bulged = try #require(Self.record(.measurement, tool: .length, points: [three[0], three[2]], bulges: [0.5, 0]).drawnPointChain)
        #expect(bulged.bulges == [0.5, 0])
        // Fewer than two points draw no chain.
        #expect(Self.record(.measurement, tool: .length, points: [three[0]]).drawnPointChain == nil)
    }

    // MARK: - X-046

    /// One box per kind (ADR-0029): a callout turns about its text box, the two corners after its
    /// target; a Text box and an Image about their two corners; anything else about its geometry's
    /// bounds. The centre is that box's centre.
    /// Old output: `styleRotationCentre` was computed on its own beside the canvas's box — the
    /// same numbers for these records, with nothing tying the two together.
    @Test("X-046: one style-rotation box, and its centre is what the record turns about")
    func styleRotationBoxPerKind() throws {
        let callout = Self.record(.callout, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 50), PDFPoint(x: 160, y: 90)])
        #expect(callout.styleRotationBox == PDFRect(x: 100, y: 50, width: 60, height: 40))
        #expect(callout.styleRotationCentre == PDFPoint(x: 130, y: 70))
        let text = Self.record(.text, points: [PDFPoint(x: 40, y: 80), PDFPoint(x: 10, y: 20)])
        #expect(text.styleRotationBox == PDFRect(x: 10, y: 20, width: 30, height: 60))
        #expect(text.styleRotationCentre == PDFPoint(x: 25, y: 50))
        let image = Self.record(.image, points: [PDFPoint(x: 5, y: 5), PDFPoint(x: 25, y: 15)])
        #expect(image.styleRotationBox == PDFRect(x: 5, y: 5, width: 20, height: 10))
        let polygon = Self.record(.polygon, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 8, y: 2), PDFPoint(x: 4, y: 10)])
        #expect(polygon.styleRotationBox == PDFRect(x: 0, y: 0, width: 8, height: 10))
        #expect(polygon.styleRotationCentre == PDFPoint(x: 4, y: 5))
        // A record turned by its style is drawn about that centre: a quarter turn of a polygon
        // vertex (8, 2) about (4, 5) — offset (4, −3) — lands on (4 + 3, 5 + 4) = (7, 9).
        var turned = polygon
        turned.style.rotationDegrees = 90
        let moved = turned.drawnPosition(of: PDFPoint(x: 8, y: 2))
        #expect(moved.distance(to: PDFPoint(x: 7, y: 9)) <= 1e-12, "\(moved)")
        #expect(Self.record(.text, points: []).styleRotationBox == nil)
    }
}
