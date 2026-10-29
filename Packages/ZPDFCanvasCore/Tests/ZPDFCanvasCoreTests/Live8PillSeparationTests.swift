import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCanvasCore

/// L-70 (live test 8): after Split Area the two halves' pills stepped out below the area side by
/// side and one covered the other — "Kitchen floo[r] Kitchen floor.2: 15,02 m²". View space, y
/// down. Each half is 40 × 60; a pill of 100 × 18 does not fit inside either, so both step out.
@Suite("Live 8 area pill separation (L-70)")
struct Live8PillSeparationTests {

    /// The left half (0…40) and the right half (40…80) of an 80 × 60 rectangle split at x = 40.
    static let left = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 60), CGPoint(x: 0, y: 60)]
    static let right = [CGPoint(x: 40, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 60), CGPoint(x: 40, y: 60)]

    static func box(_ placement: AreaPillLayout.Placement, halfWidth: CGFloat = 50, halfHeight: CGFloat = 9) -> CGRect {
        CGRect(x: placement.center.x - halfWidth, y: placement.center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
    }

    @Test("Two halves' leader pills are laid out side by side, not one over the other")
    func splitHalvesDoNotOverlap() throws {
        let a = try #require(AreaPillLayout.placement(polygon: Self.left, pillHalfWidth: 50, pillHalfHeight: 9))
        let b = try #require(AreaPillLayout.placement(polygon: Self.right, pillHalfWidth: 50, pillHalfHeight: 9))
        #expect(!a.isInterior && !b.isInterior)
        // Placed on their own, each pill hangs under its bottom-left corner: centres x 0 and 40,
        // y 60 + 18 + 2 + 9 = 89. The boxes -50…50 and -10…90 overlap by 60 points: the old output.
        #expect(a.center == CGPoint(x: 0, y: 89) && b.center == CGPoint(x: 40, y: 89))
        #expect(Self.box(a).intersects(Self.box(b)))

        let idA = UUID(), idB = UUID()
        let laidOut = AreaPillLayout.separating([
            .init(id: idA, placement: a, halfWidth: 50, halfHeight: 9),
            .init(id: idB, placement: b, halfWidth: 50, halfHeight: 9)
        ])
        let first = try #require(laidOut[idA])
        let second = try #require(laidOut[idB])
        // The first keeps its place; the second moves right to 50 + 4 + 50 = 104, same row.
        #expect(first == a)
        #expect(second.center == CGPoint(x: 104, y: 89))
        #expect(!Self.box(first).insetBy(dx: -1, dy: -1).intersects(Self.box(second)))
        // Its leader still starts at its own corner (40, 60) and ends just above the pill's top
        // edge at the nearest point: x clamped into 54…154 is 54, y 89 − 9 − 2 = 78.
        #expect(second.leaderStart == CGPoint(x: 40, y: 60))
        #expect(second.leaderEnd == CGPoint(x: 54, y: 78))
    }

    @Test("Interior pills stay put, and a leader pill steps past every pill in its way")
    func interiorStaysAndChainsAreCleared() throws {
        let interior = AreaPillLayout.Placement(center: CGPoint(x: 60, y: 89))
        let leader = AreaPillLayout.Placement(
            center: CGPoint(x: 0, y: 89), leaderStart: CGPoint(x: 0, y: 60), leaderEnd: CGPoint(x: 0, y: 78)
        )
        let blocker = AreaPillLayout.Placement(
            center: CGPoint(x: 160, y: 89), leaderStart: CGPoint(x: 160, y: 60), leaderEnd: CGPoint(x: 160, y: 78)
        )
        let ids = (UUID(), UUID(), UUID())
        // The interior pill is listed last and still wins its place: interior pills sit in their own fill.
        let laidOut = AreaPillLayout.separating([
            .init(id: ids.0, placement: leader, halfWidth: 50, halfHeight: 9),
            .init(id: ids.1, placement: blocker, halfWidth: 50, halfHeight: 9),
            .init(id: ids.2, placement: interior, halfWidth: 20, halfHeight: 9)
        ])
        #expect(laidOut[ids.2] == interior)
        // The interior box is 40…80; the leader pill (-50…50) covers it and moves to 80 + 4 + 50 =
        // 134, where it meets nothing laid out yet. The blocker (110…210) then meets it (84…184)
        // and moves to 184 + 4 + 50 = 238.
        #expect(laidOut[ids.0]?.center == CGPoint(x: 134, y: 89))
        #expect(laidOut[ids.1]?.center == CGPoint(x: 238, y: 89))
        let boxes = [laidOut[ids.0], laidOut[ids.1]].compactMap { $0 }.map { Self.box($0) } + [Self.box(interior, halfWidth: 20)]
        for i in boxes.indices { for j in boxes.indices where i < j { #expect(!boxes[i].intersects(boxes[j])) } }
    }

    @Test("Pills that never met are returned exactly as placed")
    func separatePillsAreUntouched() {
        let a = AreaPillLayout.Placement(center: CGPoint(x: 0, y: 89), leaderStart: CGPoint(x: 0, y: 60), leaderEnd: CGPoint(x: 0, y: 78))
        let b = AreaPillLayout.Placement(center: CGPoint(x: 500, y: 89), leaderStart: CGPoint(x: 500, y: 60), leaderEnd: CGPoint(x: 500, y: 78))
        let ids = (UUID(), UUID())
        let laidOut = AreaPillLayout.separating([
            .init(id: ids.0, placement: a, halfWidth: 50, halfHeight: 9),
            .init(id: ids.1, placement: b, halfWidth: 50, halfHeight: 9)
        ])
        #expect(laidOut[ids.0] == a && laidOut[ids.1] == b)
    }
}
