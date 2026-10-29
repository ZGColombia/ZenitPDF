import CoreGraphics
import Foundation
import ZPDFPDFKitBridge

/// A layer colour, in linear sRGB components `0…1`.
///
/// Deliberately not `CGColor` or `NSColor`: this is a model value that has to be
/// `Sendable`, `Hashable`, `Codable` and comparable exactly, and it has to be usable
/// from an engine package that must not import AppKit.
public struct OverlayColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Swift.min(1, Swift.max(0, red))
        self.green = Swift.min(1, Swift.max(0, green))
        self.blue = Swift.min(1, Swift.max(0, blue))
    }

    public static let black = OverlayColor(red: 0, green: 0, blue: 0)
    public static let white = OverlayColor(red: 1, green: 1, blue: 1)
}

/// How a layer's tinted ink combines with what is already on the canvas.
///
/// The modes are multiply, screen and difference. Each is applied as a *blend
/// function* and then alpha-composited by the layer's coverage, which is the standard
/// separable-blend formula — `out = base·(1−α) + B(base, layer)·α` — so opacity and
/// blend mode stay independent controls rather than interfering with each other.
public enum OverlayBlendMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The layer's colour replaces the base where it has coverage.
    case normal
    /// Darkens. The mode for stacking revisions on white paper: two overlapping lines
    /// read darker than either alone, which is what a light table does.
    case multiply
    /// Lightens. Useful for a dark-ground presentation.
    case screen
    /// `|base − layer|`. Two identical revisions composite to the background exactly,
    /// which makes "nothing changed" visible at a glance.
    case difference

    func blend(base: Double, layer: Double) -> Double {
        switch self {
        case .normal: return layer
        case .multiply: return base * layer
        case .screen: return 1 - (1 - base) * (1 - layer)
        case .difference: return abs(base - layer)
        }
    }
}

/// One revision in the overlay stack.
public struct OverlayLayer: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    /// What the user calls this revision — "Rev C", "2026-04-12 IFC".
    public var label: String
    public var color: OverlayColor
    /// `0…1`.
    public var opacity: Double
    public var isVisible: Bool
    public var blendMode: OverlayBlendMode

    public init(
        id: Int,
        label: String,
        color: OverlayColor,
        opacity: Double = 1,
        isVisible: Bool = true,
        blendMode: OverlayBlendMode = .multiply
    ) {
        self.id = id
        self.label = label
        self.color = color
        self.opacity = Swift.min(1, Swift.max(0, opacity))
        self.isVisible = isVisible
        self.blendMode = blendMode
    }
}

/// N revisions as colour-tinted layers.
///
/// The model is the whole state of Revision Overlay: which revisions are in the stack,
/// what colour and opacity each one has, and which are switched on. It carries no
/// images — a stack of layer *settings* is small, `Codable` and safe to persist with a
/// project, while the rasters are transient and rebuilt at whatever zoom the user is at.
///
/// It is built whole for each composite from the interface's own layers — colour, opacity,
/// visibility and blend mode — so it carries no palette and no per-layer mutators of its own
/// (W-083): a second palette here could only drift from the one the overlay shows.
public struct RevisionOverlayModel: Sendable, Hashable, Codable {
    public var layers: [OverlayLayer]
    /// What the composite starts from. White paper by default.
    public var background: OverlayColor

    public init(layers: [OverlayLayer], background: OverlayColor = .white) {
        self.layers = layers
        self.background = background
    }

    public var visibleLayers: [OverlayLayer] { layers.filter(\.isVisible) }
}

/// One revision's raster, already resampled into the shared frame.
public struct OverlaySource: Sendable, Hashable {
    public let layerID: Int
    public let image: GrayImage

    public init(layerID: Int, image: GrayImage) {
        self.layerID = layerID
        self.image = image
    }
}

/// An 8-bit RGBA raster, row-major, row 0 at the top, alpha last and not premultiplied.
public struct RGBAImage: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw CompareFault.malformedRaster(reason: "size \(width)x\(height)")
        }
        // Checked like GrayImage.init: the unchecked product trapped on overflow (BH-471).
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (expected, byteOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !areaOverflow, !byteOverflow else {
            throw CompareFault.malformedRaster(reason: "size \(width)x\(height) overflows")
        }
        guard pixels.count == expected else {
            throw CompareFault.malformedRaster(
                reason: "\(pixels.count) bytes for \(width)x\(height) RGBA"
            )
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func cgImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw CompareFault.coreGraphicsFailure(operation: "RGBA data provider")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CompareFault.coreGraphicsFailure(operation: "RGBA CGImage")
        }
        return image
    }
}

