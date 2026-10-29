import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Behavioural contract of ``CullingPolicy`` — the counters, the exemptions, and the things
/// culling is required not to touch. The pixel-exactness contract lives in
/// `PartialViewportCullingTests`, next to the goldens.
@Suite("Viewport culling and the sub-pixel cutoff")
struct CullingTests {

    private func id(_ value: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (
            value, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, value
        )))
    }

    private func line(_ value: UInt8, from: PDFPoint, to: PDFPoint) -> RenderableMarkup {
        RenderableMarkup(
            id: id(value),
            zIndex: Int(value),
            shape: .polyline(RenderPolyline(points: [from, to])),
            style: RenderStyle(stroke: SceneColors.ink, lineWidth: 1)
        )
    }

    /// A whole-page viewport at a zoom low enough that a 2-point markup is under half a pixel.
    private func zoomedOutViewport(_ page: PageDescriptor) -> RenderViewport {
        RenderViewport.fittingWholePage(page, zoom: 0.1, backingScale: 1.0)
    }

    @Test("A markup below half a device pixel is dropped, counted, and identically on both backends")
    func subPixelCutoffIsCountedAndShared() throws {
        let page = SceneIdentity.page()
        let markups = [
            // 2 points at zoom 0.1, scale 1 -> 0.2 device pixels: below the cutoff.
            line(1, from: PDFPoint(x: 300, y: 400), to: PDFPoint(x: 302, y: 400)),
            // 200 points -> 20 device pixels: kept.
            line(2, from: PDFPoint(x: 100, y: 100), to: PDFPoint(x: 300, y: 100))
        ]
        let viewport = zoomedOutViewport(page)

        let reference = CoreGraphicsMarkupRenderer()
        defer { reference.dispose() }
        reference.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport
        )
        #expect(reference.statistics.subPixelMarkupCount == 1)
        #expect(reference.statistics.culledMarkupCount == 0)
        #expect(reference.statistics.markupCount == 2)

        let metal = try MetalMarkupRenderer()
        defer { metal.dispose() }
        metal.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport
        )
        #expect(metal.statistics.subPixelMarkupCount == 1)

        let cgImage = try reference.renderOffscreen()
        let metalImage = try metal.renderOffscreen()
        let comparison = ImageComparator.compare(metalImage, cgImage)
        #expect(comparison.matches, Comment(rawValue: comparison.summary))
    }

    @Test("Text labels are exempt from the sub-pixel cutoff")
    func textIsExempt() {
        let page = SceneIdentity.page()
        let label = RenderableMarkup(
            id: id(9),
            shape: .textLabel(RenderTextLabel(
                anchorPoint: PDFPoint(x: 300, y: 400),
                text: "12.5 m2",
                fontName: "Helvetica",
                fontSize: 8,
                anchor: .center
            )),
            style: RenderStyle(stroke: SceneColors.label)
        )
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: [label],
            selection: .empty,
            snapFeedback: nil,
            viewport: zoomedOutViewport(page)
        )
        // The anchor's geometric bounds are a zero-size point, which would fail any extent
        // test; the ink is pixel-sized and legible, so it must be kept.
        #expect(renderer.statistics.subPixelMarkupCount == 0)
        #expect(renderer.statistics.markupCount == 1)
    }

    @Test("Markups outside a windowed viewport are culled and hit testing still finds them")
    func culledMarkupsRemainHitTestable() throws {
        let page = SceneIdentity.page()
        let inside = line(1, from: PDFPoint(x: 210, y: 300), to: PDFPoint(x: 260, y: 300))
        let outside = line(2, from: PDFPoint(x: 20, y: 700), to: PDFPoint(x: 80, y: 700))
        let viewport = try #require(RenderViewport.window(
            page,
            zoom: 4.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 200, y: 280, width: 100, height: 60)
        ))

        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: [inside, outside],
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        #expect(renderer.statistics.culledMarkupCount == 1)

        // Culling is a submission decision, not a scene decision: the hit tester still sees
        // every markup, because a click on the ledger can land anywhere on the page.
        let hit = renderer.hitTest(pagePoint: CGPoint(x: 50, y: 700), toleranceInPagePoints: 3)
        #expect(hit?.markupID == outside.id)
    }

    @Test("A disabled policy submits everything and counts nothing")
    func disabledPolicyIsInert() throws {
        let page = SceneIdentity.page()
        let markups = [
            line(1, from: PDFPoint(x: 300, y: 400), to: PDFPoint(x: 301, y: 400)),
            line(2, from: PDFPoint(x: 20, y: 700), to: PDFPoint(x: 80, y: 700))
        ]
        let viewport = try #require(RenderViewport.window(
            page,
            zoom: 4.0,
            backingScale: 2.0,
            pageRect: PDFRect(x: 200, y: 280, width: 100, height: 60)
        ))
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.cullingPolicy = .disabled
        renderer.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport
        )
        #expect(renderer.statistics.culledMarkupCount == 0)
        #expect(renderer.statistics.subPixelMarkupCount == 0)
    }

    @Test("A dragged markup is never wrongly culled while the spatial index is stale")
    func staleIndexNeverCullsAMovedMarkup() throws {
        let page = SceneIdentity.page()
        let region = PDFRect(x: 200, y: 280, width: 100, height: 60)
        let viewport = try #require(RenderViewport.window(
            page, zoom: 4.0, backingScale: 2.0, pageRect: region
        ))
        // Starts far outside the window, then is dragged into it without a topology change.
        var moving = line(1, from: PDFPoint(x: 20, y: 700), to: PDFPoint(x: 60, y: 700))
        let anchor = line(2, from: PDFPoint(x: 210, y: 300), to: PDFPoint(x: 260, y: 300))

        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page,
            markups: [moving, anchor],
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        #expect(renderer.statistics.culledMarkupCount == 1)

        moving.revision = 1
        moving.shape = .polyline(RenderPolyline(points: [
            PDFPoint(x: 220, y: 310), PDFPoint(x: 270, y: 310)
        ]))
        renderer.update(
            page: page,
            markups: [moving, anchor],
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        #expect(renderer.statistics.culledMarkupCount == 0, "the dragged markup was culled")

        // And it is actually painted: compare against a fresh renderer that never saw the
        // stale position.
        let fresh = CoreGraphicsMarkupRenderer()
        defer { fresh.dispose() }
        fresh.update(
            page: page,
            markups: [moving, anchor],
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        let reused = try renderer.renderOffscreen()
        let baseline = try fresh.renderOffscreen()
        #expect(reused.pixels == baseline.pixels)
    }
}
