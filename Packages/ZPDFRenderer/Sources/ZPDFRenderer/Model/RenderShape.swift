import Foundation
import ZPDFContracts

/// An open or closed run of straight segments in page space.
///
/// Curves are already flattened by the time they reach the renderer: flattening is the document
/// layer's business and its tolerance is a document-layer decision, so nothing here re-derives it.
public struct RenderPolyline: Sendable, Hashable, Codable {
    public var points: [PDFPoint]
    /// When true the last point is joined back to the first.
    public var isClosed: Bool
    /// The same outline as lines and cubic Béziers, for a vector destination (NL-MEASURE-05,
    /// ADR-0030 §5.6): a measurement's arc edge is painted into a PDF as curves, not as the
    /// flattened ``points``, which remain what the GPU path, hit testing and bounds use. `nil`,
    /// the default, draws ``points``; the field is absent from the encoded form when `nil`.
    public var curve: RenderCurvePath?

    public init(points: [PDFPoint], isClosed: Bool = false, curve: RenderCurvePath? = nil) {
        self.points = points
        self.isClosed = isClosed
        self.curve = curve
    }

    /// Segment count after closure, `0` for fewer than two points.
    public var segmentCount: Int {
        guard points.count >= 2 else { return 0 }
        return isClosed ? points.count : points.count - 1
    }
}

/// A filled region: one outer contour and any number of hole contours.
///
/// Contour winding is **not** significant. The fill rule is even-odd, which is what PDF's `f*`
/// operator and every takeoff cutout mean, and which is the only rule that
/// gives the same answer for a hole regardless of the order its vertices happen to be stored in.
public struct RenderPolygon: Sendable, Hashable, Codable {
    public var outer: [PDFPoint]
    public var holes: [[PDFPoint]]
    /// The outer contour, then the holes, as lines and cubic Béziers for a vector destination
    /// (ADR-0030 §5.6) — see ``RenderPolyline/curve``. `nil` draws the flattened contours.
    public var curves: [RenderCurvePath]?

    public init(outer: [PDFPoint], holes: [[PDFPoint]] = [], curves: [RenderCurvePath]? = nil) {
        self.outer = outer
        self.holes = holes
        self.curves = curves
    }
}

/// One element of a ``RenderCurvePath``: a straight run to a point, or a cubic Bézier.
public enum RenderPathElement: Sendable, Hashable, Codable {
    case line(to: PDFPoint)
    case cubic(control1: PDFPoint, control2: PDFPoint, to: PDFPoint)
}

/// A contour as lines and cubic Béziers in page space, for painting only (ADR-0030 §5.6).
///
/// A circular arc has no exact cubic form; ``init(ring:tolerance:)`` cuts each arc into pieces of
/// at most a quarter turn, and into more until no piece strays more than `tolerance` page points
/// from the circle (``BulgeArc/cubicPieces(from:to:bulge:tolerance:)``). The tolerance governs
/// the drawing and nothing else: every quantity is measured from the bulge, exactly.
public struct RenderCurvePath: Sendable, Hashable, Codable {
    public var start: PDFPoint
    public var elements: [RenderPathElement]
    public var isClosed: Bool

    public init(start: PDFPoint, elements: [RenderPathElement], isClosed: Bool) {
        self.start = start
        self.elements = elements
        self.isClosed = isClosed
    }

    /// The contour of a ring or chain with arc edges: straight edges as lines, arcs as cubics.
    /// `nil` for a ring with fewer than two edges.
    public init?(ring: PolygonRing, tolerance: Double = BulgeArc.bezierDrawingTolerance) {
        let edges = ring.bulgedEdges
        guard let first = edges.first else { return nil }
        var elements: [RenderPathElement] = []
        for edge in edges {
            if edge.bulge != 0, BulgeArc.arc(from: edge.start, to: edge.end, bulge: edge.bulge) != nil {
                for piece in BulgeArc.cubicPieces(from: edge.start, to: edge.end, bulge: edge.bulge, tolerance: tolerance) {
                    elements.append(.cubic(control1: piece.control1, control2: piece.control2, to: piece.end))
                }
            } else {
                elements.append(.line(to: edge.end))
            }
        }
        self.init(start: first.start, elements: elements, isClosed: ring.isClosed)
    }