/// The composited overlay, plus what went into it.
public struct OverlayComposite: Sendable, Hashable {
    public let image: RGBAImage
    /// The layers that actually contributed, in paint order.
    public let contributingLayerIDs: [Int]

    public init(image: RGBAImage, contributingLayerIDs: [Int]) {
        self.image = image
        self.contributingLayerIDs = contributingLayerIDs
    }
}

/// Turns N gray rasters and a ``RevisionOverlayModel`` into one image.
///
/// Compositing is done here in `Double` rather than handed to CoreGraphics blend modes
/// on purpose: the result must be identical on every machine and reproducible in a test,
/// and it must be defined for the "ink coverage" interpretation of a grayscale page
/// rather than for the RGB interpretation. A PDF page drawn in black on white has
/// coverage `(255 − gray) / 255`; that coverage, scaled by the layer's opacity, is the
/// alpha the layer's colour is painted with.
public enum OverlayCompositor {

    /// Composites the visible layers of `model`, in array order, bottom first.
    ///
    /// - Throws: ``CompareFault/overlayLayerMismatch(reason:)`` when a visible layer has
    ///   no source, and ``CompareFault/mismatchedRasterGeometry(baseline:revised:)``
    ///   when the sources are not all the same size — an overlay of two differently
    ///   sized rasters is a bug upstream, not something to paper over here.
    public static func composite(
        model: RevisionOverlayModel,
        sources: [OverlaySource],
        maximumPixels: Int = 64_000_000
    ) throws -> OverlayComposite {
        let visible = model.visibleLayers
        guard !visible.isEmpty else {
            throw CompareFault.overlayLayerMismatch(reason: "no visible layer")
        }
        var byID: [Int: GrayImage] = [:]
        for source in sources { byID[source.layerID] = source.image }

        var width = 0
        var height = 0
        for layer in visible {
            guard let image = byID[layer.id] else {
                throw CompareFault.overlayLayerMismatch(reason: "layer \(layer.id) has no raster")
            }
            if width == 0 {
                width = image.width
                height = image.height
            } else if image.width != width || image.height != height {
                throw CompareFault.mismatchedRasterGeometry(
                    baseline: "\(width)x\(height)", revised: image.geometryDescription
                )
            }
        }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= maximumPixels else {
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: product.overflow ? Int.max : product.partialValue,
                limit: maximumPixels
            )
        }

        let count = product.partialValue

        // Pixels on the outside, layers on the inside.
        //
        // The first version of this walked the whole page once per layer and kept three
        // page-sized `Double` accumulators between the passes. That is 24 bytes a pixel
        // before a single layer is painted: on an A1 sheet at 2.45 px/pt — 24
        // megapixels — 576 MB of accumulator for a picture whose output is 96 MB. Doing
        // it the other way round keeps the three accumulators in registers, allocates
        // nothing but the output, and performs exactly the same arithmetic in exactly
        // the same order per pixel, so the bytes are identical to the version the
        // existing expectations were written against.
        var images: [GrayImage] = []
        var painters: [Painter] = []
        var contributing: [Int] = []
        for layer in visible {
            guard let image = byID[layer.id] else { continue }
            contributing.append(layer.id)
            images.append(image)
            painters.append(
                Painter(
                    red: layer.color.red,
                    green: layer.color.green,
                    blue: layer.color.blue,
                    mode: layer.blendMode,
                    opacity: layer.opacity
                )
            )
        }

