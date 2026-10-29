import Foundation
import Testing
import ZPDFRenderer
import ZPDFRendererScenario

/// Loading the stored goldens, and the one place that knows where they live.
enum Goldens {

    /// The directory the regeneration tool writes to, as it appears in the test bundle.
    static func url(for name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Goldens")
    }

    static func image(named name: String) -> RasterImage? {
        guard let url = url(for: name), let data = try? Data(contentsOf: url) else { return nil }
        return RasterImage.fromPNG(data)
    }

    /// Every golden file present in the bundle.
    static func storedNames() -> Set<String> {
        guard let directory = Bundle.module.url(forResource: "Goldens", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              )
        else { return [] }
        return Set(
            contents
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    /// Renders a scene through a fresh renderer of the given backend.
    static func render(_ scene: RenderScene, backend: RendererBackend) throws -> RasterImage {
        let renderer: any OffscreenMarkupRendering
        switch backend {
        case .coreGraphics: renderer = CoreGraphicsMarkupRenderer()
        case .metal: renderer = try MetalMarkupRenderer()
        }
        defer { renderer.dispose() }
        return try scene.render(with: renderer)
    }
}