    /// Whether every coordinate is finite.
    public var isFinite: Bool {
        start.isFinite && elements.allSatisfy {
            switch $0 {
            case let .line(to): to.isFinite
            case let .cubic(c1, c2, to): c1.isFinite && c2.isFinite && to.isFinite
            }
        }
    }
}

/// The count-marker glyphs Zenit draws. Each maps to one tile of ``SymbolAtlas``.
public enum CountSymbol: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case filledCircle = 0
    case hollowCircle = 1
    case filledSquare = 2
    case hollowSquare = 3
    case filledTriangle = 4
    case hollowTriangle = 5
    case filledDiamond = 6
    case cross = 7
    case plus = 8
    case star = 9
}

/// One count marker: a symbol of a given size centred on a page point.
public struct RenderCountSymbol: Sendable, Hashable, Codable {
    public var center: PDFPoint
    public var symbol: CountSymbol
    /// Edge length of the symbol's square box, in page points.
    public var size: Double
    /// Rotation of the glyph about ``center``, in degrees, counter-clockwise on the page — the
    /// same convention imported artwork uses, so a built-in glyph and an imported mark placed
    /// with the same `MarkupSymbol.rotationDegrees` turn the same way. Non-finite is drawn as 0.
    public var rotationDegrees: Double

    public init(center: PDFPoint, symbol: CountSymbol, size: Double, rotationDegrees: Double = 0) {
        self.center = center
        self.symbol = symbol
        self.size = size
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case center, symbol, size, rotationDegrees
    }

    /// `rotationDegrees` is optional on the wire, so a scene encoded before the field existed
    /// still decodes as the unrotated glyph it was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decode(PDFPoint.self, forKey: .center)
        symbol = try container.decode(CountSymbol.self, forKey: .symbol)
        size = try container.decode(Double.self, forKey: .size)
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
    }
}

/// Where a text label sits relative to its anchor point.
public enum TextAnchor: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case topLeading = 0
    case topCenter = 1
    case topTrailing = 2
    case centerLeading = 3
    case center = 4
    case centerTrailing = 5
    case bottomLeading = 6
    case bottomCenter = 7
    case bottomTrailing = 8

    /// Fraction of the label's width to subtract from the anchor: 0 leading, 0.5 centred, 1 trailing.
    public var horizontalFraction: Double {
        switch self {
        case .topLeading, .centerLeading, .bottomLeading: 0.0
        case .topCenter, .center, .bottomCenter: 0.5
        case .topTrailing, .centerTrailing, .bottomTrailing: 1.0
        }
    }

    /// Fraction of the label's height to subtract from the anchor, measured downwards in pixels.
    public var verticalFraction: Double {
        switch self {
        case .topLeading, .topCenter, .topTrailing: 0.0
        case .centerLeading, .center, .centerTrailing: 0.5
        case .bottomLeading, .bottomCenter, .bottomTrailing: 1.0
        }
    }
}

/// A single-line text label anchored to a page point.
///
/// Labels are drawn **screen-upright**: they scale with zoom but never rotate with the page or
/// with the viewer rotation, because a takeoff label that is upside down on a 180-degree page is
/// a defect, not a feature. Both backends honour this identically.
///
/// The one exception is text that belongs to a turned object — a stamp's field text, which is
/// part of the seal and turns with it, as the canvas draws it. Such a label carries
/// ``rotationDegrees``: its baseline then runs along that direction **on the page**, and it turns
/// with the page and the view like geometry (T-065).
public struct RenderTextLabel: Sendable, Hashable, Codable {
    public var anchorPoint: PDFPoint
    public var text: String
    /// Font family name. Resolved once per atlas, never per label.
    public var fontName: String
    /// Font size in page points.
    public var fontSize: Double
    public var anchor: TextAnchor
    /// `nil`, the default, for a screen-upright label. Otherwise the direction of the text's
    /// baseline on the page, in degrees counter-clockwise from the page's +x axis; the text is
    /// laid out as usual and turned about ``anchorPoint``. Optional so a label without it encodes
    /// exactly as before.
    public var rotationDegrees: Double?

