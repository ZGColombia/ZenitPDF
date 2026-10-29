import CoreGraphics
import Foundation
import ZPDFContracts

/// The renderer contract.
///
/// Two implementations satisfy it: `CoreGraphicsMarkupRenderer`, the reference, and
/// `MetalMarkupRenderer`, the production backend. `MarkupRendererFactory` picks one and reports
/// why. A caller holds the protocol and never learns which it got, except through
/// ``MarkupPageRendering/backend``, which exists so the status bar can say so honestly.
///
/// # Threading
///
/// A renderer is a reference type bound to one drawable and is **not** `Sendable`. `update` and
/// `hitTest` must be called from the same thread — in the app that is the main actor, in tests it
/// is whatever thread the test runs on. Nothing in the package hops actors on its own.
public protocol MarkupPageRendering: AnyObject {

    /// Which backend this instance actually is.
    var backend: RendererBackend { get }

    /// Replaces the scene.
    ///
    /// The call is idempotent and diff-based: passing the same `markups` array twice, with the
    /// same `(id, revision)` pairs, must not re-upload geometry. Passing a different `selection`
    /// or `snapFeedback` with unchanged markups must not touch the geometry buffers at all.
    ///
    /// Malformed geometry is dropped, never drawn and never fatal: a markup with a non-finite
    /// coordinate, a coordinate beyond ``RenderLimits/coordinateMagnitudeBound`` or a contour
    /// longer than ``RenderLimits/maximumContourVertices`` is skipped and counted in
    /// ``MarkupPageRendering/statistics``.
    func update(
        page: PageDescriptor,
        markups: [RenderableMarkup],
        selection: SelectionSnapshot,
        snapFeedback: RenderSnapFeedback?,
        viewport: RenderViewport
    )

    /// Finds the topmost markup whose **drawn** ink is within `toleranceInPagePoints` of
    /// `pagePoint`.
    ///
    /// "Drawn" is the operative word. A hairline stroked at the one-pixel floor is hit at the
    /// width it was painted at, not at its nominal `lineWidth`, because the user aims at what
    /// they can see. Both backends delegate to the same `SceneHitTester`, so the two can never
    /// disagree.
    func hitTest(pagePoint: CGPoint, toleranceInPagePoints: CGFloat) -> HitTestResult?

    /// Releases every GPU and CPU buffer. Calling any other method afterwards is a no-op that
    /// returns empty results; it is never a crash.
    func dispose()

    /// Counters from the last ``update(page:markups:selection:snapFeedback:viewport:)``.
    var statistics: RenderStatistics { get }
}

/// Which implementation is live.
public enum RendererBackend: String, Sendable, Hashable, Codable, CaseIterable {
    case metal
    case coreGraphics

    /// A localized name for the status bar and the diagnostics panel.
    public var displayName: String {
        switch self {
        case .metal:
            return NSLocalizedString("Metal", comment: "Name of the GPU markup renderer backend")
        case .coreGraphics:
            return NSLocalizedString(
                "Core Graphics",
                comment: "Name of the CPU fallback markup renderer backend"
            )
        }
    }
}

