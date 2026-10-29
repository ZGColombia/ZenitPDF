import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// CR-37: intersection work between polygonised rings was quadratic in edges-per-ring.
///
/// Measured before the fix, debug build, on this scene: **38 842 / 38 716 / 38 419 ms** of
/// thread CPU per query for the crossing arrangement and 38 840 / 38 768 / 38 475 ms for the
/// concentric one — 36 million solver calls per pointer event against an 8 ms budget. The
/// generator now sweeps each pair's edges by x so only box-overlapping pairs are solved, and
/// stops at a per-query pair budget it reports on the resolution.
@Suite("Snap intersection budget (CR-37)")
struct SnapIntersectionBudgetTests {

    static func threadCPUMilliseconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    /// `count` rings of `edges` edges each. `crossing` puts the centres on a small circle so
    /// every pair of rings crosses twice; otherwise the rings are concentric, 2 pt apart, and
    /// never cross.
    static func rings(count: Int, edges: Int, radius: Double, crossing: Bool) -> [SnapPrimitive] {
        (0..<count).compactMap { ring -> SnapPrimitive? in
            let angle = Double(ring) / Double(count) * 2 * Double.pi
            let centre = crossing
                ? PDFPoint(x: 300 + 30 * Foundation.cos(angle), y: 300 + 30 * Foundation.sin(angle))
                : PDFPoint(x: 300, y: 300)
            let r = crossing ? radius : radius + Double(ring) * 2
            let points = (0..<edges).map { i -> PDFPoint in
                let theta = Double(i) / Double(edges) * 2 * Double.pi
                return PDFPoint(x: centre.x + r * Foundation.cos(theta), y: centre.y + r * Foundation.sin(theta))
            }
            return SnapScene.polyline(id: UInt64(1000 + ring), points, isClosed: true)
        }
    }

    static func query(page: PageDescriptor, cursor: PDFPoint, zoom: Double) throws -> SnapQuery {
        let layout = SnapReplay.layout(zoom: zoom)
        return SnapQuery(
            event: SnapPointerEvent(
                viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout), layout: layout
            ),
            settings: .default
        )
    }

    @Test("24 rings of 360 edges at 5 % zoom resolve in milliseconds, and completely", arguments: [true, false])
    func denseRingsResolveWithinBudget(crossing: Bool) throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: Self.rings(count: 24, edges: 360, radius: 60, crossing: crossing)
        )
        var engine = SnapEngine()
        let query = try Self.query(page: page, cursor: PDFPoint(x: 300, y: 300), zoom: 0.05)

        var samples: [Double] = []
        var last: SnapResolution?
        for _ in 0..<3 {
            let start = Self.threadCPUMilliseconds()
            last = try engine.resolve(query, in: scene.index)
            samples.append(Self.threadCPUMilliseconds() - start)
        }
        let resolution = try #require(last)
        print(
            "CR-37 crossing=\(crossing): thread-CPU ms per query = \(samples), "
                + "pairs solved = \(resolution.intersections.pairsEvaluated), "
                + "truncated = \(resolution.isIntersectionSearchTruncated)"
        )

        // Old output: ~38 500 ms per query. The fixed engine costs about 100 ms of thread CPU
        // per query alone in debug, and 300–550 ms while the target's other suites run beside
        // it — sweep 15 read 500.8 ms against the old 500 ms bound once the live-test-8 trace
        // suites joined the target (I-34). The bound is the hatch test's 2 000 ms: still 19×
        // below the quadratic engine, so it cannot pass by accident. The pair count below is
        // the exact guard.
        for sample in samples { #expect(sample < 2_000, "\(sample) ms" as Comment) }
        #expect(!resolution.isIntersectionSearchTruncated)
        #expect(resolution.intersections.pairsEvaluated <= 8_192)
        if crossing {
            // Every pair of rings crosses twice; the crossings near the cursor outrank every
            // vertex on priority.
            #expect(resolution.intersections.pairsEvaluated > 0)
            #expect(resolution.winner?.kind == .intersection)
        } else {
            // Concentric rings 2 pt apart: no two edges' boxes overlap, so nothing is solved.
            #expect(resolution.intersections.pairsEvaluated == 0)
            #expect(resolution.winner != nil)
        }
    }

    /// Two families of tall zigzags: twelve run left–right, twelve run bottom–top, and every
    /// one of the 144 crossings puts hundreds of steep short edges box-over-box.
    static func hatchOverHatch() -> [SnapPrimitive] {
        var primitives: [SnapPrimitive] = []
        let edges = 200
        for i in 0..<12 {
            let base = 210.0 + Double(i) * 15
            let horizontal = (0...edges).map { k -> PDFPoint in
                PDFPoint(x: 150 + Double(k) * 1.5, y: base + (k % 2 == 0 ? 20 : -20))
            }
            let vertical = (0...edges).map { k -> PDFPoint in
                PDFPoint(x: base + (k % 2 == 0 ? 20 : -20), y: 150 + Double(k) * 1.5)
            }
            if let h = SnapScene.polyline(id: UInt64(2000 + i), horizontal, isClosed: false) {
                primitives.append(h)
            }
            if let v = SnapScene.polyline(id: UInt64(3000 + i), vertical, isClosed: false) {
                primitives.append(v)
            }
        }
        return primitives
    }

    @Test("Dense linework over dense linework is cut at the pair budget, reported, and reproducible")
    func hatchOverHatchIsTruncatedAndReported() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(page: page, primitives: Self.hatchOverHatch())
        let query = try Self.query(page: page, cursor: PDFPoint(x: 300, y: 300), zoom: 0.05)

        var first = SnapEngine()
        let start = Self.threadCPUMilliseconds()
        let resolution = try first.resolve(query, in: scene.index)
        let elapsed = Self.threadCPUMilliseconds() - start
        print(
            "CR-37 hatch: thread-CPU ms = \(elapsed), pairs solved = \(resolution.intersections.pairsEvaluated), "
                + "truncated = \(resolution.isIntersectionSearchTruncated), winner = \(String(describing: resolution.winner?.kind))"
        )

        #expect(resolution.isIntersectionSearchTruncated)
        #expect(resolution.intersections.pairsEvaluated == 8_192)
        #expect(resolution.decision.logLine.hasSuffix("intersections-partial"))
        #expect(elapsed < 2_000)
        // What was found is exact, and something was found.
        let winner = try #require(resolution.winner)
        #expect(winner.position.isFinite)

        // The same index and event stop at the same pair: a second engine produces the same
        // decision line, which the 20-process determinism run also compares.
        var second = SnapEngine()
        let again = try second.resolve(query, in: scene.index)
        #expect(again.decision.logLine == resolution.decision.logLine)
        #expect(again.alternatives == resolution.alternatives)
    }

    @Test("A complete search says so in the decision log")
    func completeSearchIsLogged() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.segment(id: 1, PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 300)),
                SnapScene.segment(id: 2, PDFPoint(x: 100, y: 300), PDFPoint(x: 300, y: 100))
            ]
        )
        var engine = SnapEngine()
        let resolution = try engine.resolve(
            try Self.query(page: page, cursor: PDFPoint(x: 201, y: 201), zoom: 1), in: scene.index
        )
        #expect(resolution.winner?.kind == .intersection)
        #expect(!resolution.isIntersectionSearchTruncated)
        #expect(resolution.intersections.pairsEvaluated == 1)
        #expect(resolution.decision.logLine.hasSuffix("intersections-complete"))
    }
}
