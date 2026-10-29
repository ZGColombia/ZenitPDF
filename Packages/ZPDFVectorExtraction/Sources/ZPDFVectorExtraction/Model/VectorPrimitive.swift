import CoreGraphics
import Foundation

/// What a ``VectorPrimitive`` describes.
public enum VectorPrimitiveKind: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// One straight segment of a subpath.
    case lineSegment = 0
    /// One cubic Bézier segment of a subpath, stored as a curve.
    case cubicCurve = 1
    /// A whole subpath built by the `re` operator, as its four transformed corners.
    case rectangle = 2
    /// A whole closed subpath that is not a `re` rectangle.
    case closedSubpath = 3
}

/// How the path that produced a primitive was painted.
///
/// A path can be both stroked and filled (`B`, `b`, `B*`, `b*`), and a path that is
/// neither is not a primitive at all — it is discarded or clipping-only.
public struct VectorPaintRole: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let stroked = VectorPaintRole(rawValue: 1 << 0)
    public static let filled = VectorPaintRole(rawValue: 1 << 1)
    /// The path set the clip and was not painted. Only emitted when
    /// ``VectorExtractionOptions/emitsClipDerivedPrimitives`` is on.
    public static let clipDerived = VectorPaintRole(rawValue: 1 << 2)
}

/// Where a primitive sits relative to the clip in force when it was painted.
public enum VectorClipRelation: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// No clip was in force beyond the page box.
    case unclipped = 0
    /// The primitive's bounds lie entirely inside the clip bounds.
    case insideClip = 1
    /// The primitive's bounds cross the clip boundary. The primitive is kept: the clip
    /// is tracked as a bounding box, and a box test cannot prove which part survives.
    case partiallyClipped = 2
    /// The primitive's bounds do not meet the clip bounds at all. Such primitives are
    /// never emitted; the relation exists so a filter decision can name it.
    case outsideClip = 3
}

/// One piece of vector geometry in canonical page space.
///
/// Every field a snap candidate scorer needs is here, and nothing that would make the
/// value non-deterministic: no wall-clock time, no pointer identity, no hash of a
/// `Set`. Two extractions of the same document with the same options produce equal
/// primitives in the same order.
public struct VectorPrimitive: Sendable, Hashable, Codable, Identifiable {
    /// Stable within one extraction, and reproducible across extractions of the same
    /// document with the same options: identifiers are handed out by a counter in
    /// deterministic scan order.
    public let id: UInt64
    /// The subpath-level primitive this segment belongs to, when there is one.
    public let parentID: UInt64?
    /// `true` for an edge of a closed subpath whose subpath-level parent — a
    /// ``VectorPrimitiveKind/rectangle`` or ``VectorPrimitiveKind/closedSubpath`` — was
    /// emitted beside it, with the same paint and confidence. A consumer that compares or
    /// counts *shapes* takes the parent and skips these, or one closed shape counts 1 + N
    /// times (X-040). Open subpaths, and every subpath of an extraction made with
    /// ``VectorExtractionOptions/emitsShapePrimitives`` off, have no parent: their
    /// segments stand for themselves.
    public var isEdgeOfShape: Bool { parentID != nil }
    public let kind: VectorPrimitiveKind
    /// The fill colour's packed channels (``VectorColor/rgba``), meaningful when
    /// `colorPresence & 1`. The colours are stored as three small fields placed in alignment
    /// padding the layout already had — after the 1-byte ``kind``, after the 1-byte
    /// ``paint``, after the 1-byte ``clipRelation`` — so carrying them costs **no** stride:
    /// 232 bytes with or without colours, where two `Optional<VectorColor>` of four
    /// `Double`s made it 312 (BH-167 follow-up). `MemoryLayoutTests` pins it.
    private let fillBits: UInt32
    public let geometry: VectorGeometry
    public let bounds: VectorBounds
    /// The ordinal of the path-painting operator that produced this primitive, counted
    /// over the whole page in scan order including nested form XObjects. Two primitives
    /// with the same value came from the same painted path.
    public let sourceObjectID: UInt64
    /// Index of the subpath within its painted path, from zero.
    public let subpathIndex: Int
    /// Form XObject nesting depth: `0` for page content, `1` inside the first form.
    public let nestingDepth: Int
    public let paint: VectorPaintRole
    /// The stroke colour's packed channels, meaningful when `colorPresence & 2`.
    private let strokeBits: UInt32
    /// Stroke width in page points, with the CTM's scale applied. Zero for a fill-only
    /// path, and for the PDF "thinnest renderable line" width of `0`.
    public let strokeWidth: Double
    /// `true` when a non-empty dash array was in force. A dashed line is still a real
    /// edge, but a snap UI may want to say so.
    public let strokeIsDashed: Bool
    public let clipRelation: VectorClipRelation
    /// Bit 0: a fill colour is present. Bit 1: a stroke colour is present.
    private let colorPresence: UInt8
    /// The clip bounds in force when the path was painted, when there was a clip.
    public let clipBounds: VectorBounds?
    /// `0…1`. See ``VectorConfidence`` for the exact rule that produced it.
    public let confidence: Float
    /// The nearest enclosing marked-content layer name, when the content stream used
    /// `BDC` with an `/OC` tag.
    public let layerID: String?
    /// The fill colour in force when the path was painted, when the primitive is
    /// ``VectorPaintRole/filled`` and the colour space is one the extractor can state
    /// (see ``VectorColor`` for the rule and its limits). `nil` otherwise — including for
    /// a pattern or shading fill, which is never guessed.
    public var fillColor: VectorColor? { colorPresence & 1 == 0 ? nil : VectorColor(rgba: fillBits) }
    /// The stroke colour in force when the path was painted, when the primitive is
    /// ``VectorPaintRole/stroked``; the same rule as ``fillColor``.
    public var strokeColor: VectorColor? { colorPresence & 2 == 0 ? nil : VectorColor(rgba: strokeBits) }

