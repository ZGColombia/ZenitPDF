import Foundation
import Testing
@testable import ZPDFUIPresentation

/// U-072: a cloud's scallop count is bounded before it is converted to `Int`, so an imported
/// cloud with a huge finite vertex neither traps nor builds millions of points per scene build.
@Suite("Cloud outline stays bounded — U-072")
struct CloudOutlineBoundTests {

    private func square(_ side: Double) -> [PDFPointValue] {
        [PDFPointValue(x: 0, y: 0), PDFPointValue(x: side, y: 0),
         PDFPointValue(x: side, y: side), PDFPointValue(x: 0, y: side)]
    }

    /// Old output: `Int((1e30 / 20).rounded())` — about 5e28, past `Int.max` — trapped, and the
    /// page crashed every time it was drawn.
    @Test("An edge of 1e30 pt is drawn straight instead of trapping")
    func hugeEdgeDoesNotTrap() {
        let ring = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 1e30, y: 100)]
        let outline = ZenitMarkupGeometry.cloudOutline(ring, radius: 10)
        // Hand-derived: the 100 pt edge gets 100 / 20 = 5 scallops of 12 points (60); the two
        // edges touching the 1e30 vertex are drawn straight, one start point each (2).
        #expect(outline.count == 62)
        #expect(outline.contains(PDFPointValue(x: 1e30, y: 100)), "the far vertex is still on the outline")
    }

    /// Old output: a vertex at 1e200 made the edge length infinite, and `Int(inf)` trapped.
    @Test("An infinite edge length (vertex past 1e154) does not trap")
    func infiniteLengthDoesNotTrap() {
        let ring = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 1e200, y: 0), PDFPointValue(x: 0, y: 1e200)]
        let outline = ZenitMarkupGeometry.cloudOutline(ring, radius: 8)
        #expect(outline.count == 3, "every edge touches an out-of-bound vertex: all drawn straight")
    }

    /// Old output: a 1e7 pt square with radius 2 asked for 2.5 million scallops per edge — 120
    /// million points on every scene build.
    @Test("A cloud at the coordinate bound stays within the point budget")
    func boundEdgeStaysWithinBudget() {
        let outline = ZenitMarkupGeometry.cloudOutline(square(1e7), radius: 2)
        // Each edge is capped at 4 096 scallops; four edges total exactly the 16 384 budget.
        #expect(outline.count == ZenitMarkupGeometry.maximumScallopsPerOutline * 12)
        #expect(outline.count == 196_608)
    }

    @Test("Past the budget every edge is scaled down in proportion")
    func budgetScalesEdges() {
        // Eight edges of 1e6 pt at radius 2: each wants 4 096 (capped), 32 768 in all, twice the
        // budget, so each gets 2 048 — 16 384 scallops, 196 608 points.
        let octagon = (0..<8).map { step -> PDFPointValue in
            let angle = Double(step) / 8 * 2 * Double.pi
            return PDFPointValue(x: 1.3e6 * cos(angle), y: 1.3e6 * sin(angle))
        }
        let counts = ZenitMarkupGeometry.cloudScallopCounts(octagon, edgeCount: 8, radius: 2)
        #expect(counts.allSatisfy { $0 == 2_048 }, "\(counts)")
        #expect(ZenitMarkupGeometry.cloudOutline(octagon, radius: 2).count == 196_608)
    }

    @Test("An ordinary cloud is drawn exactly as before")
    func ordinaryCloudUnchanged() {
        // 100 pt edges at radius 10: 100 / 20 = 5 scallops per edge, 20 in all, 12 points each.
        let outline = ZenitMarkupGeometry.cloudOutline(square(100), radius: 10)
        #expect(outline.count == 240)
        #expect(outline.first == PDFPointValue(x: 0, y: 0))
        // A 1 pt edge at radius 10 still gets one scallop.
        #expect(ZenitMarkupGeometry.cloudOutline(square(1), radius: 10).count == 48)
    }

    @Test("The restated coordinate bound is the contract's 1e7 PDF points")
    func boundMatchesContract() {
        #expect(ZenitMarkupGeometry.coordinateMagnitudeBound == 1e7)
    }
}