        let background = model.background
        var output = [UInt8](repeating: 255, count: count * 4)
        try withInk(of: images[...], gathered: []) { ink in
            try painters.withUnsafeBufferPointer { paint in
                try output.withUnsafeMutableBufferPointer { out in
                    // Cancellation is checked per band rather than per pixel: a check
                    // inside the inner loop would cost more than the blend it guards.
                    var start = 0
                    while start < count {
                        try checkCompareCancellation()
                        let end = Swift.min(start + cancellationBand, count)
                        for index in start..<end {
                            var red = background.red
                            var green = background.green
                            var blue = background.blue
                            for layerIndex in paint.indices {
                                let painter = paint[layerIndex]
                                let coverage = (255.0 - Double(ink[layerIndex][index])) / 255.0
                                let alpha = coverage * painter.opacity
                                guard alpha > 0 else { continue }
                                red = red * (1 - alpha)
                                    + painter.mode.blend(base: red, layer: painter.red) * alpha
                                green = green * (1 - alpha)
                                    + painter.mode.blend(base: green, layer: painter.green) * alpha
                                blue = blue * (1 - alpha)
                                    + painter.mode.blend(base: blue, layer: painter.blue) * alpha
                            }
                            out[index * 4] = channel(red)
                            out[index * 4 + 1] = channel(green)
                            out[index * 4 + 2] = channel(blue)
                            out[index * 4 + 3] = 255
                        }
                        start = end
                    }
                }
            }
        }
        return OverlayComposite(
            image: try RGBAImage(width: width, height: height, pixels: output),
            contributingLayerIDs: contributing
        )
    }

    @inline(__always)
    private static func channel(_ value: Double) -> UInt8 {
        UInt8(Swift.min(255, Swift.max(0, (value * 255).rounded())))
    }

    /// How many pixels are composited between two cancellation checks.
    private static let cancellationBand = 1 << 20

    /// One layer's paint, flattened out of the model so the inner loop reads a struct
    /// of `Double`s rather than walking `OverlayLayer`'s clamping accessors.
    private struct Painter {
        let red: Double
        let green: Double
        let blue: Double
        let mode: OverlayBlendMode
        let opacity: Double
    }

    /// Runs `body` with a borrowed pointer into every layer's ink, all valid at once.
    ///
    /// `withUnsafeBufferPointer` only guarantees its pointer inside its own closure, and
    /// the composite needs N of them simultaneously. Nesting the closures by recursion is
    /// the one way to get that without either copying every source into a second buffer —
    /// another byte per pixel per layer — or keeping a pointer past its lifetime, which
    /// is undefined behaviour however well it appears to work.
    private static func withInk<R>(
        of images: ArraySlice<GrayImage>,
        gathered: [UnsafePointer<UInt8>],
        _ body: ([UnsafePointer<UInt8>]) throws -> R
    ) throws -> R {
        guard let first = images.first else { return try body(gathered) }
        return try first.pixels.withUnsafeBufferPointer { buffer -> R in
            guard let base = buffer.baseAddress else {
                throw CompareFault.malformedRaster(reason: "layer raster has no storage")
            }
            return try withInk(of: images.dropFirst(), gathered: gathered + [base], body)
        }
    }
}

/// What size a composite of the whole sheet would be, and what size it will actually be.
///
/// Revision Overlay composites the **whole page**, not the viewport: the raster crosses
/// the service boundary as one page image and the wire has no region on it, so there is
/// no cheaper thing to ask for. That makes the render scale the only lever, and on a
/// large sheet at a large zoom the honest scale is not the one the canvas is showing at.
/// An A1 sheet is 2 383.94 × 1 683.78 pt: at 400 % on a 2× display the whole sheet is
/// 19 071 × 13 470 pixels — 257 megapixels, over a third of a gigabyte of gray input per
/// layer before anything is painted.
///
/// So the plan reduces the scale to the largest one that fits the budget and **records
/// that it did**. It is not clamped silently: ``isReduced`` is what the overlay's own
/// statement of resolution is built from, in the same spirit as gate Z8, which refuses a
/// whole-page raster over budget rather than quietly shrinking it. The difference is that
/// an overlay has to show something, so it shows a coarser composite and says so.
public struct OverlayCompositePlan: Sendable, Hashable {

    /// The page box the composite covers, in page space.
    public let pageBox: CGRect
    /// Pixels per PDF point the caller asked for — normally the canvas's zoom times the
    /// display's backing scale.
    public let requestedScale: Double
    /// Pixels per PDF point the composite will actually be produced at.
    public let scale: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// How many layers will be composited. Part of the memory estimate, not of the size.
    public let layerCount: Int
    /// The budget the plan was fitted to.
    public let maximumPixels: Int

    public init(
        pageBox: CGRect,
        requestedScale: Double,
        scale: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        layerCount: Int,
        maximumPixels: Int
    ) {
        self.pageBox = pageBox
        self.requestedScale = requestedScale
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.layerCount = layerCount
        self.maximumPixels = maximumPixels
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }

    /// Whether the composite is coarser than what was asked for.
    public var isReduced: Bool { scale < requestedScale - 1e-9 }

