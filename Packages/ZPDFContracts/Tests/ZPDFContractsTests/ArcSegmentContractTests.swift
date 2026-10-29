import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0030 §5 (NL-MEASURE-05): arc segments as bulges. Every expected value is hand-derived.
@Suite("Arc segments in rings and chains (ADR-0030 §5)")
struct ArcSegmentContractTests {

    /// A 10 × 5 rectangle, counter-clockwise, whose right side (10,0)→(10,5) is a semicircle
    /// bulging outward: bulge tan(π/4) = 1. Area 50 + π·2.5²/2 = 50 + 3.125π.
    static let golden = PolygonRing(
        points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5), PDFPoint(x: 0, y: 5)],
        isClosed: true,
        bulges: [0, 1, 0, 0]
    )

    @Test("The semicircle: centre (10, 2.5), radius 2.5, sweep +π; exact area 50 + 3.125π")
    func golden() throws {
        let arc = try #require(BulgeArc.arc(from: PDFPoint(x: 10, y: 0), to: PDFPoint(x: 10, y: 5), bulge: 1))
        #expect(Swift.abs(arc.center.x - 10) < 1e-12 && Swift.abs(arc.center.y - 2.5) < 1e-12)
        #expect(Swift.abs(arc.radius - 2.5) < 1e-12)
        #expect(Swift.abs(arc.sweepAngle - .pi) < 1e-12)
        #expect(Swift.abs(arc.pdfArcLength - 2.5 * .pi) < 1e-12)
        let expected = 50 + 3.125 * Double.pi
        #expect(Swift.abs(Self.golden.exactSignedArea - expected) <= expected * 1e-12)
        // Bulging inward (−1) removes the half disc instead: 50 − 3.125π.
        var inward = Self.golden
        inward.bulges = [0, -1, 0, 0]
        #expect(Swift.abs(inward.exactSignedArea - (50 - 3.125 * .pi)) <= 1e-12 * 50)
    }

    /// A quarter circle, bulge tan(π/8): chord from (1,0) to (0,1) on the unit circle, centre at
    /// the origin, radius 1, sweep π/2; its segment area π/4 − 1/2.
    @Test("A quarter arc and its segment")
    func quarter() throws {
        let b = Foundation.tan(Double.pi / 8)
        let arc = try #require(BulgeArc.arc(from: PDFPoint(x: 1, y: 0), to: PDFPoint(x: 0, y: 1), bulge: b))
        #expect(Swift.abs(arc.center.x) < 1e-12 && Swift.abs(arc.center.y) < 1e-12)
        #expect(Swift.abs(arc.radius - 1) < 1e-12)
        #expect(Swift.abs(arc.sweepAngle - .pi / 2) < 1e-12)
        #expect(Swift.abs(BulgeArc.segmentArea(from: PDFPoint(x: 1, y: 0), to: PDFPoint(x: 0, y: 1), bulge: b) - (.pi / 4 - 0.5)) < 1e-12)
        // Flattened to 0.001: every chord's sagitta within it, ends exact.
        let flat = BulgeArc.flattened(from: PDFPoint(x: 1, y: 0), to: PDFPoint(x: 0, y: 1), bulge: b, tolerance: 0.001)
        #expect(flat.last == PDFPoint(x: 0, y: 1))
        #expect(flat.allSatisfy { Swift.abs(($0.x * $0.x + $0.y * $0.y).squareRoot() - 1) < 1e-12 })
    }

    @Test("Bulges are additive and honoured only when they line up")
    func additive() throws {
        let plain = PolygonRing(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)])
        let bytes = try JSONEncoder().encode(plain)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("bulges"), "a straight ring encodes as before ADR-0030")
        #expect(try JSONDecoder().decode(PolygonRing.self, from: bytes).bulges == nil)
        let back = try JSONDecoder().decode(PolygonRing.self, from: JSONEncoder().encode(Self.golden))
        #expect(back == Self.golden)
        var misaligned = Self.golden
        misaligned.bulges = [1, 1]
        #expect(misaligned.validBulges == nil && !misaligned.hasArcs, "a count that does not line up is every edge straight")
        #expect(PolygonRing(points: plain.points, bulges: [0, 0, 0]).validBulges == nil)
        let chain = MeasurementGeometry(pageID: PageID(UUID()), points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0)], pointBulges: [1, 0])
        #expect(chain.validPointBulges == [1, 0])
        var broken = chain
        broken.pointBulges = [.nan, 0]
        #expect(!broken.isFinite)
        // Flattening keeps the vertices and adds the arc's inner points.
        let flat = Self.golden.flattened(tolerance: 0.01)
        #expect(flat.points.first == PDFPoint(x: 0, y: 0) && flat.points.count > 4 && flat.bulges == nil)
    }
}
