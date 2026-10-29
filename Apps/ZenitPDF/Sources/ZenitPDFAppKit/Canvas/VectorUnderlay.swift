import CoreGraphics
import Dispatch
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFRenderer
import ZPDFVectorExtraction

/// Whether the canvas draws the vector underlay, and — when it does not — why.
///
/// Gate **Z10**: the underlay is present at every zoom on a Metal machine, and *switched off
/// with a visible explanation* on a machine that falls back to Core Graphics. The Core Graphics
/// backend needs 98.6 ms per frame at 100 % zoom and 134.3 ms at fit-to-window on the reference
/// machine (a historical viewer-benchmark measurement). Shipping a 7 fps underlay would be
/// worse than shipping none, and shipping it silently would be worse than either — the user
/// would see a canvas that behaves differently from the one in the documentation with nothing
/// anywhere to say why.
public enum VectorUnderlayAvailability: Equatable, Sendable {
    /// The GPU renderer started. The underlay is drawn.
    case available(deviceName: String)
    /// The underlay is off, and this sentence says so in the diagnostics panel.
    case unavailable(explanation: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// A sentence for the diagnostics panel. Never empty, in either case.
    public var explanation: String {
        switch self {
        case let .available(deviceName):
            return String(
                format: NSLocalizedString(
                    "The vector underlay is drawn on %@. It shows the drawing's linework only — no text, colour, shading or images.",
                    comment: "Diagnostics panel line, vector underlay active on a named GPU"
                ),
                deviceName
            )
        case let .unavailable(explanation):
            return explanation
        }
    }
}

/// The vector underlay: the page's own extracted linework, drawn under the raster.
///
/// # Why this exists and why it is drawn first
///
/// The benchmark inverted the plan's layer order. The stale raster the canvas used to show while
/// a new one arrived cost 8.0–15.5 ms a frame to present; the whole of this sheet's linework
/// costs 0.61–0.92 ms at *any* zoom, in 1.6 MB, and unlike the stale raster it is already
/// correct at the zoom the user just arrived at. So the underlay goes underneath, and it is what
/// fills the few milliseconds before the true raster lands.
///
/// # What it is not
///
/// See ``PageUnderlayCompiler``. Geometry, one ink, no text, no images. A sharp skeleton beneath
/// a sharpening page.
///
/// # What it costs today, measured rather than quoted
///
/// The benchmark's 0.61–0.92 ms is build + encode + GPU with no readback. This implementation
/// goes through `renderOffscreen()`, which resolves the multisample target and copies it to the
/// CPU, and that copy is four fifths of the cost: **3.5–4.2 ms p50 at 2.33 megapixels**, release,
/// on the reference machine. So the honest claim is narrower than the benchmark's: the underlay
/// is a clear win on a cold first frame and at fit-to-window and 100 % zoom, and roughly a wash
/// at 400 % and 800 % where a warm viewport raster is already under 3.1 ms. It never costs the
/// main thread anything — the canvas still performs exactly one blit per frame — but it is not
/// yet the sub-millisecond layer the measurement described. Removing the readback means a live
/// `CAMetalLayer` and `MetalMarkupRenderer.encode(into:)`, which is still open.
///
/// # Threading
///
/// `MarkupPageRendering` is explicitly not `Sendable` and must be driven from one place. This
/// actor is that place, and its executor is a private serial `DispatchQueue` rather than the
/// cooperative pool, so the Metal renderer sees one serialised caller for its whole life. The
/// first compile of a page's markups costs 171.4 ms on the reference machine and it happens
/// here, off the main actor, once per page — never on a zoom.
public actor VectorUnderlay {

    private let queue = DispatchSerialQueue(
        label: "com.zenitgroup.zenitpdf.underlay",
        qos: .userInitiated
    )
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let renderer: any OffscreenMarkupRendering
    private let selection: RendererSelection
    private var compiled: [RenderableMarkup] = []
    private var compiledPageIndex: Int?
    private var compiledHiddenLayerIDs: Set<String> = []
    private var compileRevision = 0
    private var preparedGeneration = Int.min
    /// Offscreen renders performed. BH-350's counter.
    public private(set) var renderCountForTesting = 0

    /// The hidden set the compiled skeleton was built with. BH-889's seam.
    public var compiledHiddenLayersForTesting: Set<String> { compiledHiddenLayerIDs }
    /// The revision the compiled skeleton carries. BH-345's seam.
    public var compiledRevisionForTesting: UInt64? { compiled.first?.revision }

    /// Creates an underlay, or reports why there is not going to be one.
    ///
    /// - Parameter preference: `.coreGraphics` in a test that wants to exercise the refusal
    ///   path without needing a Mac that has no GPU.
    public init(preference: MarkupRendererFactory.Preference = .metal) {
        let made = MarkupRendererFactory.make(preference: preference)
        self.renderer = made.renderer
        self.selection = made.selection
    }

    /// Gate Z10, as a value the diagnostics panel can read.
    public var availability: VectorUnderlayAvailability {
        guard selection.backend == .metal, let metal = renderer as? MetalMarkupRenderer else {
            let reason = selection.degradation?.localizedExplanation ?? NSLocalizedString(
                "The GPU renderer is not available on this Mac.",
                comment: "Fallback reason when the renderer backend is not Metal"
            )
            return .unavailable(
                explanation: reason + " " + NSLocalizedString(
                    "The vector underlay is switched off, because drawing it on the CPU costs about a tenth of a second per frame. The page is still drawn at full sharpness; it simply takes a few milliseconds longer to appear after a zoom.",
                    comment: "Diagnostics panel line, vector underlay switched off on a non-Metal Mac"
                )
            )
        }
        return .available(deviceName: metal.deviceName)
    }

    /// Compiles a page's extraction once. Costs 171 ms the first time on this machine's GPU and
    /// nothing afterwards, which is exactly why it is not on the zoom path.
    public func prepare(
        page: ZPDFContracts.PageDescriptor,
        extraction: VectorPageExtraction,
        hiddenLayerIDs: Set<String>,
        generation: Int? = nil
    ) {
        guard availability.isAvailable else { return }
        // Two quick layer toggles start two prepares whose arrival order on this actor is not
        // guaranteed; an older one landing last would draw a layer the person just hid
        // (BH-889).
        if let generation {
            guard generation >= preparedGeneration else { return }
            preparedGeneration = generation
        }
        compileRevision &+= 1
        compiled = PageUnderlayCompiler.markups(
            from: extraction, hiddenLayerIDs: hiddenLayerIDs, revision: compileRevision
        )
        compiledPageIndex = page.index
        compiledHiddenLayerIDs = hiddenLayerIDs
        // The first `update` is what compiles the shaders and fills the instance buffers. Doing
        // it here, on this actor, is the whole of the "off the main actor" condition the
        // benchmark attaches to gate Z10.
        if let viewport = RenderViewport.window(
            page,
            zoom: 1,
            backingScale: 1,
            pageRect: page.visibleBox
        ) {
            renderer.update(
                page: page,
                markups: compiled,
                selection: SelectionSnapshot(),
                snapFeedback: nil,
                viewport: viewport
            )
        }
    }

    /// Forgets the compiled page.
    public func reset() {
        compiled = []
        compiledPageIndex = nil
    }

    /// Renders the planned viewport region of the skeleton.
    ///
    /// - Returns: `nil` when the underlay is off, when no page has been prepared, or when the
    ///   renderer refuses the target. Never throws into the canvas: an absent underlay is a
    ///   missing convenience, not a failure of the page.
    public func render(
        page: ZPDFContracts.PageDescriptor,
        plan: ViewportRasterPlan,
        hiddenLayerIDs: Set<String>? = nil
    ) -> CGImage? {
        // A superseded request does nothing: a pinch used to queue one full Metal render and
        // GPU readback per event, each discarded on arrival (BH-350, IM-175).
        guard !Task.isCancelled else { return nil }
        guard availability.isAvailable, compiledPageIndex == page.index, !compiled.isEmpty else {
            return nil
        }
        // Compiled against another hidden set: no skeleton rather than a wrong one (BH-889).
        if let hiddenLayerIDs, hiddenLayerIDs != compiledHiddenLayerIDs { return nil }
        let backingScale = Double(plan.backingScale)
        guard backingScale > 0 else { return nil }
        let layout = PageViewLayout(
            anchor: CGPoint(
                x: -plan.originInPageDevicePixels.x / plan.backingScale,
                y: -plan.originInPageDevicePixels.y / plan.backingScale
            ),
            zoom: Double(plan.scale) / backingScale,
            backingScale: backingScale,
            isViewFlipped: true
        )
        let viewport = RenderViewport(
            layout: layout,
            viewSize: plan.destination.size,
            visiblePageRect: PDFRect(
                x: plan.pageRegion.minX,
                y: plan.pageRegion.minY,
                width: plan.pageRegion.size.width,
                height: plan.pageRegion.size.height
            )
        )
        guard (try? viewport.validate()) != nil else { return nil }
        renderer.update(
            page: page,
            markups: compiled,
            selection: SelectionSnapshot(),
            snapFeedback: nil,
            viewport: viewport
        )
        guard !Task.isCancelled else { return nil }
        // The Metal renderer hands back the image directly: renderOffscreen() + makeCGImage()
        // copied the whole frame twice (465 ms against 5.5 ms at 3060×3960, IM-084).
        if let metal = renderer as? MetalMarkupRenderer {
            guard let image = try? metal.renderOffscreenImage() else { return nil }
            renderCountForTesting += 1
            guard image.width == plan.pixelSize.width, image.height == plan.pixelSize.height else { return nil }
            return image
        }
        guard let raster = try? renderer.renderOffscreen() else { return nil }
        renderCountForTesting += 1
        guard raster.width == plan.pixelSize.width, raster.height == plan.pixelSize.height else {
            // A mismatch would land the skeleton in the wrong place, which is worse than no
            // skeleton at all. Refuse rather than stretch.
            return nil
        }
        return raster.makeCGImage()
    }

    /// Counters from the last frame, for the diagnostics panel.
    public var statistics: RenderStatistics { renderer.statistics }

    /// Releases the renderer's buffers.
    public func dispose() {
        renderer.dispose()
        compiled = []
        compiledPageIndex = nil
    }
}
