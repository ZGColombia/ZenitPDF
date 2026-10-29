import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFRenderer
import ZPDFRendererScenario

/// "Batch by material to cut state changes" — the first of the three candidate fixes for the
/// renderer's frame rate — measured rather than asserted.
///
/// # What the measurement found
///
/// The renderer already batches by material, and has since the arenas were built: geometry lives
/// in one persistent buffer per material, a frame binds each material's pipeline once and issues
/// one draw over the whole buffer, and a viewport change only narrows *which* instance indices
/// that one draw covers. So the win available under this heading is **zero**, and the number
/// below is how that is known rather than believed: the draw and pipeline-bind counts of a frame
/// are recorded in ``RenderStatistics`` by `encode(into:)` and asserted here to be the same at
/// 200 markups as at 50 000.
///
/// A frame's draw calls are: one per non-empty geometry material (fills, strokes, one per symbol
/// atlas bucket, one per font-and-size glyph bucket) plus the overlay's own. Buckets are a
/// property of the *content* — how many distinct symbol sizes and font sizes a page uses — not of
/// how many markups there are, which is exactly the property this test pins.
@Suite("Material batching", .serialized)
struct MaterialBatchingTests {

    private func viewport(_ page: PageDescriptor) -> RenderViewport {
        RenderViewport(
            layout: PageViewLayout(anchor: .zero, zoom: 1.0, backingScale: 2.0, isViewFlipped: true),
            viewSize: CGSize(width: 1_600, height: 1_000),
            visiblePageRect: page.visibleBox
        )
    }

    @Test("Draw calls and pipeline binds do not grow with the number of markups")
    func stateChangesAreFlat() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        var measured: [(count: Int, draws: Int, binds: Int)] = []
        for markupCount in [200, 2_000, 20_000, 50_000] {
            let scene = SceneLibrary.stress(count: markupCount)
            renderer.update(
                page: scene.page,
                markups: scene.markups,
                selection: .empty,
                snapFeedback: nil,
                viewport: viewport(scene.page)
            )
            _ = try renderer.encodeFrame()
            let statistics = renderer.statistics
            measured.append((markupCount, statistics.drawCallCount, statistics.pipelineStateChangeCount))
            print(String(
                format: "material batching | %6d markups -> %d draw calls, %d pipeline binds",
                markupCount, statistics.drawCallCount, statistics.pipelineStateChangeCount
            ))
        }
        let first = try #require(measured.first)
        #expect(first.draws > 0, "the frame issued no draw calls at all")
        for row in measured {
            #expect(
                row.draws == first.draws,
                "\(row.count) markups issued \(row.draws) draw calls, \(first.count) issued \(first.draws)"
            )
            #expect(
                row.binds == first.binds,
                "\(row.count) markups issued \(row.binds) pipeline binds, \(first.count) issued \(first.binds)"
            )
            // The stress corpus uses one symbol atlas bucket and one font size, so the whole
            // frame is fills, strokes, symbols, labels and the overlay's strokes: a single-digit
            // number. A regression that started drawing per markup would be in the thousands.
            #expect(row.draws <= 8, "\(row.count) markups issued \(row.draws) draw calls")
            #expect(row.binds <= row.draws, "more pipeline binds than draw calls")
        }
    }

    @Test("A frame with nothing to draw issues no draw calls")
    func emptySceneIssuesNothing() throws {
        // The counters must be a measurement of this frame, not a leftover from the last one.
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let scene = SceneLibrary.stress(count: 500)
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport(scene.page)
        )
        _ = try renderer.encodeFrame()
        #expect(renderer.statistics.drawCallCount > 0)
        renderer.update(
            page: scene.page,
            markups: [],
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport(scene.page)
        )
        _ = try renderer.encodeFrame()
        #expect(renderer.statistics.drawCallCount == 0, "an empty scene still issued draw calls")
        #expect(renderer.statistics.pipelineStateChangeCount == 0)
    }
}
