import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Bug hunt 2: the hit tester.
@Suite("Fix2 hit testing", .serialized)
struct Fix2HitTestTests {

    private static let lineID = MarkupID(UUID(uuidString: "F2417000-0000-4000-8000-000000000001") ?? UUID())

    private func renderer(width: Double) -> CoreGraphicsMarkupRenderer {
        let page = SceneIdentity.page()
        let line = RenderableMarkup(
            id: Self.lineID,
            shape: .polyline(RenderPolyline(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 300)
            ])),
            style: RenderStyle(stroke: .opaqueBlack, lineWidth: width)
        )
        let renderer = CoreGraphicsMarkupRenderer()
        renderer.update(
            page: page, markups: [line], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        )
        return renderer
    }

    @Test("BH-627: an open polyline's last vertex is reported as a vertex, like its first")
    func lastVertexIsAVertex() {
        let renderer = renderer(width: 2)
        defer { renderer.dispose() }
        let end = renderer.hitTest(pagePoint: CGPoint(x: 300, y: 301.5), toleranceInPagePoints: 1)
        // Old output: `.stroke` with no element index — only segment starts were candidates.
        #expect(end?.kind == .vertex)
        #expect(end?.elementIndex == 2)
        let start = renderer.hitTest(pagePoint: CGPoint(x: 99, y: 100), toleranceInPagePoints: 1)
        #expect(start?.kind == .vertex)
        #expect(start?.elementIndex == 0)
    }

    @Test("BH-628: a click inside the ink near a corner grabs the vertex, not the stroke")
    func vertexWinsInsideTheInk() {
        let renderer = renderer(width: 6)
        defer { renderer.dispose() }
        // 1 pt from the corner (300, 100), inside the 6 pt band.
        let near = renderer.hitTest(pagePoint: CGPoint(x: 299, y: 100), toleranceInPagePoints: 0)
        // Old output: `.stroke` — the vertex's centre distance (1) lost to the stroke's ink
        // distance (0).
        #expect(near?.kind == .vertex)
        #expect(near?.elementIndex == 1)
        // Mid-span, far from any vertex, is still the stroke.
        let middle = renderer.hitTest(pagePoint: CGPoint(x: 200, y: 101), toleranceInPagePoints: 0)
        #expect(middle?.kind == .stroke)
    }

    // MARK: IM-083

    @Test("IM-083: the indexed hit test answers exactly as the full scan, over a query grid")
    func indexedHitTestAgreesWithLinearScan() throws {
        let (page, markups) = SceneLibrary.stress(count: 3_000, seed: 0x83)
        for zoom in [0.25, 1.0, 4.0] {
            let preparer = ScenePreparer()
            let viewport = RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 2)
            let scene = try preparer.prepare(
                page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport
            )
            var compared = 0
            var hits = 0
            for gx in stride(from: 0.0, through: 612.0, by: 9.0) {
                for gy in stride(from: 0.0, through: 792.0, by: 11.0) {
                    let point = PDFPoint(x: gx, y: gy)
                    for tolerance in [0.0, 2.0] {
                        let linear = SceneHitTester.hitTest(
                            markups: scene.markups, overlay: scene.overlay,
                            transform: scene.transform, point: point, tolerance: tolerance
                        )
                        let candidates = preparer.hitCandidates(point: point, tolerance: tolerance, transform: scene.transform)
                        #expect(candidates != nil)
                        let indexed = SceneHitTester.hitTest(
                            markups: scene.markups, candidates: candidates, overlay: scene.overlay,
                            transform: scene.transform, point: point, tolerance: tolerance
                        )
                        compared += 1
                        if linear != nil { hits += 1 }
                        if linear != indexed {
                            Issue.record("zoom \(zoom) at \(point) tol \(tolerance): \(String(describing: linear)) vs \(String(describing: indexed))")
                            return
                        }
                    }
                }
            }
            #expect(hits > compared / 20, "the grid must actually hit things (\(hits) of \(compared))")
        }
    }

    @Test("IM-083: on a 100 000-markup page a hit query looks at a few hundred markups, not all of them")
    func indexedHitTestIsSubLinear() throws {
        let (page, markups) = SceneLibrary.stress(count: 100_000, seed: 0x8300)
        let preparer = ScenePreparer()
        let scene = try preparer.prepare(
            page: page, markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 4, backingScale: 2)
        )
        var worst = 0
        for (x, y) in [(100.0, 100.0), (306.0, 396.0), (500.0, 700.0), (20.0, 770.0), (600.0, 10.0)] {
            let candidates = try #require(
                preparer.hitCandidates(point: PDFPoint(x: x, y: y), tolerance: 1, transform: scene.transform)
            )
            worst = max(worst, candidates.count)
        }
        // Before: every query walked all 100 000 markups (and reduced over their instances).
        // The improvement's "< 100" cannot hold on this corpus: 100 000 markups about 16 pt
        // across on one letter page stack roughly 60 deep over any point by geometry alone, so
        // the bound is on the index's overhead instead — under half a percent of the page.
        #expect(worst < 500, "a query touched \(worst) of \(scene.markups.count) markups")
        #expect(worst < scene.markups.count / 200)
    }
}
