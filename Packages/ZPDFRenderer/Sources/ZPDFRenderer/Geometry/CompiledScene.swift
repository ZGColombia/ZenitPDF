import CoreGraphics
import Foundation
import ZPDFContracts

/// One stroked segment, in page space.
///
/// Everything a backend needs to paint the segment is here, in page points, so the same struct
/// can sit in a GPU instance buffer across a zoom change without being rewritten. The only things
/// that depend on zoom — the pixel width, the dash scale — are computed from the uniform.
public struct CompiledSegment: Sendable, Hashable {
    public var start: PDFPoint
    public var end: PDFPoint
    /// Nominal width in page points, before the on-screen floor.
    public var widthPagePoints: Double
    public var color: RGBAColor
    public var startCap: RenderCap
    public var endCap: RenderCap
    public var dash: DashPattern
    /// Arc length from the start of the owning polyline, in page points, so a dash pattern runs
    /// continuously across a corner instead of restarting at every vertex.
    public var dashOffsetPagePoints: Double

    public init(
        start: PDFPoint,
        end: PDFPoint,
        widthPagePoints: Double,
        color: RGBAColor,
        startCap: RenderCap,
        endCap: RenderCap,
        dash: DashPattern,
        dashOffsetPagePoints: Double
    ) {
        self.start = start
        self.end = end
        self.widthPagePoints = widthPagePoints
        self.color = color
        self.startCap = startCap
        self.endCap = endCap
        self.dash = dash
        self.dashOffsetPagePoints = dashOffsetPagePoints
    }
}

/// One filled triangle in page space.
public struct CompiledTriangle: Sendable, Hashable {
    public var a: PDFPoint
    public var b: PDFPoint
    public var c: PDFPoint
    public var color: RGBAColor

    public init(a: PDFPoint, b: PDFPoint, c: PDFPoint, color: RGBAColor) {
        self.a = a; self.b = b; self.c = c; self.color = color
    }
}

/// One count marker instance in page space.
public struct CompiledSymbol: Sendable, Hashable {
    public var center: PDFPoint
    public var symbol: CountSymbol
    /// Edge length in page points. Zero means "size in view points instead" — see
    /// ``sizeViewPoints`` — which is how selection handles and the snap glyph stay one physical
    /// size at every zoom.
    public var sizePagePoints: Double
    public var sizeViewPoints: Double
    public var color: RGBAColor
    /// Rotation about ``center`` in degrees, counter-clockwise on the page. `0` for the overlay's
    /// handles and snap glyph, which are always screen-upright.
    public var rotationDegrees: Double

    public init(
        center: PDFPoint,
        symbol: CountSymbol,
        sizePagePoints: Double,
        sizeViewPoints: Double = 0,
        color: RGBAColor,
        rotationDegrees: Double = 0
    ) {
        self.center = center
        self.symbol = symbol
        self.sizePagePoints = sizePagePoints
        self.sizeViewPoints = sizeViewPoints
        self.color = color
        self.rotationDegrees = rotationDegrees.isFinite ? rotationDegrees : 0
    }

    /// The rotation to apply in **device pixel** space, in radians, so that the symbol turns
    /// counter-clockwise *on the page*. Pixel space is y-down, so a page→pixel map that flips
    /// (every unmirrored view) turns the sense around; the determinant says which it is.
    public func pixelRotationRadians(pageToPixel matrix: RenderTransform.Affine) -> Double {
        guard rotationDegrees != 0 else { return 0 }
        let radians = rotationDegrees * .pi / 180
        return matrix.determinant < 0 ? -radians : radians
    }
}

/// One glyph quad, anchored to a page point and sized in device pixels.
///
/// Text is screen-upright, so the quad's size and its offsets from the anchor are pixel
/// quantities. They are valid for one glyph-atlas size bucket; ``RenderGeometryCache`` rebuilds
/// them when the bucket changes, which happens on a zoom step and never on a pan.
public struct CompiledGlyph: Sendable, Hashable {
    public var anchor: PDFPoint
    /// Offset from the anchor's pixel position to the quad's top-left corner, in device pixels.
    public var offsetX: Double
    public var offsetY: Double
    public var widthPixels: Double
    public var heightPixels: Double
    public var tile: AtlasTile
    /// Which glyph of ``CompiledMarkup/glyphFontName`` this quad shows. The raster backends never
    /// need it — they sample ``tile`` — but a vector destination must draw the glyph's outline
    /// rather than its coverage bitmap, and the outline can only be asked for by glyph id. See
    /// ``GlyphAtlas/tileOutline(for:)``.
    public var glyph: CGGlyph
    public var color: RGBAColor
    /// How far the quad is turned about its top-left corner, in device-pixel space (x right,
    /// y down, so a positive turn is clockwise on screen), in 1/65536ths of a full turn. `0` for
    /// every screen-upright label; only a label with ``RenderTextLabel/rotationDegrees`` — a
    /// stamp's field text — turns (T-065). Quantised so both backends, and the hit tester, use
    /// the very same angle; the Metal instance carries it in the upper half of its flags word.
    public var rotationSteps: UInt16

