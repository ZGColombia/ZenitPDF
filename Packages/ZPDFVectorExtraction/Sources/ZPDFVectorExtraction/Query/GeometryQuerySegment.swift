import CoreGraphics
import Foundation

/// One straight segment of a page, in canonical page space, ready to be queried.
///
/// A segment is derived from a ``VectorPrimitive`` of kind
/// ``VectorPrimitiveKind/lineSegment``. Subpath-level primitives — rectangles and closed
/// subpaths — are deliberately **not** turned into segments: the extractor already emits
/// every edge of a closed subpath as its own `.lineSegment` child (see the emission rule
/// in the scanner, where a `re` becomes four `VectorLine` segments plus one parent), so
/// reading edges off the parent as well would count every wall twice.
///
/// A segment carries no quantity. It is an identifier and two endpoints — the raw
/// material for a highlight, never for a measurement.
public struct GeometryQuerySegment: Sendable, Hashable {
    /// The ``VectorPrimitive/id`` this segment came from.
    public let primitiveID: UInt64
    /// The subpath-level primitive this segment belongs to, when there is one.
    public let parentID: UInt64?
    /// ``VectorPrimitive/sourceObjectID``: two segments sharing it came from one painted path.
    public let sourceObjectID: UInt64
    public let start: CGPoint
    public let end: CGPoint
    /// Stroke width in page points. Zero for a fill-only path.
    public let strokeWidth: Double
    /// ``VectorPrimitive/confidence``, carried through so a caller can rank highlights.
    public let confidence: Float
    /// The nearest enclosing marked-content layer name, when the page had one.
    public let layerID: String?

    public init(
        primitiveID: UInt64,
        parentID: UInt64? = nil,
        sourceObjectID: UInt64 = 0,
        start: CGPoint,
        end: CGPoint,
        strokeWidth: Double = 0,
        confidence: Float = 1,
        layerID: String? = nil
    ) {
        self.primitiveID = primitiveID
        self.parentID = parentID
        self.sourceObjectID = sourceObjectID
        self.start = start
        self.end = end
        self.strokeWidth = strokeWidth
        self.confidence = confidence
        self.layerID = layerID
    }

    /// The segment behind a primitive, or `nil` when the primitive is not a usable
    /// straight segment: a curve, a subpath-level shape, or a zero-length line.
    public init?(primitive: VectorPrimitive) {
        guard primitive.kind == .lineSegment, case let .line(line) = primitive.geometry else {
            return nil
        }
        guard !line.isDegenerate, line.length > 0 else { return nil }
        guard line.start.x.isFinite, line.start.y.isFinite,
              line.end.x.isFinite, line.end.y.isFinite else { return nil }
        self.init(
            primitiveID: primitive.id,
            parentID: primitive.parentID,
            sourceObjectID: primitive.sourceObjectID,
            start: line.start,
            end: line.end,
            strokeWidth: primitive.strokeWidth,
            confidence: primitive.confidence,
            layerID: primitive.layerID
        )
    }

    public var length: Double { (end - start).magnitude }
    public var midpoint: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
    public var bounds: VectorBounds { VectorBounds(point: start).union(end) }
    public var line: VectorLine { VectorLine(start: start, end: end) }

    /// The direction of the **undirected** line, in radians normalised to `[0, π)`.
    ///
    /// Undirected on purpose: a wall drawn left-to-right and the wall opposite it drawn
    /// right-to-left are parallel, and a query that compared directed headings would
    /// miss every such pair.
    public var lineAngle: Double {
        GeometryQueryMath.normalisedLineAngle(dx: end.x - start.x, dy: end.y - start.y)
    }
}

/// One cubic Bézier of a page, kept so the circle query has something to fit.
///
/// The extraction model has **no arc or circle primitive**: ``VectorPrimitiveKind`` is
/// `lineSegment`, `cubicCurve`, `rectangle` and `closedSubpath`, and a PDF circle reaches
/// this package as the four-cubic approximation the producer drew. The circle query
/// therefore fits circles to chains of these, and says how far the drawn geometry sat
/// from the circle it reports.
public struct GeometryQueryCurve: Sendable, Hashable {
    public let primitiveID: UInt64
    public let parentID: UInt64?
    public let sourceObjectID: UInt64
    public let subpathIndex: Int
    public let nestingDepth: Int
    public let cubic: VectorCubic
    public let layerID: String?

    public init(
        primitiveID: UInt64,
        parentID: UInt64? = nil,
        sourceObjectID: UInt64 = 0,
        subpathIndex: Int = 0,
        nestingDepth: Int = 0,
        cubic: VectorCubic,
        layerID: String? = nil
    ) {
        self.primitiveID = primitiveID
        self.parentID = parentID
        self.sourceObjectID = sourceObjectID
        self.subpathIndex = subpathIndex
        self.nestingDepth = nestingDepth
        self.cubic = cubic
        self.layerID = layerID
    }

    /// The curve behind a primitive, or `nil` when the primitive is not a cubic.
    public init?(primitive: VectorPrimitive) {
        guard primitive.kind == .cubicCurve, case let .cubic(cubic) = primitive.geometry else {
            return nil
        }
        self.init(
            primitiveID: primitive.id,
            parentID: primitive.parentID,
            sourceObjectID: primitive.sourceObjectID,
            subpathIndex: primitive.subpathIndex,
            nestingDepth: primitive.nestingDepth,
            cubic: cubic,
            layerID: primitive.layerID
        )
    }
}

/// The small pieces of trigonometry the queries share, written once so the rule that
/// governs a match is auditable in one place.
enum GeometryQueryMath {
    /// `atan2` folded onto `[0, π)`: the orientation of a line, not of a heading.
    static func normalisedLineAngle(dx: Double, dy: Double) -> Double {
        var angle = atan2(dy, dx)
        if angle < 0 { angle += .pi }
        if angle >= .pi { angle -= .pi }
        if !angle.isFinite { return 0 }
        return angle
    }

    /// The smaller of the two angles between two undirected lines, in `[0, π/2]`.
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b)
        return Swift.min(raw, .pi - raw)
    }
}
