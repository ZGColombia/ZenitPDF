import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Regressions in the scene preparer and the Core Graphics backend.
@Suite("Scene preparer regressions", .serialized)
struct ScenePreparerRegressionTests {

    private func page() -> PageDescriptor { SceneIdentity.page() }
    private func viewport(_ page: PageDescriptor, zoom: Double = 1) -> RenderViewport {
        RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 1)
    }

    private func line(_ id: MarkupID, x: Double, hidden: Bool = false) -> RenderableMarkup {
        RenderableMarkup(
            id: id,
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: x, y: 100), PDFPoint(x: x + 50, y: 100)])),
            style: RenderStyle(stroke: SceneColors.ink, lineWidth: 2),
            isHidden: hidden
        )
    }

    // MARK: - CR-73

    @Test("A markup hidden during a rebuild becomes visible when it is later unhidden")
    func hiddenDuringRebuildBecomesVisibleOnUnhide() throws {
        let page = page()
        let visibleID = MarkupID(UUID())
        let hiddenID = MarkupID(UUID())

        // Frame 1: the initial (topology) rebuild compiles the scene while `hiddenID` is hidden,
        // so it gets no storage slot.
        let preparer = ScenePreparer()
        var markups = [line(visibleID, x: 100), line(hiddenID, x: 200, hidden: true)]
        var prepared = try preparer.prepare(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page)
        )
        #expect(!prepared.markups.contains { $0.id == hiddenID }, "setup: the hidden markup should have no slot yet")

        // Frame 2: unhide it. Same ids, same order — a non-topology change. Old output: the
        // preparer found position -1, recompiled, threw the result away, flagged no rebuild, and
        // the markup stayed invisible until some other add/remove happened to rebuild.
        markups[1] = line(hiddenID, x: 200, hidden: false)
        prepared = try preparer.prepare(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page)
        )
        #expect(prepared.markups.contains { $0.id == hiddenID }, "the unhidden markup never got a slot")
        #expect(prepared.markups.count == 2)
    }

    // MARK: - CR-80

    @Test("A polygon whose fill cannot be triangulated is counted as rejected, stroke still drawn")
    func degenerateFillIsCountedRejected() throws {
        let page = page()
        let id = MarkupID(UUID())
        // Three collinear points: a fill with zero area yields no triangles, but the outline
        // still strokes. Old output: rejectedMarkupCount == 0 — the dropped fill was silent.
        let markup = RenderableMarkup(
            id: id,
            shape: .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 300, y: 100)
            ])),
            style: RenderStyle(stroke: SceneColors.outline, fill: SceneColors.concrete, lineWidth: 2)
        )
        let preparer = ScenePreparer()
        let prepared = try preparer.prepare(
            page: page, markups: [markup], selection: .empty, snapFeedback: nil, viewport: viewport(page)
        )
        #expect(prepared.statistics.rejectedMarkupCount >= 1, "the dropped fill was not counted")
        let compiled = try #require(prepared.markups.first { $0.id == id })
        #expect(compiled.triangles.isEmpty)
        #expect(compiled.fillRejected)
        #expect(!compiled.segments.isEmpty, "the outline stroke should still be present")
    }

    // MARK: - CR-79

    @Test("A transient bad viewport keeps the previous frame instead of blanking it")
    func badViewportKeepsPreviousFrame() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        let page = page()
        let markups = [RenderableMarkup(
            id: MarkupID(UUID()),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)])),
            style: RenderStyle(stroke: SceneColors.ink, lineWidth: 3)
        )]
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page))
        let before = try renderer.renderOffscreen()

        // A transient zero-zoom viewport during a resize makes the transform singular and
        // preparation throw. Old output: `scene = nil`, so renderOffscreen threw noSceneToRender
        // and hitTest returned nil — the whole markup layer vanished for a frame.
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page, zoom: 0))
        let after = try renderer.renderOffscreen()
        #expect(after.pixels == before.pixels, "the previous good frame was not preserved")
        #expect(renderer.hitTest(pagePoint: CGPoint(x: 250, y: 100), toleranceInPagePoints: 5) != nil,
                "hit-testing was lost on a transient bad viewport")
    }
}