    public init(
        anchor: PDFPoint,
        offsetX: Double,
        offsetY: Double,
        widthPixels: Double,
        heightPixels: Double,
        tile: AtlasTile,
        glyph: CGGlyph = 0,
        color: RGBAColor,
        rotationSteps: UInt16 = 0
    ) {
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.tile = tile
        self.glyph = glyph
        self.color = color
        self.rotationSteps = rotationSteps
    }

    /// Steps in one full turn of ``rotationSteps``.
    public static let rotationStepsPerTurn = 65_536.0

    /// ``rotationSteps`` in radians, in device-pixel space.
    public var rotationRadians: Double {
        Double(rotationSteps) * 2 * .pi / Self.rotationStepsPerTurn
    }

    /// The nearest step to `radians` (device-pixel space), wrapped into one turn.
    public static func rotationSteps(forPixelRadians radians: Double) -> UInt16 {
        guard radians.isFinite else { return 0 }
        let turns = radians / (2 * .pi)
        let fraction = turns - turns.rounded(.down)
        let steps = (fraction * rotationStepsPerTurn).rounded()
        return steps >= rotationStepsPerTurn ? 0 : UInt16(steps)
    }

    /// The quad's four corners as device-pixel offsets from the anchor's pixel position:
    /// top-left, top-right, bottom-right, bottom-left.
    public var cornerOffsets: [(x: Double, y: Double)] {
        guard rotationSteps != 0 else {
            return [(offsetX, offsetY), (offsetX + widthPixels, offsetY),
                    (offsetX + widthPixels, offsetY + heightPixels), (offsetX, offsetY + heightPixels)]
        }
        let turn = rotationRadians
        let cosine = Foundation.cos(turn), sine = Foundation.sin(turn)
        return [(0.0, 0.0), (widthPixels, 0.0), (widthPixels, heightPixels), (0.0, heightPixels)].map { corner in
            (offsetX + corner.0 * cosine - corner.1 * sine, offsetY + corner.0 * sine + corner.1 * cosine)
        }
    }
}

/// One raster picture, decoded, with the page-space parallelogram it fills (ADR-0043).
///
/// The picture's unit square maps onto ``origin`` (bottom-left), ``xEnd`` (bottom-right) and
/// ``yEnd`` (top-left). The page → pixel map is affine, so a backend carries the three corners to
/// device pixels and draws the image through the one affine they span.
public struct CompiledImage: Sendable {
    public var origin: PDFPoint
    public var xEnd: PDFPoint
    public var yEnd: PDFPoint
    /// The decoded pixels (``RenderImagePixels/decode(_:)``).
    public var pixels: CGImage
    /// 0…1.
    public var opacity: Double

    public init(origin: PDFPoint, xEnd: PDFPoint, yEnd: PDFPoint, pixels: CGImage, opacity: Double) {
        self.origin = origin
        self.xEnd = xEnd
        self.yEnd = yEnd
        self.pixels = pixels
        self.opacity = opacity.isFinite ? Swift.min(1, Swift.max(0, opacity)) : 1
    }

    /// The four corners: bottom-left, bottom-right, top-right, top-left.
    public var corners: [PDFPoint] {
        [origin, xEnd, PDFPoint(x: xEnd.x + yEnd.x - origin.x, y: xEnd.y + yEnd.y - origin.y), yEnd]
    }
}

