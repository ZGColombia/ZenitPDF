import Foundation
import Metal
import os

/// The seam between the renderer and the Metal system objects.
///
/// It exists so that "no Metal device" and "the shader will not compile" are conditions a test
/// can create on demand. Without it the degradation path could only be exercised on a machine
/// with a broken GPU, which is to say never, which is to say it would ship untested.
public protocol MetalRuntimeProviding: AnyObject {
    /// The device to render on, or `nil` when the machine has none.
    func makeDevice() -> (any MTLDevice)?
    /// The shading language source to compile.
    func shaderSource() -> String
}

/// The real runtime: the system default device and the real shaders.
public final class DefaultMetalRuntime: MetalRuntimeProviding {
    public init() {}
    public func makeDevice() -> (any MTLDevice)? { MTLCreateSystemDefaultDevice() }
    public func shaderSource() -> String { MetalShaderSource.library }
}

/// A runtime that fails in a chosen way, for the degradation tests.
public final class FailingMetalRuntime: MetalRuntimeProviding {
    public enum Mode: Sendable, Hashable {
        /// `makeDevice()` returns `nil`, as on a machine with no Metal-capable GPU.
        case noDevice
        /// The shader source is syntactically invalid, so `makeLibrary` throws.
        case shaderDoesNotCompile
        /// The shader compiles but has no entry point by the expected name, so pipeline creation
        /// fails — the failure a driver or OS change produces, and a different code path.
        case missingEntryPoints
    }

    public let mode: Mode
    public init(mode: Mode) { self.mode = mode }

    public func makeDevice() -> (any MTLDevice)? {
        mode == .noDevice ? nil : MTLCreateSystemDefaultDevice()
    }

    public func shaderSource() -> String {
        switch mode {
        case .noDevice:
            return MetalShaderSource.library
        case .shaderDoesNotCompile:
            return "#include <metal_stdlib>\nthis is not valid metal shading language\n"
        case .missingEntryPoints:
            return "#include <metal_stdlib>\nusing namespace metal;\nkernel void unrelated() {}\n"
        }
    }
}

/// One pipeline per material, all built for the same sample count.
///
/// Two of these exist. The multisampled set draws into the multisample (8x or 4x) attachment; the single-sample set
/// draws into the resolved one. A pipeline state is immutable and its sample count is baked in at
/// creation, so "which attachment am I drawing into" is a choice of set and nothing else.
struct MaterialPipelines {
    let segment: any MTLRenderPipelineState
    let triangle: any MTLRenderPipelineState
    let symbol: any MTLRenderPipelineState
    let glyph: any MTLRenderPipelineState
    /// The same four materials blended multiplicatively, for a highlighter
    /// (`RenderBlendMode.multiply`, K-07). Bound only for the run of instances that belongs to
    /// a multiplying markup, so a scene without one never touches them.
    let multiplySegment: any MTLRenderPipelineState
    let multiplyTriangle: any MTLRenderPipelineState
    let multiplySymbol: any MTLRenderPipelineState
    let multiplyGlyph: any MTLRenderPipelineState
}

/// Every pipeline state the renderer needs, created once.
final class MetalPipelines {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    /// Built for `sampleCount` samples. The only set that may draw into the multisample target.
    let multisampled: MaterialPipelines
    /// Built for one sample. Draws straight into the resolved target, in a second pass.
    ///
    /// When the device offers no multisampling at all this is the same set as ``multisampled``,
    /// because there is then only one attachment shape and one pass to draw into it.
    let singleSample: MaterialPipelines
    let atlasSampler: any MTLSamplerState
    let sampleCount: Int
    let pixelFormat: MTLPixelFormat

    /// - Throws: ``RendererError/metalDeviceUnavailable``,
    ///   ``RendererError/shaderCompilationFailed(_:)`` or
    ///   ``RendererError/pipelineCreationFailed(_:)``. Never traps.
    init(runtime: any MetalRuntimeProviding, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device = runtime.makeDevice() else {
            throw RendererError.metalDeviceUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.pipelineCreationFailed("the device would not create a command queue")
        }

        let library: any MTLLibrary
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            library = try device.makeLibrary(source: runtime.shaderSource(), options: options)
        } catch {
            throw RendererError.shaderCompilationFailed(String(describing: error))
        }