    /// The composite's linear resolution as a fraction of the one requested, `0…1`.
    public var resolutionFraction: Double {
        guard requestedScale > 0 else { return 1 }
        return Swift.min(1, scale / requestedScale)
    }

    /// Peak bytes the composite pass holds: one gray page per layer plus the RGBA output.
    /// The accumulators are per-pixel locals and cost nothing per page.
    public var estimatedPeakBytes: Int { pixelCount * (4 + layerCount) }

    /// An in-budget plan for a sheet, a wanted scale and a layer count: the wanted scale when it
    /// fits, otherwise the bridge's fitted scale.
    ///
    /// Deterministic by construction: the same four arguments always produce the same
    /// plan, on any machine, because every step is exact arithmetic on `Double`.
    ///
    /// The scale is ``RenderPixelSize/fittedScale(width:height:requested:pixelBudget:)``, the
    /// bridge's fit to its own ceil-per-axis rounding, which OCR uses too (T-069). It finds a
    /// fitting scale whenever one exists; the loop it replaced shrank by 0.1 % at most 64 times,
    /// so a strip sheet whose exact-area scale was more than 6 % too large threw, and
    /// `RevisionComparator` then fell back to the unfitted, over-budget scale.
    ///
    /// - Throws: ``CompareFault/invalidRenderScale(_:)`` for a scale that is not a usable
    ///   positive finite number, and ``CompareFault/malformedRaster(reason:)`` for a page
    ///   box with no area.
    ///
    /// `rotationDegrees` is the page's `/Rotate`. The renderer sizes the bitmap from the
    /// *displayed* box, so at 90 or 270 the pixel width comes from the box's height; the
    /// plan used to report the two transposed (BH-472). The budget is unaffected either way.
    public static func fit(
        pageBox: CGRect,
        requestedScale: Double,
        layerCount: Int,
        maximumPixels: Int,
        rotationDegrees: Int = 0
    ) throws -> OverlayCompositePlan {
        guard requestedScale.isFinite, requestedScale > 0, requestedScale <= 100 else {
            throw CompareFault.invalidRenderScale(requestedScale)
        }
        let width = Double(pageBox.width)
        let height = Double(pageBox.height)
        guard width > 0, height > 0, width.isFinite, height.isFinite else {
            throw CompareFault.malformedRaster(
                reason: "page box \(pageBox.width)x\(pageBox.height) has no area"
            )
        }
        guard maximumPixels > 0 else {
            throw CompareFault.pixelBudgetExceeded(requestedPixels: 0, limit: maximumPixels)
        }

        let scale = RenderPixelSize.fittedScale(
            width: width, height: height, requested: requestedScale, pixelBudget: maximumPixels
        )
        guard scale > 0 else {
            let wanted = RenderPixelSize.renderedDimension(width, scale: requestedScale)
                * RenderPixelSize.renderedDimension(height, scale: requestedScale)
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: wanted < Double(Int.max) ? Int(wanted) : Int.max, limit: maximumPixels
            )
        }
        let pixels = Self.pixels(width: width, height: height, scale: scale)
        let quarterTurned = ((rotationDegrees % 360) + 360) % 180 == 90
        return OverlayCompositePlan(
            pageBox: pageBox,
            requestedScale: requestedScale,
            scale: scale,
            pixelWidth: quarterTurned ? pixels.1 : pixels.0,
            pixelHeight: quarterTurned ? pixels.0 : pixels.1,
            layerCount: Swift.max(0, layerCount),
            maximumPixels: maximumPixels
        )
    }

    /// The pixel size the render actually produces for a box at a scale.
    ///
    /// The bridge's own rule, ``RenderPixelSize/renderedDimension(_:scale:)``: `ceil` on each
    /// axis, as `PDFKitDocumentProvider.renderPageRegion` sizes its bitmap. Rounding to nearest
    /// here instead was a real bug for exactly one run: the plan predicted 5 829 × 4 117 for the
    /// A1 sheet and the renderer produced 5 830 × 4 118, nine thousand pixels over a budget the
    /// plan had just certified as met, and the composite failed instead of being reduced. Only
    /// called with a fitted scale, so both axes are within the budget.
    private static func pixels(width: Double, height: Double, scale: Double) -> (Int, Int) {
        (
            Swift.max(1, Int(RenderPixelSize.renderedDimension(width, scale: scale))),
            Swift.max(1, Int(RenderPixelSize.renderedDimension(height, scale: scale)))
        )
    }
}
