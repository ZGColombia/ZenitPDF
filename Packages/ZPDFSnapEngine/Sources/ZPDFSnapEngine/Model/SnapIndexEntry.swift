import Foundation
import ZPDFContracts

/// Which of the three index layers an entry lives in.
///
/// The split is not cosmetic. The vector layer is expensive to produce and is cached by
/// document SHA, page and extractor version; the markup layer changes on every drag; the
/// boundary layer changes when a zone, scale region or guide is edited. Keeping them apart is
/// what makes "move a markup" cost O(markup count) instead of O(page primitive count).
public enum SnapLayerKind: Int, Sendable, Hashable, Codable, CaseIterable {
    case vector = 0
    case markup = 1
    case boundary = 2
}

/// One entry in a page's snap index: a frozen ``SnapPrimitive`` plus the provenance the scorer
/// and the feedback payload need.
public struct SnapIndexEntry: Sendable, Hashable, Codable {

    public let primitive: SnapPrimitive
    public let source: SnapGeometrySource

    /// The owning object's stable identity, as a string: a markup UUID, a zone UUID, a guide
    /// name. `nil` for PDF content, whose identity is `primitive.sourceObjectID`.
    ///
    /// Incremental updates address entries by this, never by array position.
    public let ownerID: String?

    /// Snap kinds this entry may produce, already resolved from its source. Precomputing it
    /// keeps the per-query hot loop free of source-to-kind branching.
    public let kindSet: SnapEntryKindSet

    public init(
        primitive: SnapPrimitive,
        source: SnapGeometrySource,
        ownerID: String?,
        kindSet: SnapEntryKindSet
    ) {
        self.primitive = primitive
        self.source = source
        self.ownerID = ownerID
        self.kindSet = kindSet
    }

    public var id: UInt64 { primitive.id }
    public var bounds: PDFRect { primitive.bounds }
}

/// The snap kinds one entry can produce, chosen by geometry source.
///
/// A vertex of a Zenit markup is a `markupVertex` (priority 0), the same vertex on a PDF path
/// is an `endpoint` (priority 3), and the same vertex on a zone outline is a `zoneBoundary`
/// (priority 12). One table, resolved once at index time.
public struct SnapEntryKindSet: Sendable, Hashable, Codable {
    public let vertex: SnapKind
    public let edgeMidpoint: SnapKind
    public let center: SnapKind
    public let onEdge: SnapKind
    public let quadrant: SnapKind
    public let tangent: SnapKind
    public let perpendicular: SnapKind
    public let intersection: SnapKind

    public init(
        vertex: SnapKind,
        edgeMidpoint: SnapKind,
        center: SnapKind,
        onEdge: SnapKind,
        quadrant: SnapKind,
        tangent: SnapKind,
        perpendicular: SnapKind,
        intersection: SnapKind
    ) {
        self.vertex = vertex
        self.edgeMidpoint = edgeMidpoint
        self.center = center
        self.onEdge = onEdge
        self.quadrant = quadrant
        self.tangent = tangent
        self.perpendicular = perpendicular
        self.intersection = intersection
    }

    /// PDF path and form content: the full vector vocabulary of `SNAP_CONTRACT` 13.1.
    public static let pdfVector = SnapEntryKindSet(
        vertex: .endpoint,
        edgeMidpoint: .midpoint,
        center: .center,
        onEdge: .nearestPointOnSegment,
        quadrant: .quadrant,
        tangent: .tangent,
        perpendicular: .perpendicularProjection,
        intersection: .intersection
    )

    /// A whole closed PDF subpath or rectangle, as opposed to one of its segments.
    ///
    /// Its vertices and corners are still endpoints, but "somewhere along this outline" is the
    /// generic `pdfVectorContent` (priority 13) rather than `nearestPointOnSegment`
    /// (priority 9), so the segment-level primitive wins when both describe the same edge and
    /// the shape-level one only contributes when nothing finer is in range.
    public static let pdfVectorShape = SnapEntryKindSet(
        vertex: .endpoint,
        edgeMidpoint: .midpoint,
        center: .center,
        onEdge: .pdfVectorContent,
        quadrant: .quadrant,
        tangent: .tangent,
        perpendicular: .perpendicularProjection,
        intersection: .intersection
    )

