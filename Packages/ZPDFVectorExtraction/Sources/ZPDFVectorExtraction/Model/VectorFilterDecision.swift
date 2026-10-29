import CoreGraphics
import Foundation

/// Why a path that the content stream painted did not become a snap primitive.
public enum VectorFilterRule: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// `W`/`W*` followed by `n`: the path set the clip and painted nothing.
    case clippingOnly = 0
    /// `n` without a pending clip: the path was built and thrown away.
    case discardedWithoutPainting = 1
    /// Constant alpha `0` for the paint that would have shown the path.
    case invisiblePaint = 2
    /// A rectangle-like closed subpath covering at least
    /// ``VectorBackgroundFilter/minimumCropBoxAreaFraction`` of the crop box, filled and
    /// not stroked.
    case pageSizedBackground = 3
    /// The path's bounds strictly enclose the crop box on every side: a full-bleed
    /// backdrop rather than drawing content.
    case enclosesCropBox = 4
    /// The path's bounds do not meet the crop box at all.
    case entirelyOutsideCropBox = 5
    /// The path's bounds do not meet the clip in force.
    case entirelyOutsideClip = 6
    /// The path lay inside an optional-content group that is switched off.
    case hiddenOptionalContent = 7
    /// A subpath with fewer than two distinct points, or a zero-length segment.
    case degenerateGeometry = 8
    /// The primitive budget was already spent when this path was painted.
    case primitiveBudgetExhausted = 9

    /// A short, stable, human-readable explanation. Not localized: this is diagnostic
    /// text for a decision log, not UI copy.
    public var explanation: String {
        switch self {
        case .clippingOnly: return "path only set the clip and was never painted"
        case .discardedWithoutPainting: return "path was built and discarded by `n` with no clip pending"
        case .invisiblePaint: return "constant alpha was 0 for the paint that would have shown the path"
        case .pageSizedBackground: return "filled rectangle covering the page: background, not drawing content"
        case .enclosesCropBox: return "path bounds strictly enclose the crop box on every side"
        case .entirelyOutsideCropBox: return "path bounds do not meet the crop box"
        case .entirelyOutsideClip: return "path bounds do not meet the clip in force"
        case .hiddenOptionalContent: return "path is inside an optional-content group that is switched off"
        case .degenerateGeometry: return "subpath has no extent"
        case .primitiveBudgetExhausted: return "the primitive budget was already spent"
        }
    }
}

/// One recorded filtering decision.
///
/// `QUALITY_BAR` 3.6 requires the filter decision to be recorded per primitive so that a
/// false filter is debuggable rather than invisible: the rule that fired, the numbers it
/// fired on, and where the discarded geometry was. Nothing a user could plausibly want
/// to snap to is dropped without one of these.
public struct VectorFilterDecision: Sendable, Hashable, Codable {
    public let rule: VectorFilterRule
    public let sourceObjectID: UInt64
    public let subpathIndex: Int
    public let nestingDepth: Int
    public let bounds: VectorBounds
    /// The measured quantity the rule compared, when the rule has one — the fraction of
    /// the crop box the path covered, for instance.
    public let measuredValue: Double?
    /// The configured threshold the rule compared against, when the rule has one.
    public let threshold: Double?

    public init(
        rule: VectorFilterRule,
        sourceObjectID: UInt64,
        subpathIndex: Int,
        nestingDepth: Int,
        bounds: VectorBounds,
        measuredValue: Double? = nil,
        threshold: Double? = nil
    ) {
        self.rule = rule
        self.sourceObjectID = sourceObjectID
        self.subpathIndex = subpathIndex
        self.nestingDepth = nestingDepth
        self.bounds = bounds
        self.measuredValue = measuredValue
        self.threshold = threshold
    }
}
