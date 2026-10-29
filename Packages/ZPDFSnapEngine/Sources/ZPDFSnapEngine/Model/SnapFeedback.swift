import Foundation
import ZPDFContracts
import ZPDFGeometry

/// The geometry the UI draws next to the snap glyph (`SNAP_CONTRACT` 13.10).
///
/// It is geometry, not a drawing instruction: the engine knows the construction line, the view
/// layer knows how thick and what colour it is, and Reduced Motion is the view layer's business.
public enum SnapGuideGeometry: Sendable, Hashable, Codable {
    case none
    /// The edge, extension line or perpendicular that produced the snap.
    case segment(SegmentGeometry)
    /// A half-infinite construction line — an angle constraint or a parallel guide.
    case ray(origin: PDFPoint, direction: PDFVector)
    case circle(CircleGeometry)
    case arc(ArcGeometry)
    /// A bare marker at a point, for vertices, centres and intersections.
    case crosshair(PDFPoint)
}

/// Everything the UI needs to render the current snap (`SNAP_CONTRACT` 13.10).
public struct SnapFeedback: Sendable, Hashable, Codable {

    public let kind: SnapKind
    public let point: PDFPoint

    /// The primitive the user is being told they snapped to, so a reviewer can check that the
    /// highlighted source primitive matches what the user believes they snapped to.
    public let sourcePrimitive: SnapPrimitive?

    /// For an intersection, the second primitive that crossed.
    public let secondaryPrimitive: SnapPrimitive?

    public let guide: SnapGuideGeometry

    /// A stable, locale-independent key. The UI turns it into the label of `SNAP_CONTRACT` 13.10;
    /// the engine never produces user-facing prose.
    public let labelKey: String

    /// `true` when this snap is only alive because hysteresis is holding it (`SNAP_CONTRACT` 13.9),
    /// so the UI can render the held state distinctly instead of appearing to lag.
    public let isHeldByHysteresis: Bool

    public init(
        kind: SnapKind,
        point: PDFPoint,
        sourcePrimitive: SnapPrimitive?,
        secondaryPrimitive: SnapPrimitive?,
        guide: SnapGuideGeometry,
        isHeldByHysteresis: Bool
    ) {
        self.kind = kind
        self.point = point
        self.sourcePrimitive = sourcePrimitive
        self.secondaryPrimitive = secondaryPrimitive
        self.guide = guide
        self.labelKey = "snap.kind." + kind.rawValue
        self.isHeldByHysteresis = isHeldByHysteresis
    }
}
