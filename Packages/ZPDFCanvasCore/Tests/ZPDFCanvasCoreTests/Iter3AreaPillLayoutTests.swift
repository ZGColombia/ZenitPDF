import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCanvasCore

/// T-067, the canvas copy: a slot or a thin hole that crosses the pill's box between its corners
/// sends the pill to the leader, exactly as the renderer's `AreaPillPlacement` now decides it.
/// View space, y down: the renderer suite's polygons flipped through y → −y.
@Suite("Iter3 area pill layout — notches and thin holes")
struct Iter3AreaPillLayoutTests {

    private static func flip(_ points: [(Double, Double)]) -> [CGPoint] {
        points.map { CGPoint(x: $0.0, y: -$0.1) }
    }

    /// 200 × 100 with a 5 pt slot at x 110…115 from y 30 to the top edge; centroid
    /// (99.78, 49.73) in page space. A 60 × 16 pill there has its centre and four corners in the
    /// fill and the slot through its middle.
    private static let slotted = flip([(0, 0), (200, 0), (200, 100), (115, 100), (115, 30), (110, 30), (110, 100), (0, 100)])

    @Test("T-067: a slot between the pill's corners sends it to the leader below the bottom vertex")
    func slotFallsBack() throws {
        let placement = try #require(AreaPillLayout.placement(polygon: Self.slotted, pillHalfWidth: 30, pillHalfHeight: 8))
        // Old output: interior at (99.78, −49.73), drawn across the slot.
        #expect(!placement.isInterior)
        // View space is flipped: the bottom vertex is the largest y, ties on the smaller x.
        #expect(placement.leaderStart == CGPoint(x: 0, y: 0))
        let narrow = try #require(AreaPillLayout.placement(polygon: Self.slotted, pillHalfWidth: 8, pillHalfHeight: 8))
        #expect(narrow.isInterior)
    }

    @Test("T-067: a thin hole through the pill's box with no vertex in it sends the pill to the leader")
    func thinHoleFallsBack() throws {
        let outer = Self.flip([(0, 0), (200, 0), (200, 100), (0, 100)])
        let shaft = Self.flip([(20, 53), (180, 53), (180, 54), (20, 54)])
        let placement = try #require(AreaPillLayout.placement(polygon: outer, holes: [shaft], pillHalfWidth: 30, pillHalfHeight: 8))
        // Old output: interior at (100, −50).
        #expect(!placement.isInterior)
        let clear = Self.flip([(20, 73), (180, 73), (180, 74), (20, 74)])
        let clearPlacement = try #require(AreaPillLayout.placement(polygon: outer, holes: [clear], pillHalfWidth: 30, pillHalfHeight: 8))
        #expect(clearPlacement.isInterior)
    }
}