    /// The centre of a closed PDF subpath that contains curves.
    ///
    /// Such a subpath's outline lives in its child segments and curves, which are entries of
    /// their own; the ring itself is bridged as one `.point` — its centre — and contributes
    /// exactly that, so every slot maps to `.center` (CR-35).
    public static let pdfVectorCurvedShapeCentre = SnapEntryKindSet(
        vertex: .center,
        edgeMidpoint: .center,
        center: .center,
        onEdge: .center,
        quadrant: .center,
        tangent: .center,
        perpendicular: .center,
        intersection: .center
    )

    /// A Zenit markup. Every kind here has `requiresVectorContent == false`, so markup snap
    /// keeps working on a scanned page.
    public static let zenitMarkup = SnapEntryKindSet(
        vertex: .markupVertex,
        edgeMidpoint: .markupEdge,
        center: .markupCenter,
        onEdge: .markupEdge,
        quadrant: .markupCenter,
        tangent: .markupEdge,
        perpendicular: .markupEdge,
        intersection: .markupVertex
    )

    /// A quarter of a markup ellipse (``SnapMarkupGeometry/Role/smoothCurve``, ADR-0037). Its ends
    /// are the ellipse's quadrant points, not corners, so they are `markupCenter` — what a markup
    /// circle's quadrants are — and never the priority-0 `markupVertex`.
    public static let zenitMarkupSmoothCurve = SnapEntryKindSet(
        vertex: .markupCenter,
        edgeMidpoint: .markupEdge,
        center: .markupCenter,
        onEdge: .markupEdge,
        quadrant: .markupCenter,
        tangent: .markupEdge,
        perpendicular: .markupEdge,
        intersection: .markupVertex
    )

    /// A markup construction point with nothing drawn at it — an ellipse's centre
    /// (``SnapMarkupGeometry/Role/centre``): every slot is `markupCenter`, as a markup circle's
    /// centre is.
    public static let zenitMarkupCentre = SnapEntryKindSet(
        vertex: .markupCenter,
        edgeMidpoint: .markupCenter,
        center: .markupCenter,
        onEdge: .markupCenter,
        quadrant: .markupCenter,
        tangent: .markupCenter,
        perpendicular: .markupCenter,
        intersection: .markupCenter
    )

    /// A scale calibration point: priority 1, just behind an explicit markup vertex.
    public static let calibration = SnapEntryKindSet(
        vertex: .calibrationPoint,
        edgeMidpoint: .calibrationPoint,
        center: .calibrationPoint,
        onEdge: .calibrationPoint,
        quadrant: .calibrationPoint,
        tangent: .calibrationPoint,
        perpendicular: .calibrationPoint,
        intersection: .calibrationPoint
    )

    /// A zone or scale-region outline.
    public static let boundary = SnapEntryKindSet(
        vertex: .zoneBoundary,
        edgeMidpoint: .zoneBoundary,
        center: .zoneBoundary,
        onEdge: .zoneBoundary,
        quadrant: .zoneBoundary,
        tangent: .zoneBoundary,
        perpendicular: .zoneBoundary,
        intersection: .zoneBoundary
    )

    /// A temporary construction guide. The priority table has one kind for guide geometry —
    /// `parallelGuide`, priority 14 — and it works on scans.
    public static let temporaryGuide = SnapEntryKindSet(
        vertex: .parallelGuide,
        edgeMidpoint: .parallelGuide,
        center: .parallelGuide,
        onEdge: .parallelGuide,
        quadrant: .parallelGuide,
        tangent: .parallelGuide,
        perpendicular: .parallelGuide,
        intersection: .parallelGuide
    )
}