        // Multisampling, at the highest count the device offers up to eight: 8, else 4, else 2,
        // else none, each asked of the device with `supportsTextureSampleCount`.
        //
        // Core Graphics computes exact edge area; a GPU rasteriser quantises coverage to
        // 1/sampleCount. A fill drawn with no multisampling differs from the oracle along every
        // diagonal edge by up to half a level of alpha — far outside any tolerance worth having.
        //
        // Eight rather than four (bug hunt 2, decided 2026-09-23, measured). Four samples
        // were enough everywhere but one place: an edge at exactly 45°. The standard 4x pattern
        // projects onto a 45° edge's normal unevenly (x + y = 0.5, 0.75, 1.25, 1.5 — a gap twice
        // the others), and along such an edge every pixel sees the same phase, so the error
        // accumulates instead of averaging out: one 16-pixel tile of `count-symbols-imported`
        // differed from Core Graphics by 0.028 against a 0.025 limit. At 8x every golden scene
        // meets the normal cross-backend check, that one included (worst tile 0.016).
        //
        // What it costs, measured on an Apple M5 Pro in a release build with the two counts
        // interleaved in one process, 240 GPU samples per scene, stress corpus at 1 000 to
        // 100 000 markups at 5 %, 100 % and 800 %: GPU p50 +0.02 to +0.78 ms, p99 at most
        // +0.98 ms, every p99 under 7 ms. The multisample target is memoryless on Apple-family
        // GPUs (see `MetalMarkupRenderer.prepareTargets`) and resolved on store in the fill pass
        // only, so the extra samples live in tile memory: no RAM and next to no bandwidth. On a
        // GPU without memoryless storage the target is private and doubles, 93.5 -> 185.6 MiB at
        // 3000 x 2000 and 229 -> 458 MiB at 5120 x 2880.
        //
        // **This is a budget for polygon edges alone, and since the pass split it is spent on
        // them alone.** Strokes and atlas quads never depended on it — `segment_fragment`
        // computes coverage analytically and writes the same value to every sample, and
        // `atlas_fragment` reads its alpha from a padded atlas — and paying for multisampled
        // rasterisation and blending on them cost between 3.8x and 12.1x of the frame at the
        // stress corpus's sizes (measured at four samples). They draw in a second, single-sample
        // pass; see `RenderPassPolicy`, which is where the equivalence argument and the
        // measurements are.
        let sampleCount = [8, 4, 2].first { device.supportsTextureSampleCount($0) } ?? 1

        func makePipeline(
            _ vertexName: String,
            _ fragmentName: String,
            samples: Int,
            multiply: Bool = false
        ) throws -> any MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertexName) else {
                throw RendererError.pipelineCreationFailed("missing vertex function \(vertexName)")
            }
            guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
                throw RendererError.pipelineCreationFailed("missing fragment function \(fragmentName)")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.rasterSampleCount = samples
            guard let attachment = descriptor.colorAttachments[0] else {
                throw RendererError.pipelineCreationFailed("no colour attachment 0")
            }
            attachment.pixelFormat = pixelFormat
            // Premultiplied source-over, which is what the raster comparison assumes and what
            // `CGBitmapContext` with `premultipliedLast` produces.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            if multiply {
                // Core Graphics' `.multiply` in premultiplied form,
                // `Cs·(1 − αd) + Cd·(Cs + 1 − αs)`, with the per-channel destination factor
                // supplied by the shader's second output. See `MultiplyOutput` in the shader.
                attachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
                attachment.destinationRGBBlendFactor = .source1Color
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RendererError.pipelineCreationFailed(String(describing: error))
            }
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        // Texel coordinates, not normalised ones. An instance's uv is then a property of its tile
        // alone and stays right when the glyph atlas grows taller underneath it; normalised uv
        // baked against the old height sampled row 2y after a doubling, garbling every label of
        // the bucket except the one being edited (BH-200). Linear filtering, no mipmaps and
        // clamp-to-edge are exactly what unnormalised sampling permits.
        samplerDescriptor.normalizedCoordinates = false
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.pipelineCreationFailed("the device would not create a sampler")
        }

        func makeSet(samples: Int) throws -> MaterialPipelines {
            MaterialPipelines(
                segment: try makePipeline("segment_vertex", "segment_fragment", samples: samples),
                triangle: try makePipeline("triangle_vertex", "triangle_fragment", samples: samples),
                symbol: try makePipeline("symbol_vertex", "atlas_fragment", samples: samples),
                glyph: try makePipeline("glyph_vertex", "atlas_fragment", samples: samples),
                multiplySegment: try makePipeline(
                    "segment_vertex", "segment_fragment_multiply", samples: samples, multiply: true
                ),
                multiplyTriangle: try makePipeline(
                    "triangle_vertex", "triangle_fragment_multiply", samples: samples, multiply: true
                ),
                multiplySymbol: try makePipeline(
                    "symbol_vertex", "atlas_fragment_multiply", samples: samples, multiply: true
                ),
                multiplyGlyph: try makePipeline(
                    "glyph_vertex", "atlas_fragment_multiply", samples: samples, multiply: true
                )
            )
        }

        self.device = device
        self.commandQueue = queue
        let multisampled = try makeSet(samples: sampleCount)
        self.multisampled = multisampled
        self.singleSample = sampleCount == 1 ? multisampled : try makeSet(samples: 1)
        self.atlasSampler = sampler
        self.sampleCount = sampleCount
        self.pixelFormat = pixelFormat
    }
}

/// The renderer's log. One subsystem, one category, so a degradation is findable in Console.
enum RendererLog {
    static let logger = Logger(subsystem: "com.zenitgroup.zenitpdf", category: "renderer")
}
