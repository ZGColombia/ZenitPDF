import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// IM-089: the per-query intersection budget is charged only for curve pairs whose overlap can
/// reach the cursor.
@Suite("Intersection budget reach (IM-089)")
struct IntersectionBudgetRegressionTests {

    /// Two anti-phase zigzags along y = 300, from x = 0 to 4000 in 10-point edges:
    /// A's vertices alternate y = 302, 298, ..., B's 298, 302, ... Edge k of A runs from
    /// (10k, 300 + 2s) to (10k + 10, 300 - 2s) and edge k of B mirrors it, so they cross at
    /// (10k + 5, 300), 400 times, at slopes of +/-0.4 (a crossing angle of 2 atan 0.4 = 43.6
    /// degrees, well conditioned).
    static func zigzags() throws -> SnapScene {
        func zigzag(id: UInt64, phase: Double) -> SnapPrimitive? {
            let points = (0...400).map { k -> PDFPoint in
                let s = (k % 2 == 0 ? 1.0 : -1.0) * phase
                return PDFPoint(x: Double(k) * 10, y: 300 + 2 * s)
            }
            return SnapScene.polyline(id: id, points, isClosed: false)
        }
        let page = try SnapScene.letterPage(media: PDFRect(x: 0, y: 0, width: 4100, height: 600))
        return try SnapScene.withVectorContent(
            page: page,
            primitives: [try #require(zigzag(id: 1, phase: 1)), try #require(zigzag(id: 2, phase: -1))]
        )
    }

    @Test("With a small budget, the crossing at the cursor is still found and nothing is truncated")
    func budgetGoesToPairsThatCanReachTheCursor() throws {
        let scene = try Self.zigzags()
        var settings = SnapSettings.default
        settings.enabledKinds = [.intersection, .endpoint, .nearestPointOnSegment]
        let layout = SnapReplay.layout(zoom: 1)
        var engine = SnapEngine()
        engine.intersectionPairBudget = 64
        // Cursor 0.71 page points from the crossing at (3505, 300), crossing number 350.
        let cursor = PDFPoint(x: 3505.5, y: 300.5)
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: scene.page, layout: layout), layout: layout
                ),
                settings: settings
            ),
            in: scene.index
        )
        // A guard, not a regression: decomposition already keeps only the edges whose box comes
        // within the radius, so the far crossings never reach the sweep and the small budget is
        // not exhausted — before or after IM-089.
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .intersection, "winner \(winner)" as Comment)
        #expect(winner.position.distance(to: PDFPoint(x: 3505, y: 300)) <= 1e-9)
        #expect(!resolution.isIntersectionSearchTruncated)
        // Only pairs whose overlap lies within the 14-point held radius are charged: edges
        // k = 349...351 of each line and their neighbours, a handful.
        #expect(resolution.intersections.pairsEvaluated <= 16, "\(resolution.intersections.pairsEvaluated)" as Comment)
    }

    @Test("A pair whose boxes reach the cursor but meet out of reach is not charged (IM-089)")
    func farOverlapIsNotCharged() throws {
        // Eleven horizontal lines y = 0, -0.1, ..., -1.0 and eleven vertical lines x = 0, ...,
        // -1.0, each running from -50 to 100. Cursor (12, 12) at zoom 1: the held radius is
        // 10 + 4 = 14, and every line's box is 12.0 ... 13.0 from the cursor, so all 22 are
        // participants and every horizontal/vertical pair's boxes overlap — but only near the
        // origin, at least sqrt(12^2 + 12^2) = 16.97 from the cursor, beyond the 14-point reach
        // of any candidate. Parallel lines 0.1 apart never overlap.
        var primitives: [SnapPrimitive] = []
        for i in 0...10 {
            let offset = -0.1 * Double(i)
            primitives.append(SnapScene.segment(id: UInt64(1 + i), PDFPoint(x: -50, y: offset), PDFPoint(x: 100, y: offset)))
            primitives.append(SnapScene.segment(id: UInt64(100 + i), PDFPoint(x: offset, y: -50), PDFPoint(x: offset, y: 100)))
        }
        let scene = try SnapScene.withVectorContent(page: try SnapScene.letterPage(), primitives: primitives)
        var settings = SnapSettings.default
        settings.enabledKinds = [.intersection]
        let layout = SnapReplay.layout(zoom: 1)
        var engine = SnapEngine()
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(PDFPoint(x: 12, y: 12), page: scene.page, layout: layout),
                    layout: layout
                ),
                settings: settings
            ),
            in: scene.index
        )
        #expect(resolution.winner == nil)
        // Old output: 121 — every one of the 11 x 11 pairs was solved and charged against the
        // budget although none could produce a candidate.
        #expect(resolution.intersections.pairsEvaluated == 0, "\(resolution.intersections.pairsEvaluated)" as Comment)
        #expect(!resolution.isIntersectionSearchTruncated)
    }
}
