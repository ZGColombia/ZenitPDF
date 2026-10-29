import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// The correctness contract of viewport culling, checked pixel for pixel.
///
/// The full-viewport goldens cannot catch a culling defect: with the whole page on screen
/// nothing is culled. So this suite renders a **partial** viewport — a window over a region of
/// `mixed-200`, zoomed in far enough that most of the scene lies outside the drawable — once
/// with culling disabled and once enabled, and requires the two rasters **byte-identical** on
/// each backend. Not "within tolerance": identical. Culling that changes any pixel is a bug by
/// definition.
///
/// Every test here also asserts that the culled render actually culled something, because a
/// pass in which the culler kept everything would prove nothing (a gate must show it examined
/// something).
@Suite("Partial-viewport culling goldens", .serialized)
struct PartialViewportCullingTests {

    /// A window over the middle of the page at 400 %: roughly a tenth of the page area.
    private func windowViewport(_ scene: RenderScene) throws -> RenderViewport {
        let region = PDFRect(x: 180, y: 280, width: 180, height: 140)
        return try #require(RenderViewport.window(
            scene.page,
            zoom: 4.0,
            backingScale: 2.0,
            pageRect: region
        ))
    }

    private func render(
        _ scene: RenderScene,
        viewport: RenderViewport,
        backend: RendererBackend,
        policy: CullingPolicy
    ) throws -> (image: RasterImage, statistics: RenderStatistics) {
        switch backend {
        case .coreGraphics:
            let renderer = CoreGraphicsMarkupRenderer()
            defer { renderer.dispose() }
            renderer.cullingPolicy = policy
            renderer.update(
                page: scene.page,
                markups: scene.markups,
                selection: scene.selection,
                snapFeedback: scene.snapFeedback,
                viewport: viewport
            )
            return (try renderer.renderOffscreen(), renderer.statistics)
        case .metal:
            let renderer = try MetalMarkupRenderer()
            defer { renderer.dispose() }
            renderer.cullingPolicy = policy
            renderer.update(
                page: scene.page,
                markups: scene.markups,
                selection: scene.selection,
                snapFeedback: scene.snapFeedback,
                viewport: viewport
            )
            return (try renderer.renderOffscreen(), renderer.statistics)
        }
    }

    @Test("Culled and unculled renders of the visible region are byte-identical, per backend")
    func culledEqualsUnculled() throws {
        let scene = SceneLibrary.mixed200()
        let viewport = try windowViewport(scene)
        for backend in RendererBackend.allCases {
            let unculled = try render(
                scene, viewport: viewport, backend: backend, policy: .disabled
            )
            let culled = try render(
                scene, viewport: viewport, backend: backend, policy: .default
            )
            // Non-vacuity: the culled render must actually have skipped markups, or this test
            // examined nothing.
            #expect(
                culled.statistics.culledMarkupCount > 0,
                "\(backend): the window viewport culled nothing, so equality proves nothing"
            )
            #expect(unculled.statistics.culledMarkupCount == 0)
            #expect(
                culled.image.pixels == unculled.image.pixels,
                "\(backend): culling changed rendered pixels in the visible region"
            )
        }
    }

    @Test("The two backends agree with each other on the culled partial viewport")
    func backendsAgreeWhileCulling() throws {
        let scene = SceneLibrary.mixed200()
        let viewport = try windowViewport(scene)
        let reference = try render(
            scene, viewport: viewport, backend: .coreGraphics, policy: .default
        )
        let metal = try render(
            scene, viewport: viewport, backend: .metal, policy: .default
        )
        #expect(reference.statistics.culledMarkupCount > 0)
        #expect(
            reference.statistics.culledMarkupCount == metal.statistics.culledMarkupCount,
            "the two backends culled different sets"
        )
        let result = ImageComparator.compare(metal.image, reference.image)
        #expect(result.matches, Comment(rawValue: result.summary))
    }

    @Test("Culling the dimension-grammar scene is pixel-neutral and cross-backend equal")
    func dimensionGrammarCullsCleanly() throws {
        // A window over the committed area and its label pill; the dimension lines at the page
        // edges fall outside it. Their view-sized ink (arrowheads, ticks, pills) reaches beyond
        // the measured geometry, so this is the scene that catches a culler treating "outside
        // the viewport" as a statement about centrelines rather than ink.
        let scene = SceneLibrary.dimensionGrammar(zoom: 1.0, backingScale: 1.0, name: "dimension-grammar")
        let region = PDFRect(x: 240, y: 180, width: 160, height: 130)
        let viewport = try #require(RenderViewport.window(
            scene.page,
            zoom: 4.0,
            backingScale: 2.0,
            pageRect: region
        ))
        for backend in RendererBackend.allCases {
            let unculled = try render(scene, viewport: viewport, backend: backend, policy: .disabled)
            let culled = try render(scene, viewport: viewport, backend: backend, policy: .default)
            #expect(
                culled.statistics.culledMarkupCount > 0,
                "\(backend): the window culled nothing, so equality proves nothing"
            )
            #expect(
                culled.image.pixels == unculled.image.pixels,
                "\(backend): culling changed rendered pixels in the visible region"
            )
        }
        let reference = try render(scene, viewport: viewport, backend: .coreGraphics, policy: .default)
        let metal = try render(scene, viewport: viewport, backend: .metal, policy: .default)
        let result = ImageComparator.compare(metal.image, reference.image)
        #expect(result.matches, Comment(rawValue: result.summary))
    }

    @Test("A pan within the hysteresis band changes no pixels against a fresh render")
    func hysteresisIsInvisible() throws {
        // The cached visible set is a superset while the drawable stays inside the query band;
        // a pan that reuses it must produce exactly the pixels a fresh renderer produces.
        let scene = SceneLibrary.mixed200()
        let viewport = try windowViewport(scene)
        var panned = viewport
        panned.layout.anchor.x += 24 // view points, well inside the 256-device-pixel band

        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: scene.selection,
            snapFeedback: scene.snapFeedback,
            viewport: viewport
        )
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: scene.selection,
            snapFeedback: scene.snapFeedback,
            viewport: panned
        )
        let reused = try renderer.renderOffscreen()

        let fresh = try render(
            scene, viewport: panned, backend: .coreGraphics, policy: .default
        )
        #expect(reused.pixels == fresh.image.pixels, "a cached visible set changed the picture")
    }
}