/// Everything one markup contributes to the frame, already reduced to instances.
public struct CompiledMarkup: Sendable {
    public var id: MarkupID
    public var revision: UInt64
    public var zIndex: Int
    public var segments: [CompiledSegment]
    public var triangles: [CompiledTriangle]
    public var symbols: [CompiledSymbol]
    public var glyphs: [CompiledGlyph]
    /// Font name and atlas bucket the glyphs were laid out at, `nil` when the markup has no text.
    public var glyphBucket: Int?
    public var glyphFontName: String?
    /// Page-space bounding box of everything above, stroke excluded.
    public var bounds: PDFRect?
    /// How far the painted ink can extend beyond ``bounds`` in **page points** — the stroke
    /// width, which covers a square cap's diagonal. The culler inflates the spatial index's
    /// boxes by this, so "outside the viewport" is a statement about ink, not centrelines.
    public var paddingPagePoints: Double
    /// How far the painted ink can extend beyond ``bounds`` in **device pixels**: the stroke
    /// floor, the antialiasing feather, glyph quads (which are pixel-sized and anchored to a
    /// zero-size bounds), symbol edge coverage. Zoom-dependent, so it cannot be baked into the
    /// index and is applied on the query side instead.
    public var paddingDevicePixels: Double

    /// A fill was requested for this markup but could not be triangulated (self-intersection past
    /// what the repair path handles, or a degenerate zero-area outline). The outline may still
    /// stroke, so the markup is not dropped — but the missing fill is counted as a rejection
    /// rather than lost silently (CR-80).
    public var fillRejected: Bool
    /// The stroke's dash pattern had more runs than a GPU instance can carry and was cut to
    /// four, which changes its shape. Counted in ``RenderStatistics/truncatedDashCount`` rather
    /// than changed silently (BH-623).
    public var dashTruncated: Bool
    /// How far the widest page-sized symbol reaches past ``bounds``, in page points (half its
    /// edge). Precomputed so a hit test's cheap reject is a lookup, not a reduce (IM-083).
    public var symbolReachPagePoints: Double
    /// How far the farthest glyph quad reaches from its anchor, in device pixels:
    /// `max(|offsetX| + width, |offsetY| + height)` over the glyphs. Same purpose.
    public var glyphReachPixels: Double
    /// Whether the markup's ink multiplies with the page (``RenderBlendMode/multiply``) — a
    /// highlighter. The CoreGraphics backend, and so every PDF export, paints it multiplied.
    public var multiplies: Bool = false
    /// The outline as curves for a vector painter (ADR-0030 §5.6): the CoreGraphics backend fills
    /// ``vectorFill`` (even-odd) instead of ``triangles`` and strokes ``vectorStroke`` instead of
    /// ``segments`` when they are present, so an arc reaches a PDF as Bézier curves. The Metal
    /// backend and the hit tester keep using the flattened instances.
    public var vectorStroke: [RenderCurvePath] = []
    public var vectorFill: [RenderCurvePath] = []
    /// Raster pictures (``RenderShape/image(_:)``, ADR-0043). The Core Graphics backend paints them
    /// in the fill pass, in painter's order with the fills; the hit tester treats each as the area
    /// it covers. The Metal backend uploads no instance for them.
    public var images: [CompiledImage] = []

    public init(
        id: MarkupID,
        revision: UInt64,
        zIndex: Int,
        segments: [CompiledSegment] = [],
        triangles: [CompiledTriangle] = [],
        symbols: [CompiledSymbol] = [],
        glyphs: [CompiledGlyph] = [],
        glyphBucket: Int? = nil,
        glyphFontName: String? = nil,
        bounds: PDFRect? = nil,
        paddingPagePoints: Double = 0,
        paddingDevicePixels: Double = 0,
        fillRejected: Bool = false,
        dashTruncated: Bool = false,
        symbolReachPagePoints: Double = 0,
        glyphReachPixels: Double = 0
    ) {
        self.id = id
        self.revision = revision
        self.zIndex = zIndex
        self.segments = segments
        self.triangles = triangles
        self.symbols = symbols
        self.glyphs = glyphs
        self.glyphBucket = glyphBucket
        self.glyphFontName = glyphFontName
        self.bounds = bounds
        self.paddingPagePoints = paddingPagePoints
        self.paddingDevicePixels = paddingDevicePixels
        self.fillRejected = fillRejected
        self.dashTruncated = dashTruncated
        self.symbolReachPagePoints = symbolReachPagePoints
        self.glyphReachPixels = glyphReachPixels
    }

    public var isEmpty: Bool {
        segments.isEmpty && triangles.isEmpty && symbols.isEmpty && glyphs.isEmpty && images.isEmpty
    }

    /// Approximate bytes this markup occupies in instance storage. Used for the memory report.
    public var instanceByteCount: Int {
        segments.count * MetalInstanceLayout.segmentStride
            + triangles.count * 3 * MetalInstanceLayout.triangleVertexStride
            + symbols.count * MetalInstanceLayout.symbolStride
            + glyphs.count * MetalInstanceLayout.glyphStride
    }
}
