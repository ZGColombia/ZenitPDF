import CoreGraphics
import Foundation
import Metal
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Graceful degradation: no device, or a shader that will not compile, must produce a working
/// Core Graphics renderer and a logged reason — never a crash and never a blank canvas.
@Suite("Graceful degradation")
struct DegradationTests {

    private func drawableScene() -> RenderScene {
        SceneLibrary.polygonWithHoles(holeCount: 2)
    }

    private func inkFraction(_ image: RasterImage) -> Double {
        var ink = 0.0
        for index in 0..<(image.width * image.height) {
            ink += Double(image.pixels[index * 4 + 3]) / 255
        }
        return ink / Double(image.width * image.height)
    }

    @Test("No Metal device falls back to Core Graphics with a reason, and still draws")
    func noDevice() throws {
        let (renderer, selection) = MarkupRendererFactory.make(
            preference: .metal,
            runtime: FailingMetalRuntime(mode: .noDevice)
        )
        defer { renderer.dispose() }
        #expect(selection.backend == .coreGraphics)
        #expect(selection.degradation == .noMetalDevice)
        #expect(renderer.backend == .coreGraphics)
        #expect(!(selection.degradation?.localizedExplanation.isEmpty ?? true))
        let image = try drawableScene().render(with: renderer)
        #expect(inkFraction(image) > 0.01, "the fallback produced a blank canvas")
    }

    @Test("A shader that will not compile falls back with the compiler's message, and still draws")
    func shaderCompilationFailure() throws {
        let (renderer, selection) = MarkupRendererFactory.make(
            preference: .metal,
            runtime: FailingMetalRuntime(mode: .shaderDoesNotCompile)
        )
        defer { renderer.dispose() }
        #expect(selection.backend == .coreGraphics)
        guard case let .shaderCompilationFailed(message) = selection.degradation else {
            Issue.record("expected a shader compilation failure, got \(String(describing: selection.degradation))")
            return
        }
        #expect(!message.isEmpty)
        let image = try drawableScene().render(with: renderer)
        #expect(inkFraction(image) > 0.01, "the fallback produced a blank canvas")
    }

    @Test("A library with no entry points falls back through the pipeline path, and still draws")
    func missingEntryPoints() throws {
        let (renderer, selection) = MarkupRendererFactory.make(
            preference: .metal,
            runtime: FailingMetalRuntime(mode: .missingEntryPoints)
        )
        defer { renderer.dispose() }
        #expect(selection.backend == .coreGraphics)
        guard case let .pipelineCreationFailed(message) = selection.degradation else {
            Issue.record("expected a pipeline failure, got \(String(describing: selection.degradation))")
            return
        }
        #expect(message.contains("segment_vertex"))
        let image = try drawableScene().render(with: renderer)
        #expect(inkFraction(image) > 0.01, "the fallback produced a blank canvas")
    }

    @Test("Asking for Core Graphics gets it, and says so")
    func explicitCoreGraphics() {
        let (renderer, selection) = MarkupRendererFactory.make(preference: .coreGraphics)
        defer { renderer.dispose() }
        #expect(selection.backend == .coreGraphics)
        #expect(selection.degradation == .requestedByCaller)
        #expect(renderer.backend == .coreGraphics)
    }

    @Test("On this machine the default preference really gets Metal")
    func metalIsAvailableHere() throws {
        let (renderer, selection) = MarkupRendererFactory.make()
        defer { renderer.dispose() }
        #expect(selection.backend == .metal)
        #expect(selection.degradation == nil)
        let metal = try #require(renderer as? MetalMarkupRenderer)
        #expect(!metal.deviceName.isEmpty)
        // Eight samples where the device has them, four otherwise (MetalRuntime).
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(metal.sampleCount == (device.supportsTextureSampleCount(8) ? 8 : 4))
    }

    @Test("Every renderer error prints something a human can act on")
    func errorDescriptions() {
        let errors: [RendererError] = [
            .noSceneToRender,
            .invalidViewport(reason: "empty"),
            .invalidPage(reason: "bad box"),
            .targetTooLarge(PixelSize(width: 99_999, height: 1)),
            .bitmapContextUnavailable,
            .metalDeviceUnavailable,
            .shaderCompilationFailed("x"),
            .pipelineCreationFailed("y"),
            .commandEncodingFailed("z"),
            .textureReadbackFailed("w"),
            .disposed
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("Rendering before any scene is supplied is a typed error on both backends")
    func noScene() throws {
        let cg = CoreGraphicsMarkupRenderer()
        defer { cg.dispose() }
        #expect(throws: RendererError.noSceneToRender) { try cg.renderOffscreen() }
        let metal = try MetalMarkupRenderer()
        defer { metal.dispose() }
        #expect(throws: RendererError.noSceneToRender) { try metal.renderOffscreen() }
    }

    @Test("Rendering after dispose is a typed error on both backends")
    func afterDispose() throws {
        for renderer in [CoreGraphicsMarkupRenderer() as any OffscreenMarkupRendering,
                         try MetalMarkupRenderer()] {
            let scene = drawableScene()
            _ = try scene.render(with: renderer)
            renderer.dispose()
            #expect(throws: RendererError.disposed) { try renderer.renderOffscreen() }
            // A second dispose, and an update afterwards, are both no-ops rather than crashes.
            renderer.dispose()
            renderer.update(
                page: scene.page,
                markups: scene.markups,
                selection: .empty,
                snapFeedback: nil,
                viewport: scene.viewport
            )
            #expect(renderer.statistics.markupCount == 0)
        }
    }
}