    public init(
        id: UInt64,
        parentID: UInt64?,
        kind: VectorPrimitiveKind,
        geometry: VectorGeometry,
        bounds: VectorBounds,
        sourceObjectID: UInt64,
        subpathIndex: Int,
        nestingDepth: Int,
        paint: VectorPaintRole,
        strokeWidth: Double,
        strokeIsDashed: Bool,
        clipRelation: VectorClipRelation,
        clipBounds: VectorBounds?,
        confidence: Float,
        layerID: String?,
        fillColor: VectorColor? = nil,
        strokeColor: VectorColor? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.geometry = geometry
        self.bounds = bounds
        self.sourceObjectID = sourceObjectID
        self.subpathIndex = subpathIndex
        self.nestingDepth = nestingDepth
        self.paint = paint
        self.strokeWidth = strokeWidth
        self.strokeIsDashed = strokeIsDashed
        self.clipRelation = clipRelation
        self.clipBounds = clipBounds
        self.confidence = confidence
        self.layerID = layerID
        self.fillBits = fillColor?.rgba ?? 0
        self.strokeBits = strokeColor?.rgba ?? 0
        self.colorPresence = (fillColor == nil ? 0 : 1) | (strokeColor == nil ? 0 : 2)
    }
}

/// Coded exactly as the synthesised conformance coded the type when the colours were stored
/// properties: the same keys, optionals omitted when absent.
extension VectorPrimitive {
    private enum CodingKeys: String, CodingKey {
        case id, parentID, kind, geometry, bounds, sourceObjectID, subpathIndex, nestingDepth
        case paint, strokeWidth, strokeIsDashed, clipRelation, clipBounds, confidence, layerID
        case fillColor, strokeColor
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UInt64.self, forKey: .id),
            parentID: try c.decodeIfPresent(UInt64.self, forKey: .parentID),
            kind: try c.decode(VectorPrimitiveKind.self, forKey: .kind),
            geometry: try c.decode(VectorGeometry.self, forKey: .geometry),
            bounds: try c.decode(VectorBounds.self, forKey: .bounds),
            sourceObjectID: try c.decode(UInt64.self, forKey: .sourceObjectID),
            subpathIndex: try c.decode(Int.self, forKey: .subpathIndex),
            nestingDepth: try c.decode(Int.self, forKey: .nestingDepth),
            paint: try c.decode(VectorPaintRole.self, forKey: .paint),
            strokeWidth: try c.decode(Double.self, forKey: .strokeWidth),
            strokeIsDashed: try c.decode(Bool.self, forKey: .strokeIsDashed),
            clipRelation: try c.decode(VectorClipRelation.self, forKey: .clipRelation),
            clipBounds: try c.decodeIfPresent(VectorBounds.self, forKey: .clipBounds),
            confidence: try c.decode(Float.self, forKey: .confidence),
            layerID: try c.decodeIfPresent(String.self, forKey: .layerID),
            fillColor: try c.decodeIfPresent(VectorColor.self, forKey: .fillColor),
            strokeColor: try c.decodeIfPresent(VectorColor.self, forKey: .strokeColor)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(kind, forKey: .kind)
        try c.encode(geometry, forKey: .geometry)
        try c.encode(bounds, forKey: .bounds)
        try c.encode(sourceObjectID, forKey: .sourceObjectID)
        try c.encode(subpathIndex, forKey: .subpathIndex)
        try c.encode(nestingDepth, forKey: .nestingDepth)
        try c.encode(paint, forKey: .paint)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(strokeIsDashed, forKey: .strokeIsDashed)
        try c.encode(clipRelation, forKey: .clipRelation)
        try c.encodeIfPresent(clipBounds, forKey: .clipBounds)
        try c.encode(confidence, forKey: .confidence)
        try c.encodeIfPresent(layerID, forKey: .layerID)
        try c.encodeIfPresent(fillColor, forKey: .fillColor)
        try c.encodeIfPresent(strokeColor, forKey: .strokeColor)
    }
}

/// The confidence rule, written once so it is auditable rather than scattered.
///
/// Confidence is not a probability. It is a fixed ranking of how certain the extractor
/// is that the geometry it emitted is an edge a person drew and would want to snap to.
/// Every factor is multiplicative and every factor is documented:
///
/// | Factor | Value | Why |
/// |---|---|---|
/// | stroked path | `1.00` | A stroke is drawn linework: the highest possible certainty |
/// | fill-only path | `0.95` | The boundary is real, but it may be covered by later paint |
/// | clip-derived path | `0.50` | The path was never painted; it only bounded other paint |
/// | partially clipped | `× 0.90` | Part of the primitive is invisible and the box test cannot say which |
/// | inside a form XObject | `× 1.00` | Form geometry is ordinary geometry; depth changes nothing |
public enum VectorConfidence {
    public static let stroked: Float = 1.0
    public static let fillOnly: Float = 0.95
    public static let clipDerived: Float = 0.5
    public static let partiallyClippedFactor: Float = 0.9

    public static func value(paint: VectorPaintRole, clipRelation: VectorClipRelation) -> Float {
        var base: Float
        if paint.contains(.clipDerived) {
            base = clipDerived
        } else if paint.contains(.stroked) {
            base = stroked
        } else {
            base = fillOnly
        }
        if clipRelation == .partiallyClipped { base *= partiallyClippedFactor }
        return base
    }
}