    public init(
        anchorPoint: PDFPoint,
        text: String,
        fontName: String = "Helvetica",
        fontSize: Double = 11,
        anchor: TextAnchor = .topLeading,
        rotationDegrees: Double? = nil
    ) {
        self.anchorPoint = anchorPoint
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.anchor = anchor
        self.rotationDegrees = rotationDegrees
    }
}

/// A committed length drawn in the drawing's own dimension grammar:
/// a shaft between the two measured points, an arrowhead at each end whose **tip is exactly the
/// measured point**, a perpendicular extension tick through each point, and the formatted value
/// in a rounded dark pill sitting on the line.
///
/// # What is geometry and what is decoration
///
/// `start` and `end` are the measured endpoints, in page points; they are the only geometry.
/// Every other length here is in **view points**, so arrowheads, ticks and the pill stay one
/// legible physical size at every zoom — exactly the policy selection handles use — while the
/// measured span keeps scaling with the page. Decoration that grew with the page would vanish
/// at 25 % zoom and swallow the drawing at 800 %; decoration that moved the tips would be a lie
/// about what was measured. Neither is allowed: the tips are the measured points, the arrow
/// bases are not.
public struct RenderDimensionLine: Sendable, Hashable, Codable {
    /// First measured endpoint. The tip of the first arrowhead, exactly.
    public var start: PDFPoint
    /// Second measured endpoint. The tip of the second arrowhead, exactly.
    public var end: PDFPoint
    /// The formatted value shown in the pill, for example `"14,72 m"`. Already localized;
    /// the renderer never formats numbers.
    public var label: String
    /// Font family for the pill text. Resolved once per atlas, never per label.
    public var fontName: String
    /// Pill text size in view points.
    public var fontSizeViewPoints: Double
    /// Arrowhead length from tip to base, in view points.
    public var arrowLengthViewPoints: Double
    /// Arrowhead half-width at the base, in view points.
    public var arrowHalfWidthViewPoints: Double
    /// Full length of the perpendicular extension tick through each endpoint, in view points.
    public var tickLengthViewPoints: Double
    /// Pill background colour, or `nil` for the default dark pill
    /// (``RenderShape/defaultPillFill``). The pill text uses the markup style's stroke colour.
    public var pillFill: RGBAColor?

    public init(
        start: PDFPoint,
        end: PDFPoint,
        label: String,
        fontName: String = "Helvetica",
        fontSizeViewPoints: Double = 10,
        arrowLengthViewPoints: Double = 9,
        arrowHalfWidthViewPoints: Double = 3.5,
        tickLengthViewPoints: Double = 9,
        pillFill: RGBAColor? = nil
    ) {
        self.start = start
        self.end = end
        self.label = label
        self.fontName = fontName
        self.fontSizeViewPoints = fontSizeViewPoints
        self.arrowLengthViewPoints = arrowLengthViewPoints
        self.arrowHalfWidthViewPoints = arrowHalfWidthViewPoints
        self.tickLengthViewPoints = tickLengthViewPoints
        self.pillFill = pillFill
    }
}

/// A value label in a rounded dark pill, anchored to a page point — the committed form of the
/// measurement caption: labels sit in rounded dark pills with cyan text so they stay legible
/// over both white paper and dark fills. An area markup puts one of
/// these inside its fill; the producer chooses the anchor, typically the polygon's centroid.
///
/// The pill is centred on the anchor and sized in view points, so it reads at every zoom. The
/// text colour is the markup style's stroke colour; the pill background is ``pillFill`` or the
/// default dark.
public struct RenderLabelPill: Sendable, Hashable, Codable {
    /// The pill's centre, in page points.
    public var anchorPoint: PDFPoint
    /// The formatted text, for example `"Area C: 21,34 m²"`. Already localized.
    public var text: String
    /// Font family for the pill text.
    public var fontName: String
    /// Text size in view points.
    public var fontSizeViewPoints: Double
    /// Pill background colour, or `nil` for the default dark pill.
    public var pillFill: RGBAColor?

