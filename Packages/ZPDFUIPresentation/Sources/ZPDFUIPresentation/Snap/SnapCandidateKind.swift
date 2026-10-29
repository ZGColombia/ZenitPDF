import Foundation

/// The seventeen Vector Snap and markup-snap candidate types.
///
/// Every candidate is labelled in the snap glyph so that snapping is never a silent,
/// colour-only affordance.
public enum SnapCandidateKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// The end of a vector segment.
    case endpoint
    /// The midpoint of a vector segment.
    case midpoint
    /// The crossing of two vector segments.
    case intersection
    /// The closest point on a segment to the cursor.
    case nearestPointOnSegment
    /// The foot of a perpendicular dropped onto a segment.
    case perpendicularProjection
    /// A guide parallel to a reference segment.
    case parallelGuide
    /// The centre of a circle, arc or bounding box.
    case center
    /// A circle quadrant point at 0°, 90°, 180° or 270°.
    case quadrant
    /// A tangent point on a circle or arc.
    case tangent
    /// A grid intersection.
    case grid
    /// A fixed angular increment from the previous point.
    case angleIncrement
    /// A vertex of an existing Zenit markup.
    case markupVertex
    /// An edge of an existing Zenit markup.
    case markupEdge
    /// The centre of an existing Zenit markup.
    case markupCenter
    /// A point on a path extracted from the PDF's own vector content.
    case pdfVectorContent
    /// A point on a Project Zone or Scale Region boundary.
    case zoneBoundary
    /// A stored calibration point.
    case calibrationPoint

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the candidate comes from the PDF's own vector content rather than from
    /// Zenit markups or synthetic guides. Scanned pages have none of these.
    public var requiresVectorContent: Bool {
        switch self {
        case .endpoint, .midpoint, .intersection, .nearestPointOnSegment,
             .perpendicularProjection, .center, .quadrant, .tangent, .pdfVectorContent:
            return true
        case .parallelGuide, .grid, .angleIncrement, .markupVertex, .markupEdge,
             .markupCenter, .zoneBoundary, .calibrationPoint:
            return false
        }
    }

    /// A localized name shown next to the snap glyph and read by VoiceOver.
    public var displayName: String {
        switch self {
        case .endpoint: return NSLocalizedString("Endpoint", comment: "Vector Snap candidate type")
        case .midpoint: return NSLocalizedString("Midpoint", comment: "Vector Snap candidate type")
        case .intersection: return NSLocalizedString("Intersection", comment: "Vector Snap candidate type")
        case .nearestPointOnSegment: return NSLocalizedString("Nearest Point", comment: "Vector Snap candidate type")
        case .perpendicularProjection: return NSLocalizedString("Perpendicular", comment: "Vector Snap candidate type")
        case .parallelGuide: return NSLocalizedString("Parallel", comment: "Vector Snap candidate type")
        case .center: return NSLocalizedString("Center", comment: "Vector Snap candidate type")
        case .quadrant: return NSLocalizedString("Quadrant", comment: "Vector Snap candidate type")
        case .tangent: return NSLocalizedString("Tangent", comment: "Vector Snap candidate type")
        case .grid: return NSLocalizedString("Grid", comment: "Vector Snap candidate type")
        case .angleIncrement: return NSLocalizedString("Angle Increment", comment: "Vector Snap candidate type")
        case .markupVertex: return NSLocalizedString("Markup Vertex", comment: "Vector Snap candidate type")
        case .markupEdge: return NSLocalizedString("Markup Edge", comment: "Vector Snap candidate type")
        case .markupCenter: return NSLocalizedString("Markup Center", comment: "Vector Snap candidate type")
        case .pdfVectorContent: return NSLocalizedString("Drawing Geometry", comment: "Vector Snap candidate type")
        case .zoneBoundary: return NSLocalizedString("Zone Boundary", comment: "Vector Snap candidate type")
        case .calibrationPoint: return NSLocalizedString("Calibration Point", comment: "Vector Snap candidate type")
        }
    }

    /// SF Symbol name for the snap glyph, distinct per kind so shape carries meaning.
    public var symbolName: String {
        switch self {
        case .endpoint: return "square"
        case .midpoint: return "triangle"
        case .intersection: return "xmark"
        case .nearestPointOnSegment: return "circle"
        case .perpendicularProjection: return "perspective"
        case .parallelGuide: return "equal"
        case .center: return "circle.circle"
        case .quadrant: return "diamond"
        case .tangent: return "circle.and.line.horizontal"
        case .grid: return "grid"
        case .angleIncrement: return "angle"
        case .markupVertex: return "square.dashed"
        case .markupEdge: return "line.diagonal"
        case .markupCenter: return "dot.circle"
        case .pdfVectorContent: return "scribble.variable"
        case .zoneBoundary: return "pentagon"
        case .calibrationPoint: return "ruler"
        }
    }
}

/// The guide the snap engine wants drawn alongside the snap glyph.
///
/// The hint is the *reason* a point was chosen, in words, so that a user who cannot see
/// the guide line still understands the snap.
public struct SnapGuideHint: Codable, Hashable, Sendable {

    /// Localized explanation, for example `"Parallel to grid line 3"`.
    public var text: String
    /// Start of the guide line in page space, if a line should be drawn.
    public var start: PDFPointValue?
    /// End of the guide line in page space, if a line should be drawn.
    public var end: PDFPointValue?
    /// The constrained angle in degrees, when the hint comes from an angle increment.
    public var angleDegrees: Double?

    /// Creates a guide hint.
    public init(
        text: String,
        start: PDFPointValue? = nil,
        end: PDFPointValue? = nil,
        angleDegrees: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.angleDegrees = angleDegrees
    }
}

/// What the canvas should draw for the currently winning snap candidate.
///
/// `nil` at the presenter level means "no candidate", which the canvas renders as an
/// unmodified crosshair. Reduce Motion turns the glyph's pulse into a static state; the
/// snapshot itself never animates.
public struct SnapFeedbackSnapshot: Codable, Hashable, Sendable {

    /// Which kind of candidate won.
    public var kind: SnapCandidateKind
    /// The snapped position in page space.
    public var pagePoint: PDFPointValue
    /// Localized description of the source primitive, for example `"Wall centreline"`.
    public var sourceLabel: String
    /// The guide to draw, if the candidate implies one.
    public var guideHint: SnapGuideHint?
    /// Page the candidate belongs to.
    public var pageID: PageDescriptor.ID
    /// Normalised candidate score, `0...1`. Used only to fade competing glyphs.
    public var confidence: Double

    /// Creates a snap feedback snapshot.
    public init(
        kind: SnapCandidateKind,
        pagePoint: PDFPointValue,
        sourceLabel: String,
        guideHint: SnapGuideHint? = nil,
        pageID: PageDescriptor.ID,
        confidence: Double = 1
    ) {
        self.kind = kind
        self.pagePoint = pagePoint
        self.sourceLabel = sourceLabel
        self.guideHint = guideHint
        self.pageID = pageID
        self.confidence = min(1, max(0, confidence))
    }

    /// A localized announcement such as `"Snapped to endpoint, wall centreline"`.
    public var accessibilityAnnouncement: String {
        let base = String(
            format: NSLocalizedString(
                "Snapped to %1$@, %2$@",
                comment: "VoiceOver announcement when the cursor snaps: candidate type, source description"
            ),
            kind.displayName,
            sourceLabel
        )
        guard let hint = guideHint, !hint.text.isEmpty else { return base }
        return base + ". " + hint.text
    }
}