/// What part of a markup was hit.
///
/// The order of the cases is the priority order: a handle beats a stroke, a stroke beats a fill.
/// That is the order a user expects when they click near the corner of a selected filled polygon.
public enum HitKind: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case handle = 0
    case vertex = 1
    case stroke = 2
    case fill = 3

    public static func < (lhs: HitKind, rhs: HitKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One hit.
public struct HitTestResult: Sendable, Hashable, Codable {
    public let markupID: MarkupID
    public let kind: HitKind
    /// Index of the handle or vertex hit, when ``kind`` is ``HitKind/handle`` or
    /// ``HitKind/vertex``.
    public let elementIndex: Int?
    /// Distance from the query point to the drawn ink, in page points. `0` inside a fill.
    public let distanceInPagePoints: Double
    /// The closest point on the drawn ink, in page space.
    public let point: PDFPoint

    public init(
        markupID: MarkupID,
        kind: HitKind,
        elementIndex: Int? = nil,
        distanceInPagePoints: Double,
        point: PDFPoint
    ) {
        self.markupID = markupID
        self.kind = kind
        self.elementIndex = elementIndex
        self.distanceInPagePoints = distanceInPagePoints
        self.point = point
    }
}

/// Counters from the last update. Printed by the benchmarks and shown in the diagnostics panel.
public struct RenderStatistics: Sendable, Hashable, Codable {
    /// Markups accepted into the scene.
    public var markupCount: Int
    /// Markups of the current scene dropped because their geometry failed ``RenderLimits``, or
    /// whose requested fill could not be triangulated. A property of the **scene**, not of the
    /// last update: a pan or hover that recompiles nothing reports the same number (BH-626).
    public var rejectedMarkupCount: Int
    /// Markups of the current scene whose dash pattern had more runs than an instance carries
    /// and was cut to its first four, which changes its shape (BH-623). Same scene-wide sense as
    /// ``rejectedMarkupCount``.
    public var truncatedDashCount: Int
    public var lineInstanceCount: Int
    public var triangleCount: Int
    public var symbolInstanceCount: Int
    public var glyphInstanceCount: Int
    /// Markups whose instances were rewritten by the last update. `0` for a pure selection,
    /// hover, snap or pan change — those are the frames this counter exists to police. Freeing a
    /// slot is not counted: the question it answers is how many markups had to be re-uploaded.
    public var dirtySlotCount: Int
    /// Bytes actually written into instance storage by the last update.
    public var uploadedByteCount: Int
    /// Total bytes resident in instance storage (GPU buffers on Metal, arrays on Core Graphics).
    /// Render targets are not in it; see ``renderTargetByteCount``.
    public var residentByteCount: Int
    /// Bytes held by the render targets (resolve texture, multisample texture where it is not
    /// memoryless, readback buffer) at the time of the last update. A drawable-size cost, kept
    /// apart from the per-page instance figure. `0` on Core Graphics, which renders into the
    /// caller's bitmap.
    public var renderTargetByteCount: Int
    /// Markups not submitted this frame because their painted bounds cannot intersect the
    /// drawable. Skipping them changes no pixel; the partial-viewport golden pair proves it.
    public var culledMarkupCount: Int
    /// Markups not submitted because their geometric extent projects below the sub-pixel
    /// cutoff of the active ``CullingPolicy``. This one does change pixels — by design, and
    /// never silently: the count is here and both backends drop the identical set.
    public var subPixelMarkupCount: Int
    /// Draw calls the last encoded frame issued. Zero on the Core Graphics backend, which has
    /// none. It is here so "the renderer batches by material" is a number a test can read rather
    /// than a claim in a comment: it must stay flat as the markup count grows.
    public var drawCallCount: Int
    /// Render pipeline state binds the last encoded frame issued — the state changes that
    /// batching by material exists to remove. Same contract as ``drawCallCount``.
    public var pipelineStateChangeCount: Int

    public init(
        markupCount: Int = 0,
        rejectedMarkupCount: Int = 0,
        lineInstanceCount: Int = 0,
        triangleCount: Int = 0,
        symbolInstanceCount: Int = 0,
        glyphInstanceCount: Int = 0,
        dirtySlotCount: Int = 0,
        uploadedByteCount: Int = 0,
        residentByteCount: Int = 0,
        culledMarkupCount: Int = 0,
        subPixelMarkupCount: Int = 0,
        drawCallCount: Int = 0,
        pipelineStateChangeCount: Int = 0,
        truncatedDashCount: Int = 0,
        renderTargetByteCount: Int = 0
    ) {
        self.renderTargetByteCount = renderTargetByteCount
        self.markupCount = markupCount
        self.rejectedMarkupCount = rejectedMarkupCount
        self.truncatedDashCount = truncatedDashCount
        self.lineInstanceCount = lineInstanceCount
        self.triangleCount = triangleCount
        self.symbolInstanceCount = symbolInstanceCount
        self.glyphInstanceCount = glyphInstanceCount
        self.dirtySlotCount = dirtySlotCount
        self.uploadedByteCount = uploadedByteCount
        self.residentByteCount = residentByteCount
        self.culledMarkupCount = culledMarkupCount
        self.subPixelMarkupCount = subPixelMarkupCount
        self.drawCallCount = drawCallCount
        self.pipelineStateChangeCount = pipelineStateChangeCount
    }

    public static let empty = RenderStatistics()
}

/// A renderer that can paint into a CPU-readable RGBA8 image with no window and no display.
///
/// Both backends conform. This is what makes the golden-image suite possible: the same scene goes
/// through both implementations offscreen and the two rasters are compared pixel by pixel.
public protocol OffscreenMarkupRendering: MarkupPageRendering {
    /// Renders the current scene into a fresh premultiplied-sRGB RGBA8 image at the viewport's
    /// pixel size.
    ///
    /// - Throws: ``RendererError`` — never traps, whatever the scene contains.
    func renderOffscreen() throws -> RasterImage
}

/// Every way rendering can fail. Typed, exhaustive, and never a trap.
public enum RendererError: Error, Sendable, Hashable, CustomStringConvertible {
    case noSceneToRender
    case invalidViewport(reason: String)
    case invalidPage(reason: String)
    case targetTooLarge(PixelSize)
    case bitmapContextUnavailable
    case metalDeviceUnavailable
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case commandEncodingFailed(String)
    case textureReadbackFailed(String)
    case disposed

    public var description: String {
        switch self {
        case .noSceneToRender:
            "no scene has been supplied to the renderer yet"
        case let .invalidViewport(reason):
            "invalid viewport: \(reason)"
        case let .invalidPage(reason):
            "invalid page: \(reason)"
        case let .targetTooLarge(size):
            "render target \(size.width)x\(size.height) exceeds the \(RenderLimits.maximumTargetPixels) pixel bound"
        case .bitmapContextUnavailable:
            "Core Graphics refused to create the bitmap context"
        case .metalDeviceUnavailable:
            "no Metal device is available on this machine"
        case let .shaderCompilationFailed(message):
            "Metal shader compilation failed: \(message)"
        case let .pipelineCreationFailed(message):
            "Metal pipeline creation failed: \(message)"
        case let .commandEncodingFailed(message):
            "Metal command encoding failed: \(message)"
        case let .textureReadbackFailed(message):
            "reading the render target back to the CPU failed: \(message)"
        case .disposed:
            "the renderer has been disposed"
        }
    }
}