    public init(
        anchorPoint: PDFPoint,
        text: String,
        fontName: String = "Helvetica",
        fontSizeViewPoints: Double = 10,
        pillFill: RGBAColor? = nil
    ) {
        self.anchorPoint = anchorPoint
        self.text = text
        self.fontName = fontName
        self.fontSizeViewPoints = fontSizeViewPoints
        self.pillFill = pillFill
    }
}

/// A raster picture placed on the page: an image inserted with Edit ▸ Insert Image (ADR-0043).
///
/// The picture's unit square is mapped onto a parallelogram in page space: its bottom-left corner
/// to ``origin``, its bottom-right to ``xEnd`` and its top-left to ``yEnd`` — the same unit mapping
/// the canvas draws the picture through (`CanvasStampPlacement.pagePoint(unit:)`), so it is
/// letterboxed, turned and mirrored on paper exactly as on screen.
///
/// The picture travels as its **encoded bytes** (``source``), the very bytes the project stores
/// beside the 96-cell mosaic, so a scene stays a self-contained `Codable` value and the renderer
/// decodes them once per compile, within the import's bounds (``RenderImagePixels``). This is the
/// one shape whose ink is a raster by nature, and the one exception the flatten path's "no image
/// XObject" guard allows.
public struct RenderImage: Sendable, Hashable, Codable {
    /// Where the picture's bottom-left corner lies, in page points.
    public var origin: PDFPoint
    /// Where its bottom-right corner lies.
    public var xEnd: PDFPoint
    /// Where its top-left corner lies.
    public var yEnd: PDFPoint
    /// The encoded picture: JPEG, PNG, TIFF or HEIC, as imported.
    public var source: Data
    /// The picture's opacity, 0…1; a non-finite value draws opaque.
    public var opacity: Double

    public init(origin: PDFPoint, xEnd: PDFPoint, yEnd: PDFPoint, source: Data, opacity: Double = 1) {
        self.origin = origin
        self.xEnd = xEnd
        self.yEnd = yEnd
        self.source = source
        self.opacity = opacity
    }

    /// The four corners in page space: bottom-left, bottom-right, top-right, top-left.
    public var corners: [PDFPoint] {
        let topRight = PDFPoint(x: xEnd.x + yEnd.x - origin.x, y: xEnd.y + yEnd.y - origin.y)
        return [origin, xEnd, topRight, yEnd]
    }
}

/// The things the renderer can draw. Every markup type reduces to these:
/// a cloud is a polyline, an arrowhead is a filled polygon, a stamp is a label plus a polygon.
/// The two measurement-grammar shapes — the dimension line and the label pill — are composites
/// the compiler expands into the same segment, triangle and glyph instances as everything else,
/// so both backends and the hit tester get them for free.
public enum RenderShape: Sendable, Hashable, Codable {
    case polyline(RenderPolyline)
    case filledPolygon(RenderPolygon)
    case countSymbol(RenderCountSymbol)
    case textLabel(RenderTextLabel)
    case dimensionLine(RenderDimensionLine)
    case labelPill(RenderLabelPill)
    /// A raster picture (ADR-0043). Painted by the Core Graphics backend — the backend of every
    /// paper and file destination; the Metal backend, which the product drives only for the
    /// vector underlay, compiles it to its bounds and hit area and paints no pixels.
    case image(RenderImage)

    /// The default pill background: dark, slightly translucent, per the visual reference's label pills.
    public static let defaultPillFill = RGBAColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 0.92)

    /// Whether the shape's compiled instances depend on the zoom level, so a zoom step must
    /// recompile it. Text is pixel-sized; the measurement grammar's decorations are view-sized.
    public var isZoomDependent: Bool {
        switch self {
        case .textLabel, .dimensionLine, .labelPill: return true
        case .polyline, .filledPolygon, .countSymbol, .image: return false
        }
    }
}
