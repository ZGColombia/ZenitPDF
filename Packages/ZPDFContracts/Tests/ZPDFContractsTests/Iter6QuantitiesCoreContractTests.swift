import Foundation
import Testing
import ZPDFContracts

/// W-089: a measurement's box is the curve as
/// drawn — arc edges reach past their vertices, a loose arc is boxed as itself, not its circle.
/// Every expected value is derived by hand beside it; each test states the old output.
@Suite("W-089 — a measurement's box follows its arcs (contracts)")
struct Iter6QuantitiesCoreContractTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000006b1")!)

    static func expectBox(_ box: PDFRect?, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                          _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let box else {
            Issue.record("\(label): no box", sourceLocation: sourceLocation)
            return
        }
        let ok = Swift.abs(box.minX - minX) <= 1e-9 && Swift.abs(box.minY - minY) <= 1e-9
            && Swift.abs(box.maxX - maxX) <= 1e-9 && Swift.abs(box.maxY - maxY) <= 1e-9
        #expect(ok, "\(label): (\(box.minX), \(box.minY))–(\(box.maxX), \(box.maxY))", sourceLocation: sourceLocation)
    }

    /// The finding's example: a 10 × 5 area (0, 0) → (10, 0) → (10, 5) → (0, 5), counter-clockwise,
    /// whose right edge (10, 0) → (10, 5) is an outward semicircle: bulge tan(π/4) = 1, centre
    /// (10, 2.5), radius 2.5, so it reaches x = 12.5 at (12.5, 2.5).
    /// Old output: (0, 0)–(10, 5), the vertices' box; a marquee over the bulge missed the area.
    @Test("W-089: an area's box reaches as far as its arc edge is drawn")
    func ringBoxIncludesTheBulge() {
        let ring = PolygonRing(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5), PDFPoint(x: 0, y: 5)],
            isClosed: true,
            bulges: [0, 1, 0, 0]
        )
        Self.expectBox(ring.bounds, 0, 0, 12.5, 5, "ring")
        let geometry = MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: ring)])
        Self.expectBox(geometry.bounds, 0, 0, 12.5, 5, "measurement")
        // A ring of straight edges is its vertices' box, unchanged.
        var straight = ring
        straight.bulges = nil
        Self.expectBox(straight.bounds, 0, 0, 10, 5, "straight ring")
    }

    /// A Polylength chain (0, 0) → (10, 0) with bulge −1: a clockwise semicircle from (0, 0) to
    /// (10, 0) about (5, 0) of radius 5, bending to the left of the +x edge, up to (5, 5).
    /// Old output: (0, 0)–(10, 0), a box of no height.
    @Test("W-089: a chain's box includes its arc edges")
    func chainBoxIncludesTheBulge() {
        let geometry = MeasurementGeometry(
            pageID: Self.page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)], pointBulges: [-1, 0]
        )
        Self.expectBox(geometry.bounds, 0, 0, 10, 5, "chain")
    }

    /// A loose arc: centre (100, 100), r = 10, from 0 sweeping π/2 counter-clockwise — the quarter
    /// from (110, 100) to (100, 110). Its box is (100, 100)–(110, 110).
    /// Old output: the whole circle, (90, 90)–(110, 110).
    @Test("W-089: a loose arc is boxed as the arc, not its circle")
    func looseArcBox() {
        let quarter = ArcGeometry(center: PDFPoint(x: 100, y: 100), radius: 10, startAngle: 0, sweepAngle: Double.pi / 2)
        Self.expectBox(quarter.bounds, 100, 100, 110, 110, "arc")
        Self.expectBox(MeasurementGeometry(pageID: Self.page, arcs: [quarter]).bounds, 100, 100, 110, 110, "measurement")

        // Clockwise from π/4 sweeping −π/2: (100 + 5√2, 100 + 5√2) through (110, 100) to
        // (100 + 5√2, 100 − 5√2). Only the axis point at 0 is inside; old output (90, 90)–(110, 110).
        let h = 5 * 2.0.squareRoot()
        let clockwise = ArcGeometry(center: PDFPoint(x: 100, y: 100), radius: 10, startAngle: Double.pi / 4, sweepAngle: -Double.pi / 2)
        Self.expectBox(clockwise.bounds, 100 + h, 100 - h, 110, 100 + h, "clockwise quarter")
        #expect(clockwise.axisExtremes.count == 1)

        // A whole turn is the whole circle.
        let full = ArcGeometry(center: PDFPoint(x: 100, y: 100), radius: 10, startAngle: 0.3, sweepAngle: 2 * Double.pi)
        Self.expectBox(full.bounds, 90, 90, 110, 110, "whole turn")
        #expect(full.axisExtremes.count == 4)
    }
}
