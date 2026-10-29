import Foundation
import ZPDFContracts

/// Why the renderer is not the one that was asked for.
public enum RendererDegradation: Sendable, Hashable, CustomStringConvertible {
    /// The machine has no Metal-capable GPU.
    case noMetalDevice
    /// The shaders would not compile. Carries the compiler's message.
    case shaderCompilationFailed(String)
    /// The shaders compiled but a pipeline could not be created.
    case pipelineCreationFailed(String)
    /// The caller asked for Core Graphics.
    case requestedByCaller
    /// Starting the Metal renderer failed for a reason that is none of the above — a failure
    /// that is not about the device, the shaders or a pipeline. Carries the real error, so the
    /// log and the panel do not blame pipeline creation for it (BH-622).
    case startupFailed(String)

    public var description: String {
        switch self {
        case .noMetalDevice:
            "no Metal device is available; falling back to the Core Graphics renderer"
        case let .shaderCompilationFailed(message):
            "Metal shader compilation failed, falling back to the Core Graphics renderer: \(message)"
        case let .pipelineCreationFailed(message):
            "Metal pipeline creation failed, falling back to the Core Graphics renderer: \(message)"
        case .requestedByCaller:
            "the Core Graphics renderer was requested explicitly"
        case let .startupFailed(message):
            "the Metal renderer failed to start, falling back to the Core Graphics renderer: \(message)"
        }
    }

    /// A localized sentence for the diagnostics panel, so the user can see *why* the canvas is
    /// slower rather than only that it is.
    public var localizedExplanation: String {
        switch self {
        case .noMetalDevice:
            NSLocalizedString(
                "This Mac has no Metal-capable graphics device, so markups are drawn on the CPU.",
                comment: "Renderer degradation reason shown in the diagnostics panel"
            )
        case .shaderCompilationFailed, .pipelineCreationFailed, .startupFailed:
            NSLocalizedString(
                "The GPU renderer could not start, so markups are drawn on the CPU. See Console for details.",
                comment: "Renderer degradation reason shown in the diagnostics panel"
            )
        case .requestedByCaller:
            NSLocalizedString(
                "Markups are drawn on the CPU because the GPU renderer is switched off in Preferences.",
                comment: "Renderer degradation reason shown in the diagnostics panel"
            )
        }
    }
}

/// What the factory produced.
public struct RendererSelection: Sendable {
    public let backend: RendererBackend
    /// `nil` when the caller got exactly what it asked for.
    public let degradation: RendererDegradation?

    public init(backend: RendererBackend, degradation: RendererDegradation?) {
        self.backend = backend
        self.degradation = degradation
    }
}

/// Builds a renderer, and never fails to build one.
///
/// # The guarantee
///
/// `make(...)` returns a working ``OffscreenMarkupRendering`` in every case that can arise on a
/// user's machine. There is no throwing variant, no optional return and no path that leaves the
/// caller without a renderer, because the alternatives at the call site are a crash and a blank
/// canvas, and a takeoff drawing with invisible markups is worse than a slow one. Every fallback
/// is logged at `error` level with the reason, and the reason is handed back so the UI can say it
/// out loud instead of leaving the user to wonder why panning got heavy.
public enum MarkupRendererFactory {

    /// Which backend the caller would like.
    public enum Preference: Sendable, Hashable {
        case metal
        case coreGraphics
    }

    /// Creates the best available renderer.
    ///
    /// - Parameters:
    ///   - preference: `.metal` in production; `.coreGraphics` when the user has switched the GPU
    ///     renderer off or when a test wants the oracle.
    ///   - runtime: the Metal system-object seam. Tests inject `FailingMetalRuntime`.
    /// - Returns: a live renderer and a description of what was chosen and why.
    public static func make(
        preference: Preference = .metal,
        runtime: any MetalRuntimeProviding = DefaultMetalRuntime()
    ) -> (renderer: any OffscreenMarkupRendering, selection: RendererSelection) {
        guard preference == .metal else {
            return (
                CoreGraphicsMarkupRenderer(),
                RendererSelection(backend: .coreGraphics, degradation: .requestedByCaller)
            )
        }
        do {
            let renderer = try MetalMarkupRenderer(runtime: runtime)
            return (renderer, RendererSelection(backend: .metal, degradation: nil))
        } catch {
            let degradation = Self.degradation(from: error)
            RendererLog.logger.error(
                "markup renderer degraded: \(degradation.description, privacy: .public)"
            )
            return (
                CoreGraphicsMarkupRenderer(),
                RendererSelection(backend: .coreGraphics, degradation: degradation)
            )
        }
    }

    static func degradation(from error: any Error) -> RendererDegradation {
        guard let rendererError = error as? RendererError else {
            return .startupFailed(String(describing: error))
        }
        // Exhaustive on purpose: a new `RendererError` case must be classified here, not
        // swept into "pipeline creation failed" by a catch-all (BH-622).
        switch rendererError {
        case .metalDeviceUnavailable:
            return .noMetalDevice
        case let .shaderCompilationFailed(message):
            return .shaderCompilationFailed(message)
        case let .pipelineCreationFailed(message):
            return .pipelineCreationFailed(message)
        case .noSceneToRender, .invalidViewport, .invalidPage, .targetTooLarge,
             .bitmapContextUnavailable, .commandEncodingFailed, .textureReadbackFailed, .disposed:
            return .startupFailed(rendererError.description)
        }
    }
}
